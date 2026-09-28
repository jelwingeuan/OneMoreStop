import Foundation
import MapKit
import Observation
import SwiftUI

@MainActor @Observable
final class AppState {
    var origin: Place?
    var destination: Place?
    var route: RoutePlan?
    var journey: Journey?
    var focusedRecommendationID: String?
    var recommendations = [StopRecommendation]()
    var phase: DiscoveryPhase = .idle
    var budgetMinutes = 20
    var defaultBudgetMinutes = 20
    var mode: DiscoveryMode = .eat
    var mood: DiscoveryMood = .any
    var localFirst = false
    var evJourney = false
    var exploringArea = false
    var travelerProgress = 0.0
    var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687), latitudinalMeters: 120_000, longitudinalMeters: 120_000))
    var cameraWasMovedByUser = false
    var locationMessage: String?
    var journeyMessage: String?
    var journeyBusy = false
    var openedLegCount = 0
    var surpriseIndex = 0
    var showSurpriseAlternatives = false

    var selectedStops: [Place] { journey?.stops ?? [] }
    var canAddStop: Bool { selectedStops.count < DiscoveryTuning.maxStops }
    var surpriseChoice: StopRecommendation? {
        guard !recommendations.isEmpty else { return nil }
        return recommendations[surpriseIndex % recommendations.count]
    }

    private let location = LocationService()
    let search = MapSearchService()
    private let directions = DirectionsService()
    private var discoveryTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var journeyTask: Task<Void, Never>?
    private var verified: [StopRecommendation] = []
    private var verifiedBudget = 0
    private var verifiedMode: DiscoveryMode?
    private var verifiedRouteID: UUID?
    private var verifiedStopIDs = [String]()
    private var discoveryID = UUID()

    func useCurrentLocationIfAuthorized() async {
        if location.isAuthorized && origin == nil { await useCurrentLocation() }
    }

    func useCurrentLocation() async {
        do {
            let position = try await location.currentLocation()
            let coordinate = Coordinate(position.coordinate)
            origin = Place(id: "current-origin", name: "Current Location", coordinate: coordinate)
            locationMessage = location.hasReducedAccuracy
                ? "Approximate location is on. Choose a starting place for more precise detours."
                : nil
            if destination != nil { calculateRoute(resetBudget: route == nil) }
        } catch { locationMessage = error.localizedDescription }
    }

    func refreshTravelerProgress() async {
        guard location.isAuthorized, let route else { return }
        if let position = try? await location.currentLocation() {
            let progress = GeoMath.routeProximity(Coordinate(position.coordinate), path: route.baseline.path).progress
            if abs(progress - travelerProgress) > 0.02 {
                travelerProgress = progress
                discover()
            }
        }
    }

    func setOrigin(_ place: Place) {
        origin = place
        locationMessage = nil
        if destination != nil { calculateRoute(resetBudget: route == nil) }
    }

    func setDestination(_ place: Place) {
        destination = place
        if origin != nil { calculateRoute(resetBudget: true) }
    }

    private func cancelWork() {
        routeTask?.cancel()
        discoveryTask?.cancel()
        journeyTask?.cancel()
        directions.cancelAll()
        search.cancelAll()
    }

    func calculateRoute(resetBudget: Bool = false) {
        cancelWork()
        guard let origin, let destination else { return }
        if resetBudget { budgetMinutes = defaultBudgetMinutes }
        journeyBusy = false
        journeyMessage = nil
        route = nil
        journey = nil
        openedLegCount = 0
        cameraWasMovedByUser = false
        recommendations = []
        verified = []
        verifiedRouteID = nil
        phase = .findingRoute
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let baseline = try await directions.route(from: origin, to: destination)
                try Task.checkCancellation()
                let plan = RoutePlan(id: UUID(), origin: origin, destination: destination, baseline: baseline, createdAt: .now)
                route = plan
                journey = Journey(stops: [], legs: [baseline], baseline: baseline)
                travelerProgress = 0
                if !cameraWasMovedByUser { fitCamera(to: baseline.path) }
                discover()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed("Couldn’t find a driving route. Check the places and try again.")
            }
        }
    }

    func selectBudget(_ minutes: Int) {
        guard !journeyBusy, budgetMinutes != minutes else { return }
        budgetMinutes = minutes
        if verifiedMode == mode && verifiedRouteID == route?.id &&
            verifiedStopIDs == selectedStops.map(\.id) && minutes <= verifiedBudget {
            discoveryTask?.cancel()
            recommendations = Array(StopScoringService.withinBudget(verified, minutes: minutes)
                .prefix(DiscoveryTuning.maxRecommendations))
            phase = recommendations.isEmpty ? .noResults : .loaded
        } else { discover() }
    }

    func selectMode(_ value: DiscoveryMode) {
        guard !journeyBusy, mode != value else { return }
        mode = value
        surpriseIndex = 0
        showSurpriseAlternatives = false
        discover()
    }

    func selectMood(_ value: DiscoveryMood) {
        guard !journeyBusy, mood != value else { return }
        mood = value
        discover()
    }

    func selectPreset(_ preset: DiscoveryPreset) {
        guard !journeyBusy else { return }
        mode = preset.mode
        budgetMinutes = preset.minutes
        surpriseIndex = 0
        showSurpriseAlternatives = false
        discover()
    }

    func discover() {
        guard !journeyBusy else { return }
        discoveryTask?.cancel()
        directions.cancelAll()
        search.cancelAll()
        verifiedRouteID = nil
        verified = []
        guard let route, let journey, canAddStop else {
            recommendations = []
            phase = .loaded
            return
        }
        let mode = mode
        let mood = mood
        let budget = budgetMinutes
        let requestID = UUID()
        discoveryID = requestID
        recommendations = []
        phase = .discoveringPlaces
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await RouteCorridorService(search: search).candidates(
                    for: route, journey: journey, mode: mode, mood: mood, budgetMinutes: budget,
                    localFirst: localFirst, evJourney: evJourney)
                try Task.checkCancellation()
                guard discoveryID == requestID else { return }
                phase = .calculatingDetours
                let ranked = try await DetourEngine(directions: directions).recommendations(
                    for: route, journey: journey, candidates: candidates, mode: mode, mood: mood,
                    localFirst: localFirst, travelerProgress: travelerProgress,
                    exploringArea: exploringArea, budgetMinutes: budget) { [weak self] partial in
                        guard let self, discoveryID == requestID else { return }
                        recommendations = Array(partial.prefix(DiscoveryTuning.maxRecommendations))
                    }
                try Task.checkCancellation()
                guard discoveryID == requestID else { return }
                verified = ranked
                verifiedBudget = budget
                verifiedMode = mode
                verifiedRouteID = route.id
                verifiedStopIDs = journey.stops.map(\.id)
                recommendations = Array(StopScoringService.withinBudget(ranked, minutes: budget)
                    .prefix(DiscoveryTuning.maxRecommendations))
                phase = recommendations.isEmpty ? .noResults : .loaded
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, discoveryID == requestID else { return }
                phase = .failed("Couldn’t check stops right now. Check your connection and try again.")
            }
        }
    }

    func addStop(_ recommendation: StopRecommendation) -> Bool {
        guard !journeyBusy, let journey, canAddStop else { return false }
        let index = min(recommendation.insertionIndex, journey.stops.count)
        var legs = journey.legs
        legs.replaceSubrange(index...index, with: [recommendation.firstLeg, recommendation.secondLeg])
        let updated = Journey(stops: JourneyMath.inserted(recommendation.place, into: journey.stops, at: index),
                              legs: legs, baseline: journey.baseline)
        guard updated.extraDuration <= Double(budgetMinutes * 60) + 1 else {
            journeyMessage = "This stop now exceeds your extra driving time budget. Try a wider budget."
            return false
        }
        self.journey = updated
        openedLegCount = 0
        focusedRecommendationID = recommendation.id
        journeyMessage = nil
        discover()
        return true
    }

    func removeStop(at index: Int) {
        guard !journeyBusy, let journey, journey.stops.indices.contains(index) else { return }
        var stops = journey.stops
        stops.remove(at: index)
        rebuildJourney(with: stops)
    }

    func moveStop(from source: Int, to destination: Int) {
        guard !journeyBusy, let journey else { return }
        rebuildJourney(with: JourneyMath.moved(journey.stops, from: source, to: destination))
    }

    func replaceStop(at index: Int, with place: Place) {
        guard !journeyBusy, let journey, journey.stops.indices.contains(index) else { return }
        var stops = journey.stops
        stops[index] = place
        rebuildJourney(with: stops)
    }

    private func rebuildJourney(with stops: [Place]) {
        guard let route else { return }
        journeyTask?.cancel()
        discoveryTask?.cancel()
        directions.cancelAll()
        recommendations = []
        journeyBusy = true
        journeyMessage = nil
        journeyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let points = [route.origin] + stops + [route.destination]
                var legs = [RouteMetrics]()
                for index in 0..<(points.count - 1) {
                    try Task.checkCancellation()
                    legs.append(try await directions.route(from: points[index], to: points[index + 1]))
                }
                try Task.checkCancellation()
                let updated = Journey(stops: stops, legs: legs, baseline: route.baseline)
                guard updated.extraDuration <= Double(budgetMinutes * 60) + 1 ||
                        stops.count < (journey?.stops.count ?? 0) else {
                    journeyMessage = "That order exceeds your time budget. Your previous trip is still here."
                    journeyBusy = false
                    discover()
                    return
                }
                journey = updated
                openedLegCount = 0
                journeyBusy = false
                discover()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                journeyMessage = "Couldn’t recalculate this trip. Try again when routing is available."
                journeyBusy = false
                phase = .loaded
            }
        }
    }

    func repeatJourney(_ saved: RecentJourney) async {
        let places = saved.places
        guard places.count >= 2 else { return }
        if saved.originWasCurrent {
            do {
                let position = try await location.currentLocation()
                origin = Place(id: "current-origin", name: "Current Location", coordinate: Coordinate(position.coordinate))
            } catch {
                locationMessage = error.localizedDescription
                return
            }
        } else { origin = places[0] }
        destination = places[1]
        budgetMinutes = saved.budgetMinutes
        cancelWork()
        guard let origin, let destination else { return }
        journeyBusy = false
        journeyMessage = nil
        route = nil
        journey = nil
        recommendations = []
        openedLegCount = 0
        phase = .findingRoute
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let baseline = try await directions.route(from: origin, to: destination)
                try Task.checkCancellation()
                let plan = RoutePlan(id: UUID(), origin: origin, destination: destination, baseline: baseline, createdAt: .now)
                let stops = Array(places.dropFirst(2))
                let points = [origin] + stops + [destination]
                var legs = [RouteMetrics]()
                for index in 0..<(points.count - 1) {
                    try Task.checkCancellation()
                    legs.append(try await directions.route(from: points[index], to: points[index + 1]))
                }
                try Task.checkCancellation()
                route = plan
                journey = Journey(stops: stops, legs: legs, baseline: baseline)
                if let journey, journey.extraDuration > Double(budgetMinutes * 60) + 1 {
                    journeyMessage = "Current routes put this journey over its saved time budget."
                }
                fitCamera(to: baseline.path)
                discover()
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed("Couldn’t repeat this journey right now.")
            }
        }
    }

    func fitCamera(to path: [Coordinate]) {
        guard !path.isEmpty else { return }
        let points = path.map { MKMapPoint($0.clLocation) }
        var rect = MKMapRect.null
        for point in points { rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0)) }
        camera = .rect(rect.insetBy(dx: -rect.width * 0.16 - 2_000, dy: -rect.height * 0.16 - 2_000))
        cameraWasMovedByUser = false
    }

    @discardableResult
    func openNextLeg() -> Bool {
        guard let route, let journey, openedLegCount < journey.legs.count else { return false }
        let endpoints = journey.stops + [route.destination]
        let source = openedLegCount == 0
            ? (route.origin.id == "current-origin" ? MKMapItem.forCurrentLocation() : route.origin.mapItem())
            : MKMapItem.forCurrentLocation()
        let opened = MKMapItem.openMaps(with: [source, endpoints[openedLegCount].mapItem()],
                                        launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        if opened { openedLegCount += 1 }
        return opened
    }
}

enum DiscoveryPreset: String, CaseIterable, Identifiable {
    case quickBreak, coffeeRun, explore, adventure
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quickBreak: "Quick Break"
        case .coffeeRun: "Coffee Run"
        case .explore: "Explore"
        case .adventure: "Adventure"
        }
    }
    var minutes: Int {
        switch self {
        case .quickBreak: 10
        case .coffeeRun: 15
        case .explore: 30
        case .adventure: 90
        }
    }
    var mode: DiscoveryMode {
        switch self {
        case .quickBreak: .useful
        case .coffeeRun: .coffee
        case .explore: .explore
        case .adventure: .surpriseMe
        }
    }
}
