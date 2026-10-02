import CoreLocation
import Foundation
import MapKit

actor MapRequestGate {
    static let shared = MapRequestGate()
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Never>)] = []
    #if DEBUG
    private var started = 0
    private var peak = 0
    private var cacheHits = 0

    struct Metrics: Sendable {
        let started: Int
        let active: Int
        let peak: Int
        let waiting: Int
        let cacheHits: Int
    }

    func metrics() -> Metrics {
        Metrics(started: started, active: active, peak: peak, waiting: waiting.count,
                cacheHits: cacheHits)
    }

    func recordCacheHit() { cacheHits += 1 }
    #endif

    func acquire() async throws {
        while active >= DiscoveryTuning.maxConcurrentRequests {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in waiting.append((id, continuation)) }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        active += 1
        #if DEBUG
        started += 1
        peak = max(peak, active)
        #endif
    }

    func release() {
        active = max(0, active - 1)
        let queued = waiting
        waiting.removeAll()
        queued.forEach { $0.1.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume()
    }
}

@MainActor
final class LocationService: NSObject, @MainActor CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse
    }

    var hasReducedAccuracy: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    func currentLocation() async throws -> CLLocation {
        guard continuation == nil else { throw LocationError.alreadyLocating }
        if manager.authorizationStatus != .notDetermined && !isAuthorized { throw LocationError.permissionDenied }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if isAuthorized { manager.requestLocation() }
                else { manager.requestWhenInUseAuthorization() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                manager.stopUpdatingLocation()
                continuation?.resume(throwing: CancellationError())
                continuation = nil
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isAuthorized, continuation != nil { manager.requestLocation() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            continuation?.resume(throwing: LocationError.permissionDenied)
            continuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { continuation?.resume(returning: location) }
        else { continuation?.resume(throwing: LocationError.unavailable) }
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: LocationError.unavailable)
        continuation = nil
    }

    enum LocationError: LocalizedError {
        case permissionDenied, unavailable, alreadyLocating
        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Location is off. Choose a starting place to continue."
            case .unavailable: "Your location is unavailable. Try again or choose a starting place."
            case .alreadyLocating: "Still finding your location."
            }
        }
    }
}

@MainActor
final class MapSearchService: NSObject, @MainActor MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private var completionHandler: (([MKLocalSearchCompletion]) -> Void)?
    private var suggestionGateTask: Task<Void, Never>?
    private var suggestionGateID = UUID()
    private var suggestionHasGate = false
    private var latestSuggestionQuery = ""
    private var latestSuggestionCoordinate: Coordinate?
    private var active: [UUID: MKLocalSearch] = [:]
    private var discoveryCache: [String: ([Place], Date)] = [:]
    private var discoveryInflight: [String: (UUID, Task<[Place], Error>)] = [:]

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func suggestions(for query: String, near coordinate: Coordinate?, onUpdate: @escaping ([MKLocalSearchCompletion]) -> Void) {
        completionHandler = onUpdate
        latestSuggestionQuery = query
        latestSuggestionCoordinate = coordinate
        guard !query.isEmpty else {
            cancelSuggestions()
            onUpdate([])
            return
        }
        if suggestionHasGate { configureSuggestions(); return }
        guard suggestionGateTask == nil else { return }
        let gateID = UUID()
        suggestionGateID = gateID
        suggestionGateTask = Task { [weak self] in
            guard let self else { return }
            var acquired = false
            do {
                try await MapRequestGate.shared.acquire()
                acquired = true
                try Task.checkCancellation()
                guard completionHandler != nil else { throw CancellationError() }
                suggestionHasGate = true
                configureSuggestions()
            } catch {
                if acquired { await MapRequestGate.shared.release() }
            }
            if suggestionGateID == gateID { suggestionGateTask = nil }
        }
    }

    private func configureSuggestions() {
        if let coordinate = latestSuggestionCoordinate {
            completer.region = MKCoordinateRegion(center: coordinate.clLocation,
                                                  latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        }
        completer.queryFragment = latestSuggestionQuery
    }

    func cancelSuggestions() {
        suggestionGateTask?.cancel()
        suggestionGateID = UUID()
        suggestionGateTask = nil
        completer.cancel()
        completionHandler = nil
        if suggestionHasGate {
            suggestionHasGate = false
            Task { await MapRequestGate.shared.release() }
        }
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { completionHandler?(completer.results) }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { completionHandler?([]) }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Place {
        let request = MKLocalSearch.Request(completion: completion)
        let response = try await search(request)
        guard let item = response.mapItems.first else { throw SearchError.noResults }
        return Place(item: item)
    }

    func discover(around center: Coordinate, radius: Double, category: StopCategory) async throws -> [Place] {
        let key = "\(Int((center.latitude * 100).rounded())):\(Int((center.longitude * 100).rounded())):\(Int(radius)):\(category.rawValue)"
        if let cached = discoveryCache[key], Date().timeIntervalSince(cached.1) < DiscoveryTuning.cacheLifetime {
            #if DEBUG
            await MapRequestGate.shared.recordCacheHit()
            #endif
            return cached.0
        }
        if let pending = discoveryInflight[key] { return try await pending.1.value }
        let requestID = UUID()
        let task = Task { @MainActor in try await performDiscovery(around: center, radius: radius, category: category) }
        discoveryInflight[key] = (requestID, task)
        defer { if discoveryInflight[key]?.0 == requestID { discoveryInflight[key] = nil } }
        let places = try await task.value
        try Task.checkCancellation()
        discoveryCache[key] = (places, .now)
        return places
    }

    private func performDiscovery(around center: Coordinate, radius: Double, category: StopCategory) async throws -> [Place] {
        let response: MKLocalSearch.Response
        if let structured = category.structuredCategory {
            let request = MKLocalPointsOfInterestRequest(center: center.clLocation, radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [structured])
            response = try await search(request)
        } else {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = category.searchQuery
            request.region = MKCoordinateRegion(center: center.clLocation,
                                                latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
            response = try await search(request)
        }
        return response.mapItems.map { Place(item: $0, category: category) }
    }

    private func search(_ request: MKLocalSearch.Request) async throws -> MKLocalSearch.Response {
        try await run(MKLocalSearch(request: request))
    }

    private func search(_ request: MKLocalPointsOfInterestRequest) async throws -> MKLocalSearch.Response {
        try await run(MKLocalSearch(request: request))
    }

    private func run(_ search: MKLocalSearch) async throws -> MKLocalSearch.Response {
        let id = UUID()
        active[id] = search
        defer { active[id] = nil }
        try await MapRequestGate.shared.acquire()
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await search.start()
            } onCancel: {
                Task { @MainActor [weak self] in self?.active[id]?.cancel() }
            }
            await MapRequestGate.shared.release()
            return response
        } catch {
            await MapRequestGate.shared.release()
            throw error
        }
    }

    func cancelAll() {
        cancelSuggestions()
        discoveryInflight.values.forEach { $0.1.cancel() }
        discoveryInflight.removeAll()
        active.values.forEach { $0.cancel() }
        active.removeAll()
    }

    enum SearchError: LocalizedError {
        case noResults
        var errorDescription: String? { "No matching place was found. Try another search." }
    }
}

