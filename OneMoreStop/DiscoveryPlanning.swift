import Foundation

struct PlannedSearch: Hashable, Sendable {
    let center: Coordinate
    let radius: Double
    let category: StopCategory
}

struct CandidateDiscovery: Sendable {
    let places: [Place]
    let samples: [Coordinate]
    let attemptedSearches: Int
    let successfulSearches: Int
    let successfulCenters: [Coordinate]

    var coverageIsUsable: Bool {
        attemptedSearches > 0 && Double(successfulSearches) / Double(attemptedSearches) >= 0.8
    }
}

enum OpportunityCoverage {
    static func nearbyCount(_ places: [Place], path: [Coordinate], radius: Double = 2_000) -> Int {
        places.filter { GeoMath.routeProximity($0.coordinate, path: path).distance <= radius }.count
    }

    static func density(at center: Coordinate, places: [Place], radius: Double = 3_000) -> Int {
        places.filter { GeoMath.distance(center, $0.coordinate) <= radius }.count
    }
}

struct SurpriseConstraints: Equatable, Sendable {
    var noFood = false
    var onlyAhead = false
    var maxExtraMinutes: Int?
}

enum QueryPlanner {
    static func plan(samples: [Coordinate], radius: Double, mode: DiscoveryMode,
                     mood: DiscoveryMood, needs: Set<JourneyNeed>, isMalaysia: Bool,
                     localFirst: Bool, evJourney: Bool, adventure: Bool,
                     surprise: SurpriseConstraints = .init(),
                     limit: Int = DiscoveryTuning.maxSamples) -> [PlannedSearch] {
        guard !samples.isEmpty, limit > 0 else { return [] }
        let requested = needs.sorted { $0.rawValue < $1.rawValue }.compactMap { $0.categories.first }
        let modes = mode.categories(isMalaysia: isMalaysia, localFirst: localFirst,
                                    evJourney: evJourney, adventure: adventure, mood: mood)
        var seen = Set<StopCategory>()
        let categories = (requested + modes).filter { category in
            if mode == .surpriseMe && surprise.noFood &&
                [.food, .localFood, .nasiLemak, .mamak, .coffee, .dessert].contains(category) { return false }
            return seen.insert(category).inserted
        }
        guard !categories.isEmpty else { return [] }
        let count = min(limit, max(samples.count, categories.count))
        return (0..<count).map { index in
            PlannedSearch(center: samples[index % samples.count], radius: radius,
                          category: categories[index % categories.count])
        }
    }
}

struct AheadComparison: Sendable {
    let nearby: StopRecommendation
    let later: StopRecommendation
    let savings: TimeInterval
}

enum OpportunityAssessment {
    static func betterAhead(in recommendations: [StopRecommendation], travelerProgress: Double = 0,
                            minimumSavings: TimeInterval = 180) -> AheadComparison? {
        let sorted = recommendations.filter { $0.progress + 0.02 >= travelerProgress }
            .sorted { $0.progress < $1.progress }
        for nearby in sorted {
            guard let later = sorted.first(where: {
                $0.progress >= nearby.progress + 0.08 &&
                !$0.needs.isDisjoint(with: nearby.needs) &&
                nearby.incrementalDetourTime - $0.incrementalDetourTime >= minimumSavings
            }) else { continue }
            return AheadComparison(nearby: nearby, later: later,
                                   savings: nearby.incrementalDetourTime - later.incrementalDetourTime)
        }
        return nil
    }

    static func isZeroRegret(_ recommendation: StopRecommendation, travelerProgress: Double) -> Bool {
        recommendation.incrementalDetourTime <= 5 * 60 &&
        recommendation.progress + 0.02 >= travelerProgress &&
        recommendation.distanceFromRoute <= 1_000
    }

    static func detourLabel(_ seconds: TimeInterval) -> String {
        if seconds <= 5 * 60 { return "Easy stop" }
        if seconds <= 15 * 60 { return "Moderate detour" }
        return "Large detour"
    }
}
