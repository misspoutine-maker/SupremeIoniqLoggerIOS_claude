import Foundation

private func normalizeGeo(_ s: String?) -> String? {
    guard let s else { return nil }
    return s.folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces).lowercased()
}

private func makeFormatter(_ fmt: String, _ locale: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: locale)
    f.dateFormat = fmt
    return f
}

@MainActor
final class TripManager: ObservableObject {
    @Published var stages: [Stage] = []
    @Published var activeVoyage: Stage?
    @Published var activeStage: Stage?   // une seule étape à la fois

    private var lastCountry: String?
    private var lastAdmin: String?
    private var lastBorderKm = 0.0

    private let saveURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("trips.json")
    }()
    private let timeDf = makeFormatter("HH:mm", "en_US_POSIX")
    private let labelDf = makeFormatter("EEE, MMM d, yyyy", "en_US")

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let list = try? JSONDecoder().decode([Stage].self, from: data) else { return }
        stages = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stages) { try? data.write(to: saveURL, options: .atomic) }
    }

    // MARK: voyage

    func startVoyage(soc: Double?, kmNow: Double) {
        guard activeVoyage == nil else { return }
        activeVoyage = Stage(type: .trip, startTime: nowMs(), startSoc: soc, startKm: kmNow)
        lastCountry = nil; lastAdmin = nil; lastBorderKm = 0
    }

    func setVoyageStart(name: String, address: String) {
        activeVoyage?.startName = name
        activeVoyage?.startAddress = address
    }

    func endVoyage(name: String, address: String, soc: Double?, kmNow: Double, energyUsedKwh: Double) {
        guard var v = activeVoyage else { return }
        v.endTime = nowMs()
        v.endName = name; v.endAddress = address; v.endSoc = soc; v.endKm = kmNow
        v.energyKwh = energyUsedKwh
        let dist = kmNow - v.startKm
        v.avgConsumptionWhKm = dist > 0.5 ? (energyUsedKwh * 1000.0) / dist : nil
        stages.append(v)
        activeVoyage = nil
        persist()
    }

    /// Détecte un franchissement de frontière (pays, province ou État ; pas de ville).
    func checkBorder(country: String?, adminArea: String?, kmNow: Double) {
        guard let voyage = activeVoyage else { return }
        let nCountry = normalizeGeo(country), nAdmin = normalizeGeo(adminArea)
        let crossed = (lastCountry != nil && nCountry != nil && nCountry != lastCountry)
            || (lastAdmin != nil && nAdmin != nil && nAdmin != lastAdmin && nCountry == lastCountry)
        if crossed {
            let t = nowMs()
            let hours = Double(t - voyage.startTime) / 3_600_000.0
            activeVoyage?.borders.append(BorderCross(time: t, country: country, adminArea: adminArea,
                                                     kmAtCrossing: kmNow, segmentKm: kmNow - lastBorderKm, hoursElapsed: hours))
            lastBorderKm = kmNow
        }
        if let c = nCountry { lastCountry = c }
        if let a = nAdmin { lastAdmin = a }
    }

    // MARK: étapes

    func startStage(_ type: StageType, kmNow: Double, soc: Double?, startTimeMs: Int64? = nil) {
        guard activeStage == nil else { return }
        activeStage = Stage(type: type, startTime: startTimeMs ?? nowMs(), startSoc: soc, startKm: kmNow)
    }

    func startStandaloneCharge(soc: Double?, startTimeMs: Int64) {
        guard activeStage == nil else { return }
        activeStage = Stage(type: .charge, startTime: startTimeMs, startSoc: soc, standalone: true)
    }

    /// Pendant une recharge : "+ Meal" la transforme en Charge/Meal.
    func convertActiveToChargeMeal() {
        if activeStage?.type == .charge { activeStage?.type = .chargeMeal }
    }

    private func sumCosts(_ meal: Double?, _ charge: Double?, _ other: Double?) -> Double? {
        let l = [meal, charge, other].compactMap { $0 }
        return l.isEmpty ? nil : l.reduce(0, +)
    }

    func endStage(name: String, address: String, meal: Double?, charge: Double?, other: Double?,
                  kmNow: Double, energyKwh: Double?, soc: Double?,
                  avgKw: Double? = nil, maxKw: Double? = nil, endTimeMs: Int64? = nil) {
        guard var s = activeStage else { return }
        s.endTime = endTimeMs ?? nowMs()
        s.endName = name; s.endAddress = address; s.endKm = kmNow; s.endSoc = soc
        s.mealCost = meal; s.chargeCost = charge
        s.cost = sumCosts(meal, charge, other)
        if s.type == .charge || s.type == .chargeMeal {
            s.energyKwh = energyKwh; s.avgChargeKw = avgKw; s.maxChargeKw = maxKw
        }
        stages.append(s)
        activeStage = nil
        persist()
    }

    /// Modifie nom, ville et coûts d'une étape enregistrée.
    func updateStage(_ stage: Stage, name: String, city: String, meal: Double?, charge: Double?, other: Double?) {
        stages = stages.map { s in
            guard s.sameKey(stage) else { return s }
            var n = s
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { n.endName = name }
            if !city.trimmingCharacters(in: .whitespaces).isEmpty { n.endAddress = city }
            n.mealCost = meal; n.chargeCost = charge; n.cost = sumCosts(meal, charge, other)
            return n
        }
        persist()
    }

    func deleteStage(_ stage: Stage) {
        stages.removeAll { $0.sameKey(stage) }
        persist()
    }

    func deleteTrip(_ trip: Stage) {
        let stops = stopsOf(trip)
        stages.removeAll { s in s.sameKey(trip) || stops.contains { $0.sameKey(s) } }
        persist()
    }

    func standaloneCharges() -> [Stage] { stages.filter { $0.standalone }.sorted { $0.startTime > $1.startTime } }

    /// Dernier prix au kWh payé à cette borne.
    func lastRateFor(_ name: String?) -> Double? {
        guard let name, !name.isEmpty else { return nil }
        let c = stages.filter {
            ($0.type == .charge || $0.type == .chargeMeal) && $0.endName == name
                && $0.chargeCostOf() > 0 && ($0.energyKwh ?? 0) > 1.0
        }.max { $0.startTime < $1.startTime }
        guard let st = c, let e = st.energyKwh else { return nil }
        return st.chargeCostOf() / e
    }

    // MARK: lecture / présentation

    func dayLabel(_ t: Int64) -> String { labelDf.string(from: Date(timeIntervalSince1970: Double(t) / 1000)) }
    func timeLabel(_ t: Int64) -> String { timeDf.string(from: Date(timeIntervalSince1970: Double(t) / 1000)) }

    func routeOf(_ trip: Stage) -> String {
        func pick(_ a: String?, _ b: String?) -> String {
            if let a, !a.isEmpty { return a }
            return b ?? "?"
        }
        return "\(pick(trip.startAddress, trip.startName)) \u{2192} \(pick(trip.endAddress, trip.endName))"
    }

    func stopsOf(_ trip: Stage) -> [Stage] {
        let hi = trip.endTime ?? Int64.max
        return stages.filter { $0.type != .trip && !$0.standalone && $0.startTime >= trip.startTime && $0.startTime <= hi }
            .sorted { $0.startTime < $1.startTime }
    }

    func statsOf(_ trip: Stage) -> TripStats {
        let end = trip.endTime ?? nowMs()
        let stops = stopsOf(trip)
        func dur(_ s: Stage) -> Double { Double(max((s.endTime ?? end) - s.startTime, 0)) / 3_600_000.0 }
        let charge = stops.filter { $0.type == .charge || $0.type == .chargeMeal }.reduce(0.0) { $0 + dur($1) }
        let meal = stops.filter { $0.type == .meal }.reduce(0.0) { $0 + dur($1) }
        let other = stops.filter { $0.type == .other }.reduce(0.0) { $0 + dur($1) }
        let total = Double(end - trip.startTime) / 3_600_000.0
        return TripStats(km: max(trip.endKm - trip.startKm, 0), totalHours: total,
                         travelHours: max(total - charge - meal - other, 0),
                         chargeHours: charge, mealHours: meal, otherHours: other,
                         cost: stops.reduce(0.0) { $0 + ($1.cost ?? 0) },
                         energyKwh: stops.reduce(0.0) { $0 + ($1.energyKwh ?? 0) },
                         avgKwh100: trip.avgConsumptionWhKm.map { $0 / 10.0 })
    }

    func timelineOf(_ trip: Stage) -> [TimelineItem] {
        var items: [TimelineItem] = []
        items.append(TimelineItem(kind: "depart", time: trip.startTime, title: "\(trip.startName ?? "Start") (Departure)",
                                  line2: timeLabel(trip.startTime), line3: trip.startAddress ?? "", km: 0))
        for s in stopsOf(trip) {
            var range = timeLabel(s.startTime)
            if let end = s.endTime { range = "\(timeLabel(s.startTime)) - \(timeLabel(end)) (\((end - s.startTime) / 60_000) min)" }
            let kind: String
            switch s.type {
            case .charge: kind = "charge"
            case .meal: kind = "meal"
            case .chargeMeal: kind = "chargemeal"
            default: kind = "other"
            }
            let place = [s.endName, s.endAddress].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
            var extra = ""
            if s.type == .charge || s.type == .chargeMeal {
                var parts: [String] = []
                if let e = s.energyKwh { parts.append(String(format: "%.1f kWh", e)) }
                if let a = s.avgChargeKw { parts.append(String(format: "avg %.0f kW", a)) }
                if let m = s.maxChargeKw { parts.append(String(format: "max %.0f kW", m)) }
                extra = parts.joined(separator: " - ")
            }
            let place2 = [place, extra].filter { !$0.isEmpty }.joined(separator: "  |  ")
            items.append(TimelineItem(kind: kind, time: s.startTime, title: s.type.label, line2: range, line3: place2,
                                      km: s.startKm - trip.startKm, stageStart: s.startTime))
        }
        for b in trip.borders {
            items.append(TimelineItem(kind: "border", time: b.time, title: "Border Crossing", line2: timeLabel(b.time),
                                      line3: [b.country, b.adminArea].compactMap { $0 }.joined(separator: " / "),
                                      km: b.kmAtCrossing - trip.startKm))
        }
        if let end = trip.endTime {
            let place = [trip.endName, trip.endAddress].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
            items.append(TimelineItem(kind: "end", time: end, title: "End Trip", line2: timeLabel(end), line3: place,
                                      km: trip.endKm - trip.startKm))
        }
        return items.sorted { $0.time < $1.time }
    }
}
