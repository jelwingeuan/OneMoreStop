import Foundation

enum TimeBudget: Equatable, Sendable {
    case spare(minutes: Int)
    case arriveBy(Date)

    var deadline: Date? {
        if case .arriveBy(let date) = self { return date }
        return nil
    }

    func allowedExtraDriving(baseline: TimeInterval, plannedVisits: TimeInterval, now: Date) -> TimeInterval {
        switch self {
        case .spare(let minutes): Double(max(0, minutes)) * 60
        case .arriveBy(let deadline): max(0, deadline.timeIntervalSince(now) - baseline - plannedVisits)
        }
    }

    func remaining(baseline: TimeInterval, journey: TimeInterval, plannedVisits: TimeInterval, now: Date) -> TimeInterval {
        switch self {
        case .spare(let minutes): max(0, Double(minutes) * 60 - max(0, journey - baseline))
        case .arriveBy(let deadline): max(0, deadline.timeIntervalSince(now) - journey - plannedVisits)
        }
    }
}

enum JourneyNeed: String, CaseIterable, Codable, Identifiable, Sendable {
    case food, coffee, fuel, charging, prayer, shopping, groceries, atm, pharmacy, nature, scenic, rest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .charging: "EV charging"
        case .rest: "Rest stop"
        case .atm: "ATM"
        default: rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .coffee: "cup.and.saucer.fill"
        case .fuel: "fuelpump.fill"
        case .charging: "bolt.car.fill"
        case .prayer: "building.columns.fill"
        case .shopping: "bag.fill"
        case .groceries: "basket.fill"
        case .atm: "banknote.fill"
        case .pharmacy: "cross.case.fill"
        case .nature: "leaf.fill"
        case .scenic: "mountain.2.fill"
        case .rest: "car.side.fill"
        }
    }

    static func verified(for category: StopCategory?) -> Set<JourneyNeed> {
        switch category {
        case .food, .localFood, .nasiLemak, .mamak: [.food]
        case .coffee: [.coffee]
        case .fuel: [.fuel]
        case .charging: [.charging]
        case .surau: [.prayer]
        case .shopping: [.shopping]
        case .groceries: [.groceries]
        case .atm: [.atm]
        case .pharmacy: [.pharmacy]
        case .nature, .park, .waterfall: [.nature]
        case .scenic, .viewpoint, .beach: [.scenic]
        case .restStop, .restArea: [.rest]
        default: []
        }
    }

    var categories: [StopCategory] {
        switch self {
        case .food: [.food, .localFood]
        case .coffee: [.coffee]
        case .fuel: [.fuel]
        case .charging: [.charging]
        case .prayer: [.surau]
        case .shopping: [.shopping]
        case .groceries: [.groceries]
        case .atm: [.atm]
        case .pharmacy: [.pharmacy]
        case .nature: [.park, .nature]
        case .scenic: [.viewpoint, .scenic]
        case .rest: [.restArea, .restStop]
        }
    }
}

enum RecommendationReason: Equatable, Sendable {
    case smallDetour
    case matchesNeed(JourneyNeed)
    case ahead
    case betterAhead(minutesSaved: Int)

    var text: String {
        switch self {
        case .smallDetour: "Barely off your route"
        case .matchesNeed(let need): "Matches your \(need.title.lowercased()) need"
        case .ahead: "Ahead on your route"
        case .betterAhead(let saved): "Wait for this stop and save about \(saved) min driving"
        }
    }
}

enum OpportunityConfidence: Sendable {
    case checkingRoute, routingVerified
}

enum FeatureFlags {
    static let arriveBy = true
    static let journeyNeeds = true
    static let stopCombinations = true
    static let groupMode = true
    static let liveOpportunities = true
    static let spontaneousJourneys = true
    static let searchDensity = true
    static let alternateRouteComparison = true
    static let opportunityRadar = true
    static let oneMoreStopButton = true
    static let timeMachineSlider = true
    static let stopAutopilot = true
    static let missionMode = true
    static let journeyRhythm = true
    static let saveForReturn = true
    static let whatWasThat = true
    static let detourRoulette = true
    static let journeyChains = true
    static let passengerControl = true
    static let meetOnTheWay = true
    static let rendezvousMode = true
    static let journeyChapters = true
    static let interestingOnlyMode = true
    static let opportunityScoreV2 = true
    static let liveActivityOpportunity = true
    static let appIntentShortcuts = true
    static let carPlayPreparation = false
}

enum DesignValues {
    static let cardRadius: Double = 18
    static let sheetSpacing: Double = 18
}
