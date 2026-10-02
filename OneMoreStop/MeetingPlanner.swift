import Foundation

struct MeetingParticipant: Identifiable, Sendable {
    let id: UUID
    var name: String
    var origin: Place?
    var destination: Place?
    var departure: Date

    init(id: UUID = UUID(), name: String, origin: Place? = nil, destination: Place? = nil,
         departure: Date = .now) {
        self.id = id
        self.name = name
        self.origin = origin
        self.destination = destination
        self.departure = departure
    }
}

struct MeetingCost: Sendable {
    let participantName: String
    let detour: TimeInterval
    let arrival: Date
}

struct MeetingResult: Identifiable, Sendable {
    let place: Place
    let costs: [MeetingCost]
    var id: String { place.id }
    var combinedDetour: TimeInterval { costs.reduce(0) { $0 + $1.detour } }
    var maximumDetour: TimeInterval { costs.map(\.detour).max() ?? 0 }
    var arrivalSpread: TimeInterval {
        guard let first = costs.map(\.arrival).min(), let last = costs.map(\.arrival).max() else { return 0 }
        return last.timeIntervalSince(first)
    }
}

enum MeetingRanking {
    static func rank(_ results: [MeetingResult], minimizeTotal: Bool) -> [MeetingResult] {
        results.sorted { a, b in
            let firstA = minimizeTotal ? a.combinedDetour : a.maximumDetour
            let firstB = minimizeTotal ? b.combinedDetour : b.maximumDetour
            if firstA != firstB { return firstA < firstB }
            let secondA = minimizeTotal ? a.maximumDetour : a.combinedDetour
            let secondB = minimizeTotal ? b.maximumDetour : b.combinedDetour
            if secondA != secondB { return secondA < secondB }
            if a.arrivalSpread != b.arrivalSpread { return a.arrivalSpread < b.arrivalSpread }
            return a.id < b.id
        }
    }
}

@MainActor
final class MeetingPlannerService {
    private let directions: any DrivingDirectionsProviding
    private let search: any PlaceDiscoveryProviding

    init(directions: any DrivingDirectionsProviding, search: any PlaceDiscoveryProviding) {
        self.directions = directions
        self.search = search
    }

    func find(participants: [MeetingParticipant], minimizeTotal: Bool) async throws -> [MeetingResult] {
        guard (2...6).contains(participants.count), participants.allSatisfy({ $0.origin != nil && $0.destination != nil }) else {
            return []
        }
        var baselines = [RouteMetrics]()
        for person in participants {
            try Task.checkCancellation()
            baselines.append(try await directions.route(from: person.origin!, to: person.destination!))
        }
        let samples = PolylineSampling.sample(baselines[0].path,
            spacing: DiscoveryTuning.sampleSpacing(for: baselines[0].distance), limit: 8)
        let shared = samples.filter { sample in
            baselines.dropFirst().allSatisfy { GeoMath.routeProximity(sample, path: $0.path).distance < 20_000 }
        }
        var found = [Place]()
        for center in shared.prefix(4) {
            try Task.checkCancellation()
            for category in [StopCategory.coffee, .food] {
                if let places = try? await search.discover(around: center, radius: 5_000, category: category) {
                    found += places
                }
            }
        }
        let candidates = CandidateDeduplication.unique(found).filter { place in
            baselines.allSatisfy { GeoMath.routeProximity(place.coordinate, path: $0.path).distance < 12_000 }
        }.sorted { first, second in
            let firstCost = baselines.reduce(0.0) { $0 + GeoMath.routeProximity(first.coordinate, path: $1.path).distance }
            let secondCost = baselines.reduce(0.0) { $0 + GeoMath.routeProximity(second.coordinate, path: $1.path).distance }
            return firstCost == secondCost ? first.id < second.id : firstCost < secondCost
        }.prefix(4)
        var results = [MeetingResult]()
        for place in candidates {
            try Task.checkCancellation()
            var costs = [MeetingCost]()
            for (index, person) in participants.enumerated() {
                do {
                    let toMeeting = try await directions.route(from: person.origin!, to: place)
                    let onward = try await directions.route(from: place, to: person.destination!)
                    costs.append(MeetingCost(participantName: person.name,
                        detour: DetourMath.extra(toMeeting.duration, onward.duration,
                                                 baseline: baselines[index].duration),
                        arrival: person.departure.addingTimeInterval(toMeeting.duration)))
                } catch is CancellationError { throw CancellationError() }
                catch { break }
            }
            if costs.count == participants.count { results.append(MeetingResult(place: place, costs: costs)) }
        }
        return MeetingRanking.rank(results, minimizeTotal: minimizeTotal)
    }
}
