import Foundation

/// Converts distance progress on the displayed journey into routed driving time.
/// Each leg keeps its own duration, since a slow final leg must not be treated as
/// though it has the journey's average speed.
enum JourneyDrivingProgress {
    private static let maximumProjectionDistance = 100.0
    private static let maximumAlongRouteShift = 500.0
    private static let maximumProgressDrift = 0.03
    private static let backtrackTolerance = 20.0

    private struct LegPosition {
        let index: Int
        let fraction: Double
    }

    static func remaining(in journey: Journey, routeProgress: Double) -> TimeInterval {
        guard let position = position(in: journey, routeProgress: routeProgress) else {
            let progress = routeProgress.isFinite ? min(max(routeProgress, 0), 1) : 0
            return max(0, journey.drivingDuration * (1 - progress))
        }
        return max(0, journey.legs[position.index].duration * (1 - position.fraction) +
            journey.legs.dropFirst(position.index + 1).reduce(0) { $0 + $1.duration })
    }

    static func remainingAfterEdit(current: Journey, proposed: Journey,
                                   destinationID: String, routeProgress: Double) -> TimeInterval? {
        let progress = routeProgress.isFinite ? min(max(routeProgress, 0), 1) : 0
        if progress == 0 { return proposed.drivingDuration }
        guard let position = position(in: current, routeProgress: routeProgress),
              current.legs.count == current.stops.count + 1,
              proposed.legs.count == proposed.stops.count + 1,
              proposed.legs.indices.contains(position.index),
              !requiresBacktracking(current: current, proposed: proposed,
                                    routeProgress: progress) else { return nil }

        let currentEndpoints = current.stops.map(\.id) + [destinationID]
        let proposedEndpoints = proposed.stops.map(\.id) + [destinationID]
        // Completed legs can change during a reorder. Their savings cannot offset
        // driving still ahead, so only the matching current leg may be prorated.
        if currentEndpoints[position.index] == proposedEndpoints[position.index] &&
            current.legs[position.index].path == proposed.legs[position.index].path {
            return max(0, proposed.legs[position.index].duration * (1 - position.fraction) +
                proposed.legs.dropFirst(position.index + 1).reduce(0) { $0 + $1.duration })
        }

        if let projectedProgress = mappedProgress(from: current, onto: proposed,
                                                 routeProgress: routeProgress),
           !passesUnvisitedStop(current: current, proposed: proposed,
                                routeProgress: progress, projectedProgress: projectedProgress) {
            let projected = remaining(in: proposed, routeProgress: projectedProgress)
            let currentRemaining = remaining(in: current, routeProgress: routeProgress)
            return max(projected,
                       currentRemaining + max(0, proposed.drivingDuration - current.drivingDuration))
        }
        // Without a shared current leg or a trustworthy projection, the old
        // origin-routed legs cannot verify driving from the traveler's position.
        return nil
    }

    static func progress(atStop index: Int, in journey: Journey) -> Double? {
        guard journey.stops.indices.contains(index), let (lengths, total) = legLengths(in: journey) else {
            return nil
        }
        return min(max(lengths.prefix(index + 1).reduce(0, +) / total, 0), 1)
    }

    private static func position(in journey: Journey, routeProgress: Double) -> LegPosition? {
        guard let (lengths, total) = legLengths(in: journey) else { return nil }
        let progress = routeProgress.isFinite ? min(max(routeProgress, 0), 1) : 0
        if progress >= 1 { return LegPosition(index: journey.legs.count - 1, fraction: 1) }

        var distance = total * progress
        for index in lengths.indices {
            let length = lengths[index]
            if distance < length || index == lengths.count - 1 {
                return LegPosition(index: index,
                    fraction: length > 0 ? min(max(distance / length, 0), 1) : 0)
            }
            distance -= length
        }
        return nil
    }

    private static func legLengths(in journey: Journey) -> ([Double], Double)? {
        guard !journey.legs.isEmpty else { return nil }
        let pathLengths = journey.legs.map { leg in
            zip(leg.path, leg.path.dropFirst()).reduce(0.0) {
                $0 + GeoMath.distance($1.0, $1.1)
            }
        }
        let pathTotal = pathLengths.reduce(0, +)
        let lengths = pathTotal.isFinite && pathTotal > 0
            ? pathLengths : journey.legs.map { $0.distance.isFinite ? max(0, $0.distance) : 0 }
        let total = lengths.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        return (lengths, total)
    }

