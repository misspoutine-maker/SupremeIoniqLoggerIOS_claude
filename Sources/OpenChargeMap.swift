import Foundation

struct ChargeStation: Identifiable {
    let name: String
    let address: String
    let city: String
    var id: String { name + address }
}

enum OpenChargeMap {
    /// Bornes proches (rayon en km). Liste vide si pas de clé, pas de réseau ou erreur.
    static func nearby(lat: Double, lon: Double, radiusKm: Double = 3.0) async -> [ChargeStation] {
        guard !Config.ocmApiKey.isEmpty else { return [] }
        let urlStr = "https://api.openchargemap.io/v3/poi/?output=json&latitude=\(lat)&longitude=\(lon)"
            + "&distance=\(radiusKm)&distanceunit=KM&maxresults=5&compact=true&verbose=false&key=\(Config.ocmApiKey)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return arr.compactMap { o in
                guard let info = o["AddressInfo"] as? [String: Any],
                      let name = info["Title"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                func s(_ k: String) -> String? {
                    guard let v = info[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    return v
                }
                let addr = [s("AddressLine1"), s("Town"), s("StateOrProvince")].compactMap { $0 }.joined(separator: ", ")
                return ChargeStation(name: name, address: addr, city: s("Town") ?? "")
            }
        } catch {
            return []
        }
    }
}
