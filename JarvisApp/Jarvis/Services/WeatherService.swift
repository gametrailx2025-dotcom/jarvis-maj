import Foundation

/// Météo Open-Meteo (gratuite, sans clé API).
enum WeatherService {
    private struct GeoResponse: Decodable {
        struct Result: Decodable { let latitude: Double; let longitude: Double; let name: String }
        let results: [Result]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double?
            let weather_code: Int
            let wind_speed_10m: Double?
            let relative_humidity_2m: Double?
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let precipitation_probability_max: [Int?]?
        }
        let current: Current
        let daily: Daily
    }

    enum WeatherError: LocalizedError {
        case cityNotFound(String)
        var errorDescription: String? {
            switch self { case .cityNotFound(let c): return "Ville introuvable : \(c)." }
        }
    }

    static func fetch(city: String) async throws -> WeatherInfo {
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"),
                          .init(name: "language", value: "fr"), .init(name: "format", value: "json")]
        let (gdata, _) = try await URLSession.shared.data(from: geo.url!)
        guard let place = try JSONDecoder().decode(GeoResponse.self, from: gdata).results?.first else {
            throw WeatherError.cityNotFound(city)
        }
        return try await fetch(latitude: place.latitude, longitude: place.longitude, name: place.name)
    }

    /// Météo pour des coordonnées précises (position de l'appareil).
    static func fetch(latitude: Double, longitude: Double, name: String) async throws -> WeatherInfo {
        var fc = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        fc.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "4"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
        ]
        let (fdata, _) = try await URLSession.shared.data(from: fc.url!)
        let f = try JSONDecoder().decode(ForecastResponse.self, from: fdata)
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        var days: [DayForecast] = []
        for (i, d) in f.daily.time.enumerated() where i < f.daily.weather_code.count {
            let rain = f.daily.precipitation_probability_max.flatMap { i < $0.count ? $0[i] : nil }
            days.append(DayForecast(date: parser.date(from: d) ?? Date(),
                                    min: f.daily.temperature_2m_min[i], max: f.daily.temperature_2m_max[i],
                                    code: f.daily.weather_code[i], rain: rain))
        }
        return WeatherInfo(city: name, temp: f.current.temperature_2m, feels: f.current.apparent_temperature,
                           code: f.current.weather_code, wind: f.current.wind_speed_10m,
                           humidity: f.current.relative_humidity_2m, days: days)
    }
}
