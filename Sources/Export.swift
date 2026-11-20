import SwiftUI
import UIKit

private let dtDf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
private let dayDf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
private let hmDf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f }()
private func d(_ t: Int64) -> Date { Date(timeIntervalSince1970: Double(t) / 1000) }
private func fmtDT(_ t: Int64) -> String { dtDf.string(from: d(t)) }
private func fmtDay(_ t: Int64) -> String { dayDf.string(from: d(t)) }
private func fmtTime(_ t: Int64) -> String { hmDf.string(from: d(t)) }
private func hoursToHms(_ h: Double) -> String { let m = Int(h * 60); return String(format: "%d:%02d", m / 60, m % 60) }
private func f0(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "" }
private func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
private func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "" }
private func usd(_ v: Double?) -> String { v.map { String(format: "%.2f$", $0) } ?? "" }

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct ReportSection {
    let title: String
    let rows: [[String]]
    var newPage = false
}

private struct SummaryRow {
    var place: String, city: String, legKm: Double, cumKm: Double, time: String
    var legHours: Double, cumHours: Double, stopType: String
    var socArrival: Double?, socDeparture: Double?, energyKwh: Double?, cost: Double?
    var avgKw: Double? = nil, maxKw: Double? = nil
}

extension TripManager {
    /// Une ligne par arrêt, avec distance/temps de trajet et cumuls.
    private func buildSummary(_ trip: Stage) -> [SummaryRow] {
        var rows: [SummaryRow] = []
        var prevKm = trip.startKm, prevTime = trip.startTime, cumHours = 0.0
        rows.append(SummaryRow(place: trip.startName ?? "Start", city: trip.startAddress ?? "", legKm: 0, cumKm: 0,
                               time: fmtTime(trip.startTime), legHours: 0, cumHours: 0, stopType: "",
                               socArrival: nil, socDeparture: trip.startSoc, energyKwh: nil, cost: nil))
        for s in stopsOf(trip) {
            let legKm = s.startKm - prevKm
            let legHours = Double(s.startTime - prevTime) / 3_600_000.0
            cumHours += legHours
            rows.append(SummaryRow(place: s.endName ?? s.type.label, city: s.endAddress ?? "", legKm: legKm, cumKm: s.startKm,
                                   time: fmtTime(s.startTime), legHours: legHours, cumHours: cumHours, stopType: s.type.label,
                                   socArrival: s.startSoc, socDeparture: s.endSoc, energyKwh: s.energyKwh, cost: s.cost,
                                   avgKw: s.avgChargeKw, maxKw: s.maxChargeKw))
            prevKm = s.endKm
            prevTime = s.endTime ?? s.startTime
        }
        let endTime = trip.endTime ?? nowMs()
        let legKm = trip.endKm - prevKm
        let legHours = Double(endTime - prevTime) / 3_600_000.0
        cumHours += legHours
        rows.append(SummaryRow(place: trip.endName ?? "Arrival", city: trip.endAddress ?? "", legKm: legKm, cumKm: trip.endKm,
                               time: fmtTime(endTime), legHours: legHours, cumHours: cumHours, stopType: "",
                               socArrival: trip.endSoc, socDeparture: nil, energyKwh: nil, cost: nil))
        return rows
    }

