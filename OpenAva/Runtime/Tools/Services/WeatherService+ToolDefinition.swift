import Foundation
import OpenClawKit
import OpenClawProtocol

extension WeatherService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
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
                ] as [String: Any])
            ),
        ]
    }
}
