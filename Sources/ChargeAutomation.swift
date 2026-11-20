import Foundation
import UserNotifications

/// Recharges automatiques : démarre une étape Charge quand l'OBD détecte une recharge (voiture à l'arrêt),
/// la termine après ~1 min sans puissance, cherche la borne (Open Charge Map), puis notifie pour le coût.
/// Pendant un voyage l'étape appartient au voyage ; sinon c'est une recharge hors voyage.
@MainActor
final class ChargeAutomation: ObservableObject {
    private static let startAfter: TimeInterval = 20   // recharge continue avant de créer l'étape
    private static let endAfter: TimeInterval = 60     // pas de puissance = recharge terminée
    private static let staleData: TimeInterval = 120   // OBD muet pendant une recharge auto = fin

    /// Recharge auto qui vient de se terminer : l'écran propose aussitôt d'entrer le coût.
    @Published var pendingCost: Stage?

    private var obd: ObdBle?
    private var gps: LocationTracker?
    private var trips: TripManager?
    private var started = false
    private var loop: Task<Void, Never>?

    private var chargingSince: Date?
    private var lastCharging = Date.distantPast
    private var lastChargingKm = 0.0
    private var autoStart: Int64 = 0          // 0 = aucune recharge automatique en cours
    private var stationName: String?
    private var stationCity: String?

    func start(obd: ObdBle, gps: LocationTracker, trips: TripManager) {
        guard !started else { return }
        started = true
        self.obd = obd; self.gps = gps; self.trips = trips
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let obd, let gps, let trips else { return }
        let now = Date()
        let charging = obd.isCharging
        if charging {
            if chargingSince == nil { chargingSince = now }
            lastCharging = now
            lastChargingKm = gps.totalDistanceKm
            if autoStart == 0, trips.activeStage == nil, let since = chargingSince,
               now.timeIntervalSince(since) >= Self.startAfter {
                beginAuto(since: since)
            }
        } else {
            chargingSince = nil
        }

        if autoStart != 0 {
            let st = trips.activeStage
            if st == nil || st!.startTime != autoStart || st!.type != .charge {
                autoStart = 0   // l'utilisateur a repris la main (fin manuelle ou repas ajouté)
            } else {
                let stale = obd.lastData.map { now.timeIntervalSince($0) > Self.staleData } ?? false
                if (!charging && now.timeIntervalSince(lastCharging) >= Self.endAfter) || stale { finishAuto() }
            }
        }
    }

    private func beginAuto(since: Date) {
        guard let obd, let gps, let trips else { return }
        let startMs = Int64(since.timeIntervalSince1970 * 1000)
        if trips.activeVoyage != nil {
            trips.startStage(.charge, kmNow: gps.totalDistanceKm, soc: obd.soc, startTimeMs: startMs)
        } else {
            trips.startStandaloneCharge(soc: obd.soc, startTimeMs: startMs)
        }
        guard trips.activeStage != nil else { return }
        autoStart = startMs
        stationName = nil
        stationCity = gps.city
        // Borne la plus proche (250 m) via Open Charge Map
        if let loc = gps.lastLocation {
            Task { @MainActor [weak self] in
                let st = await OpenChargeMap.nearby(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, radiusKm: 0.25).first
                if let st, self?.autoStart == startMs { self?.stationName = st.name }
            }
        }
    }

    private func finishAuto() {
        guard let obd, let gps, let trips else { return }
        let finished = trips.activeStage
        let name = stationName ?? "Charger"
        let city = stationCity ?? gps.city ?? ""
        let kwh = obd.chargeEnergyKwh
        trips.endStage(name: name, address: city, meal: nil, charge: nil, other: nil,
                       kmNow: lastChargingKm, energyKwh: kwh, soc: obd.soc,
                       avgKw: obd.chargeAvgKw, maxKw: obd.chargeMaxKw,
                       endTimeMs: Int64(lastCharging.timeIntervalSince1970 * 1000))
        autoStart = 0
        if let finished { pendingCost = finished }
        notifyDone(name: name, kwh: kwh)
    }

    private func notifyDone(name: String, kwh: Double) {
        let c = UNMutableNotificationContent()
        c.title = "Charging finished"
        c.body = String(format: "%.1f kWh at %@ - tap to add the cost", kwh, name)
        c.sound = .default
        let req = UNNotificationRequest(identifier: "charge-done", content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
}
