@preconcurrency import CoreLocation
@preconcurrency import CoreMotion
import Foundation

/// GPS (vitesse, distance, ville, frontières), baromètre (altitude). Continue en arrière-plan (mode "location").
@MainActor
final class LocationTracker: NSObject, ObservableObject {
    @Published var speedKph: Double?
    @Published var speedMph: Double?
    @Published var altitudeM: Double?
    @Published var altitudeBaroM: Double?
    @Published var city: String?
    @Published var lastLocation: CLLocation?
    @Published var fullAddress: String?
    @Published var country: String?
    @Published var adminArea: String?
    @Published var totalDistanceKm = 0.0
    @Published var maxSpeedKph = 0.0
    @Published var avgMovingSpeedKph: Double?
    @Published var running = false

    private let manager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let geocoder = CLGeocoder()
    private var prevLoc: CLLocation?
    private var movingSec = 0.0
    private var lastFix: Date?
    private var lastGeocodeAt = Date.distantPast
    private var baroBase: Double?
    private var lastRel = 0.0
    private var haveBaro = false

    func start() {
        guard !running else { return }
        running = true
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let rel = data?.relativeAltitude.doubleValue else { return }
                Task { @MainActor in self?.onRelative(rel) }
            }
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        baroBase = nil; haveBaro = false
    }

    func resetDistance() {
        totalDistanceKm = 0; prevLoc = nil
        maxSpeedKph = 0; avgMovingSpeedKph = nil; movingSec = 0; lastFix = nil
    }

    private func onRelative(_ rel: Double) {
        lastRel = rel
        haveBaro = true
        if baroBase == nil {
            guard let g = altitudeM else { return }
            baroBase = g - rel
        }
        altitudeBaroM = baroBase! + rel
    }

    fileprivate func onLocation(_ loc: CLLocation) {
        guard loc.horizontalAccuracy >= 0, abs(loc.timestamp.timeIntervalSinceNow) < 30 else { return }
        let hasSpeed = loc.speed >= 0
        // Ignore la dérive GPS à l'arrêt ; rattrape les trous de signal en ligne droite.
        if let prev = prevLoc {
            let d = prev.distance(from: loc)
            let gapSec = loc.timestamp.timeIntervalSince(prev.timestamp)
            let movingNow = !hasSpeed || loc.speed > 0.8
            let accuracyOk = loc.horizontalAccuracy <= 40
            let gapJump = gapSec > 15 && d > 150
            if accuracyOk && (movingNow || gapJump) { totalDistanceKm += d / 1000.0 }
        }
        prevLoc = loc
        lastLocation = loc
        let kph = hasSpeed ? loc.speed * 3.6 : 0.0
        speedKph = kph
        speedMph = kph / 1.60934
        if let lf = lastFix, kph > 3.0 { movingSec += min(max(loc.timestamp.timeIntervalSince(lf), 0), 5) }
        lastFix = loc.timestamp
        if loc.horizontalAccuracy <= 40 && kph > maxSpeedKph { maxSpeedKph = kph }
        if movingSec > 30 { avgMovingSpeedKph = totalDistanceKm / (movingSec / 3600.0) }

        if loc.verticalAccuracy >= 0 {
            altitudeM = loc.altitude
            if haveBaro && loc.verticalAccuracy <= 20 {
                if let base = baroBase { baroBase = base + 0.03 * (loc.altitude - (base + lastRel)) }
                else { baroBase = loc.altitude - lastRel }
                altitudeBaroM = baroBase! + lastRel
            }
        }

        if Date().timeIntervalSince(lastGeocodeAt) > 15 && !geocoder.isGeocoding {
            lastGeocodeAt = Date()
            geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "en_US")) { [weak self] marks, _ in
                guard let pm = marks?.first else { return }
                let town = pm.locality ?? pm.subAdministrativeArea ?? pm.administrativeArea
                let country = pm.country
                let admin = pm.administrativeArea
                let addr = [pm.subThoroughfare, pm.thoroughfare, pm.locality].compactMap { $0 }.joined(separator: " ")
                Task { @MainActor in
                    self?.city = town; self?.country = country; self?.adminArea = admin; self?.fullAddress = addr
                }
            }
        }
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in for l in locations { self.onLocation(l) } }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        if st == .authorizedWhenInUse || st == .authorizedAlways { manager.startUpdatingLocation() }
    }
}
