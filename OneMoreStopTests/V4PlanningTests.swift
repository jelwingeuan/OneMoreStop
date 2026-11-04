import ActivityKit
import Foundation
import SwiftData
import Testing
@testable import OneMoreStop

@MainActor
private final class FakeMeetingDirections: DrivingDirectionsProviding {
    let path: [Coordinate]
    init(path: [Coordinate]) { self.path = path }
    func route(from origin: Place, to destination: Place) async throws -> RouteMetrics {
        let minutes: Double
        switch (origin.id, destination.id) {
        case ("a", "d"), ("b", "d"): minutes = 60
        case ("a", "meet"): minutes = 30
        case ("b", "meet"): minutes = 25
        case ("meet", "d"): minutes = 36
        default: minutes = 20
        }
        return RouteMetrics(duration: minutes * 60, distance: 30_000, path: path)
    }
}

@MainActor
private final class FakeMeetingSearch: PlaceDiscoveryProviding {
    let place: Place
    init(place: Place) { self.place = place }
    func discover(around center: Coordinate, radius: Double, category: StopCategory) async throws -> [Place] {
        [place]
    }
}

@MainActor
private final class FakeChainDirections: DrivingDirectionsProviding {
    let path: [Coordinate]
    init(path: [Coordinate]) { self.path = path }
    func route(from origin: Place, to destination: Place) async throws -> RouteMetrics {
        RouteMetrics(duration: 25 * 60, distance: 10_000, path: path)
    }
}

@MainActor
private final class FakeActivityProvider: LiveActivityProviding {
    var startCount = 0
    var endCount = 0
    var latest: JourneyActivityAttributes.ContentState?
    var isRunning: Bool { startCount > endCount }
    func start(routeID: UUID, content: JourneyActivityAttributes.ContentState) async {
        startCount += 1
        latest = content
    }
    func update(_ content: JourneyActivityAttributes.ContentState) async { latest = content }
    func end() async { endCount += 1 }
}

@MainActor
struct V4PlanningTests {
    let a = Coordinate(latitude: 3, longitude: 101)
    let b = Coordinate(latitude: 3, longitude: 101.1)

