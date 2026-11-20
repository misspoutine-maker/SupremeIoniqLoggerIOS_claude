import SwiftUI

let appVersion = "iOS v3.1 (stopwatch trip + stops)"

struct RootView: View {
    @EnvironmentObject var obd: ObdBle
    @EnvironmentObject var gps: LocationTracker
    @EnvironmentObject var trips: TripManager
    @StateObject private var automation = ChargeAutomation()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("keepScreenOn") private var keepAwake = true

    @State private var tab = 0
    @State private var now = Date()
    @State private var sheet: SheetKind?
    @State private var detailStart: Int64?
    @State private var actionsTrip: Stage?
    @State private var deleteTrip: Stage?
    @State private var deleteSession: Stage?
    @State private var stationSuggestions: [ChargeStation] = []
    @State private var shareItem: ShareItem?

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let items: [(String, String)] = [("Live", "🚗"), ("Today", "📅"), ("History", "🕘"), ("More", "☰")]

    private var detail: Stage? {
        detailStart.flatMap { s in trips.stages.first { $0.type == .trip && $0.startTime == s } }
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                LinearGradient(colors: [Pal.bg, Pal.bg2], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                if detail != nil {
                    content(landscape: landscape, size: geo.size)
                } else if landscape {
                    HStack(spacing: 0) {
                        navBar(vertical: true)
                        content(landscape: true, size: geo.size)
                    }
                } else {
                    VStack(spacing: 0) {
                        content(landscape: false, size: geo.size)
                        navBar(vertical: false)
                    }
                }
            }
        }
        .onReceive(clock) { t in
            now = t
            // Le GPS indique à l'OBD si la voiture roule (distingue régénération et recharge).
            if let loc = gps.lastLocation {
                obd.moving = t.timeIntervalSince(loc.timestamp) < 15 && (gps.speedKph ?? 0) > 3.0
            } else { obd.moving = false }
            if sheet == nil, let p = automation.pendingCost {
                automation.pendingCost = nil   // une seule fois ; "Add cost" reste disponible ensuite
                sheet = .pendingCost(p)
            }
        }
        .onAppear {
            applyKeepAwake()
            automation.start(obd: obd, gps: gps, trips: trips)
            gps.start()
            if !obd.isActive() { obd.connect() }
        }
        .onChange(of: keepAwake) { _ in applyKeepAwake() }
        .onChange(of: scenePhase) { _ in applyKeepAwake() }
        .onChange(of: gps.country) { _ in trips.checkBorder(country: gps.country, adminArea: gps.adminArea, kmNow: gps.totalDistanceKm) }
        .onChange(of: gps.adminArea) { _ in trips.checkBorder(country: gps.country, adminArea: gps.adminArea, kmNow: gps.totalDistanceKm) }
        .sheet(item: $sheet) { kind in sheetView(kind) }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
        .confirmationDialog("Trip Actions", isPresented: Binding(get: { actionsTrip != nil }, set: { if !$0 { actionsTrip = nil } }),
                            titleVisibility: .visible, presenting: actionsTrip) { t in
            Button("View Details") { detailStart = t.startTime }
            Button("Export as CSV") { share(csv: true, only: t) }
            Button("Export as PDF") { share(csv: false, only: t) }
            Button("Delete Trip", role: .destructive) { deleteTrip = t }
            Button("Cancel", role: .cancel) {}
        } message: { t in
            Text("\(trips.dayLabel(t.startTime)) - \(trips.timeLabel(t.startTime))")
        }
        .alert("Delete Trip", isPresented: Binding(get: { deleteTrip != nil }, set: { if !$0 { deleteTrip = nil } }),
               presenting: deleteTrip) { t in
            Button("Delete", role: .destructive) {
                trips.deleteTrip(t)
                if detailStart == t.startTime { detailStart = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Are you sure you want to delete this trip? This action cannot be undone.")
        }
        .alert("Delete charging session", isPresented: Binding(get: { deleteSession != nil }, set: { if !$0 { deleteSession = nil } }),
               presenting: deleteSession) { s in
            Button("Delete", role: .destructive) { trips.deleteStage(s) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This action cannot be undone.")
        }
    }

    private func applyKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    // MARK: contenu

    @ViewBuilder
    private func content(landscape: Bool, size: CGSize) -> some View {
        if let d = detail {
            TripDetailView(trip: d, onBack: { detailStart = nil }, onDelete: { deleteTrip = d },
                           onEditStage: { sheet = .edit($0) },
                           onExportCsv: { share(csv: true, only: d) }, onExportPdf: { share(csv: false, only: d) })
        } else {
            switch tab {
            case 0:
                LiveView(now: now, landscape: landscape, availH: size.height - 16, availW: size.width,
                         onSettings: { tab = 3 }, onExit: exitApp, onStartEnd: startEnd, onStage: onStage)
            case 1:
                TodayView(now: now, tripKm: gps.totalDistanceKm, consumption: consumption,
                          chargeLive: (obd.chargeAvgKw.map { String(format: "avg %.1f kW", $0) } ?? "avg --")
                              + "  |  " + String(format: "%.2f kWh", obd.chargeEnergyKwh),
                          onOpen: { detailStart = $0.startTime }, onMenu: { actionsTrip = $0 },
                          onEdit: { sheet = .edit($0) }, onDelete: { deleteSession = $0 })
            case 2:
                HistoryView(onOpen: { detailStart = $0.startTime }, onMenu: { actionsTrip = $0 },
                            onEdit: { sheet = .edit($0) }, onDelete: { deleteSession = $0 })
            default:
                MoreView(onExit: exitApp, onExportCsv: { share(csv: true, only: nil) }, onExportPdf: { share(csv: false, only: nil) })
            }
        }
    }

    private var consumption: Double? {
        gps.totalDistanceKm > 0.3 ? obd.dischargeEnergyKwh * 100 / gps.totalDistanceKm : nil
    }

    private func navBar(vertical: Bool) -> some View {
        let buttons = ForEach(0..<items.count, id: \.self) { i in
            Button { tab = i } label: {
                VStack(spacing: 2) {
                    Text(items[i].1).font(.system(size: 20))
                    Text(items[i].0).font(.system(size: 11))
                }
                .foregroundColor(tab == i ? Pal.blue : Pal.muted)
                .frame(maxWidth: vertical ? 64 : .infinity, minHeight: 48)
                .background(tab == i ? Pal.blue.opacity(0.2) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        return Group {
            if vertical { VStack(spacing: 8) { buttons; Spacer() }.padding(.top, 12).frame(width: 72) }
            else { HStack(spacing: 4) { buttons }.padding(.horizontal, 8).padding(.vertical, 4) }
        }
        .background(Pal.bg2.ignoresSafeArea())
    }

    // MARK: actions voyage / arrêts

    private func startEnd() {
        if trips.activeVoyage == nil {
            gps.resetDistance(); obd.resetDischargeEnergy()
            trips.startVoyage(soc: obd.soc, kmNow: 0)
            sheet = .tripStart
        } else {
            sheet = .tripEnd
        }
    }

    private func onStage(_ t: StageType) {
        let active = trips.activeStage?.type
        if active == .charge && t == .chargeMeal {
            trips.convertActiveToChargeMeal()   // "+ Meal" pendant une recharge
        } else if active == t {
            stationSuggestions = []
            if t == .charge || t == .chargeMeal, let loc = gps.lastLocation {
                Task { stationSuggestions = await OpenChargeMap.nearby(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude) }
            }
            sheet = .stageEnd(t)
        } else if trips.activeVoyage != nil && active == nil {
            trips.startStage(t, kmNow: gps.totalDistanceKm, soc: obd.soc)
        }
    }

    private func rateHint(_ st: Stage) -> String? {
        guard st.type == .charge || st.type == .chargeMeal, let rate = trips.lastRateFor(st.endName) else { return nil }
        var s = String(format: "Last rate here: $%.2f/kWh", rate)
        if let kwh = st.energyKwh { s += String(format: " -> about $%.2f", rate * kwh) }
        return s
    }

    @ViewBuilder
    private func sheetView(_ kind: SheetKind) -> some View {
        let city = gps.city ?? ""
        switch kind {
        case .tripStart:
            PlaceDialog(title: "Trip start", defaultAddress: city, costLabels: [], presets: ["Home", "Work", "Hotel", "Other"],
                        onConfirm: { n, a, _ in trips.setVoyageStart(name: n, address: a); sheet = nil },
                        onCancel: { sheet = nil })
        case .tripEnd:
            PlaceDialog(title: "Trip end", defaultAddress: city, costLabels: [], presets: ["Home", "Work", "Hotel", "Other"],
                        onConfirm: { n, a, _ in
                            trips.endVoyage(name: n, address: a, soc: obd.soc, kmNow: gps.totalDistanceKm,
                                            energyUsedKwh: obd.dischargeEnergyKwh)
                            sheet = nil
                        },
                        onCancel: { sheet = nil })
        case .stageEnd(let t):
            PlaceDialog(title: "End: \(t.label)", defaultAddress: city, costLabels: costLabelsFor(t), presets: [],
                        suggestions: (t == .charge || t == .chargeMeal) ? stationSuggestions : [],
                        onConfirm: { n, a, costs in
                            let isCharge = t == .charge || t == .chargeMeal
                            let (meal, charge, other) = splitCosts(t, costs)
                            trips.endStage(name: n, address: a, meal: meal, charge: charge, other: other,
                                           kmNow: gps.totalDistanceKm, energyKwh: isCharge ? obd.chargeEnergyKwh : nil,
                                           soc: obd.soc, avgKw: obd.chargeAvgKw, maxKw: obd.chargeMaxKw)
                            sheet = nil
                        },
                        onCancel: { sheet = nil })
        case .pendingCost(let st):
            PlaceDialog(title: "Charging finished" + (st.energyKwh.map { String(format: " - %.1f kWh", $0) } ?? ""),
                        defaultAddress: st.endAddress ?? "", costLabels: costLabelsFor(st.type), presets: [],
                        initialName: st.endName ?? "", costHint: rateHint(st),
                        onConfirm: { n, a, costs in
                            let (meal, charge, other) = splitCosts(st.type, costs)
                            trips.updateStage(st, name: n, city: a, meal: meal, charge: charge, other: other)
                            sheet = nil
                        },
                        onCancel: { sheet = nil })
        case .edit(let st):
            PlaceDialog(title: "Edit: \(st.type.label)", defaultAddress: st.endAddress ?? "", costLabels: costLabelsFor(st.type),
                        presets: [], initialName: st.endName ?? "", initialCosts: editCosts(st), costHint: rateHint(st),
                        onConfirm: { n, a, costs in
                            let (meal, charge, other) = splitCosts(st.type, costs)
                            trips.updateStage(st, name: n, city: a, meal: meal, charge: charge, other: other)
                            sheet = nil
                        },
                        onCancel: { sheet = nil })
        }
    }

    private func editCosts(_ st: Stage) -> [Double?] {
        let v: [Double]
        switch st.type {
        case .meal: v = [st.mealCostOf()]
        case .charge: v = [st.chargeCostOf()]
        case .chargeMeal: v = [st.chargeCostOf(), st.mealCostOf()]
        default: v = [st.otherCostOf()]
        }
        return v.map { x -> Double? in x == 0 ? nil : x }
    }

    private func share(csv: Bool, only: Stage?) {
        if let url = csv ? trips.exportCsv(only: only) : trips.exportPdf(only: only) { shareItem = ShareItem(url: url) }
    }

    private func exitApp() {
        obd.disconnect()
        gps.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }
}
