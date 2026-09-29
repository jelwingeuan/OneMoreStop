import Foundation
import MapKit

enum SpontaneousKind: String, CaseIterable, Identifiable, Sendable {
    case driveUntil, escape
    var id: String { rawValue }
    var title: String { self == .driveUntil ? "Drive Until" : "Escape Mode" }
}

struct SpontaneousPlan: Identifiable, Sendable {
    let origin: Place
    let place: Place
    let secondPlace: Place?
    let legs: [RouteMetrics]
    let returnsHome: Bool
    let targetMinutes: Int
    let kind: SpontaneousKind

    init(origin: Place, place: Place, secondPlace: Place? = nil, legs: [RouteMetrics],
         returnsHome: Bool, targetMinutes: Int, kind: SpontaneousKind) {
        self.origin = origin
        self.place = place
        self.secondPlace = secondPlace
        self.legs = legs
        self.returnsHome = returnsHome
        self.targetMinutes = targetMinutes
        self.kind = kind
    }

    var stops: [Place] { [place] + [secondPlace].compactMap { $0 } }
    var id: String { place.id + (secondPlace.map { ":" + $0.id } ?? "") +
        (returnsHome ? ":loop" : ":one-way") }
    var drivingDuration: TimeInterval { legs.reduce(0) { $0 + $1.duration } }
    var path: [Coordinate] { legs.flatMap(\.path) }
}

enum SpontaneousPlanning {
    static func searchRadius(minutes: Int, returnsHome: Bool) -> Double {
        min(45_000, max(8_000, Double(minutes) * (returnsHome ? 350 : 700)))
    }

    static func fits(_ duration: TimeInterval, targetMinutes: Int) -> Bool {
        duration > Double(targetMinutes) * 60 * 0.2 && duration <= Double(targetMinutes) * 60
    }
}

@MainActor
final class SpontaneousJourneyService {
    let search: any PlaceDiscoveryProviding
    let directions: any DrivingDirectionsProviding

    init(search: any PlaceDiscoveryProviding, directions: any DrivingDirectionsProviding) {
        self.search = search
        self.directions = directions
    }

    func suggestions(origin: Place, kind: SpontaneousKind, minutes: Int,
                     mode: DiscoveryMode, returnsHome: Bool) async throws -> [SpontaneousPlan] {
        let categories = Array(mode.categories(isMalaysia: RegionProfile.isMalaysia(origin.coordinate),
                                               localFirst: false, evJourney: false,
                                               adventure: kind == .escape)
            .prefix(DiscoveryTuning.maxSpontaneousCategories))
        let radius = SpontaneousPlanning.searchRadius(minutes: minutes, returnsHome: returnsHome)
        var found = [Place]()
        var successfulSearches = 0
        for category in categories {
            try Task.checkCancellation()
            do {
                found += try await search.discover(around: origin.coordinate, radius: radius, category: category)
                successfulSearches += 1
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        if successfulSearches == 0 { throw DiscoveryError.searchUnavailable }
        let candidates = CandidateDeduplication.unique(found)
            .filter { GeoMath.distance(origin.coordinate, $0.coordinate) > 1_000 }
            .sorted { left, right in
                GeoMath.distance(origin.coordinate, left.coordinate) < GeoMath.distance(origin.coordinate, right.coordinate)
            }
        var plans = [SpontaneousPlan]()
        for place in candidates.prefix(DiscoveryTuning.maxSpontaneousCandidates) {
            try Task.checkCancellation()
            do {
                let outward = try await directions.route(from: origin, to: place)
                let legs = returnsHome ? [outward, try await directions.route(from: place, to: origin)] : [outward]
                let plan = SpontaneousPlan(origin: origin, place: place, legs: legs,
                                           returnsHome: returnsHome, targetMinutes: minutes, kind: kind)
                if SpontaneousPlanning.fits(plan.drivingDuration, targetMinutes: minutes) { plans.append(plan) }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        if kind == .escape && returnsHome {
            let paired = Array(candidates.prefix(DiscoveryTuning.maxEscapePairCandidates))
            for firstIndex in paired.indices {
                for secondIndex in paired.indices where secondIndex > firstIndex {
                    try Task.checkCancellation()
                    let first = paired[firstIndex], second = paired[secondIndex]
                    do {
                        let legs = [try await directions.route(from: origin, to: first),
                                    try await directions.route(from: first, to: second),
                                    try await directions.route(from: second, to: origin)]
                        let plan = SpontaneousPlan(origin: origin, place: first, secondPlace: second,
                                                   legs: legs, returnsHome: true,
                                                   targetMinutes: minutes, kind: kind)
                        if SpontaneousPlanning.fits(plan.drivingDuration, targetMinutes: minutes) {
                            plans.append(plan)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue }
                }
            }
        }
        return plans.sorted {
            let left = abs($0.drivingDuration - Double(minutes * 60))
            let right = abs($1.drivingDuration - Double(minutes * 60))
            return left == right ? $0.id < $1.id : left < right
        }.prefix(6).map { $0 }
    }
}
