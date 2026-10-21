import CoreLocation
import Foundation

final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    enum Mode { case stopped, foreground, background }
    private let manager = CLLocationManager()
    private var mode: Mode = .stopped
    private(set) var lastKnownCoordinate: CLLocationCoordinate2D?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    deinit {
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    func setMode(_ next: Mode) {
        guard mode != next else { return }
        mode = next
        if next == .stopped {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            manager.pausesLocationUpdatesAutomatically = true
            return
        }
        // A map alone never grants a location-based background keep-alive.
        manager.allowsBackgroundLocationUpdates = next == .background
        manager.pausesLocationUpdatesAutomatically = next != .background
        if next == .background {
            if manager.authorizationStatus == .notDetermined || manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
        } else if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastKnownCoordinate = locations.last?.coordinate
    }
}
