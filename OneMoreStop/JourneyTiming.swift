import Foundation

/// Estimates the deadline budget from the traveler's position on the selected journey.
/// Route progress is distance based, so these values are approximate until directions
/// are recalculated from the current location.
struct ActiveDeadlineBudget: Equatable, Sendable {
    let estimatedRemainingDriving: TimeInterval
    let remainingMargin: TimeInterval
    let allowedTotalDetour: TimeInterval

    init(deadline: Date, now: Date, baselineDriving: TimeInterval,
         journeyDriving: TimeInterval, routeProgress: Double,
         remainingPlannedVisits: TimeInterval) {
        let progress = routeProgress.isFinite ? min(max(routeProgress, 0), 1) : 0
        let journeyDuration = max(0, journeyDriving)
        estimatedRemainingDriving = journeyDuration * (1 - progress)

        let rawMargin = deadline.timeIntervalSince(now) - estimatedRemainingDriving
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
        Set(rules.filter { $0.enabled && elapsed >= Double($0.minimumElapsedMinutes * 60) &&
            remainingBudget >= Double($0.maximumDetourMinutes * 60) }.map(\.need))
    }
}

enum TimeMachine {
    static let buckets = [5, 10, 15, 20, 30, 45, 60, 90]

    static func filtered(_ recommendations: [StopRecommendation], minutes: Int) -> [StopRecommendation] {
        StopScoringService.withinBudget(recommendations, minutes: minutes)
    }
}
