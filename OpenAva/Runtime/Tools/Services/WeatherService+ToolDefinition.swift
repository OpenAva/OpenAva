import Foundation
import OpenClawKit
import OpenClawProtocol

extension WeatherService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "weather_get",
                command: "weather.get",
                description: "Get current weather conditions and optional multi-day forecast using Open-Meteo. Provide either a location name or latitude/longitude coordinates.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "location": [
                            "type": "string",
                            "description": "City or place name in English only (e.g. 'Tokyo', 'New York').",
                        ],
                        "latitude": [
                            "type": "number",
                            "description": "Latitude in decimal degrees. Requires longitude.",
                        ],
                        "longitude": [
                            "type": "number",
                            "description": "Longitude in decimal degrees. Requires latitude.",
                        ],
                        "forecastDays": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 16,
                            "description": "Number of forecast days to return (1 = today only, default 1).",
                        ],
                        "temperatureUnit": [
                            "type": "string",
                            "enum": ["celsius", "fahrenheit"],
                            "description": "Temperature unit (default: celsius).",
                        ],
                    ],
                    "anyOf": [
                        ["required": ["location"]],
                        ["required": ["latitude", "longitude"]],
                    ],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 16 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["weather.get"] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleWeatherInvoke(request)
        }
    }

    private func handleWeatherInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct WeatherParams: Decodable {
            var location: String?
            var latitude: Double?
            var longitude: Double?
            var forecastDays: Int?
            var temperatureUnit: String?
        }

        let params = (try? ToolInvocationHelpers.decodeParams(WeatherParams.self, from: request.paramsJSON)) ?? WeatherParams()
        let result = try await fetchWeather(
            location: params.location,
            latitude: params.latitude,
            longitude: params.longitude,
            forecastDays: params.forecastDays ?? 1,
            temperatureUnit: params.temperatureUnit ?? "celsius"
        )
        let current = result.current
        let forecastLines = (result.forecast ?? []).map { day in
            "- \(day.date): \(day.condition), \(day.temperatureMin)~\(day.temperatureMax)\(current.temperatureUnit), precip=\(day.precipitationSum)mm"
        }
        let forecastText = forecastLines.isEmpty ? "- (none)" : forecastLines.joined(separator: "\n")
        let text = """
        ## Weather
        - location: \(result.location) (\(result.latitude), \(result.longitude))
        - timezone: \(result.timezone)
        - now: \(current.condition), \(current.temperature)\(current.temperatureUnit), feels \(current.apparentTemperature)\(current.temperatureUnit)
        - humidity: \(current.humidity)%
        - wind: \(current.windSpeed) \(current.windSpeedUnit), direction \(current.windDirection)°

        ### Forecast
        \(forecastText)
        """
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }
}
