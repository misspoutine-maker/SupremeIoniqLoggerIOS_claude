import SwiftUI

let appVersion = "v1"

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Supreme Ioniq 6").font(.largeTitle).bold()
            Text("Étape 1 – squelette")
            Text(appVersion).font(.caption).foregroundColor(.secondary)
        }
    }
}
