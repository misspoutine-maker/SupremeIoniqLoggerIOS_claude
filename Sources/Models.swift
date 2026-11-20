import Foundation

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func fmtHm(_ hours: Double) -> String {
    let m = max(Int(hours * 60), 0)
    return String(format: "%dh %02dm", m / 60, m % 60)
}

func fmtDuration(_ ms: Int64) -> String {
    let t = max(Int(ms / 60_000), 0)
    return String(format: "%d:%02d", t / 60, t % 60)
}

func money(_ v: Double) -> String { String(format: "$%.2f", v) }

/// Accepte la virgule décimale : "12,50" -> 12.5
func parseMoney(_ s: String) -> Double? {
    Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
}

enum StageType: String, Codable {
    case trip = "TRIP", meal = "MEAL", charge = "CHARGE", chargeMeal = "CHARGE_MEAL", other = "OTHER"
    var label: String {
        switch self {
        case .trip: return "Trip"
        case .meal: return "Meal stop"
        case .charge: return "Charging stop"
        case .chargeMeal: return "Charge/Meal stop"
        case .other: return "Other stop"
        }
    }
}

struct BorderCross: Codable, Equatable {
    var time: Int64
    var country: String?
    var adminArea: String?
    var kmAtCrossing: Double
    var segmentKm: Double
    var hoursElapsed: Double
}

/// Voyage (type .trip) ou étape (repas, recharge, autre). Même format JSON que la version Android.
struct Stage: Codable, Equatable {
    var type: StageType
    var startTime: Int64
    var endTime: Int64? = nil
    var startAddress: String? = nil
    var startName: String? = nil
    var endAddress: String? = nil
    var endName: String? = nil
    var cost: Double? = nil
    var borders: [BorderCross] = []
    var startSoc: Double? = nil
    var endSoc: Double? = nil
    var startKm: Double = 0
    var endKm: Double = 0
    var energyKwh: Double? = nil           // recharge : kWh délivrés ; voyage : kWh consommés (net)
    var avgConsumptionWhKm: Double? = nil  // voyage seulement
    var mealCost: Double? = nil
    var chargeCost: Double? = nil
    var avgChargeKw: Double? = nil
    var maxChargeKw: Double? = nil
    var standalone: Bool = false           // recharge hors voyage

    init(type: StageType, startTime: Int64, startSoc: Double? = nil, startKm: Double = 0, standalone: Bool = false) {
        self.type = type; self.startTime = startTime; self.startSoc = startSoc
        self.startKm = startKm; self.standalone = standalone
    }

    enum CodingKeys: String, CodingKey {
        case type, startTime, endTime, startAddress, startName, endAddress, endName, cost, borders
        case startSoc, endSoc, startKm, endKm, energyKwh, avgConsumptionWhKm, mealCost, chargeCost
        case avgChargeKw, maxChargeKw, standalone
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = try c.decode(StageType.self, forKey: .type)
        startTime = try c.decode(Int64.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Int64.self, forKey: .endTime)
        startAddress = try c.decodeIfPresent(String.self, forKey: .startAddress)
        startName = try c.decodeIfPresent(String.self, forKey: .startName)
        endAddress = try c.decodeIfPresent(String.self, forKey: .endAddress)
        endName = try c.decodeIfPresent(String.self, forKey: .endName)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        borders = try c.decodeIfPresent([BorderCross].self, forKey: .borders) ?? []
        startSoc = try c.decodeIfPresent(Double.self, forKey: .startSoc)
        endSoc = try c.decodeIfPresent(Double.self, forKey: .endSoc)
        startKm = try c.decodeIfPresent(Double.self, forKey: .startKm) ?? 0
        endKm = try c.decodeIfPresent(Double.self, forKey: .endKm) ?? 0
        energyKwh = try c.decodeIfPresent(Double.self, forKey: .energyKwh)
        avgConsumptionWhKm = try c.decodeIfPresent(Double.self, forKey: .avgConsumptionWhKm)
        mealCost = try c.decodeIfPresent(Double.self, forKey: .mealCost)
        chargeCost = try c.decodeIfPresent(Double.self, forKey: .chargeCost)
        avgChargeKw = try c.decodeIfPresent(Double.self, forKey: .avgChargeKw)
        maxChargeKw = try c.decodeIfPresent(Double.self, forKey: .maxChargeKw)
        standalone = try c.decodeIfPresent(Bool.self, forKey: .standalone) ?? false
    }

    func sameKey(_ o: Stage) -> Bool { startTime == o.startTime && type == o.type }

    func mealCostOf() -> Double { mealCost ?? (type == .meal ? (cost ?? 0) : 0) }
    func chargeCostOf() -> Double {
        if let c = chargeCost { return c }
        if type == .charge { return cost ?? 0 }
        if type == .chargeMeal && mealCost == nil { return cost ?? 0 }
        return 0
    }
    func otherCostOf() -> Double { type == .other ? (cost ?? 0) : 0 }
}

struct TripStats {
    var km: Double, totalHours: Double, travelHours: Double
    var chargeHours: Double, mealHours: Double, otherHours: Double
    var cost: Double, energyKwh: Double, avgKwh100: Double?
}

struct TimelineItem: Identifiable {
    var kind: String, time: Int64, title: String, line2: String, line3: String, km: Double
    var stageStart: Int64 = 0   // début de l'étape correspondante (0 = pas modifiable)
    var id: String { "\(kind)-\(time)-\(title)" }
}

/// Chronomètre H:MM:SS.
func fmtClock(_ ms: Int64) -> String {
    let s = max(Int(ms / 1000), 0)
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}
