import SwiftUI

@main
struct SupremeApp: App {
    @StateObject private var obd = ObdBle()
    @StateObject private var gps = LocationTracker()
    @StateObject private var trips = TripManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(obd)
                .environmentObject(gps)
                .environmentObject(trips)
                .preferredColorScheme(.dark)
        }
    }
}