    /// Reprojects the known route position only when both paths still describe
    /// approximately the same position. A location refresh is needed otherwise.
    static func mappedProgress(from current: Journey, onto proposed: Journey,
                               routeProgress: Double) -> Double? {
        guard let coordinate = coordinate(on: current.path, progress: routeProgress) else { return nil }
        let oldPosition = GeoMath.routeProgress(coordinate, path: current.path)
        let newPosition = GeoMath.routeProgress(coordinate, path: proposed.path)
        guard abs(oldPosition.fraction - routeProgress) <= maximumProgressDrift,
              newPosition.distanceFromRoute <= maximumProjectionDistance,
              abs(newPosition.distanceAlongRoute - oldPosition.distanceAlongRoute) <= maximumAlongRouteShift else {
            return nil
        }
        return newPosition.fraction
    }

    private static func requiresBacktracking(current: Journey, proposed: Journey,
                                             routeProgress: Double) -> Bool {
        let path = current.path
        let total = zip(path, path.dropFirst()).reduce(0.0) {
            $0 + GeoMath.distance($1.0, $1.1)
        }
        guard total.isFinite, total > 0 else { return true }
        let traveled = total * routeProgress
        return proposed.stops.contains { stop in
            guard !wasPassed(stop, in: current, routeProgress: routeProgress) else { return false }
            let position = GeoMath.routeProgress(stop.coordinate, path: path)
            return position.distanceAlongRoute + backtrackTolerance < traveled
        }
    }

    private static func passesUnvisitedStop(current: Journey, proposed: Journey,
                                            routeProgress: Double, projectedProgress: Double) -> Bool {
        guard let (_, total) = legLengths(in: proposed) else { return true }
        return proposed.stops.enumerated().contains { index, stop in
            guard !wasPassed(stop, in: current, routeProgress: routeProgress),
                  let stopProgress = progress(atStop: index, in: proposed) else { return false }
            return stopProgress * total + backtrackTolerance < projectedProgress * total
        }
    }

    private static func wasPassed(_ stop: Place, in current: Journey,
                                  routeProgress: Double) -> Bool {
        guard let index = current.stops.firstIndex(where: { $0.id == stop.id }),
              let stopProgress = progress(atStop: index, in: current),
              let (_, total) = legLengths(in: current) else { return false }
        return stopProgress * total + backtrackTolerance < routeProgress * total
    }

    private static func coordinate(on path: [Coordinate], progress: Double) -> Coordinate? {
        guard path.count > 1, progress.isFinite else { return nil }
        let lengths = zip(path, path.dropFirst()).map(GeoMath.distance)
        let total = lengths.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        var distance = total * min(max(progress, 0), 1)
        for index in lengths.indices {
            let length = lengths[index]
            if distance <= length || index == lengths.count - 1 {
                let fraction = length > 0 ? min(max(distance / length, 0), 1) : 0
                return Coordinate(latitude: path[index].latitude +
                    (path[index + 1].latitude - path[index].latitude) * fraction,
                    longitude: path[index].longitude +
                    (path[index + 1].longitude - path[index].longitude) * fraction)
            }
            distance -= length
        }
        return nil
    }
}

/// Estimates the deadline budget from the traveler's position on the selected journey.
/// Route progress is distance based, so these values are approximate until directions
/// are recalculated from the current location.
struct ActiveDeadlineBudget: Equatable, Sendable {
    let estimatedRemainingDriving: TimeInterval
    let remainingMargin: TimeInterval
    let allowedTotalDetour: TimeInterval

    init(deadline: Date, now: Date, baselineDriving: TimeInterval,
         journeyDriving: TimeInterval, estimatedRemainingDriving: TimeInterval,
         remainingPlannedVisits: TimeInterval) {
        let journeyDuration = max(0, journeyDriving)
        self.estimatedRemainingDriving = estimatedRemainingDriving.isFinite
            ? max(0, estimatedRemainingDriving) : journeyDuration

        let rawMargin = deadline.timeIntervalSince(now) - self.estimatedRemainingDriving
            - max(0, remainingPlannedVisits)
        remainingMargin = max(0, rawMargin)

        // Recommendations carry detour against the full baseline journey. Restore
        // the current journey's already-consumed detour before comparing them.
        let currentTotalDetour = max(0, journeyDuration - max(0, baselineDriving))
        allowedTotalDetour = max(0, currentTotalDetour + rawMargin)
    }
}

