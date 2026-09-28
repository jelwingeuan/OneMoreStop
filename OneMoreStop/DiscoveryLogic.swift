import Foundation
import MapKit

enum DiscoveryTuning {
    static let budgets = [5, 10, 20, 30, 45, 60]
    static let maxSamples = 12
    static let maxCandidatesForRouting = 12
    static let maxRecommendations = 8
    static let maxConcurrentRequests = 3
    static let cacheLifetime: TimeInterval = 600
    static let maxStops = 3

    static func sampleSpacing(for routeMeters: Double) -> Double {
        if routeMeters < 30_000 { return 2_500 }
        if routeMeters < 150_000 { return 10_000 }
        return 20_000
    }

    static func searchRadius(for budgetMinutes: Int) -> Double {
        switch budgetMinutes {
        case ...5: 2_000
        case ...10: 3_000
        case ...20: 5_000
        case ...30: 7_000
        case ...45: 9_000
        default: 10_000
        }
    }
}

enum RegionProfile {
    static func isMalaysia(_ coordinate: Coordinate) -> Bool {
        (1...7).contains(coordinate.latitude) && (99...120).contains(coordinate.longitude)
    }
}

enum GeoMath {
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        a.location.distance(from: b.location)
    }

    static func routeProximity(_ point: Coordinate, path: [Coordinate]) -> (distance: Double, progress: Double) {
        guard !path.isEmpty else { return (.infinity, 0) }
        guard path.count > 1 else { return (distance(point, path[0]), 0) }
        let lengths = zip(path, path.dropFirst()).map(distance)
        let total = lengths.reduce(0, +)
        var traveled = 0.0
        var best = (distance: Double.infinity, progress: 0.0)
        for (index, segmentLength) in lengths.enumerated() {
            let a = path[index], b = path[index + 1]
            // Local tangent-plane projection is a cheap shortlist heuristic, not a driving distance.
            let latScale = 111_195.0
            let lonScale = latScale * cos(point.latitude * .pi / 180)
            let ax = (a.longitude - point.longitude) * lonScale
            let ay = (a.latitude - point.latitude) * latScale
            let bx = (b.longitude - point.longitude) * lonScale
            let by = (b.latitude - point.latitude) * latScale
            let dx = bx - ax, dy = by - ay
            let fraction = min(1, max(0, -(ax * dx + ay * dy) / max(1, dx * dx + dy * dy)))
            let proximity = hypot(ax + fraction * dx, ay + fraction * dy)
            if proximity < best.distance {
                best = (proximity, total > 0 ? (traveled + fraction * segmentLength) / total : 0)
            }
            traveled += segmentLength
        }
        return best
    }
}

enum PolylineSampling {
    // Uses traveled distance, never raw vertex count; includes both endpoints.
    static func sample(_ path: [Coordinate], spacing: Double, limit: Int) -> [Coordinate] {
        guard path.count > 1, spacing > 0, limit > 1 else { return path.prefix(1).map { $0 } }
        let distances = zip(path, path.dropFirst()).map(GeoMath.distance)
        let total = distances.reduce(0, +)
        guard total > 0 else { return [path[0]] }
        let count = min(limit, max(2, Int(ceil(total / spacing)) + 1))
        var sampled = [Coordinate]()
        var segment = 0
        var accumulated = 0.0
        for sampleIndex in 0..<count {
            let target = total * Double(sampleIndex) / Double(count - 1)
            while segment < distances.count - 1 && accumulated + distances[segment] < target {
                accumulated += distances[segment]
                segment += 1
            }
            let fraction = (target - accumulated) / max(distances[segment], 1)
            let a = path[segment], b = path[segment + 1]
            sampled.append(Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                      longitude: a.longitude + (b.longitude - a.longitude) * fraction))
        }
        return sampled
    }
}

enum CandidateDeduplication {
    static func unique(_ places: [Place]) -> [Place] {
        var ids = Set<String>()
        return places.filter { ids.insert($0.id).inserted }
    }
}