    private func reportSections(only: Stage?) -> [ReportSection] {
        var sections: [ReportSection] = []
        let tripList = (only.map { [$0] } ?? stages.filter { $0.type == .trip }).sorted { $0.startTime < $1.startTime }
        let header = ["Date", "Location", "City", "Travel Dist.", "Total Dist", "Time", "Travel time", "Total travel time",
                      "Stop", "SOC Arrival", "SOC Departure", "Energy (kWh)", "Max kW", "Avg kW", "Cost", "kWh/100km"]
        let blank = [String](repeating: "", count: header.count)
        func row(_ cells: [Int: String]) -> [String] {
            var r = blank
            for (i, v) in cells { r[i] = v }
            return r
        }
        // regroupe par journée en gardant l'ordre
        var days: [String] = []
        for t in tripList { let dy = fmtDay(t.startTime); if !days.contains(dy) { days.append(dy) } }

        for day in days {
            let dayTrips = tripList.filter { fmtDay($0.startTime) == day }
            var rows: [[String]] = [header]
            var dayKm = 0.0, dayHours = 0.0, dayCharged = 0.0, dayNet = 0.0
            var meals = 0.0, charges = 0.0, others = 0.0
            for (t, trip) in dayTrips.enumerated() {
                if t > 0 { rows.append(blank) }
                let summary = buildSummary(trip)
                for (i, r) in summary.enumerated() {
                    rows.append([
                        i == 0 ? (t == 0 ? day : "Trip \(t + 1)") : "",
                        r.place, r.city,
                        i == 0 ? "" : String(format: "%.0f km", r.legKm),
                        i == 0 ? "" : String(format: "%.0f km", r.cumKm),
                        r.time,
                        i == 0 ? "" : hoursToHms(r.legHours),
                        i == 0 ? "" : hoursToHms(r.cumHours),
                        r.stopType, pct(r.socArrival), pct(r.socDeparture), f1(r.energyKwh), f0(r.maxKw), f0(r.avgKw),
                        usd(r.cost),
                        i == summary.count - 1 ? f1(trip.avgConsumptionWhKm.map { $0 / 10.0 }) : ""
                    ])
                }
                dayKm += trip.endKm - trip.startKm
                dayHours += summary.last?.cumHours ?? 0
                dayNet += trip.energyKwh ?? 0
                for s in stopsOf(trip) {
                    dayCharged += s.energyKwh ?? 0
                    meals += s.mealCostOf(); charges += s.chargeCostOf(); others += s.otherCostOf()
                }
            }
            rows.append(blank)
            rows.append(row([0: "Day total", 4: String(format: "%.0f km", dayKm), 7: hoursToHms(dayHours),
                             11: String(format: "%.1f", dayCharged), 14: usd(meals + charges + others),
                             15: dayKm > 0.5 ? String(format: "%.1f", dayNet * 100.0 / dayKm) : ""]))
            if meals > 0 { rows.append(row([1: "Meals", 14: usd(meals)])) }
            if charges > 0 { rows.append(row([1: "Charging", 14: usd(charges)])) }
            if others > 0 { rows.append(row([1: "Other", 14: usd(others)])) }
            sections.append(ReportSection(title: "Summary - \(day)", rows: rows, newPage: true))

            var borderRows: [[String]] = []
            for tr in dayTrips {
                for b in tr.borders {
                    borderRows.append([fmtDT(tr.startTime), [b.country, b.adminArea].compactMap { $0 }.joined(separator: " / "),
                                       String(format: "%.1f", b.kmAtCrossing), String(format: "%.1f", b.segmentKm),
                                       String(format: "%.2f", b.hoursElapsed), fmtDT(b.time)])
                }
            }
            if !borderRows.isEmpty {
                sections.append(ReportSection(title: "Border crossings - \(day)",
                                        rows: [["Trip start", "Location", "Kilometer", "Distance", "Hours", "Time"]] + borderRows))
            }
        }

        if only == nil {
            let sessions = stages.filter { $0.standalone }.sorted { $0.startTime < $1.startTime }
            if !sessions.isEmpty {
                let hdr = ["Date", "Start", "End", "Place", "City", "SOC Start", "SOC End", "Energy (kWh)", "Max kW", "Avg kW", "Cost"]
                let rows = sessions.map { st in
                    [fmtDay(st.startTime), fmtTime(st.startTime), st.endTime.map { fmtTime($0) } ?? "",
                     st.endName ?? "", st.endAddress ?? "", pct(st.startSoc), pct(st.endSoc),
                     f1(st.energyKwh), f0(st.maxChargeKw), f0(st.avgChargeKw), usd(st.cost)]
                }
                sections.append(ReportSection(title: "Charging sessions (outside trips)", rows: [hdr] + rows, newPage: true))
            }
        }
        return sections
    }

    private func exportURL(_ ext: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("supreme_ioniq6_\(nowMs()).\(ext)")
    }

    func exportCsv(only: Stage? = nil) -> URL? {
        var sb = ""
        for sec in reportSections(only: only) {
            sb += sec.title + "\n"
            for r in sec.rows { sb += r.map { $0.replacingOccurrences(of: ";", with: ",") }.joined(separator: ";") + "\n" }
            sb += "\n"
        }
        let url = exportURL("csv")
        do { try ("\u{FEFF}" + sb).write(to: url, atomically: true, encoding: .utf8) } catch { return nil }   // BOM : Excel affiche les accents
        return url
    }

    func exportPdf(only: Stage? = nil) -> URL? {
        let pageRect = CGRect(x: 0, y: 0, width: 842, height: 595)   // paysage
        let baseSize: CGFloat = 9
        let sections = reportSections(only: only)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            var y: CGFloat = 36
            ctx.beginPage()
            func newPage() { ctx.beginPage(); y = 36 }
            func draw(_ s: String, x: CGFloat, font: UIFont) {
                (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
            func title(_ text: String) {
                if y > 540 { newPage() }
                draw(text, x: 36, font: .boldSystemFont(ofSize: 13))
                y += 20
            }
            title("Supreme Ioniq 6 Logger - Trip report")
            y -= 6
            draw(dtDf.string(from: Date()), x: 36, font: .systemFont(ofSize: baseSize))
            y += 14
            for sec in sections {
                if sec.newPage && y > 100 { newPage() }
                title(sec.title)
                // Colonnes alignées ; la police est réduite si le tableau dépasse la largeur de page.
                let n = sec.rows.map { $0.count }.max() ?? 0
                var widths = [CGFloat](repeating: 0, count: n)
                let measure = UIFont.systemFont(ofSize: baseSize)
                for r in sec.rows { for (c, s) in r.enumerated() {
                    widths[c] = max(widths[c], (s as NSString).size(withAttributes: [.font: measure]).width)
                } }
                let gap: CGFloat = 8
                let total = widths.reduce(0, +) + gap * CGFloat(n)
                let scale: CGFloat = total > 770 ? 770 / total : 1
                let font = UIFont.systemFont(ofSize: baseSize * scale)
                let bold = UIFont.boldSystemFont(ofSize: baseSize * scale)
                for (ri, r) in sec.rows.enumerated() {
                    if r.allSatisfy({ $0.isEmpty }) { y += 8; continue }
                    if y > 560 { newPage() }
                    var x: CGFloat = 36
                    for c in r.indices {
                        draw(r[c], x: x, font: ri == 0 ? bold : font)
                        x += (widths[c] + gap) * scale
                    }
                    y += 13
                }
                y += 12
            }
        }
        let url = exportURL("pdf")
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}
