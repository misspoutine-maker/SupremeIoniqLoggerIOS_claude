import SwiftUI

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var obd: ObdBle
    @EnvironmentObject var gps: LocationTracker
    @EnvironmentObject var trips: TripManager
    let now: Date
    let landscape: Bool
    let availH: CGFloat
    let availW: CGFloat
    let onSettings: () -> Void
    let onExit: () -> Void
    let onStartEnd: () -> Void
    let onStage: (StageType) -> Void

    private var consumption: Double? {
        gps.totalDistanceKm > 0.3 ? obd.dischargeEnergyKwh * 100 / gps.totalDistanceKm : nil
    }
    private var region: String { [gps.adminArea, gps.country].compactMap { $0 }.joined(separator: ", ") }
    private var altText: String {
        "🏔 Altitude: " + ((gps.altitudeBaroM ?? gps.altitudeM).map { String(format: "%.0f m", $0) } ?? "--")
    }
    private var ageSec: Int? { obd.lastData.map { Int(now.timeIntervalSince($0)) } }
    private var socNote: String {
        var s = "Dashboard SOC"
        if let b = obd.socBms { s += String(format: " - BMS %.1f %%", b) }
        if let a = ageSec { s += a <= 5 ? " - live" : " - last data \(a)s ago" }
        return s
    }
    private var socWarn: Bool { (ageSec ?? 0) > 10 }
    private var maxKph: Double? { gps.maxSpeedKph > 0 ? gps.maxSpeedKph : nil }

    var body: some View {
        if landscape { landscapeBody } else { portraitBody }
    }

    private func fmt0(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "--" }

    private func speedStats(avg: Double?, max: Double?, unit: String) -> some View {
        DarkCard(padding: 8) {
            HStack {
                ForEach([("Average", avg), ("Max", max)], id: \.0) { item in
                    VStack(spacing: 1) {
                        Text(item.0).font(.system(size: 11)).foregroundColor(Pal.muted)
                        Text(fmt0(item.1)).font(.system(size: 22, weight: .bold)).foregroundColor(Pal.text)
                        Text(unit).font(.system(size: 11)).foregroundColor(Pal.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func socInfo(compact: Bool) -> some View {
        let temp: String = {
            guard let mx = obd.battTempMax, let mn = obd.battTempMin else { return "--" }
            return mn == mx ? "\(mx)" : "\(mn)-\(mx)"
        }()
        let tempColor: Color = {
            guard let mx = obd.battTempMax else { return Pal.muted }
            if mx >= 45 { return Pal.red }
            if (obd.battTempMin ?? mx) <= 5 { return Pal.blue }
            return Pal.muted
        }()
        return VStack(alignment: .leading, spacing: compact ? 3 : 8) {
            Text("⚡ Power").font(.system(size: 12)).foregroundColor(Pal.muted)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(obd.powerKw.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: compact ? 28 : 34, weight: .bold))
                    .foregroundColor((obd.powerKw ?? 0) < -0.5 ? Pal.green : Pal.text)
                Text("kW").font(.system(size: 14)).foregroundColor(Pal.muted)
            }
            Divider().background(Pal.cardBorder)
            Text("Consumption").font(.system(size: 12)).foregroundColor(Pal.muted)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(consumption.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: compact ? 16 : 20, weight: .bold)).foregroundColor(Pal.text)
                Text("kWh/100km").font(.system(size: 11)).foregroundColor(Pal.muted)
            }
            Text("🌡 \(temp) °C").font(.system(size: 12)).foregroundColor(tempColor)
        }
    }

    @ViewBuilder private var chargingCard: some View {
        if obd.isCharging {
            DarkCard(border: Pal.green, padding: 10) {
                Text("⚡ Charging").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.green)
                StatStrip(items: [
                    ("Average", obd.chargeAvgKw.map { String(format: "%.1f kW", $0) } ?? "--"),
                    ("Max", obd.chargeMaxKw.map { String(format: "%.1f kW", $0) } ?? "--"),
                    ("Energy", String(format: "%.2f kWh", obd.chargeEnergyKwh))
                ]).padding(.top, 4)
            }
        }
    }

    private func stageStyle(_ t: StageType) -> (String, Color) {
        switch t {
        case .meal: return ("🍴 Meal", Pal.orange)
        case .charge: return ("⚡ Charge", Pal.blue)
        case .chargeMeal: return ("⚡🍴 Charge / Meal", Pal.purple)
        default: return ("⋯ Other stop", Pal.gray)
        }
    }

    private func timerBlock(_ label: String, _ time: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundColor(Pal.muted)
            Text(time).font(.system(size: 28, weight: .bold, design: .monospaced)).foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }

    /// Chronomètres : trajet en cours et arrêt en cours.
    @ViewBuilder private var timerCard: some View {
        let nowT = Int64(now.timeIntervalSince1970 * 1000)
        if trips.activeVoyage != nil || trips.activeStage != nil {
            DarkCard(border: Pal.orange.opacity(0.6), padding: 10) {
                HStack(alignment: .top) {
                    if let v = trips.activeVoyage { timerBlock("🚗 Trip", fmtClock(nowT - v.startTime), Pal.orange) }
                    if let st = trips.activeStage {
                        let sty = stageStyle(st.type)
                        timerBlock(sty.0, fmtClock(nowT - st.startTime), sty.1)
                    }
                }
            }
        }
    }

    private var actionRow: some View {
        let tripActive = trips.activeVoyage != nil
        let standaloneActive = trips.activeStage?.standalone == true
        let at = trips.activeStage?.type
        func enabled(_ t: StageType) -> Bool { (tripActive || standaloneActive) && (at == nil || at == t) }
        return HStack(alignment: .top, spacing: 6) {
            ActionButton(icon: tripActive ? "■" : "▶", label: tripActive ? "End Trip" : "Start Trip",
                         accent: tripActive ? Pal.red : Pal.green, active: tripActive, enabled: true, action: onStartEnd)
            ActionButton(icon: "🍴", label: at == .meal ? "End Meal" : "Meal", accent: Pal.orange,
                         active: at == .meal, enabled: enabled(.meal)) { onStage(.meal) }
            ActionButton(icon: "⚡", label: at == .charge ? "End Charge" : "Charge", accent: Pal.blue,
                         active: at == .charge, enabled: enabled(.charge)) { onStage(.charge) }
            ActionButton(icon: "⚡🍴", label: at == .chargeMeal ? "End Charge / Meal" : (at == .charge ? "+ Meal" : "Charge / Meal"),
                         accent: Pal.purple, active: at == .chargeMeal,
                         enabled: enabled(.chargeMeal) || at == .charge) { onStage(.chargeMeal) }
            ActionButton(icon: "⋯", label: at == .other ? "End Other" : "Other", accent: Pal.gray,
                         active: at == .other, enabled: enabled(.other)) { onStage(.other) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("📍").font(.system(size: landscape ? 18 : 30))
            VStack(alignment: .leading, spacing: 1) {
                Text(gps.city ?? "--").font(.system(size: landscape ? 20 : 28, weight: .bold)).foregroundColor(Pal.text).lineLimit(1)
                if !region.isEmpty && !landscape { Text(region).font(.system(size: 14)).foregroundColor(Pal.muted) }
                Text(landscape ? ([region, altText].filter { !$0.isEmpty }.joined(separator: "  -  ")) : altText)
                    .font(.system(size: landscape ? 11 : 13)).foregroundColor(Pal.muted).lineLimit(1)
            }
            Spacer()
            Button(action: onSettings) { Text("⚙").font(.system(size: landscape ? 20 : 24)).foregroundColor(Pal.muted) }
            Button(action: onExit) { Text("Exit").font(.system(size: landscape ? 13 : 14)).foregroundColor(Pal.red) }
        }
    }

    private var portraitBody: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 6) {
                        SpeedGauge(value: gps.speedMph, maxValue: 160, majorStep: 20, unit: "mph", accent: Pal.blue)
                        speedStats(avg: gps.avgMovingSpeedKph.map { $0 / 1.60934 }, max: maxKph.map { $0 / 1.60934 }, unit: "mph")
                    }
                    VStack(spacing: 6) {
                        SpeedGauge(value: gps.speedKph, maxValue: 240, majorStep: 40, unit: "km/h", accent: Pal.green)
                        speedStats(avg: gps.avgMovingSpeedKph, max: maxKph, unit: "km/h")
                    }
                }
                DarkCard {
                    HStack(spacing: 14) {
                        SocGauge(soc: obd.soc).frame(maxWidth: .infinity)
                        Rectangle().fill(Pal.cardBorder).frame(width: 1, height: 130)
                        socInfo(compact: false).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(socNote).font(.system(size: 11)).foregroundColor(socWarn ? Pal.red : Pal.muted).padding(.top, 6)
                }
                chargingCard
                timerCard
                actionRow
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var landscapeBody: some View {
        let g = min(max(availH - 72, 110), 230, (availW * 0.55 - 12) / 2)
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                header
                HStack {
                    Spacer()
                    VStack(spacing: 2) {
                        SpeedGauge(value: gps.speedMph, maxValue: 160, majorStep: 20, unit: "mph", accent: Pal.blue)
                            .frame(width: g, height: g)
                        Text("Avg \(fmt0(gps.avgMovingSpeedKph.map { $0 / 1.60934 })) - Max \(fmt0(maxKph.map { $0 / 1.60934 })) mph")
                            .font(.system(size: 11)).foregroundColor(Pal.muted)
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        SpeedGauge(value: gps.speedKph, maxValue: 240, majorStep: 40, unit: "km/h", accent: Pal.green)
                            .frame(width: g, height: g)
                        Text("Avg \(fmt0(gps.avgMovingSpeedKph)) - Max \(fmt0(maxKph)) km/h")
                            .font(.system(size: 11)).foregroundColor(Pal.muted)
                    }
                    Spacer()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(spacing: 8) {
                    DarkCard(padding: 10) {
                        HStack(spacing: 10) {
                            SocGauge(soc: obd.soc).frame(width: 104, height: 104)
                            socInfo(compact: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(socNote).font(.system(size: 10)).foregroundColor(socWarn ? Pal.red : Pal.muted).padding(.top, 4)
                    }
                    chargingCard
                    timerCard
                    actionRow
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - More

struct MoreView: View {
    @EnvironmentObject var obd: ObdBle
    @EnvironmentObject var gps: LocationTracker
    let onExit: () -> Void
    let onExportCsv: () -> Void
    let onExportPdf: () -> Void
    @AppStorage("keepScreenOn") private var keepAwake = true

    init(onExit: @escaping () -> Void, onExportCsv: @escaping () -> Void, onExportPdf: @escaping () -> Void) {
        self.onExit = onExit; self.onExportCsv = onExportCsv; self.onExportPdf = onExportPdf
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("More").font(.system(size: 24, weight: .bold)).foregroundColor(Pal.text)
                DarkCard {
                    Text("OBD adapter").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                    Text(obd.state).font(.system(size: 12)).foregroundColor(Pal.muted).padding(.vertical, 4)
                    HStack(spacing: 8) {
                        Button("Connect OBD") { obd.connect() }.buttonStyle(.borderedProminent)
                        Button("Disconnect") { obd.disconnect() }.buttonStyle(.bordered)
                    }
                }
                DarkCard {
                    Text("GPS").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                    Text(gps.running ? "Running (starts automatically with the app)." : "Stopped.")
                        .font(.system(size: 12)).foregroundColor(Pal.muted).padding(.vertical, 4)
                    HStack(spacing: 8) {
                        Button("Start GPS") { gps.start() }.buttonStyle(.bordered)
                        Button("Stop GPS") { gps.stop() }.buttonStyle(.bordered)
                    }
                }
                DarkCard {
                    Text("Export all trips").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                    HStack(spacing: 8) {
                        Button("Export CSV", action: onExportCsv).buttonStyle(.borderedProminent)
                        Button("Export PDF", action: onExportPdf).buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 6)
                }
                DarkCard {
                    Toggle("Keep screen on while the app is open", isOn: $keepAwake)
                        .font(.system(size: 14)).foregroundColor(Pal.text)
                }
                DarkCard {
                    Text("Diagnostics").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                    ForEach(Array(obd.log.suffix(40).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 9, design: .monospaced)).foregroundColor(Pal.muted)
                    }
                }
                Button(action: onExit) {
                    Text("Exit app").foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Pal.red).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(appVersion).font(.system(size: 11)).foregroundColor(Pal.muted).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}
