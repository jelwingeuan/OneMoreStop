import Foundation

struct StopCombination: Identifiable, Sendable {
    let first: Place
    let second: Place
    let journey: Journey
    let insertionIndex: Int
    let routeID: UUID
    let originalStopIDs: [String]
    let needs: Set<JourneyNeed>
    let incrementalDetour: TimeInterval

    var id: String { "\(first.id)|\(second.id)" }
}

enum CombinationPlanning {
    static func pairs(from recommendations: [StopRecommendation], existingStopCount: Int,
                      limit: Int = 4) -> [(StopRecommendation, StopRecommendation)] {
        guard existingStopCount <= 1 else { return [] }
        let ordered = recommendations.sorted { $0.progress < $1.progress }
        var pairs: [(StopRecommendation, StopRecommendation)] = []
        for firstIndex in ordered.indices {
            for secondIndex in ordered.indices where secondIndex > firstIndex {
                let first = ordered[firstIndex], second = ordered[secondIndex]
                guard first.insertionIndex == second.insertionIndex,
                      first.needs.isDisjoint(with: second.needs),
                      !first.needs.isEmpty, !second.needs.isEmpty,
                      GeoMath.distance(first.place.coordinate, second.place.coordinate) <= 1_500 else { continue }
                pairs.append((first, second))
                if pairs.count == limit { return pairs }
            }
        }
        return pairs
    }
}

@MainActor
final class StopCombinationService {
    private let directions: any DrivingDirectionsProviding

    init(directions: any DrivingDirectionsProviding) { self.directions = directions }

    func combinations(for route: RoutePlan, journey: Journey, verified: [StopRecommendation],
                      allowedExtraDriving: TimeInterval) async throws -> [StopCombination] {
        let pairs = CombinationPlanning.pairs(from: verified, existingStopCount: journey.stops.count)
        var found = [StopCombination]()
        for (first, second) in pairs {
            try Task.checkCancellation()
            var stops = journey.stops
            stops.insert(contentsOf: [first.place, second.place], at: first.insertionIndex)
            let points = [route.origin] + stops + [route.destination]
            do {
                var legs = [RouteMetrics]()
                for index in 0..<(points.count - 1) {
                    try Task.checkCancellation()
                    legs.append(try await directions.route(from: points[index], to: points[index + 1]))
                }
                let proposed = Journey(stops: stops, legs: legs, baseline: route.baseline)
                guard proposed.extraDuration <= allowedExtraDriving + 1 else { continue }
                found.append(StopCombination(first: first.place, second: second.place,
                                             journey: proposed, insertionIndex: first.insertionIndex,
                                             routeID: route.id, originalStopIDs: journey.stops.map(\.id),
                                             needs: first.needs.union(second.needs),
                                             incrementalDetour: max(0, proposed.drivingDuration - journey.drivingDuration)))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return found.sorted {
            $0.incrementalDetour == $1.incrementalDetour ? $0.id < $1.id : $0.incrementalDetour < $1.incrementalDetour
        }
    }
}
