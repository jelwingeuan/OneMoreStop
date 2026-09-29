import Foundation

// A provider can be supplied later when a real weather source is configured.
// No weather or sunset claims are rendered while the provider is unconfigured.
struct WeatherContext: Sendable {
    let summary: String
    let observedAt: Date
    let sourceName: String
}

protocol WeatherContextProviding: Sendable {
    func current(at coordinate: Coordinate) async throws -> WeatherContext?
}

struct UnconfiguredWeatherProvider: WeatherContextProviding {
    func current(at coordinate: Coordinate) async throws -> WeatherContext? { nil }
}
