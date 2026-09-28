import Foundation
import MapKit

@MainActor
final class RouteCorridorService {
    private let search: MapSearchService

    init(search: MapSearchService) { self.search = search }

    func candidates(for plan: RoutePlan, journey: Journey, mode: DiscoveryMode, mood: DiscoveryMood,
                    budgetMinutes: Int, localFirst: Bool, evJourney: Bool) async throws -> [Place] {
        let radius = DiscoveryTuning.searchRadius(for: budgetMinutes)
        let path = journey.path.isEmpty ? plan.baseline.path : journey.path
        let samples = PolylineSampling.sample(path,
                                              spacing: DiscoveryTuning.sampleSpacing(for: journey.drivingDistance),
                                              limit: DiscoveryTuning.maxSamples)
        let isMalaysia = RegionProfile.isMalaysia(plan.destination.coordinate)
        let categories = mode.categories(isMalaysia: isMalaysia, localFirst: localFirst,
                                         evJourney: evJourney, adventure: budgetMinutes >= 90, mood: mood)
        var found = [Place]()
        var successfulSearches = 0
        for batchStart in stride(from: 0, to: samples.count, by: DiscoveryTuning.maxConcurrentRequests) {
            try Task.checkCancellation()
            let indices = batchStart..<min(batchStart + DiscoveryTuning.maxConcurrentRequests, samples.count)
            let (additions, successes) = await withTaskGroup(of: (Bool, [Place]).self) { group in
                for index in indices {
                    group.addTask { [search] in
                        do {
                            let places = try await search.discover(around: samples[index], radius: radius,
                                                                    category: categories[index % categories.count])
                            return (true, places)
                        } catch { return (false, []) }
                    }
                }
                var batchPlaces = [Place]()
                var successes = 0
                for await (succeeded, places) in group {
                    if succeeded { successes += 1 }
                    batchPlaces += places
                }
                return (batchPlaces, successes)
            }
            found += additions
            successfulSearches += successes
        }
        try Task.checkCancellation()
        if successfulSearches == 0 && !samples.isEmpty { throw DiscoveryError.searchUnavailable }
        return CandidateDeduplication.unique(found)
    }
}

@MainActor
final class DetourEngine {
    private let directions: DirectionsService

    init(directions: DirectionsService) { self.directions = directions }

    func recommendations(for plan: RoutePlan, journey: Journey, candidates: [Place],
                         mode: DiscoveryMode, mood: DiscoveryMood, localFirst: Bool,
                         travelerProgress: Double, exploringArea: Bool, budgetMinutes: Int,
                         onBatch: @MainActor ([StopRecommendation]) -> Void) async throws -> [StopRecommendation] {
        let radius = DiscoveryTuning.searchRadius(for: budgetMinutes)
        let isMalaysia = RegionProfile.isMalaysia(plan.destination.coordinate)
        let categories = mode.categories(isMalaysia: isMalaysia, localFirst: localFirst,
                                         evJourney: true, adventure: budgetMinutes >= 90, mood: mood)
        let shortlisted = candidates.compactMap { place -> (Place, Double, Double, Int)? in
            let position = GeoMath.routeProximity(place.coordinate, path: plan.baseline.path)
            let nearestLeg = journey.legs.enumerated().map { ($0.offset, GeoMath.routeProximity(place.coordinate, path: $0.element.path).distance) }
                .min { $0.1 < $1.1 }
            guard let nearestLeg, nearestLeg.1 <= radius * 1.4, position.progress < 0.99,
                  place.id != plan.origin.id, place.id != plan.destination.id,
                  !journey.stops.contains(where: { $0.id == place.id }) else { return nil }
            return (place, nearestLeg.1, position.progress, nearestLeg.0)
        }
        .sorted { ($0.1 + StopScoringService.aheadPenalty(candidate: $0.2, traveler: travelerProgress, exploringArea: exploringArea) * 200) <
            ($1.1 + StopScoringService.aheadPenalty(candidate: $1.2, traveler: travelerProgress, exploringArea: exploringArea) * 200) }
        .prefix(DiscoveryTuning.maxCandidatesForRouting)

        var results = [StopRecommendation]()
        var successfulRoutes = 0
        for batchStart in stride(from: 0, to: shortlisted.count, by: DiscoveryTuning.maxConcurrentRequests) {
            try Task.checkCancellation()
            let batch = Array(shortlisted.dropFirst(batchStart).prefix(DiscoveryTuning.maxConcurrentRequests))
            let (additions, successes) = await withTaskGroup(of: (Bool, StopRecommendation?).self) { group in
                for (place, distance, progress, insertionIndex) in batch {
                    group.addTask { [directions] in
                        do {
                            let from = insertionIndex == 0 ? plan.origin : journey.stops[insertionIndex - 1]
                            let to = insertionIndex == journey.stops.count ? plan.destination : journey.stops[insertionIndex]
                            let first = try await directions.route(from: from, to: place)
                            let second = try await directions.route(from: place, to: to)
                            let oldLeg = journey.legs[insertionIndex]
                            let totalDuration = journey.drivingDuration - oldLeg.duration + first.duration + second.duration
                            let totalDistance = journey.drivingDistance - oldLeg.distance + first.distance + second.distance
                            let extraTime = DetourMath.extra(totalDuration, 0, baseline: plan.baseline.duration)
                            let extraDistance = DetourMath.extra(totalDistance, 0, baseline: plan.baseline.distance)
                            let base = StopScoringService.score(categoryMatch: categories.contains(place.category ?? .restStop),
                                                                detour: extraTime, budget: Double(budgetMinutes * 60),
                                                                proximity: distance, progress: progress)
                            let preference = StopScoringService.preference(for: place.category, mode: mode, mood: mood,
                                                                            localFirst: localFirst, isMalaysia: isMalaysia,
                                                                            adventure: budgetMinutes >= 90)
                            let penalty = StopScoringService.aheadPenalty(candidate: progress, traveler: travelerProgress,
                                                                          exploringArea: exploringArea)
                            return (true, StopRecommendation(place: place, detourTime: extraTime,
                                                             detourDistance: extraDistance, distanceFromRoute: distance,
                                                             progress: progress, score: base + preference - penalty,
                                                             firstLeg: first, secondLeg: second, insertionIndex: insertionIndex))
                        } catch { return (false, nil) }
                    }
                }
                var batchResults = [StopRecommendation]()
                var successes = 0
                for await (succeeded, result) in group {
                    if succeeded { successes += 1 }
                    if let result { batchResults.append(result) }
                }
                return (batchResults, successes)
            }
            results += additions
            successfulRoutes += successes
            onBatch(StopScoringService.withinBudget(results, minutes: budgetMinutes))
        }
        try Task.checkCancellation()
        if successfulRoutes == 0 && !shortlisted.isEmpty { throw DiscoveryError.routingUnavailable }
        return results
    }
}

enum DiscoveryError: Error {
    case searchUnavailable, routingUnavailable
}
