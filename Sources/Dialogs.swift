import SwiftUI

/// Fenêtre « lieu + ville + coûts » (début/fin de voyage, fin d'arrêt, modification).
struct PlaceDialog: View {
    let title: String
    let defaultAddress: String
    let costLabels: [String]
    let presets: [String]
    var initialName: String = ""
    var initialCosts: [Double?] = []
    var costHint: String? = nil
    var suggestions: [ChargeStation] = []
    let onConfirm: (String, String, [Double?]) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var costs: [String] = []
    @State private var loaded = false

    init(title: String, defaultAddress: String, costLabels: [String], presets: [String],
         initialName: String = "", initialCosts: [Double?] = [], costHint: String? = nil,
         suggestions: [ChargeStation] = [],
         onConfirm: @escaping (String, String, [Double?]) -> Void, onCancel: @escaping () -> Void) {
        self.title = title; self.defaultAddress = defaultAddress; self.costLabels = costLabels
        self.presets = presets; self.initialName = initialName; self.initialCosts = initialCosts
        self.costHint = costHint; self.suggestions = suggestions; self.onConfirm = onConfirm; self.onCancel = onCancel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundColor(Pal.text)
                if !presets.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { p in
                            Button(p) { name = (p == "Hotel") ? "Hotel: " : p }
                                .buttonStyle(.bordered).font(.system(size: 12))
                        }
                    }
                }
                if !suggestions.isEmpty {
                    Text("Nearby stations:").font(.system(size: 12)).foregroundColor(Pal.muted)
                    ForEach(suggestions) { st in
                        Button { name = st.name; if !st.city.isEmpty { address = st.city } } label: {
                            Text(st.name + (st.city.isEmpty ? "" : " - \(st.city)")).font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                field("Place name", text: $name, decimal: false)
                field("City", text: $address, decimal: false)
                ForEach(costLabels.indices, id: \.self) { i in
                    if i < costs.count { field(costLabels[i], text: $costs[i], decimal: true) }
                }
                if let h = costHint { Text(h).font(.system(size: 11)).foregroundColor(Pal.muted) }
                HStack(spacing: 10) {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered)
                    Spacer()
                    Button("Confirm") { onConfirm(name, address, costs.map { parseMoney($0) }) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 6)
            }
            .padding(20)
        }
        .background(Pal.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = initialName
            address = defaultAddress
            costs = costLabels.indices.map { i in
                if i < initialCosts.count, let v = initialCosts[i] { return String(format: "%.2f", v) }
                return ""
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, decimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundColor(Pal.muted)
            TextField("", text: text)
                .keyboardType(decimal ? .decimalPad : .default)
                .textFieldStyle(.roundedBorder)
        }
    }
}

enum SheetKind: Identifiable {
    case tripStart, tripEnd, stageEnd(StageType), edit(Stage), pendingCost(Stage)
    var id: String {
        switch self {
        case .tripStart: return "ts"
        case .tripEnd: return "te"
        case .stageEnd(let t): return "se-\(t.rawValue)"
        case .edit(let s): return "ed-\(s.startTime)-\(s.type.rawValue)"
        case .pendingCost(let s): return "pc-\(s.startTime)"
        }
    }
}

func costLabelsFor(_ t: StageType?) -> [String] {
    switch t {
    case .meal?: return ["Meal cost ($)"]
    case .charge?: return ["Charging cost ($)"]
    case .chargeMeal?: return ["Charging cost ($)", "Meal cost ($)"]
    default: return ["Cost ($)"]
    }
}

/// (meal, charge, other) selon le type d'étape et l'ordre des champs de costLabelsFor.
func splitCosts(_ t: StageType?, _ c: [Double?]) -> (Double?, Double?, Double?) {
    func at(_ i: Int) -> Double? { i < c.count ? c[i] : nil }
    switch t {
    case .meal?: return (at(0), nil, nil)
    case .charge?: return (nil, at(0), nil)
    case .chargeMeal?: return (at(1), at(0), nil)
    default: return (nil, nil, at(0))
    }
}
