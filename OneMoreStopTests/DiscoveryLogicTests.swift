import Foundation
import Testing
@testable import OneMoreStop

struct DiscoveryLogicTests {
    @Test func arrivalDeadlineCountsOnlyPlannedVisits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let budget = TimeBudget.arriveBy(now.addingTimeInterval(100 * 60))
        #expect(budget.allowedExtraDriving(baseline: 60 * 60, plannedVisits: 10 * 60, now: now) == 30 * 60)
        #expect(budget.remaining(baseline: 60 * 60, journey: 72 * 60,
                                 plannedVisits: 10 * 60, now: now) == 18 * 60)
        #expect(TimeBudget.spare(minutes: 20).remaining(baseline: 60 * 60, journey: 72 * 60,
                                                      plannedVisits: 30 * 60, now: now) == 8 * 60)
    }

    @Test func routeProgressDistinguishesAheadAndBehind() {
        let path = [Coordinate(latitude: 3, longitude: 101), Coordinate(latitude: 3, longitude: 102)]
        let progress = GeoMath.routeProgress(Coordinate(latitude: 3.001, longitude: 101.5), path: path)
        #expect(progress.isOnRoute)
        #expect(abs(progress.distanceAlongRoute - progress.distanceRemaining) < 500)
        #expect(progress.isAhead(0.8))
        #expect(!progress.isAhead(0.2))
    }

    @Test func queryPlannerBoundsAndDeduplicatesNeeds() {
        let samples = [Coordinate(latitude: 2.9, longitude: 101.7),
                       Coordinate(latitude: 2.8, longitude: 101.8)]
        let plan = QueryPlanner.plan(samples: samples, radius: 3_000, mode: .coffee, mood: .any,
                                     needs: [.coffee, .fuel, .charging], isMalaysia: true,
                                     localFirst: false, evJourney: true, adventure: false)
        #expect(plan.count <= DiscoveryTuning.maxSamples)
        #expect(Set(plan.map(\.category)).isSuperset(of: [.coffee, .fuel, .charging]))
        #expect(plan.count == 4)
    }

    @Test func verifiedNeedsDoNotInventAmenities() {
        #expect(JourneyNeed.verified(for: .restArea) == [.rest])
        #expect(JourneyNeed.verified(for: .charging) == [.charging])
        #expect(JourneyNeed.verified(for: .food) == [.food])
        #expect(JourneyNeed.verified(for: .attractions).isEmpty)
    }

    @Test func betterAheadRequiresSharedNeedAndVerifiedSavings() {
        let point = Coordinate(latitude: 2.9, longitude: 101.7)
        let metrics = RouteMetrics(duration: 600, distance: 1_000, path: [point])
        func result(_ id: String, progress: Double, added: Double, need: JourneyNeed) -> StopRecommendation {
            var item = StopRecommendation(place: Place(id: id, name: id, coordinate: point),
                                          detourTime: added, detourDistance: 0, distanceFromRoute: 50,
                                          progress: progress, score: 0, firstLeg: metrics, secondLeg: metrics)
            item.incrementalDetourTime = added
            item.needs = [need]
            return item
        }
        let now = result("now", progress: 0.2, added: 12 * 60, need: .coffee)
        let later = result("later", progress: 0.7, added: 2 * 60, need: .coffee)
        let other = result("other", progress: 0.8, added: 1 * 60, need: .fuel)
        #expect(OpportunityAssessment.betterAhead(in: [now, later])?.savings == 600.0)
        #expect(OpportunityAssessment.betterAhead(in: [now, later], travelerProgress: 0.5) == nil)
        #expect(OpportunityAssessment.betterAhead(in: [now, other]) == nil)
        #expect(OpportunityAssessment.isZeroRegret(later, travelerProgress: 0.1))
        #expect(!OpportunityAssessment.isZeroRegret(now, travelerProgress: 0.1))
    }

    @Test func combinationsRequireNearbyComplementaryPlacesAndRoom() {
        let point = Coordinate(latitude: 2.9, longitude: 101.7)
        let far = Coordinate(latitude: 2.95, longitude: 101.7)
        let metrics = RouteMetrics(duration: 600, distance: 1_000, path: [point])
        func item(_ id: String, at coordinate: Coordinate, need: JourneyNeed) -> StopRecommendation {
            var result = StopRecommendation(place: Place(id: id, name: id, coordinate: coordinate),
                                            detourTime: 300, detourDistance: 500, distanceFromRoute: 100,
                                            progress: 0.5, score: 10, firstLeg: metrics, secondLeg: metrics)
            result.needs = [need]
            return result
        }
        let coffee = item("coffee", at: point, need: .coffee)
        let fuel = item("fuel", at: point, need: .fuel)
        let distant = item("distant", at: far, need: .food)
        #expect(CombinationPlanning.pairs(from: [coffee, fuel, distant], existingStopCount: 0).count == 1)
        #expect(CombinationPlanning.pairs(from: [coffee, fuel], existingStopCount: 2).isEmpty)
    }

    @Test func detourMathUsesBothRoutedLegs() {
        #expect(DetourMath.extra(35 * 60, 37 * 60, baseline: 60 * 60) == 12 * 60)
        #expect(DetourMath.extra(29 * 60, 30 * 60, baseline: 60 * 60) == 0)
    }

    @Test func samplingUsesDistanceAndKeepsEndpoints() {
        let path = [Coordinate(latitude: 2.9, longitude: 101.7),
                    Coordinate(latitude: 2.95, longitude: 101.7),
                    Coordinate(latitude: 3.0, longitude: 101.7)]
        let samples = PolylineSampling.sample(path, spacing: 2_000, limit: 5)
        #expect(samples.count == 5)
        #expect(samples.first == path.first)
        #expect(abs((samples.last?.latitude ?? 0) - 3.0) < 0.00001)
        #expect(samples[1].latitude > path[0].latitude)
    }

    @Test func duplicateFallbackNormalizesNameAndCoordinates() {
        let point = Coordinate(latitude: 2.9250, longitude: 101.6850)
        let a = Place(id: Place.key(identifier: nil, name: "Kopi Tiam!", coordinate: point), name: "Kopi Tiam!", coordinate: point)
        let b = Place(id: Place.key(identifier: nil, name: "kopi tiam", coordinate: point), name: "kopi tiam", coordinate: point)
        let c = Place(id: Place.key(identifier: "apple-1", name: "Kopi Tiam", coordinate: point), name: "Kopi Tiam", coordinate: point)
        #expect(CandidateDeduplication.unique([a, b, c]).count == 2)
    }

    @Test func budgetFiltersAndRankingIsDeterministic() {
        let path = [Coordinate(latitude: 2.9, longitude: 101.7)]
        let metrics = RouteMetrics(duration: 1_000, distance: 10_000, path: path)
        let near = Place(id: "near", name: "Near", coordinate: path[0], category: .food)
        let far = Place(id: "far", name: "Far", coordinate: path[0], category: .food)
        let nearResult = StopRecommendation(place: near, detourTime: 6 * 60, detourDistance: 1_000,
                                            distanceFromRoute: 50, progress: 0.4, score: 90,
                                            firstLeg: metrics, secondLeg: metrics)
        let farResult = StopRecommendation(place: far, detourTime: 21 * 60, detourDistance: 3_000,
                                           distanceFromRoute: 500, progress: 0.5, score: 95,
                                           firstLeg: metrics, secondLeg: metrics)
        #expect(StopScoringService.withinBudget([farResult, nearResult], minutes: 20).map(\.id) == ["near"])
        #expect(StopScoringService.withinBudget([farResult, nearResult], minutes: 30).map(\.id) == ["far", "near"])
        #expect(StopScoringService.score(categoryMatch: true, detour: 5 * 60, budget: 20 * 60, proximity: 100, progress: 0.5) >
                StopScoringService.score(categoryMatch: true, detour: 15 * 60, budget: 20 * 60, proximity: 100, progress: 0.5))
    }

    @Test func formattingRespectsTimeAndLocale() {
        #expect(TripFormatting.extraTime(480) == "+8 min")
        #expect(TripFormatting.duration(5_040) == "1 hr 24 min")
        #expect(TripFormatting.distance(2_300, locale: Locale(identifier: "en_MY")).contains("km"))
        #expect(TripFormatting.distance(1_609, locale: Locale(identifier: "en_US")).contains("mi"))
        #expect(TripFormatting.distance(1_609, preference: "miles").contains("mi"))
        #expect(TripFormatting.distance(2_300, preference: "kilometers").contains("km"))
        let time = Date(timeIntervalSince1970: 0)
        #expect(!TripFormatting.arrival(time, locale: Locale(identifier: "en_MY")).isEmpty)
    }

    @Test func projectionTracksRouteProgressAndDistance() {
        let path = [Coordinate(latitude: 3.0, longitude: 101.0),
                    Coordinate(latitude: 3.0, longitude: 102.0)]
        let nearMiddle = GeoMath.routeProximity(Coordinate(latitude: 3.001, longitude: 101.5), path: path)
        #expect(abs(nearMiddle.progress - 0.5) < 0.02)
        #expect(nearMiddle.distance < 150)
        #expect(StopScoringService.aheadPenalty(candidate: 0.3, traveler: 0.6, exploringArea: false) > 0)
        #expect(StopScoringService.aheadPenalty(candidate: 0.3, traveler: 0.6, exploringArea: true) == 0)
    }

    @Test func journeyInsertionReorderAndArrivalUseDrivingLegs() {
        let point = Coordinate(latitude: 3, longitude: 101)
        let first = Place(id: "a", name: "A", coordinate: point)
        let second = Place(id: "b", name: "B", coordinate: point)
        let third = Place(id: "c", name: "C", coordinate: point)
        let ordered = JourneyMath.inserted(third, into: [first, second], at: 1)
        #expect(ordered.map(\.id) == ["a", "c", "b"])
        #expect(JourneyMath.moved(ordered, from: 0, to: 3).map(\.id) == ["c", "b", "a"])
        let metrics = RouteMetrics(duration: 1_200, distance: 10_000, path: [point])
        let journey = Journey(stops: ordered, legs: [metrics, metrics, metrics, metrics],
                              baseline: RouteMetrics(duration: 3_600, distance: 30_000, path: [point]))
        #expect(journey.extraDuration == 1_200)
        #expect(journey.extraDistance == 10_000)
        #expect(JourneyMath.arrival(after: journey.legs, startingAt: Date(timeIntervalSince1970: 0)) ==
                Date(timeIntervalSince1970: 4_800))
    }

    @Test func modesMoodAndRegionalConfigurationAreDeterministic() {
        #expect(RegionProfile.isMalaysia(Coordinate(latitude: 2.9, longitude: 101.7)))
        #expect(!RegionProfile.isMalaysia(Coordinate(latitude: 37.4, longitude: -122.1)))
        let local = DiscoveryMode.eat.categories(isMalaysia: true, localFirst: true, evJourney: false, adventure: false)
        #expect(local.first == .localFood)
        let usefulEV = DiscoveryMode.useful.categories(isMalaysia: true, localFirst: false, evJourney: true, adventure: false)
        #expect(usefulEV.contains(.charging))
        let usefulStandard = DiscoveryMode.useful.categories(isMalaysia: true, localFirst: false, evJourney: false, adventure: false)
        #expect(!usefulStandard.contains(.charging))
        let calm = StopScoringService.preference(for: .park, mode: .nature, mood: .calm,
                                                  localFirst: false, isMalaysia: false, adventure: false)
        let hungry = StopScoringService.preference(for: .park, mode: .nature, mood: .hungry,
                                                    localFirst: false, isMalaysia: false, adventure: false)
        #expect(calm > hungry)
    }

    @Test func savedSnapshotsDoNotNeedMapKitObjects() throws {
        let place = Place(id: "sample", name: "A stop", address: "Near the road",
                          coordinate: Coordinate(latitude: 2.9, longitude: 101.7), category: .coffee)
        let encoded = try JSONEncoder().encode(PlaceSnapshot(place))
        let restored = try JSONDecoder().decode(PlaceSnapshot.self, from: encoded).place
        #expect(restored.name == place.name)
        #expect(restored.coordinate == place.coordinate)
        #expect(restored.category == .coffee)
    }

    @Test @MainActor func currentOriginIsNotPersistedInJourneyHistory() {
        let exact = Coordinate(latitude: 2.9228, longitude: 101.6544)
        let origin = Place(id: "current-origin", name: "Current Location", coordinate: exact)
        let destination = Place(id: "destination", name: "Destination", coordinate: Coordinate(latitude: 2.2, longitude: 102.2))
        let journey = RecentJourney(origin: origin, destination: destination, stops: [], budgetMinutes: 20,
                                    drivingDuration: 3_600, extraDuration: 0)
        #expect(journey.originWasCurrent)
        #expect(journey.places[0].coordinate != exact)
        #expect(journey.places[1].coordinate == destination.coordinate)
    }

    @Test @MainActor func savedJourneyKeepsPlannedVisitsAndPreferencesCanReset() {
        let point = Coordinate(latitude: 3, longitude: 101)
        let origin = Place(id: "origin", name: "Origin", coordinate: point)
        let stop = Place(id: "coffee", name: "Coffee", coordinate: point, category: .coffee)
        let destination = Place(id: "destination", name: "Destination", coordinate: point)
        let record = RecentJourney(origin: origin, destination: destination, stops: [stop],
                                   budgetMinutes: 20, drivingDuration: 3_600, extraDuration: 300,
                                   plannedVisits: [stop.id: 15])
        #expect(record.plannedVisits[stop.id] == 15)
        let preferences = UserPreferenceRecord()
        preferences.recordSelection(.coffee)
        #expect(preferences.selectedCategoryCounts["coffee"] == 1)
        preferences.resetLearning()
        #expect(preferences.selectedCategoryCounts.isEmpty)
    }

    @Test func spontaneousTimeUsesActualDrivingDuration() {
        #expect(SpontaneousPlanning.fits(60 * 60, targetMinutes: 60))
        #expect(!SpontaneousPlanning.fits(61 * 60, targetMinutes: 60))
        #expect(!SpontaneousPlanning.fits(5 * 60, targetMinutes: 60))
        #expect(SpontaneousPlanning.searchRadius(minutes: 120, returnsHome: true) <
                SpontaneousPlanning.searchRadius(minutes: 120, returnsHome: false))
    }

    @Test func opportunityCoverageCountsOnlyNearbyFoundPlaces() {
        let path = [Coordinate(latitude: 3, longitude: 101), Coordinate(latitude: 3, longitude: 101.1)]
        let near = Place(id: "near", name: "Near", coordinate: Coordinate(latitude: 3.001, longitude: 101.05))
        let far = Place(id: "far", name: "Far", coordinate: Coordinate(latitude: 3.1, longitude: 101.05))
        #expect(OpportunityCoverage.nearbyCount([near, far], path: path) == 1)
        #expect(OpportunityCoverage.density(at: near.coordinate, places: [near, far]) == 1)
    }

    @Test @MainActor func groupVotesRemainOnePerNamedParticipant() {
        let group = LocalGroupRecord(name: "Friends")
        #expect(group.addParticipant("Asha"))
        #expect(!group.addParticipant("asha"))
        #expect(group.addParticipant("Ben"))
        group.castVote(participant: "Asha", placeID: "coffee")
        group.castVote(participant: "Asha", placeID: "park", placeName: "The Park")
        group.castVote(participant: "Ben", placeID: "park")
        #expect(group.votes.count == 2)
        #expect(group.voteCount(for: "coffee") == 0)
        #expect(group.voteCount(for: "park") == 2)
        #expect(group.placeNames["park"] == "The Park")
        group.preferredMode = .nature
        #expect(group.preferredMode == .nature)
    }

    @Test @MainActor func challengeCopyReflectsPlansOnly() {
        let point = Coordinate(latitude: 3, longitude: 101)
        let origin = Place(id: "origin", name: "Start", coordinate: point)
        let destination = Place(id: "destination", name: "End", coordinate: point)
        let scenic = Place(id: "scenic", name: "View", coordinate: point, category: .scenic)
        let saved = RecentJourney(origin: origin, destination: destination, stops: [scenic],
                                  budgetMinutes: 20, drivingDuration: 1_000, extraDuration: 300)
        #expect(PlanningChallenges.earned(from: [saved]) == ["First stop planned", "Scenic planner"])
        #expect(JourneyShare.summary(origin: "Start", destination: "End", stops: [scenic])
            .contains("Start → View → End"))
    }

    @Test @MainActor func combinationChecksCompleteRoutedJourneyAgainstBudget() async throws {
        let coordinate = Coordinate(latitude: 3, longitude: 101)
        let origin = Place(id: "origin", name: "Start", coordinate: coordinate)
        let destination = Place(id: "destination", name: "End", coordinate: coordinate)
        let coffee = Place(id: "coffee", name: "Coffee", coordinate: coordinate, category: .coffee)
        let fuel = Place(id: "fuel", name: "Fuel", coordinate: coordinate, category: .fuel)
        let baseline = RouteMetrics(duration: 50 * 60, distance: 20_000, path: [coordinate])
        let route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                              baseline: baseline, createdAt: .now)
        let journey = Journey(stops: [], legs: [baseline], baseline: baseline)
        func recommendation(_ place: Place, need: JourneyNeed, progress: Double) -> StopRecommendation {
            var value = StopRecommendation(place: place, detourTime: 10 * 60, detourDistance: 0,
                                           distanceFromRoute: 0, progress: progress, score: 80,
                                           firstLeg: baseline, secondLeg: baseline)
            value.needs = [need]
            return value
        }
        let directions = FakeDirections(times: [
            "origin:coffee": 20 * 60, "coffee:fuel": 10 * 60, "fuel:destination": 30 * 60
        ], coordinate: coordinate)
        let service = StopCombinationService(directions: directions)
        let verified = [recommendation(coffee, need: .coffee, progress: 0.3),
                        recommendation(fuel, need: .fuel, progress: 0.4)]
        let accepted = try await service.combinations(for: route, journey: journey, verified: verified,
                                                      allowedExtraDriving: 10 * 60)
        #expect(accepted.count == 1)
        #expect(accepted[0].journey.drivingDuration == 60 * 60)
        let rejected = try await service.combinations(for: route, journey: journey, verified: verified,
                                                      allowedExtraDriving: 9 * 60)
        #expect(rejected.isEmpty)
    }

    @Test @MainActor func spontaneousProviderChecksBothReturnLegs() async throws {
        let coordinate = Coordinate(latitude: 3, longitude: 101)
        let destinationCoordinate = Coordinate(latitude: 3.1, longitude: 101)
        let origin = Place(id: "origin", name: "Start", coordinate: coordinate)
        let park = Place(id: "park", name: "Park", coordinate: destinationCoordinate, category: .park)
        let search = FakeDiscovery(places: [park])
        let directions = FakeDirections(times: ["origin:park": 40 * 60, "park:origin": 45 * 60],
                                        coordinate: coordinate)
        let service = SpontaneousJourneyService(search: search, directions: directions)
        let plans = try await service.suggestions(origin: origin, kind: .escape, minutes: 90,
                                                  mode: .nature, returnsHome: true)
        #expect(plans.count == 1)
        #expect(plans[0].drivingDuration == 85 * 60)
        #expect(plans[0].legs.count == 2)
        let tooShort = try await service.suggestions(origin: origin, kind: .escape, minutes: 60,
                                                     mode: .nature, returnsHome: true)
        #expect(tooShort.isEmpty)
    }

    @Test @MainActor func spontaneousSearchAndRoutingFailuresAreSafe() async throws {
        let origin = Place(id: "origin", name: "Start", coordinate: Coordinate(latitude: 3, longitude: 101))
        let park = Place(id: "park", name: "Park", coordinate: Coordinate(latitude: 3.1, longitude: 101),
                         category: .park)
        let missingRoutes = FakeDirections(times: [:], coordinate: origin.coordinate)
        let unavailable = SpontaneousJourneyService(search: FakeDiscovery(places: [], fails: true),
                                                     directions: missingRoutes)
        do {
            _ = try await unavailable.suggestions(origin: origin, kind: .escape, minutes: 90,
                                                  mode: .nature, returnsHome: true)
            Issue.record("A failed search was treated as successful")
        } catch DiscoveryError.searchUnavailable {
        }
        let noRoute = SpontaneousJourneyService(search: FakeDiscovery(places: [park]),
                                                directions: missingRoutes)
        let result = try await noRoute.suggestions(origin: origin, kind: .escape, minutes: 90,
                                                   mode: .nature, returnsHome: true)
        #expect(result.isEmpty)
    }

    @Test @MainActor func escapeCanUseTwoRoutedStops() async throws {
        let origin = Place(id: "origin", name: "Start", coordinate: Coordinate(latitude: 3, longitude: 101))
        let park = Place(id: "park", name: "Park", coordinate: Coordinate(latitude: 3.08, longitude: 101),
                         category: .park)
        let cafe = Place(id: "cafe", name: "Cafe", coordinate: Coordinate(latitude: 3.1, longitude: 101),
                         category: .coffee)
        let directions = FakeDirections(times: [
            "origin:park": 20 * 60, "park:origin": 20 * 60,
            "origin:cafe": 25 * 60, "cafe:origin": 25 * 60,
            "park:cafe": 15 * 60
        ], coordinate: origin.coordinate)
        let plans = try await SpontaneousJourneyService(search: FakeDiscovery(places: [park, cafe]),
                                                         directions: directions)
            .suggestions(origin: origin, kind: .escape, minutes: 60,
                         mode: .explore, returnsHome: true)
        #expect(plans.first?.stops.map(\.id) == ["park", "cafe"])
        #expect(plans.first?.legs.count == 3)
        #expect(abs((plans.first?.drivingDuration ?? 0) - 60 * 60) < 0.01)
    }

    @Test func globalMapGateCancelsAQueuedRequest() async throws {
        let gate = MapRequestGate()
        for _ in 0..<DiscoveryTuning.maxConcurrentRequests { try await gate.acquire() }
        let queued = Task {
            try await gate.acquire()
            await gate.release()
        }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do {
            try await queued.value
            Issue.record("A canceled queued request unexpectedly acquired the gate")
        } catch is CancellationError {
        }
        for _ in 0..<DiscoveryTuning.maxConcurrentRequests { await gate.release() }
        #if DEBUG
        let metrics = await gate.metrics()
        #expect(metrics.peak == DiscoveryTuning.maxConcurrentRequests)
        #expect(metrics.waiting == 0)
        #endif
    }
}

@MainActor
private final class FakeDirections: DrivingDirectionsProviding {
    let times: [String: TimeInterval]
    let coordinate: Coordinate
    init(times: [String: TimeInterval], coordinate: Coordinate) {
        self.times = times
        self.coordinate = coordinate
    }
    func route(from origin: Place, to destination: Place) async throws -> RouteMetrics {
        guard let duration = times["\(origin.id):\(destination.id)"] else { throw FakeError.missing }
        return RouteMetrics(duration: duration, distance: 10_000, path: [coordinate])
    }
}

@MainActor
private final class FakeDiscovery: PlaceDiscoveryProviding {
    let places: [Place]
    let fails: Bool
    init(places: [Place], fails: Bool = false) { self.places = places; self.fails = fails }
    func discover(around center: Coordinate, radius: Double, category: StopCategory) async throws -> [Place] {
        if fails { throw FakeError.missing }
        return places
    }
}

private enum FakeError: Error { case missing }