enum DetourMath {
    static func extra(_ first: Double, _ second: Double, baseline: Double) -> Double {
        max(0, first + second - baseline)
    }
}

enum JourneyMath {
    static func inserted(_ place: Place, into stops: [Place], at index: Int) -> [Place] {
        var copy = stops
        copy.insert(place, at: min(max(0, index), copy.count))
        return copy
    }

    static func moved(_ stops: [Place], from source: Int, to destination: Int) -> [Place] {
        guard stops.indices.contains(source), (0...stops.count).contains(destination) else { return stops }
        var copy = stops
        let place = copy.remove(at: source)
        copy.insert(place, at: min(destination > source ? destination - 1 : destination, copy.count))
        return copy
    }

    static func arrival(after legs: [RouteMetrics], startingAt date: Date) -> Date {
        date.addingTimeInterval(legs.reduce(0) { $0 + $1.duration })
    }
}

enum StopScoringService {
    static func score(categoryMatch: Bool, detour: Double, budget: Double, proximity: Double, progress: Double) -> Double {
        let relevance = categoryMatch ? 40.0 : 20.0
        let time = 25.0 * (1 - min(1, detour / max(budget, 1)))
        let close = 20.0 * (1 - min(1, proximity / 10_000))
        let ahead = 15.0 * min(1, max(0, progress))
        return relevance + time + close + ahead
    }

    static func withinBudget(_ recommendations: [StopRecommendation], minutes: Int) -> [StopRecommendation] {
        recommendations.filter { $0.detourTime <= Double(minutes * 60) + 1 }
            .sorted { $0.score == $1.score ? $0.place.id < $1.place.id : $0.score > $1.score }
    }

    static func preference(for category: StopCategory?, mode: DiscoveryMode, mood: DiscoveryMood,
                           localFirst: Bool, isMalaysia: Bool, adventure: Bool) -> Double {
        guard let category else { return 0 }
        var value = 0.0
        if mode.categories(isMalaysia: isMalaysia, localFirst: localFirst, evJourney: true, adventure: adventure).contains(category) { value += 12 }
        if localFirst && isMalaysia && [.localFood, .mamak, .nasiLemak, .restArea].contains(category) { value += 5 }
        if adventure && [.nature, .scenic, .localFood, .attractions, .waterfall].contains(category) { value += 6 }
        switch mood {
        case .calm where [.park, .nature, .scenic, .beach].contains(category): value += 5
        case .curious where [.attractions, .viewpoint, .waterfall].contains(category): value += 5
        case .hungry where [.food, .localFood, .mamak, .coffee].contains(category): value += 5
        default: break
        }
        return value
    }

    static func aheadPenalty(candidate: Double, traveler: Double, exploringArea: Bool) -> Double {
        exploringArea || candidate + 0.02 >= traveler ? 0 : 35
    }
}

enum RecommendationCopyService {
    static func phrase(for recommendation: StopRecommendation) -> String {
        if recommendation.detourTime < 5 * 60 { return "Barely a detour" }
        if recommendation.place.category == .coffee { return "Quick coffee stop" }
        if recommendation.place.category == .park { return "Stretch your legs" }
        if recommendation.place.category == .scenic || recommendation.place.category == .viewpoint { return "Scenic break" }
        return "Worth \(Int((recommendation.detourTime / 60).rounded())) extra minutes"
    }
}

enum TripFormatting {
    static func extraTime(_ seconds: Double) -> String { "+\(Int((seconds / 60).rounded())) min" }
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        return hours == 0 ? "\(minutes) min" : "\(hours) hr \(minutes % 60) min"
    }
    static func distance(_ meters: Double, locale: Locale = .current, preference: String = "automatic") -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = preference == "automatic" ? .naturalScale : .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 1
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        if preference == "miles" { return formatter.string(from: measurement.converted(to: .miles)) }
        if preference == "kilometers" { return formatter.string(from: measurement.converted(to: .kilometers)) }
        return formatter.string(from: measurement)
    }
    static func arrival(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }
}
