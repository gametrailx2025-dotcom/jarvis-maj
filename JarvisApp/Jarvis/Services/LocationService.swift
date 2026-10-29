import CoreLocation
import Foundation

/// Position de l'appareil pour la météo. Le système affiche lui-même la demande d'autorisation
/// la première fois ; si elle est refusée, l'app utilise la ville saisie dans les Réglages.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        status = manager.authorizationStatus
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    /// Demande l'autorisation si besoin, puis renvoie la position (ou nil si refusée / indisponible).
    func currentLocation() async -> CLLocation? {
        let s = manager.authorizationStatus
        if s == .denied || s == .restricted || continuation != nil { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            continuation = c
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
            if s == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    /// Nom de la ville correspondant à une position.
    static func cityName(for location: CLLocation) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "fr_FR"))
        return placemarks?.first?.locality ?? placemarks?.first?.name
    }

    private func finish(_ location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: location)
        continuation = nil
    }

    private func authorizationChanged(_ s: CLAuthorizationStatus) {
        status = s
        guard continuation != nil else { return }
        switch s {
        case .notDetermined: break
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(s) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
