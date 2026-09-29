import Foundation

enum JourneyShare {
    static func summary(origin: String, destination: String, stops: [Place]) -> String {
        let points = [origin] + stops.map(\.name) + [destination]
        return "Planned in OneMoreStop: " + points.joined(separator: " → ")
    }
}

enum PlanningChallenges {
    static func earned(from journeys: [RecentJourney]) -> [String] {
        var result = [String]()
        if journeys.contains(where: { $0.places.count > 2 }) { result.append("First stop planned") }
        if journeys.contains(where: { $0.places.count >= 5 }) { result.append("Three-stop planner") }
        if journeys.contains(where: { journey in
            journey.places.dropFirst(2).contains {
                guard let category = $0.category else { return false }
                return [.scenic, .nature, .park, .viewpoint, .waterfall].contains(category)
            }
        }) { result.append("Scenic planner") }
        return result
    }
}