    @Test func returnPlaceRequiresRelevantDirectionAndCurrentCorridor() {
        let origin = Place(id: "old-start", name: "Old start", coordinate: a)
        let destination = Place(id: "old-end", name: "Old end", coordinate: b)
        let saved = SavedReturnOpportunity(place: PlaceSnapshot(Place(id: "view", name: "View", coordinate: b)),
            origin: PlaceSnapshot(origin), destination: PlaceSnapshot(destination),
            originalDetourSeconds: 300, reasons: [], savedAt: .now)
        let metrics = RouteMetrics(duration: 3_600, distance: 10_000, path: [b, a])
        let reverse = RoutePlan(id: UUID(), origin: destination, destination: origin,
                                baseline: metrics, createdAt: .now)
        let journey = Journey(stops: [], legs: [metrics], baseline: metrics)
        #expect(ReturnTripMatcher.candidates([saved], route: reverse, journey: journey,
                                             travelerProgress: 0).map(\.name) == ["View"])
        #expect(ReturnTripMatcher.candidates([saved], route: reverse, journey: journey,
                                             travelerProgress: 0.9).isEmpty)
    }

    @Test func meetingUsesRoutedIndividualCosts() async throws {
        let aPlace = Place(id: "a", name: "A", coordinate: a)
        let bPlace = Place(id: "b", name: "B", coordinate: a)
        let destination = Place(id: "d", name: "D", coordinate: b)
        let meet = Place(id: "meet", name: "Cafe", coordinate: a, category: .coffee)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let planner = MeetingPlannerService(directions: FakeMeetingDirections(path: [a, b]),
                                            search: FakeMeetingSearch(place: meet))
        let result = try await planner.find(participants: [
            MeetingParticipant(name: "You", origin: aPlace, destination: destination, departure: start),
            MeetingParticipant(name: "Friend", origin: bPlace, destination: destination, departure: start)
        ], minimizeTotal: false)
        #expect(result.first?.costs.map(\.detour) == [360, 60])
        #expect(result.first?.maximumDetour == 360)
        #expect(result.first?.arrivalSpread == 300)
    }

    @Test func chainCandidatesStaySmallAndOrdered() {
        let metrics = RouteMetrics(duration: 600, distance: 1_000, path: [a, b])
        func item(_ id: String, progress: Double, category: StopCategory) -> StopRecommendation {
            StopRecommendation(place: Place(id: id, name: id, coordinate: a, category: category),
                detourTime: 300, detourDistance: 100, distanceFromRoute: 10,
                progress: progress, score: 70, firstLeg: metrics, secondLeg: metrics)
        }
        let pairs = JourneyChainPlanning.pairs([item("late", progress: 0.7, category: .viewpoint),
                                                item("early", progress: 0.2, category: .coffee)], existingStops: 0)
        #expect(pairs.count == 1)
        #expect(pairs.first?.0.id == "early")
        #expect(JourneyChainPlanning.pairs([], existingStops: 2).isEmpty)
    }

    @Test func chainRoutesTheCompleteProposalBeforeBudgetApproval() async throws {
        let origin = Place(id: "a", name: "A", coordinate: a)
        let destination = Place(id: "d", name: "D", coordinate: b)
        let baseline = RouteMetrics(duration: 3_600, distance: 30_000, path: [a, b])
        let route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                              baseline: baseline, createdAt: .now)
        let journey = Journey(stops: [], legs: [baseline], baseline: baseline)
        func candidate(_ id: String, progress: Double, category: StopCategory) -> StopRecommendation {
            StopRecommendation(place: Place(id: id, name: id, coordinate: a, category: category),
                detourTime: 300, detourDistance: 100, distanceFromRoute: 10,
                progress: progress, score: 80, firstLeg: baseline, secondLeg: baseline)
        }
        let candidates = [candidate("coffee", progress: 0.2, category: .coffee),
                          candidate("view", progress: 0.6, category: .viewpoint)]
        let engine = JourneyChainEngine(directions: FakeChainDirections(path: [a, b]))
        let accepted = try await engine.chains(route: route, journey: journey,
                                                candidates: candidates, budget: 20 * 60)
        #expect(accepted.count == 1)
        #expect(accepted[0].journey.legs.count == 3)
        #expect(accepted[0].journey.extraDuration == 15 * 60)
        let rejected = try await engine.chains(route: route, journey: journey,
                                                candidates: candidates, budget: 10 * 60)
        #expect(rejected.isEmpty)
    }

    @Test func addStopUsesOnlyTheCurrentVerifiedLegs() {
        let origin = Place(id: "start", name: "Start", coordinate: a)
        let destination = Place(id: "end", name: "End", coordinate: b)
        let oldPlace = Place(id: "stop", name: "Old stop", coordinate: a)
        let currentPlace = Place(id: "stop", name: "Current stop", coordinate: b)
        let baseline = RouteMetrics(duration: 60 * 60, distance: 40_000, path: [a, b])
        let oldLeg = RouteMetrics(duration: 10 * 60, distance: 5_000, path: [a, b])
        let first = RouteMetrics(duration: 35 * 60, distance: 23_000, path: [a, b])
        let second = RouteMetrics(duration: 37 * 60, distance: 24_000, path: [a, b])
        let captured = StopRecommendation(place: oldPlace, detourTime: 0, detourDistance: 0,
            distanceFromRoute: 0, progress: 0.2, score: 90, firstLeg: oldLeg, secondLeg: oldLeg)
        let current = StopRecommendation(place: currentPlace, detourTime: 12 * 60, detourDistance: 7_000,
            distanceFromRoute: 0, progress: 0.2, score: 90, firstLeg: first, secondLeg: second)
        let state = AppState()
        state.route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                                baseline: baseline, createdAt: .now)
        state.journey = Journey(stops: [], legs: [baseline], baseline: baseline)
        state.budgetMinutes = 20

        #expect(!state.addStop(captured))
        #expect(state.journey?.stops.isEmpty == true)
        state.recommendations = [current]
        #expect(state.addStop(captured))
        #expect(state.journey?.stops.first?.name == "Current stop")
        #expect(state.journey?.drivingDuration == 4_320.0)
    }

    @Test func rediscoveryRemovesAnUnavailableOpportunityImmediately() {
        let origin = Place(id: "start", name: "Start", coordinate: a)
        let destination = Place(id: "end", name: "End", coordinate: b)
        let stop = Place(id: "stop", name: "Coffee", coordinate: a, category: .coffee)
        let baseline = RouteMetrics(duration: 3_600, distance: 30_000, path: [a, b])
        let route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                              baseline: baseline, createdAt: .now)
        let state = AppState()
        state.route = route
        state.journey = Journey(stops: [], legs: [baseline], baseline: baseline)
        state.recommendations = [StopRecommendation(place: stop, detourTime: 300, detourDistance: 500,
            distanceFromRoute: 0, progress: 0.2, score: 80, firstLeg: baseline, secondLeg: baseline)]
        state.opportunities = [JourneyOpportunity(place: PlaceSnapshot(stop), routeID: route.id,
            progress: 0.2, distanceAhead: 1_000, approximateMinutesAhead: 5,
            incrementalDriving: 300, totalDetour: 300, score: 80, reasons: [],
            source: .corridor, status: .surfaced, expiresAtProgress: 0.25)]

        state.discover()

        #expect(state.recommendations.isEmpty)
        #expect(state.opportunities.isEmpty)
    }

    @Test func meetingFairnessCanBeOverriddenByTotalDetour() {
        let now = Date(timeIntervalSince1970: 0)
        let unfair = MeetingResult(place: Place(id: "unfair", name: "Unfair", coordinate: a),
            costs: [MeetingCost(participantName: "A", detour: 600, arrival: now),
                    MeetingCost(participantName: "B", detour: 60, arrival: now)])
        let fair = MeetingResult(place: Place(id: "fair", name: "Fair", coordinate: a),
            costs: [MeetingCost(participantName: "A", detour: 420, arrival: now),
                    MeetingCost(participantName: "B", detour: 420, arrival: now)])
        #expect(MeetingRanking.rank([unfair, fair], minimizeTotal: false).first?.id == "fair")
        #expect(MeetingRanking.rank([unfair, fair], minimizeTotal: true).first?.id == "unfair")
    }

    @Test func chaptersAndActivitySnapshotUsePlainValues() throws {
        #expect(JourneyChapter.at(progress: 0.05) == .starting)
        #expect(JourneyChapter.at(progress: 0.5) == .halfway)
        #expect(JourneyChapter.at(progress: 0.95) == .finalLeg)
        let content = JourneyActivityAttributes.ContentState(destination: "Melaka",
            remainingMinutes: 12, opportunityName: "Coffee", opportunityMinutesAhead: 14,
            opportunityDetourMinutes: 3, updatedAt: .now)
        let decoded = try JSONDecoder().decode(JourneyActivityAttributes.ContentState.self,
                                               from: JSONEncoder().encode(content))
        #expect(decoded == content)
    }

    @Test func v4RecordsPersistBesideExistingPlacesAndPreferences() throws {
        let container = try ModelContainer(for: SavedPlace.self, UserPreferenceRecord.self,
                                           ReturnOpportunityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let origin = Place(id: "origin", name: "Origin", coordinate: a)
        let destination = Place(id: "destination", name: "Destination", coordinate: b)
        let place = Place(id: "coffee", name: "Coffee", coordinate: a, category: .coffee)
        let route = RoutePlan(id: UUID(), origin: origin, destination: destination,
            baseline: RouteMetrics(duration: 3_600, distance: 10_000, path: [a, b]), createdAt: .now)
        let recommendation = StopRecommendation(place: place, detourTime: 300, detourDistance: 100,
            distanceFromRoute: 0, progress: 0.2, score: 90, firstLeg: route.baseline,
            secondLeg: route.baseline)
        let preference = UserPreferenceRecord()
        preference.autopilotRules = [JourneyRule(need: .coffee, enabled: true,
                                                minimumElapsedMinutes: 90, maximumDetourMinutes: 10)]
        preference.recordMode(.coffee)
        context.insert(preference)
        context.insert(SavedPlace(place))
        context.insert(ReturnOpportunityRecord(recommendation: recommendation, route: route))
        try context.save()
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<SavedPlace>()).count == 1)
        #expect(try reader.fetch(FetchDescriptor<UserPreferenceRecord>()).first?.autopilotRules?.first?.enabled == true)
        #expect(try reader.fetch(FetchDescriptor<UserPreferenceRecord>()).first?.selectedModeCounts["coffee"] == 1)
        #expect(try reader.fetch(FetchDescriptor<ReturnOpportunityRecord>()).first?.snapshot?.place.name == "Coffee")
    }

    @Test func activeJourneyStartsAndEndsActivityProvider() async throws {
        let fake = FakeActivityProvider()
        let state = AppState(liveOpportunity: fake)
        let origin = Place(id: "a", name: "A", coordinate: a)
        let destination = Place(id: "d", name: "D", coordinate: b)
        let metrics = RouteMetrics(duration: 3_600, distance: 10_000, path: [a, b])
        state.route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                                baseline: metrics, createdAt: .now)
        state.journey = Journey(stops: [], legs: [metrics], baseline: metrics)
        state.startActiveJourney()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fake.startCount == 1)
        #expect(fake.latest?.destination == "D")
        state.endActiveJourney()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fake.endCount >= 1)
    }

    @Test func repeatingSavedJourneyClearsActiveRouteProgress() async {
        let origin = Place(id: "old-origin", name: "Old start", coordinate: a)
        let destination = Place(id: "old-destination", name: "Old end", coordinate: b)
        let saved = RecentJourney(origin: origin, destination: destination, stops: [],
                                  budgetMinutes: 20, drivingDuration: 3_600, extraDuration: 0)
        let state = AppState(liveOpportunity: FakeActivityProvider())
        state.activeJourney = true
        state.liveActivityRunning = true
        state.travelerProgress = 0.8
        state.isTravelerOnRoute = false
        state.timeMachinePreview = 45
        state.routeComparisonBusy = true

        await state.repeatJourney(saved)

        #expect(!state.activeJourney)
        #expect(!state.liveActivityRunning)
        #expect(state.travelerProgress == 0)
        #expect(state.isTravelerOnRoute)
        #expect(state.timeMachinePreview == nil)
        #expect(!state.routeComparisonBusy)
    }

    @Test func startupEndsOnlyOrphanedActivity() async {
        let fake = FakeActivityProvider()
        let state = AppState(liveOpportunity: fake)
        await state.endOrphanedLiveActivities()
        #expect(fake.endCount == 1)
        state.activeJourney = true
        await state.endOrphanedLiveActivities()
        #expect(fake.endCount == 1)
    }
}
