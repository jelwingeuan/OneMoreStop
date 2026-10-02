import Foundation

enum JourneyChapter: String, Sendable {
    case starting, onTheWay, halfway, finalLeg

    var title: String {
        switch self {
        case .starting: "Setting off"
        case .onTheWay: "On the way"
        case .halfway: "Middle of the journey"
        case .finalLeg: "Final leg"
        }
    }

    static func at(progress: Double) -> JourneyChapter {
        switch progress {
        case ..<0.15: .starting
        case ..<0.4: .onTheWay
        case ..<0.8: .halfway
        default: .finalLeg
        }
    }
}

enum RouteOpportunitySummary {
    static func counts(_ discovery: CandidateDiscovery, path: [Coordinate]) -> [(String, Int)] {
        guard discovery.successfulSearches > 0 else { return [] }
        let near = CandidateDeduplication.unique(discovery.places).filter {
            GeoMath.routeProximity($0.coordinate, path: path).distance <= 5_000
        }
        let groups: [(String, Set<StopCategory>)] = [
            ("Food", [.food, .localFood, .mamak, .nasiLemak]),
            ("Coffee", [.coffee]),
            ("Scenic", [.scenic, .viewpoint, .beach]),
            ("Rest", [.restArea, .restStop])
        ]
        return groups.compactMap { title, categories in
            let count = near.filter { $0.category.map(categories.contains) ?? false }.count
            return count > 0 ? (title, count) : nil
        }
    }
}
