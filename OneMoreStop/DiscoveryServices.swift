import Foundation
import MapKit

@MainActor
final class RouteCorridorService {
    private let search: MapSearchService

    init(search: MapSearchService) { self.search = search }

    func candidates(for plan: RoutePlan, journey: Journey, mode: DiscoveryMode, mood: DiscoveryMood,
                    needs: Set<JourneyNeed>, surprise: SurpriseConstraints, budgetMinutes: Int,
                    localFirst: Bool, evJourney: Bool) async throws -> CandidateDiscovery {
        let radius = DiscoveryTuning.searchRadius(for: budgetMinutes)
        let path = journey.path.isEmpty ? plan.baseline.path : journey.path
        let samples = PolylineSampling.sample(path,
                                              spacing: DiscoveryTuning.sampleSpacing(for: journey.drivingDistance),
                                              limit: DiscoveryTuning.maxSamples)
        let isMalaysia = RegionProfile.isMalaysia(plan.destination.coordinate)
        let requests = QueryPlanner.plan(samples: samples, radius: radius, mode: mode, mood: mood,
                                         needs: needs, isMalaysia: isMalaysia, localFirst: localFirst,
                                         evJourney: evJourney, adventure: budgetMinutes >= 60,
                                         surprise: surprise)
        var found = [Place]()
        var successfulSearches = 0
        var successfulCenters = [Coordinate]()
        for batchStart in stride(from: 0, to: requests.count, by: DiscoveryTuning.maxConcurrentRequests) {
            try Task.checkCancellation()
            let indices = batchStart..<min(batchStart + DiscoveryTuning.maxConcurrentRequests, requests.count)
            let (additions, centers) = await withTaskGroup(of: (Coordinate?, [Place]).self) { group in
                for index in indices {
                    let request = requests[index]
                    group.addTask { [search] in
                        do {
                            let places = try await search.discover(around: request.center, radius: request.radius,
                                                                    category: request.category)
                            return (request.center, places)
                        } catch { return (nil, []) }
                    }
                }
                var batchPlaces = [Place]()
                var centers = [Coordinate]()
                for await (center, places) in group {
                    if let center { centers.append(center) }
                    batchPlaces += places
                }
                return (batchPlaces, centers)
            }
            found += additions
            successfulSearches += centers.count
            successfulCenters += centers
        }
        try Task.checkCancellation()
        if successfulSearches == 0 && !requests.isEmpty { throw DiscoveryError.searchUnavailable }
        return CandidateDiscovery(places: CandidateDeduplication.unique(found), samples: samples,
                                  attemptedSearches: requests.count, successfulSearches: successfulSearches,
                                  successfulCenters: successfulCenters)
    }
}

@MainActor
final class DetourEngine {
    private let directions: DirectionsService

    init(directions: DirectionsService) { self.directions = directions }

    func recommendations(for plan: RoutePlan, journey: Journey, candidates: [Place],
                         mode: DiscoveryMode, mood: DiscoveryMood, localFirst: Bool, evJourney: Bool,
                         needs: Set<JourneyNeed>, ignoredIDs: Set<String>, preferenceCounts: [String: Int],
                         surprise: SurpriseConstraints,
                         travelerProgress: Double, exploringArea: Bool, budgetMinutes: Int,
                         onBatch: @MainActor ([StopRecommendation]) -> Void) async throws -> [StopRecommendation] {
        let radius = DiscoveryTuning.searchRadius(for: budgetMinutes)
        let isMalaysia = RegionProfile.isMalaysia(plan.destination.coordinate)
        let categories = mode.categories(isMalaysia: isMalaysia, localFirst: localFirst,
                                         evJourney: evJourney, adventure: budgetMinutes >= 60, mood: mood)
        let shortlisted = candidates.compactMap { place -> (Place, Double, Double, Int)? in
            let position = GeoMath.routeProximity(place.coordinate, path: plan.baseline.path)
            let nearestLeg = journey.legs.enumerated().map { ($0.offset, GeoMath.routeProximity(place.coordinate, path: $0.element.path).distance) }
                .min { $0.1 < $1.1 }
            guard let nearestLeg, nearestLeg.1 <= radius * 1.4, position.progress < 0.99,
                  place.id != plan.origin.id, place.id != plan.destination.id,
                  !journey.stops.contains(where: { $0.id == place.id }),
                  !ignoredIDs.contains(place.id),
                  !(mode == .surpriseMe && surprise.onlyAhead && position.progress + 0.02 < travelerProgress) else { return nil }
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
                                                                            adventure: budgetMinutes >= 60)
                            let penalty = StopScoringService.aheadPenalty(candidate: progress, traveler: travelerProgress,
                                                                          exploringArea: exploringArea)
                            let matchedNeeds = JourneyNeed.verified(for: place.category).intersection(needs)
                            var result = StopRecommendation(place: place, detourTime: extraTime,
                                                            detourDistance: extraDistance, distanceFromRoute: distance,
                                                            progress: progress,
                                                            score: base + preference - penalty + Double(matchedNeeds.count * 14) +
                                                                Double(min(preferenceCounts[place.category?.rawValue ?? "", default: 0], 5) * 2),
                                                            firstLeg: first, secondLeg: second, insertionIndex: insertionIndex)
                            result.incrementalDetourTime = max(0, totalDuration - journey.drivingDuration)
                            if mode == .surpriseMe, let maximum = surprise.maxExtraMinutes,
                               result.incrementalDetourTime > Double(maximum * 60) { return (true, nil) }
                            result.needs = JourneyNeed.verified(for: place.category)
                            if result.incrementalDetourTime <= 5 * 60 { result.reasons.append(.smallDetour) }
                            if progress >= travelerProgress { result.reasons.append(.ahead) }
                            for need in matchedNeeds.sorted(by: { $0.rawValue < $1.rawValue }) {
                                result.reasons.append(.matchesNeed(need))
                            }
                            if mode == .zeroRegret && !OpportunityAssessment.isZeroRegret(result, travelerProgress: travelerProgress) {
                                return (true, nil)
                            }
                            return (true, result)
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
