import CoreLocation
import Foundation

@MainActor
protocol CurrentLocationProviding {
    var isAuthorized: Bool { get }
    var hasReducedAccuracy: Bool { get }
    func currentLocation() async throws -> CLLocation
}

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
extension LocationService: CurrentLocationProviding {}
