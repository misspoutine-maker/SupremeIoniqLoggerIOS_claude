@preconcurrency import CoreBluetooth
import Foundation

/// Lecteur OBD2 BLE (Veepeak OBDCheck BLE, vLinker MC+, clones ELM327).
/// Séquence et index repris de la version Android v30 (validés sur la voiture).
@MainActor
final class ObdBle: NSObject, ObservableObject {
    // bytes[] inclut l'écho "62 01 01"
    static let socIdx = 7        // e/2 : SOC BMS (220101)
    static let tempMaxIdx = 17   // Signed(O)
    static let tempMinIdx = 18   // Signed(P)
    static let dispSocIdx = 34   // af/2 : SOC tableau de bord (220105)
    static let curHi = 13, curLo = 14, voltHi = 15, voltLo = 16

    private static let known: [(CBUUID, CBUUID, CBUUID)] = [
        (CBUUID(string: "FFF0"), CBUUID(string: "FFF1"), CBUUID(string: "FFF2")),   // Veepeak, vLinker, clones
        (CBUUID(string: "18F0"), CBUUID(string: "2AF0"), CBUUID(string: "2AF1")),   // Vgate iCar Pro / OBDLink
        (CBUUID(string: "FFE0"), CBUUID(string: "FFE1"), CBUUID(string: "FFE1")),   // HM-10
        (CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
         CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
         CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"))                    // Nordic UART
    ]
    private static let nameHints = ["veepeak", "obd", "vlink", "vgate", "icar", "elm", "mc+"]

    @Published var state = "Disconnected"
    @Published var soc: Double?
    @Published var socBms: Double?
    @Published var battTempMax: Int?
    @Published var battTempMin: Int?
    @Published var lastData: Date?
    @Published var current: Double?
    @Published var voltage: Double?
    @Published var powerKw: Double?
    @Published var chargeAvgKw: Double?
    @Published var chargeMaxKw: Double?
    @Published var chargeEnergyKwh = 0.0
    @Published var dischargeEnergyKwh = 0.0
    @Published var isCharging = false
    @Published var log: [String] = []

    var moving = false   // fourni par le GPS

    private var chargeSamples = 0
    private var chargeSumKw = 0.0
    private var chargeMax = 0.0
    private var lastEnergyTs: Date?
    private var haveDisplaySoc = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var buf = ""
    private var pending: CheckedContinuation<String, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var wantConnect = false
    private var scanning = false
    private var scanRequested = false
    private var pendingServices = 0
    private var sessionStarted = false

    func resetDischargeEnergy() { dischargeEnergyKwh = 0 }

    private func addLog(_ s: String) { log = Array((log + [s]).suffix(60)) }

    func isActive() -> Bool {
        state == "Connected" || state.hasPrefix("Scanning") || state.hasPrefix("Connecting")
            || state.hasPrefix("Initializing") || state.hasPrefix("Reconnecting")
    }

    // MARK: connexion

    func connect() {
        disconnect()
        log = []
        wantConnect = true
        scanRequested = true
        state = "Scanning…"
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)   // l'état déclenche la recherche
        } else if central?.state == .poweredOn {
            startScan()
        }
    }

    func disconnect() {
        wantConnect = false
        scanRequested = false
        stopScan()
        sessionTask?.cancel(); sessionTask = nil
        resolve("TIMEOUT")
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; tx = nil; sessionStarted = false
        state = "Disconnected"
    }

    private func startScan() {
        guard let c = central, c.state == .poweredOn, scanRequested else { return }
        scanRequested = false
        scanning = true
        c.scanForPeripherals(withServices: nil, options: nil)
        scanTimeout?.cancel()
        scanTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, !Task.isCancelled, self.scanning else { return }
            self.stopScan()
            self.state = "No adapter found (see log)"
        }
    }

    private func stopScan() {
        scanTimeout?.cancel(); scanTimeout = nil
        if scanning { central?.stopScan() }
        scanning = false
    }

    private var seen = Set<String>()

    fileprivate func onDiscover(_ p: CBPeripheral, name: String?) {
        guard scanning, let n = name else { return }
        if seen.insert(n).inserted { addLog("BLE seen: \(n)") }
        if Self.nameHints.contains(where: { n.lowercased().contains($0) }) {
            stopScan()
            state = "Connecting to \(n)…"
            peripheral = p
            p.delegate = self
            central?.connect(p, options: nil)
        }
    }

    fileprivate func onCentralState(_ s: CBManagerState) {
        switch s {
        case .poweredOn: if scanRequested { startScan() }
        case .poweredOff: if wantConnect { state = "Bluetooth is off" }
        case .unauthorized: state = "Bluetooth permission denied (Settings)"
        case .unsupported: state = "Bluetooth LE not supported"
        default: break
        }
    }

    fileprivate func onConnected(_ p: CBPeripheral) {
        addLog("connected")
        sessionStarted = false
        p.discoverServices(nil)
    }

    fileprivate func onDisconnected() {
        sessionTask?.cancel(); sessionTask = nil
        resolve("TIMEOUT")
        tx = nil; sessionStarted = false
        if wantConnect, let p = peripheral {
            state = "Reconnecting…"
            central?.connect(p, options: nil)   // reste en attente, reprend dès que l'adaptateur revient
        } else {
            state = "Disconnected"
        }
    }

    fileprivate func onServices(_ p: CBPeripheral) {
        let services = p.services ?? []
        pendingServices = services.count
        if services.isEmpty { state = "No usable OBD service"; return }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    fileprivate func onCharacteristics(_ p: CBPeripheral) {
        pendingServices -= 1
        if pendingServices > 0 { return }
        func isNotify(_ c: CBCharacteristic) -> Bool { !c.properties.intersection([.notify, .indicate]).isEmpty }
        func isWrite(_ c: CBCharacteristic) -> Bool { !c.properties.intersection([.write, .writeWithoutResponse]).isEmpty }
        let services = p.services ?? []
        var notif: CBCharacteristic?
        var write: CBCharacteristic?
        // 1) profils connus
        for (sUuid, nUuid, wUuid) in Self.known {
            guard let svc = services.first(where: { $0.uuid == sUuid }) else { continue }
            let n = svc.characteristics?.first(where: { $0.uuid == nUuid })
            let w = svc.characteristics?.first(where: { $0.uuid == wUuid })
            if let n, let w, isNotify(n), isWrite(w) { notif = n; write = w; break }
        }
        // 2) détection générique
        if notif == nil {
            for svc in services {
                let id = svc.uuid.uuidString
                if id == "1800" || id == "1801" || id == "180A" { continue }
                let n = svc.characteristics?.first(where: { isNotify($0) })
                let w = svc.characteristics?.first(where: { isWrite($0) })
                if let n, let w { notif = n; write = w; break }
            }
        }
        guard let notif, let write else {
            state = "No usable OBD service"
            for s in services {
                addLog("SVC \(s.uuid.uuidString): " + (s.characteristics ?? []).map { "\($0.uuid.uuidString)/p\($0.properties.rawValue)" }.joined(separator: ", "))
            }
            return
        }
        tx = write
        writeType = write.properties.contains(.write) ? .withResponse : .withoutResponse
        addLog("write=\(write.uuid.uuidString)/p\(write.properties.rawValue) notify=\(notif.uuid.uuidString)/p\(notif.properties.rawValue)")
        p.setNotifyValue(true, for: notif)
    }

    fileprivate func onNotifyState(_ p: CBPeripheral) {
        addLog("notifications enabled")
        if !sessionStarted { sessionStarted = true; startSession() }
    }

    fileprivate func onRx(_ data: Data) {
        buf += String(decoding: data, as: UTF8.self)
        if buf.contains(">") {
            let r = buf
            buf = ""
            resolve(r)
        }
    }

    // MARK: échanges ELM

    private func resolve(_ s: String) {
        if let c = pending { pending = nil; c.resume(returning: s) }
    }

    private func send(_ cmd: String) async -> String {
        guard let p = peripheral, let c = tx else { return "TIMEOUT" }
        buf = ""
        let r: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pending = cont
            p.writeValue(Data((cmd + "\r").utf8), for: c, type: writeType)
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { self?.resolve("TIMEOUT") }
            }
        }
        timeoutTask?.cancel(); timeoutTask = nil
        addLog("\(cmd) → " + r.replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        return r
    }

    private func startSession() {
        sessionTask?.cancel()
        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = "Initializing ELM…"
            try? await Task.sleep(nanoseconds: 500_000_000)
            let canBoth = (self.tx?.properties.contains(.write) ?? false) && (self.tx?.properties.contains(.writeWithoutResponse) ?? false)
            if await self.send("ATZ") == "TIMEOUT" && canBoth {
                self.writeType = (self.writeType == .withResponse) ? .withoutResponse : .withResponse
                self.addLog("ATZ timeout: retry with the other write type")
                _ = await self.send("ATZ")
            }
            for c in ["ATE0", "ATL0", "ATS0", "ATH0", "ATCAF1", "ATCFC1", "ATSP6", "ATSH7E4"] {
                _ = await self.send(c)
            }
            if Task.isCancelled { return }
            self.state = "Connected"
            while !Task.isCancelled {
                self.parse101(await self.send("220101"))
                self.parse105(await self.send("220105"))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: décodage

    private func toBytes(_ r: String) -> [Int] {
        var out: [Int] = []
        for raw in r.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            let line = raw.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            let chars = Array(line)
            guard chars.count >= 2, chars[0].isHexDigit, chars[1] == ":" else { continue }
            let hex = String(line.dropFirst(2)).replacingOccurrences(of: " ", with: "")
            var i = hex.startIndex
            while hex.distance(from: i, to: hex.endIndex) >= 2 {
                let j = hex.index(i, offsetBy: 2)
                if let v = Int(hex[i..<j], radix: 16) { out.append(v) }
                i = j
            }
        }
        return out
    }

    /// 220105 : SOC affiché au tableau de bord.
    private func parse105(_ r: String) {
        let b = toBytes(r)
        if b.count > Self.dispSocIdx, b[0] == 0x62, b[1] == 0x01, b[2] == 0x05 {
            soc = Double(b[Self.dispSocIdx]) / 2.0
            haveDisplaySoc = true
        }
    }

    /// 220101 : SOC BMS, courant, tension, températures → puissance, énergie.
    private func parse101(_ r: String) {
        let b = toBytes(r)
        guard b.count > Self.tempMinIdx, b[0] == 0x62, b[1] == 0x01, b[2] == 0x01 else { return }
        let bms = Double(b[Self.socIdx]) / 2.0
        socBms = bms
        func signed8(_ v: Int) -> Int { v > 127 ? v - 256 : v }
        let tMax = signed8(b[Self.tempMaxIdx]), tMin = signed8(b[Self.tempMinIdx])
        if (-40...80).contains(tMax) && (-40...80).contains(tMin) { battTempMax = tMax; battTempMin = tMin }
        if !haveDisplaySoc { soc = bms }
        let rawCur = (b[Self.curHi] << 8) | b[Self.curLo]
        let signedCur = rawCur >= 32768 ? rawCur - 65536 : rawCur
        let amps = Double(signedCur) / 10.0
        let volts = Double((b[Self.voltHi] << 8) + b[Self.voltLo]) / 10.0
        current = amps
        voltage = volts
        let kw = amps * volts / 1000.0
        powerKw = kw

        let now = Date()
        lastData = now
        let dtHours = lastEnergyTs.map { now.timeIntervalSince($0) / 3600.0 } ?? 0.0
        lastEnergyTs = now

        // Négatif = recharge, mais aussi régénération en roulant : recharge seulement à l'arrêt.
        let charging = kw < -0.5 && !moving
        if charging && !isCharging {
            chargeEnergyKwh = 0
            chargeAvgKw = nil; chargeMaxKw = nil
        }
        if charging {
            let absKw = -kw
            chargeSamples += 1; chargeSumKw += absKw
            if absKw > chargeMax { chargeMax = absKw }
            chargeAvgKw = chargeSumKw / Double(chargeSamples)
            chargeMaxKw = chargeMax
            chargeEnergyKwh += absKw * dtHours
        } else if isCharging {
            chargeSamples = 0; chargeSumKw = 0; chargeMax = 0
        }
        // Consommation nette : régénération déduite en roulant ; à l'arrêt seule la consommation compte.
        if moving { dischargeEnergyKwh += kw * dtHours }
        else if kw > 0 { dischargeEnergyKwh += kw * dtHours }
        isCharging = charging
    }
}

// MARK: délégués CoreBluetooth (appelés sur la file principale)

extension ObdBle: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        Task { @MainActor in self.onCentralState(s) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        Task { @MainActor in self.onDiscover(peripheral, name: name) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in self.onConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.onDisconnected() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.onDisconnected() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in self.onServices(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in self.onCharacteristics(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in self.onNotifyState(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in self.onRx(data) }
    }
}
