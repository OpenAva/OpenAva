import Foundation

/// WMO weather interpretation code → human-readable description
private let wmoDescriptions: [Int: String] = [
    0: "Clear sky",
    1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
    45: "Fog", 48: "Depositing rime fog",
    51: "Light drizzle", 53: "Moderate drizzle", 55: "Dense drizzle",
    61: "Slight rain", 63: "Moderate rain", 65: "Heavy rain",
    71: "Slight snow", 73: "Moderate snow", 75: "Heavy snow",
    77: "Snow grains",
    80: "Slight rain showers", 81: "Moderate rain showers", 82: "Violent rain showers",
    85: "Slight snow showers", 86: "Heavy snow showers",
    95: "Thunderstorm", 96: "Thunderstorm with slight hail", 99: "Thunderstorm with heavy hail",
]

/// Structured current weather conditions
struct WeatherCurrent: Codable {
    var temperature: Double
    var apparentTemperature: Double
    var humidity: Int
    var precipitation: Double
    var weatherCode: Int
    var condition: String
    var windSpeed: Double
    var windDirection: Int
    var surfacePressure: Double
    var isDay: Bool
    var temperatureUnit: String
    var windSpeedUnit: String
    var time: String
}

/// One day of daily forecast
struct WeatherDailyForecast: Codable {
    var date: String
    var weatherCode: Int
    var condition: String
    var temperatureMax: Double
    var temperatureMin: Double
    var precipitationSum: Double
    var windSpeedMax: Double
}

/// Full weather response returned to the LLM
struct WeatherResult: Codable {
    var location: String
    var latitude: Double
    var longitude: Double
    var timezone: String
    var current: WeatherCurrent
    var forecast: [WeatherDailyForecast]?
}

enum WeatherServiceError: Error, LocalizedError {
    case locationNotFound(String)
    case networkError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .locationNotFound(name): return "Location not found: \(name)"
        case let .networkError(msg): return "Network error: \(msg)"
        case .invalidResponse: return "Invalid response from weather API"
        }
    }
}

actor WeatherService {
    private static let geocodingBaseURL = "https://geocoding-api.open-meteo.com/v1/search"
    private static let forecastBaseURL = "https://api.open-meteo.com/v1/forecast"
    private static let timeoutSeconds: TimeInterval = 15

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeoutSeconds
        config.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: config)
    }

    /// Fetch weather for a named location (geocodes first) or direct coordinates.
    func fetchWeather(
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        forecastDays: Int = 1,
        temperatureUnit: String = "celsius"
    ) async throws -> WeatherResult {
        let (lat, lon, resolvedName) = try await resolveCoordinates(
            location: location, latitude: latitude, longitude: longitude
        )

        return try await fetchForecast(
            latitude: lat,
            longitude: lon,
            locationName: resolvedName,
            forecastDays: max(1, min(forecastDays, 16)),
            temperatureUnit: temperatureUnit
        )
    }

    // MARK: - Private

    private func resolveCoordinates(
        location: String?,
        latitude: Double?,
        longitude: Double?
    ) async throws -> (lat: Double, lon: Double, name: String) {
        if let lat = latitude, let lon = longitude {
            return (lat, lon, "lat:\(lat),lon:\(lon)")
        }
        guard let name = location, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WeatherServiceError.locationNotFound("No location or coordinates provided")
        }
        return try await geocode(name: name)
    }

    private func geocode(name: String) async throws -> (lat: Double, lon: Double, name: String) {
        var components = URLComponents(string: Self.geocodingBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw WeatherServiceError.networkError("Invalid geocoding URL")
        }

        struct GeoResponse: Decodable {
            struct GeoResult: Decodable {
                var latitude: Double
                var longitude: Double
                var name: String
                var country: String?
                var admin1: String?
            }

            var results: [GeoResult]?
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw WeatherServiceError.invalidResponse
        }

        let geo = try JSONDecoder().decode(GeoResponse.self, from: data)
        guard let first = geo.results?.first else {
            throw WeatherServiceError.locationNotFound(name)
        }

        var displayName = first.name
        if let region = first.admin1 { displayName += ", \(region)" }
        if let country = first.country { displayName += ", \(country)" }
        return (first.latitude, first.longitude, displayName)
    }

    private func fetchForecast(
        latitude: Double,
        longitude: Double,
        locationName: String,
        forecastDays: Int,
        temperatureUnit: String
    ) async throws -> WeatherResult {
        var components = URLComponents(string: Self.forecastBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: "\(latitude)"),
            URLQueryItem(name: "longitude", value: "\(longitude)"),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,surface_pressure,wind_speed_10m,wind_direction_10m,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max"),
            URLQueryItem(name: "temperature_unit", value: temperatureUnit == "fahrenheit" ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "\(forecastDays)"),
        ]
        guard let url = components.url else {
            throw WeatherServiceError.networkError("Invalid forecast URL")
        }

        struct ForecastResponse: Decodable {
            struct CurrentUnits: Decodable {
                var temperature_2m: String?
                var wind_speed_10m: String?
            }

            struct Current: Decodable {
                var time: String
                var temperature_2m: Double
                var apparent_temperature: Double
                var relative_humidity_2m: Int
                var precipitation: Double
                var weather_code: Int
                var surface_pressure: Double
                var wind_speed_10m: Double
                var wind_direction_10m: Int
                var is_day: Int
            }

            struct Daily: Decodable {
                var time: [String]
                var weather_code: [Int]
                var temperature_2m_max: [Double]
                var temperature_2m_min: [Double]
                var precipitation_sum: [Double]
                var wind_speed_10m_max: [Double]
            }

            var latitude: Double
            var longitude: Double
            var timezone: String
            var current_units: CurrentUnits?
            var current: Current
            var daily: Daily
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw WeatherServiceError.invalidResponse
        }

        let fr = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let c = fr.current
        let tempUnit = temperatureUnit == "fahrenheit" ? "°F" : "°C"
        let windUnit = fr.current_units?.wind_speed_10m ?? "km/h"

        let current = WeatherCurrent(
            temperature: c.temperature_2m,
            apparentTemperature: c.apparent_temperature,
            humidity: c.relative_humidity_2m,
            precipitation: c.precipitation,
            weatherCode: c.weather_code,
            condition: wmoDescriptions[c.weather_code] ?? "Unknown",
            windSpeed: c.wind_speed_10m,
            windDirection: c.wind_direction_10m,
            surfacePressure: c.surface_pressure,
            isDay: c.is_day != 0,
            temperatureUnit: tempUnit,
            windSpeedUnit: windUnit,
            time: c.time
        )

        let daily = fr.daily
        var forecastList: [WeatherDailyForecast] = []
        for i in daily.time.indices {
            forecastList.append(WeatherDailyForecast(
                date: daily.time[i],
                weatherCode: daily.weather_code[i],
                condition: wmoDescriptions[daily.weather_code[i]] ?? "Unknown",
                temperatureMax: daily.temperature_2m_max[i],
                temperatureMin: daily.temperature_2m_min[i],
                precipitationSum: daily.precipitation_sum[i],
                windSpeedMax: daily.wind_speed_10m_max[i]
            ))
        }

        return WeatherResult(
            location: locationName,
            latitude: fr.latitude,
            longitude: fr.longitude,
            timezone: fr.timezone,
            current: current,
            forecast: forecastList.isEmpty ? nil : forecastList
        )
    }
}
