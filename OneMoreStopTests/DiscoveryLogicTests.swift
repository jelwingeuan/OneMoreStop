import Foundation
import Testing
@testable import OneMoreStop

struct DiscoveryLogicTests {
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
}
