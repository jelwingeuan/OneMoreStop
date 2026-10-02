import Foundation

enum JourneyChainPlanning {
    static func pairs(_ recommendations: [StopRecommendation], existingStops: Int) -> [(StopRecommendation, StopRecommendation)] {
        guard existingStops <= 1 else { return [] }
        let sorted = recommendations.sorted { $0.progress < $1.progress }
        var pairs = [(StopRecommendation, StopRecommendation)]()
        for firstIndex in sorted.indices {
            for secondIndex in sorted.indices where secondIndex > firstIndex {
                let first = sorted[firstIndex], second = sorted[secondIndex]
                guard first.insertionIndex == second.insertionIndex,
                      first.place.category != second.place.category,
                      second.progress - first.progress >= 0.03 else { continue }
                pairs.append((first, second))
                if pairs.count == 3 { return pairs }
            }
        }
        return pairs
    }
}

@MainActor
final class JourneyChainEngine {
    private let directions: any DrivingDirectionsProviding
    init(directions: any DrivingDirectionsProviding) { self.directions = directions }

    func chains(route: RoutePlan, journey: Journey, candidates: [StopRecommendation],
                budget: TimeInterval) async throws -> [StopCombination] {
        var result = [StopCombination]()
        for (first, second) in JourneyChainPlanning.pairs(candidates, existingStops: journey.stops.count) {
            try Task.checkCancellation()
            var stops = journey.stops
            stops.insert(contentsOf: [first.place, second.place], at: first.insertionIndex)
            guard stops.count <= DiscoveryTuning.maxStops else { continue }
            let places = [route.origin] + stops + [route.destination]
            do {
                var legs = [RouteMetrics]()
                for index in 0..<(places.count - 1) {
                    try Task.checkCancellation()
                    legs.append(try await directions.route(from: places[index], to: places[index + 1]))
                }
                let proposal = Journey(stops: stops, legs: legs, baseline: route.baseline)
                guard proposal.extraDuration <= budget + 1 else { continue }
                result.append(StopCombination(first: first.place, second: second.place,
                    journey: proposal, insertionIndex: first.insertionIndex, routeID: route.id,
                    originalStopIDs: journey.stops.map(\.id), needs: first.needs.union(second.needs),
                    incrementalDetour: max(0, proposal.drivingDuration - journey.drivingDuration)))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return result.sorted { $0.incrementalDetour == $1.incrementalDetour
            ? $0.id < $1.id : $0.incrementalDetour < $1.incrementalDetour }
    }
}
