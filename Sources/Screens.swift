import SwiftUI

private func summaryStrip(_ s: [TripStats], extraChargeHours: Double = 0, extraCost: Double = 0) -> [(String, String)] {
    [("Total Distance", String(format: "%.0f km", s.reduce(0.0) { $0 + $1.km })),
     ("Travel Time", fmtHm(s.reduce(0.0) { $0 + $1.travelHours })),
     ("Charge Time", fmtHm(s.reduce(0.0) { $0 + $1.chargeHours } + extraChargeHours)),
     ("Cost", money(s.reduce(0.0) { $0 + $1.cost } + extraCost))]
}

struct TimelineRow: View {
    let item: TimelineItem
    var onEdit: (() -> Void)? = nil

    private var style: (String, Color) {
        switch item.kind {
        case "depart": return ("📍", Pal.green)
        case "charge": return ("⚡", Pal.blue)
        case "meal": return ("🍴", Pal.orange)
        case "chargemeal": return ("⚡", Pal.purple)
        case "border": return ("🛂", Pal.purple)
        case "end": return ("🏁", Pal.green)
        default: return ("⋯", Pal.gray)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(icon: style.0, color: style.1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Pal.text)
                Text(item.line2).font(.system(size: 12)).foregroundColor(Pal.muted)
                if !item.line3.isEmpty { Text(item.line3).font(.system(size: 12)).foregroundColor(Pal.muted) }
                if let onEdit { Button("Edit", action: onEdit).font(.system(size: 12)) }
            }
            Spacer(minLength: 4)
            Text(String(format: "%.0f km", item.km)).font(.system(size: 13)).foregroundColor(Pal.text)
        }
        .padding(.vertical, 6)
    }
}

/// Recharge hors voyage.
struct ChargeSessionCard: View {
    @EnvironmentObject var trips: TripManager
    let st: Stage
    let onEdit: (Stage) -> Void
    let onDelete: (Stage) -> Void

    var body: some View {
        let place = [st.endName, st.endAddress].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        var parts: [String] = []
        if st.startSoc != nil || st.endSoc != nil {
            let a = st.startSoc.map { String(format: "%.0f", $0) } ?? "?"
            let b = st.endSoc.map { String(format: "%.0f", $0) } ?? "?"
            parts.append("SOC \(a)% -> \(b)%")
        }
        if let e = st.energyKwh { parts.append(String(format: "%.1f kWh", e)) }
        if let a = st.avgChargeKw { parts.append(String(format: "avg %.0f kW", a)) }
        if let m = st.maxChargeKw { parts.append(String(format: "max %.0f kW", m)) }
        let details = parts.joined(separator: "  |  ")
        var title = "\(trips.dayLabel(st.startTime))  \(trips.timeLabel(st.startTime))"
        if let end = st.endTime {
            title += " - \(trips.timeLabel(end)) (\(fmtHm(Double(end - st.startTime) / 3_600_000.0)))"
        }
        return DarkCard(border: Pal.blue.opacity(0.5)) {
            HStack(spacing: 10) {
                IconBadge(icon: "⚡", color: Pal.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(Pal.text)
                    Text(place.isEmpty ? "Charging session" : place).font(.system(size: 12)).foregroundColor(Pal.muted)
                    if !details.isEmpty { Text(details).font(.system(size: 12)).foregroundColor(Pal.text) }
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                if let c = st.cost {
                    Text(money(c)).font(.system(size: 14, weight: .semibold)).foregroundColor(Pal.text)
                    Button("Edit") { onEdit(st) }
                } else {
                    Button("Add cost") { onEdit(st) }.buttonStyle(.borderedProminent)
                }
                Button("Delete") { onDelete(st) }.foregroundColor(Pal.red)
            }
            .padding(.top, 6)
        }
    }
}

struct TodayView: View {
    @EnvironmentObject var trips: TripManager
    let now: Date
    let tripKm: Double
    let consumption: Double?
    let chargeLive: String
    let onOpen: (Stage) -> Void
    let onMenu: (Stage) -> Void
    let onEdit: (Stage) -> Void
    let onDelete: (Stage) -> Void

