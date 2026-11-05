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
            try Task.checkCancellation()
            let id = UUID()
            await withTaskCancellationHandler {
                await waitForSlot(id)
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

    private func waitForSlot(_ id: UUID) async {
        // Keep registration on this actor even when the cancellation handler runs elsewhere.
        await withCheckedContinuation(isolation: self) { continuation in
            // Cancellation can reach the actor before this waiter is registered.
            if Task.isCancelled { continuation.resume(); return }
            waiting.append((id, continuation))
        }
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
    private var manager = CLLocationManager()
    private var request: (id: UUID, continuation: CheckedContinuation<CLLocation, Error>, started: Bool)?

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
        guard request == nil else { throw LocationError.alreadyLocating }
        if manager.authorizationStatus != .notDetermined && !isAuthorized { throw LocationError.permissionDenied }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await beginRequest(requestID)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(requestID) }
        }
    }

    private func beginRequest(_ id: UUID) async throws -> CLLocation {
        try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
            // The cancellation handler may run before this continuation is registered.
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            guard request == nil else {
                continuation.resume(throwing: LocationError.alreadyLocating)
                return
            }
            guard manager.authorizationStatus == .notDetermined || isAuthorized else {
                continuation.resume(throwing: LocationError.permissionDenied)
                return
            }
            request = (id, continuation, false)
            if isAuthorized { requestLocationIfAuthorized() }
            else { manager.requestWhenInUseAuthorization() }
        }
    }

    private func requestLocationIfAuthorized() {
        guard isAuthorized, var current = request, !current.started else { return }
        current.started = true
        request = current
        manager.requestLocation()
    }

    private func cancelRequest(_ id: UUID) {
        guard request?.id == id else { return }
        finishRequest(.failure(CancellationError()))
        // A one-shot CoreLocation callback may still arrive after cancellation.
        // Retire its manager so it cannot complete the next request.
        manager.delegate = nil
        manager.stopUpdatingLocation()
        manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.delegate = self
    }

    private func finishRequest(_ result: Result<CLLocation, Error>) {
        guard let current = request else { return }
        request = nil
        current.continuation.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        if isAuthorized { requestLocationIfAuthorized() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            finishRequest(.failure(LocationError.permissionDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager else { return }
        if let location = locations.last { finishRequest(.success(location)) }
        else { finishRequest(.failure(LocationError.unavailable)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager else { return }
        finishRequest(.failure(LocationError.unavailable))
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

struct ExpiringMemoryCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let storedAt: Date
        var lastUse: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var useCounter: UInt64 = 0
    private let lifetime: TimeInterval
    private let capacity: Int

    init(lifetime: TimeInterval, capacity: Int) {
        self.lifetime = max(0, lifetime)
        self.capacity = max(1, capacity)
    }

    mutating func get(_ key: Key, now: Date = .now) -> Value? {
        guard var entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) < lifetime else {
            entries[key] = nil
            return nil
        }
        useCounter &+= 1
        entry.lastUse = useCounter
        entries[key] = entry
        return entry.value
    }

    mutating func set(_ value: Value, for key: Key, now: Date = .now) {
        useCounter &+= 1
        entries[key] = Entry(value: value, storedAt: now, lastUse: useCounter)
        entries = entries.filter { now.timeIntervalSince($0.value.storedAt) < lifetime }
        let overflow = entries.count - capacity
        guard overflow > 0 else { return }
        for (key, _) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }).prefix(overflow) {
            entries[key] = nil
        }
    }

    var count: Int { entries.count }
}

private struct DiscoverySearchKey: Hashable {
    let center: Coordinate
    let radius: Double
    let category: StopCategory
}

@MainActor
final class MapSearchService: NSObject, @MainActor MKLocalSearchCompleterDelegate {
    private struct DiscoveryFlight {
        let id: UUID
        let task: Task<[Place], Error>
        var waiters: Set<UUID>
    }

    private let completer = MKLocalSearchCompleter()
    private var completionHandler: (([MKLocalSearchCompletion]) -> Void)?
    private var suggestionGateTask: Task<Void, Never>?
    private var suggestionGateID = UUID()
    private var suggestionHasGate = false
    private var latestSuggestionQuery = ""
    private var latestSuggestionCoordinate: Coordinate?
    private var active: [UUID: MKLocalSearch] = [:]
    private var discoveryCache = ExpiringMemoryCache<DiscoverySearchKey, [Place]>(
        lifetime: DiscoveryTuning.cacheLifetime, capacity: DiscoveryTuning.maxCachedSearches)
    private var discoveryInflight: [DiscoverySearchKey: DiscoveryFlight] = [:]
    private let discoveryRequest: (@MainActor (Coordinate, Double, StopCategory) async throws -> [Place])?

    init(discoveryRequest: (@MainActor (Coordinate, Double, StopCategory) async throws -> [Place])? = nil) {
        self.discoveryRequest = discoveryRequest
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
        try Task.checkCancellation()
        let key = DiscoverySearchKey(center: center, radius: radius, category: category)
        if let cached = discoveryCache.get(key) {
            #if DEBUG
            await MapRequestGate.shared.recordCacheHit()
            #endif
            try Task.checkCancellation()
            return cached
        }
        let waiterID = UUID()
        let flight: DiscoveryFlight
        if var existing = discoveryInflight[key] {
            existing.waiters.insert(waiterID)
            discoveryInflight[key] = existing
            flight = existing
        } else {
            let task = Task { @MainActor [self] in
                try Task.checkCancellation()
                let places = try await performDiscovery(around: center, radius: radius, category: category)
                try Task.checkCancellation()
                discoveryCache.set(places, for: key)
                return places
            }
            flight = DiscoveryFlight(id: UUID(), task: task, waiters: [waiterID])
            discoveryInflight[key] = flight
        }
        let flightID = flight.id
        let task = flight.task
        defer { removeDiscoveryWaiter(key: key, flightID: flightID, waiterID: waiterID) }
        return try await withTaskCancellationHandler {
            let places = try await task.value
            try Task.checkCancellation()
            return places
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.removeDiscoveryWaiter(key: key, flightID: flightID, waiterID: waiterID)
            }
        }
    }

    private func removeDiscoveryWaiter(key: DiscoverySearchKey, flightID: UUID, waiterID: UUID) {
        guard var flight = discoveryInflight[key], flight.id == flightID,
              flight.waiters.remove(waiterID) != nil else { return }
        if flight.waiters.isEmpty {
            discoveryInflight[key] = nil
            flight.task.cancel()
        } else {
            discoveryInflight[key] = flight
        }
    }

    #if DEBUG
    func pendingDiscoveryWaiters(around center: Coordinate, radius: Double, category: StopCategory) -> Int {
        discoveryInflight[DiscoverySearchKey(center: center, radius: radius, category: category)]?.waiters.count ?? 0
    }
    #endif

    private func performDiscovery(around center: Coordinate, radius: Double, category: StopCategory) async throws -> [Place] {
        if let discoveryRequest { return try await discoveryRequest(center, radius, category) }
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
        discoveryInflight.values.forEach { $0.task.cancel() }
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
    private var values = ExpiringMemoryCache<String, RouteMetrics>(
        lifetime: DiscoveryTuning.cacheLifetime, capacity: DiscoveryTuning.maxCachedRoutes)

    func get(_ key: String) -> RouteMetrics? {
        values.get(key)
    }

    func set(_ value: RouteMetrics, for key: String) { values.set(value, for: key) }
}

@MainActor
final class DirectionsService {
    private struct RouteFlight {
        let id: UUID
        let task: Task<RouteMetrics, Error>
        var waiters: Set<UUID>
    }

    private let cache = RoutingCache()
    private var active: [UUID: MKDirections] = [:]
    private var inflight: [String: RouteFlight] = [:]
    private let routeRequest: (@MainActor (Place, Place) async throws -> RouteMetrics)?

    init(routeRequest: (@MainActor (Place, Place) async throws -> RouteMetrics)? = nil) {
        self.routeRequest = routeRequest
    }

    func route(from origin: Place, to destination: Place) async throws -> RouteMetrics {
        try Task.checkCancellation()
        let key = routeKey(from: origin, to: destination)
        if let cached = await cache.get(key) {
            #if DEBUG
            await MapRequestGate.shared.recordCacheHit()
            #endif
            try Task.checkCancellation()
            return cached
        }
        try Task.checkCancellation()
        let waiterID = UUID()
        let flight: RouteFlight
        if var existing = inflight[key] {
            existing.waiters.insert(waiterID)
            inflight[key] = existing
            flight = existing
        } else {
            let task = Task { @MainActor [self] in
                try Task.checkCancellation()
                let value = try await requestRoute(from: origin, to: destination)
                try Task.checkCancellation()
                await cache.set(value, for: key)
                return value
            }
            flight = RouteFlight(id: UUID(), task: task, waiters: [waiterID])
            inflight[key] = flight
        }
        let flightID = flight.id
        let task = flight.task
        defer { removeRouteWaiter(key: key, flightID: flightID, waiterID: waiterID) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.removeRouteWaiter(key: key, flightID: flightID, waiterID: waiterID)
            }
        }
    }

    private func removeRouteWaiter(key: String, flightID: UUID, waiterID: UUID) {
        guard var flight = inflight[key], flight.id == flightID,
              flight.waiters.remove(waiterID) != nil else { return }
        if flight.waiters.isEmpty {
            inflight[key] = nil
            flight.task.cancel()
        } else {
            inflight[key] = flight
        }
    }

    #if DEBUG
    func pendingRouteWaiters(from origin: Place, to destination: Place) -> Int {
        inflight[routeKey(from: origin, to: destination)]?.waiters.count ?? 0
    }
    #endif

    private func routeKey(from origin: Place, to destination: Place) -> String {
        "\(origin.coordinate.latitude.rounded(to: 4)),\(origin.coordinate.longitude.rounded(to: 4)):\(destination.coordinate.latitude.rounded(to: 4)),\(destination.coordinate.longitude.rounded(to: 4)):car"
    }

    func routeOptions(from origin: Place, to destination: Place) async throws -> [RouteMetrics] {
        try await calculate(from: origin, to: destination, alternates: true)
    }

    private func requestRoute(from origin: Place, to destination: Place) async throws -> RouteMetrics {
        if let routeRequest { return try await routeRequest(origin, destination) }
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
        inflight.values.forEach { $0.task.cancel() }
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
