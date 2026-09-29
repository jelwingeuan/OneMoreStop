import Foundation

@MainActor
protocol DrivingDirectionsProviding {
    func route(from origin: Place, to destination: Place) async throws -> RouteMetrics
}

@MainActor
protocol PlaceDiscoveryProviding {
    func discover(around center: Coordinate, radius: Double, category: StopCategory) async throws -> [Place]
}

extension DirectionsService: DrivingDirectionsProviding {}
extension MapSearchService: PlaceDiscoveryProviding {}
