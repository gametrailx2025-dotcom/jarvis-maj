import CoreLocation
import Foundation

/// Temps de trajet sans clé API : Photon (adresses) + OSRM (routes), données OpenStreetMap.
/// Pas de trafic en temps réel : pour le trafic, JARVIS affiche Google Maps.
@MainActor
enum TravelService {
    private struct Place {
        let lat: Double
        let lon: Double
        let label: String
    }

    static func route(to destination: String, from origin: String?, mode: String, model: AppModel) async -> String {
        var start: Place?
        if let origin {
            start = await geocode(origin, near: nil)
            if start == nil { return "Je ne trouve pas « \(origin) » sur la carte." }
        } else if let here = await model.location.currentLocation() {
            start = Place(lat: here.coordinate.latitude, lon: here.coordinate.longitude, label: "votre position")
        }
        guard let from = start else {
            return "Je ne connais pas votre position : autorisez la localisation, ou dites « trajet de Lyon à Paris »."
        }
        guard let to = await geocode(destination, near: (from.lat, from.lon)) else {
            return "Je ne trouve pas « \(destination) » sur la carte."
        }
        let (base, label): (String, String) = {
            switch mode {
            case "foot": return ("https://routing.openstreetmap.de/routed-foot/route/v1/foot", "à pied")
            case "bike": return ("https://routing.openstreetmap.de/routed-bike/route/v1/bike", "à vélo")
            default: return ("https://router.project-osrm.org/route/v1/driving", "en voiture")
            }
        }()
        guard let url = URL(string: "\(base)/\(from.lon),\(from.lat);\(to.lon),\(to.lat)?overview=false"),
              let json = await getJSON(url),
              let route = (json["routes"] as? [[String: Any]])?.first,
              let duration = route["duration"] as? Double, let distance = route["distance"] as? Double else {
            return "Le calcul d'itinéraire ne répond pas. Réessayez dans un instant."
        }
        let km = distance / 1000
        let dist = km >= 10 ? "\(Int(km.rounded())) kilomètres"
                            : String(format: "%.1f kilomètres", km).replacingOccurrences(of: ".", with: ",")
        var text = "Pour aller à \(to.label) \(label) : environ \(durationFR(duration)), \(dist)."
        if mode == "driving" { text += " Sans le trafic en temps réel : dites « trafic pour \(destination) » pour le voir." }
        return text
    }

    private static func durationFR(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) minute\(minutes > 1 ? "s" : "")" }
        let h = minutes / 60, m = minutes % 60
        return "\(h) heure\(h > 1 ? "s" : "")" + (m > 0 ? String(format: " %02d", m) : "")
    }

    private static func geocode(_ place: String, near: (Double, Double)?) async -> Place? {
        var comps = URLComponents(string: "https://photon.komoot.io/api/")
        var items = [URLQueryItem(name: "q", value: place), URLQueryItem(name: "limit", value: "1"),
                     URLQueryItem(name: "lang", value: "fr")]
        if let near {
            items.append(URLQueryItem(name: "lat", value: String(near.0)))
            items.append(URLQueryItem(name: "lon", value: String(near.1)))
        }
        comps?.queryItems = items
        guard let url = comps?.url, let json = await getJSON(url),
              let feature = (json["features"] as? [[String: Any]])?.first,
              let coords = (feature["geometry"] as? [String: Any])?["coordinates"] as? [Double], coords.count >= 2 else {
            return nil
        }
        let props = feature["properties"] as? [String: Any] ?? [:]
        var label = props["name"] as? String ?? place
        if let city = props["city"] as? String, city != label { label += ", \(city)" }
        return Place(lat: coords[1], lon: coords[0], label: label)
    }

    private static func getJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("JARVIS-assistant/1.0", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
    }
}
