import Foundation
import CoreLocation
import Combine

/// Native weather for the tile: current location (CoreLocation) → Open-Meteo
/// (free, no API key). City name comes from Apple's reverse geocoder.
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    @Published private(set) var city: String?
    @Published private(set) var temp: Double?
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var code: Int?
    @Published private(set) var denied = false

    private let manager = CLLocationManager()
    private var lastFetch: Date = .distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Ask for location (first time prompts) and refresh at most every 10 minutes.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastFetch) > 600 else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized: manager.requestLocation()
        default: denied = true
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedAlways, .authorized: denied = false; m.requestLocation()
        case .denied, .restricted: denied = true
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        reverseGeocode(loc)
        fetch(loc.coordinate)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { }

    private func reverseGeocode(_ loc: CLLocation) {
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] places, _ in
            guard let p = places?.first else { return }
            DispatchQueue.main.async {
                self?.city = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea
            }
        }
    }

    private func fetch(_ c: CLLocationCoordinate2D) {
        var comp = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comp.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", c.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", c.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        guard let url = comp.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let data = data, err == nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let cur = obj["current"] as? [String: Any]
            let daily = obj["daily"] as? [String: Any]
            let t = cur?["temperature_2m"] as? Double
            let wc = cur?["weather_code"] as? Int
            let hi = (daily?["temperature_2m_max"] as? [Double])?.first
            let lo = (daily?["temperature_2m_min"] as? [Double])?.first
            DispatchQueue.main.async {
                if let t = t { self?.temp = t }
                if let wc = wc { self?.code = wc }
                self?.high = hi; self?.low = lo
                self?.lastFetch = Date()
            }
        }.resume()
    }

    /// WMO weather code → SF Symbol + short German description.
    static func describe(_ code: Int?) -> (symbol: String, text: String) {
        switch code {
        case 0:            return ("sun.max.fill", "Klar")
        case 1:            return ("sun.max.fill", "Überwiegend klar")
        case 2:            return ("cloud.sun.fill", "Teils bewölkt")
        case 3:            return ("cloud.fill", "Bewölkt")
        case 45, 48:       return ("cloud.fog.fill", "Nebel")
        case 51, 53, 55:   return ("cloud.drizzle.fill", "Nieselregen")
        case 56, 57:       return ("cloud.sleet.fill", "Gefrierender Niesel")
        case 61, 63, 65:   return ("cloud.rain.fill", "Regen")
        case 66, 67:       return ("cloud.sleet.fill", "Gefrierender Regen")
        case 71, 73, 75, 77: return ("cloud.snow.fill", "Schnee")
        case 80, 81, 82:   return ("cloud.heavyrain.fill", "Schauer")
        case 85, 86:       return ("cloud.snow.fill", "Schneeschauer")
        case 95:           return ("cloud.bolt.fill", "Gewitter")
        case 96, 99:       return ("cloud.bolt.rain.fill", "Gewitter mit Hagel")
        default:           return ("cloud.fill", "—")
        }
    }
}