enum JourneyMission: String, CaseIterable, Identifiable, Sendable {
    case coffee, localFood, scenicBreak, quickPhoto, smallAdventure, quietBreak, newPlace, memorableStop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .coffee: "Coffee"
        case .localFood: "Local food"
        case .scenicBreak: "Scenic break"
        case .quickPhoto: "Scenic stop"
        case .smallAdventure: "Small adventure"
        case .quietBreak: "Nature break"
        case .newPlace: "Somewhere new"
        case .memorableStop: "Explore attractions"
        }
    }
    var mode: DiscoveryMode {
        switch self {
        case .coffee: .coffee
        case .localFood: .eat
        case .scenicBreak, .quickPhoto: .scenic
        case .smallAdventure: .microAdventure
        case .quietBreak: .nature
        case .newPlace, .memorableStop: .explore
        }
    }
    func matches(_ category: StopCategory?) -> Bool {
        guard let category else { return false }
        switch self {
        case .coffee: return [.coffee, .dessert].contains(category)
        case .localFood: return [.localFood, .mamak, .nasiLemak, .food].contains(category)
        case .scenicBreak, .quickPhoto: return [.scenic, .viewpoint, .beach, .park].contains(category)
        case .smallAdventure: return [.nature, .park, .waterfall, .attractions].contains(category)
        case .quietBreak: return [.nature, .park, .beach].contains(category)
        case .newPlace, .memorableStop: return [.attractions, .viewpoint, .nature, .localFood].contains(category)
        }
    }
}

enum JourneyRhythmState: String, Sendable {
    case earlyJourney, settled, breakWindowApproaching, breakWindow, lateJourney, nearDestination
}

struct JourneyRule: Codable, Equatable, Sendable {
    let need: JourneyNeed
    var enabled: Bool
    let minimumElapsedMinutes: Int
    let maximumDetourMinutes: Int
}

enum JourneyRhythmService {
    static func state(elapsed: TimeInterval, remaining: TimeInterval,
                      timeSinceLastSelectedStop: TimeInterval?) -> JourneyRhythmState {
        if remaining <= 20 * 60 { return .nearDestination }
        if elapsed < 30 * 60 { return .earlyJourney }
        if remaining < 50 * 60 { return .lateJourney }
        let since = timeSinceLastSelectedStop ?? elapsed
        if since >= 90 * 60 { return .breakWindow }
        if since >= 70 * 60 { return .breakWindowApproaching }
        return .settled
    }

    static func suggestedNeeds(rules: [JourneyRule], elapsed: TimeInterval,
                               remainingBudget: TimeInterval) -> Set<JourneyNeed> {
        Set(suggestedLimits(rules: rules, elapsed: elapsed, remainingBudget: remainingBudget).keys)
    }

    /// The available wallet can be smaller than a rule's cap and still fit a useful stop.
    static func suggestedLimits(rules: [JourneyRule], elapsed: TimeInterval,
                                remainingBudget: TimeInterval) -> [JourneyNeed: TimeInterval] {
        guard elapsed.isFinite, remainingBudget.isFinite, remainingBudget > 0 else { return [:] }
        var limits = [JourneyNeed: TimeInterval]()
        for rule in rules where rule.enabled &&
            elapsed >= Double(max(0, rule.minimumElapsedMinutes)) * 60 && rule.maximumDetourMinutes > 0 {
            let cap = min(remainingBudget, Double(rule.maximumDetourMinutes) * 60)
            limits[rule.need] = max(limits[rule.need] ?? 0, cap)
        }
        return limits
    }

    static func permitsSuggestion(needs: Set<JourneyNeed>, incrementalDetour: TimeInterval,
                                  limits: [JourneyNeed: TimeInterval]) -> Bool {
        guard incrementalDetour.isFinite else { return false }
        return needs.contains { need in
            guard let limit = limits[need] else { return false }
            return incrementalDetour <= limit
        }
    }
}

enum TimeMachine {
    static let buckets = [5, 10, 15, 20, 30, 45, 60, 90]

    static func filtered(_ recommendations: [StopRecommendation], minutes: Int) -> [StopRecommendation] {
        StopScoringService.withinBudget(recommendations, minutes: minutes)
    }
}