    var body: some View {
        let nowT = Int64(now.timeIntervalSince1970 * 1000)
        let dayNow = trips.dayLabel(nowT)
        let today = trips.stages.filter { $0.type == .trip && trips.dayLabel($0.startTime) == dayNow }.sorted { $0.startTime < $1.startTime }
        let sessions = trips.stages.filter { $0.standalone && trips.dayLabel($0.startTime) == dayNow }.sorted { $0.startTime > $1.startTime }
        let sessionHours = sessions.reduce(0.0) { $0 + Double(max(($1.endTime ?? nowT) - $1.startTime, 0)) / 3_600_000.0 }
        let sessionCost = sessions.reduce(0.0) { $0 + ($1.cost ?? 0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Today's Trips").font(.system(size: 24, weight: .bold)).foregroundColor(Pal.text)
                Text(dayNow).font(.system(size: 13)).foregroundColor(Pal.muted)
                DarkCard {
                    StatStrip(items: summaryStrip(today.map { trips.statsOf($0) }, extraChargeHours: sessionHours, extraCost: sessionCost))
                }
                if let v = trips.activeVoyage {
                    DarkCard(border: Pal.orange) {
                        Text("🚗 In progress - \(fmtClock(nowT - v.startTime))")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(Pal.orange)
                        Text(String(format: "%.1f km", tripKm) + (consumption.map { String(format: " - %.1f kWh/100 km", $0) } ?? ""))
                            .font(.system(size: 13)).foregroundColor(Pal.text)
                        if let st = trips.activeStage {
                            Text("\(st.type.label) since \(fmtClock(nowT - st.startTime))")
                                .font(.system(size: 13)).foregroundColor(Pal.orange)
                        }
                        ForEach(trips.timelineOf(v)) { TimelineRow(item: $0) }
                    }
                }
                if let st = trips.activeStage, st.standalone {
                    DarkCard(border: Pal.blue) {
                        Text("⚡ Charging in progress - \(fmtClock(nowT - st.startTime))")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(Pal.blue)
                        Text(chargeLive).font(.system(size: 13)).foregroundColor(Pal.text)
                    }
                }
                if today.isEmpty && trips.activeVoyage == nil && sessions.isEmpty {
                    Text("Nothing recorded today").font(.system(size: 13)).foregroundColor(Pal.muted)
                }
                ForEach(today, id: \.startTime) { trip in
                    DarkCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(trips.timeLabel(trip.startTime)) - \(trips.timeLabel(trip.endTime ?? trip.startTime))")
                                    .font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                                Text(trips.routeOf(trip)).font(.system(size: 12)).foregroundColor(Pal.muted)
                            }
                            Spacer()
                            Button { onMenu(trip) } label: { Text("⋮").font(.system(size: 22)).foregroundColor(Pal.muted).padding(8) }
                        }
                        ForEach(trips.timelineOf(trip)) { TimelineRow(item: $0) }
                    }
                    .onTapGesture { onOpen(trip) }
                }
                if !sessions.isEmpty {
                    Text("Charging sessions").font(.system(size: 16, weight: .bold)).foregroundColor(Pal.text)
                    ForEach(sessions, id: \.startTime) { ChargeSessionCard(st: $0, onEdit: onEdit, onDelete: onDelete) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var trips: TripManager
    let onOpen: (Stage) -> Void
    let onMenu: (Stage) -> Void
    let onEdit: (Stage) -> Void
    let onDelete: (Stage) -> Void
    @State private var mode = 0   // 0 = All Trips, 1 = By Date, 2 = Charges

    init(onOpen: @escaping (Stage) -> Void, onMenu: @escaping (Stage) -> Void,
         onEdit: @escaping (Stage) -> Void, onDelete: @escaping (Stage) -> Void) {
        self.onOpen = onOpen; self.onMenu = onMenu; self.onEdit = onEdit; self.onDelete = onDelete
    }

    private func seg(_ label: String, _ i: Int) -> some View {
        Button { mode = i } label: {
            Text(label).font(.system(size: 15, weight: .semibold))
                .foregroundColor(mode == i ? .white : Pal.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(mode == i ? Pal.blue : Pal.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    var body: some View {
        let all = trips.stages.filter { $0.type == .trip }.sorted { $0.startTime > $1.startTime }
        let sessions = trips.stages.filter { $0.standalone }.sorted { $0.startTime > $1.startTime }
        var days: [String] = []
        for t in all { let d = trips.dayLabel(t.startTime); if !days.contains(d) { days.append(d) } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("History").font(.system(size: 24, weight: .bold)).foregroundColor(Pal.text)
                HStack(spacing: 8) { seg("All Trips", 0); seg("By Date", 1); seg("Charges", 2) }
                if mode == 2 {
                    if sessions.isEmpty {
                        Text("No charging session outside trips yet").font(.system(size: 13)).foregroundColor(Pal.muted)
                    }
                    ForEach(sessions, id: \.startTime) { ChargeSessionCard(st: $0, onEdit: onEdit, onDelete: onDelete) }
                } else {
                    if all.isEmpty { Text("No trips recorded yet").font(.system(size: 13)).foregroundColor(Pal.muted) }
                    if mode == 0 {
                        ForEach(all, id: \.startTime) { trip in tripCard(trip) }
                    } else {
                        ForEach(days, id: \.self) { day in
                            let list = all.filter { trips.dayLabel($0.startTime) == day }
                            DarkCard {
                                Text(day).font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                                StatStrip(items: summaryStrip(list.map { trips.statsOf($0) })).padding(.vertical, 6)
                                ForEach(list, id: \.startTime) { t in
                                    Text("\(trips.timeLabel(t.startTime)) - \(trips.timeLabel(t.endTime ?? t.startTime))   \(trips.routeOf(t))")
                                        .font(.system(size: 12)).foregroundColor(Pal.muted)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                        .onTapGesture { onOpen(t) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func tripCard(_ trip: Stage) -> some View {
        let st = trips.statsOf(trip)
        return DarkCard {
            HStack(spacing: 10) {
                IconBadge(icon: "🚗", color: Pal.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trips.dayLabel(trip.startTime)).font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                    Text(trips.routeOf(trip)).font(.system(size: 12)).foregroundColor(Pal.muted)
                    Text(String(format: "📏 %.0f km    ⏱ %@    $ %.2f", st.km, fmtHm(st.totalHours), st.cost))
                        .font(.system(size: 12)).foregroundColor(Pal.text)
                }
                Spacer(minLength: 0)
                Button { onMenu(trip) } label: { Text("⋮").font(.system(size: 22)).foregroundColor(Pal.muted).padding(8) }
            }
        }
        .onTapGesture { onOpen(trip) }
    }
}

struct TripDetailView: View {
    @EnvironmentObject var trips: TripManager
    let trip: Stage
    let onBack: () -> Void
    let onDelete: () -> Void
    let onEditStage: (Stage) -> Void
    let onExportCsv: () -> Void
    let onExportPdf: () -> Void

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundColor(Pal.text)
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundColor(Pal.text)
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        let st = trips.statsOf(trip)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(action: onBack) { Text("←").font(.system(size: 26)).foregroundColor(Pal.text).padding(.trailing, 8) }
                    Text("Trip Details").font(.system(size: 22, weight: .bold)).foregroundColor(Pal.text)
                }
                DarkCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trips.dayLabel(trip.startTime)).font(.system(size: 16, weight: .bold)).foregroundColor(Pal.text)
                            Text("\(trips.timeLabel(trip.startTime)) - \(trips.timeLabel(trip.endTime ?? trip.startTime))  (\(fmtHm(st.totalHours)))")
                                .font(.system(size: 12)).foregroundColor(Pal.muted)
                        }
                        Spacer()
                        Text("EV").font(.system(size: 12, weight: .bold)).foregroundColor(Pal.green)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Pal.green.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(trips.routeOf(trip)).font(.system(size: 13)).foregroundColor(Pal.muted).padding(.vertical, 6)
                    StatStrip(items: summaryStrip([st]))
                }
                DarkCard {
                    Text("Trip Summary").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text).padding(.bottom, 4)
                    line("🚗 Travel Time", fmtHm(st.travelHours))
                    line("⚡ Recharge Time", fmtHm(st.chargeHours))
                    line("🍴 Meal Time", fmtHm(st.mealHours))
                    line("⋯ Other", fmtHm(st.otherHours))
                    Divider().background(Pal.cardBorder).padding(.vertical, 4)
                    line("Distance Travelled", String(format: "%.0f km", st.km))
                }
                DarkCard {
                    Text("Trip Timeline").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text)
                    ForEach(trips.timelineOf(trip)) { item in
                        TimelineRow(item: item, onEdit: item.stageStart != 0 ? {
                            if let s = trips.stopsOf(trip).first(where: { $0.startTime == item.stageStart }) { onEditStage(s) }
                        } : nil)
                    }
                }
                DarkCard {
                    Text("⚡ Energy & Cost").font(.system(size: 15, weight: .bold)).foregroundColor(Pal.text).padding(.bottom, 6)
                    StatStrip(items: [
                        ("Energy charged", String(format: "%.1f kWh", st.energyKwh)),
                        ("Cost", money(st.cost)),
                        ("Consumption", st.avgKwh100.map { String(format: "%.1f kWh/100km", $0) } ?? "--")
                    ])
                }
                HStack(spacing: 10) {
                    Button("Export CSV", action: onExportCsv).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    Button("Export PDF", action: onExportPdf).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                Button(action: onDelete) {
                    Text("Delete Trip").foregroundColor(Pal.red).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.red.opacity(0.6), lineWidth: 1))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}