private extension StopCategory {
    var structuredCategory: MKPointOfInterestCategory? {
        switch self {
        case .food: .restaurant
        case .coffee: .cafe
        case .park: .park
        case .shopping: .store
        case .dessert: .bakery
        case .fuel: .gasStation
        default: nil
        }
    }

    var searchQuery: String {
        switch self {
        case .scenic: "scenic viewpoint"
        case .nature: "nature attraction"
        case .attractions: "tourist attraction"
        case .restStop: "rest stop"
        case .localFood: "local food"
        case .nasiLemak: "nasi lemak"
        case .mamak: "mamak"
        case .restArea: "R&R rest area"
        case .surau: "surau mosque"
        case .beach: "beach"
        case .waterfall: "waterfall"
        case .viewpoint: "viewpoint"
        case .charging: "EV charging station"
        case .atm: "ATM"
        case .pharmacy: "pharmacy"
        case .groceries: "grocery store"
        default: title
        }
    }
}

actor RoutingCache {
    private var values: [String: (RouteMetrics, Date)] = [:]

    func get(_ key: String) -> RouteMetrics? {
        guard let value = values[key], Date().timeIntervalSince(value.1) < DiscoveryTuning.cacheLifetime else { return nil }
        return value.0
    }

    func set(_ value: RouteMetrics, for key: String) { values[key] = (value, .now) }
}

@MainActor
final class DirectionsService {
    private let cache = RoutingCache()
    private var active: [UUID: MKDirections] = [:]
    private var inflight: [String: (UUID, Task<RouteMetrics, Error>)] = [:]

    func route(from origin: Place, to destination: Place) async throws -> RouteMetrics {
        let key = "\(origin.coordinate.latitude.rounded(to: 4)),\(origin.coordinate.longitude.rounded(to: 4)):\(destination.coordinate.latitude.rounded(to: 4)),\(destination.coordinate.longitude.rounded(to: 4)):car"
        if let cached = await cache.get(key) {
            #if DEBUG
            await MapRequestGate.shared.recordCacheHit()
            #endif
            return cached
        }
        if let pending = inflight[key] { return try await pending.1.value }
        let requestID = UUID()
        let task = Task { @MainActor in try await requestRoute(from: origin, to: destination) }
        inflight[key] = (requestID, task)
        defer { if inflight[key]?.0 == requestID { inflight[key] = nil } }
        let value = try await task.value
        try Task.checkCancellation()
        await cache.set(value, for: key)
        return value
    }

    func routeOptions(from origin: Place, to destination: Place) async throws -> [RouteMetrics] {
        try await calculate(from: origin, to: destination, alternates: true)
    }

    private func requestRoute(from origin: Place, to destination: Place) async throws -> RouteMetrics {
        guard let first = try await calculate(from: origin, to: destination, alternates: false).first else {
            throw DirectionsError.noRoute
        }
        return first
    }

    private func calculate(from origin: Place, to destination: Place, alternates: Bool) async throws -> [RouteMetrics] {
        let request = MKDirections.Request()
        request.source = origin.mapItem()
        request.destination = destination.mapItem()
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternates
        let directions = MKDirections(request: request)
        let id = UUID()
        active[id] = directions
        defer { active[id] = nil }
        try await MapRequestGate.shared.acquire()
        let response: MKDirections.Response
        do {
            response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await directions.calculate()
            } onCancel: {
                Task { @MainActor [weak self] in self?.active[id]?.cancel() }
            }
            await MapRequestGate.shared.release()
        } catch {
            await MapRequestGate.shared.release()
            throw error
        }
        guard !response.routes.isEmpty else { throw DirectionsError.noRoute }
        return response.routes.prefix(3).map { route in
            let points = route.polyline.points()
            let path = (0..<route.polyline.pointCount).map { Coordinate(points[$0].coordinate) }
            return RouteMetrics(duration: route.expectedTravelTime, distance: route.distance, path: path)
        }.sorted { $0.duration < $1.duration }
    }

    func cancelAll() {
        active.values.forEach { $0.cancel() }
        active.removeAll()
        inflight.values.forEach { $0.1.cancel() }
        inflight.removeAll()
    }

    enum DirectionsError: LocalizedError {
        case noRoute
        var errorDescription: String? { "No driving route is available for those places." }
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let multiplier = pow(10, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}
