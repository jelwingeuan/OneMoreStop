import Foundation

enum OpportunityStatus: String, Sendable {
    case discovered, evaluating, verified, surfaced, skipped, saved, expired, accepted
}

enum OpportunitySource: String, Sendable {
    case corridor, returnTrip, mission
}

struct JourneyOpportunity: Identifiable, Sendable {
    let place: PlaceSnapshot
    let routeID: UUID
    let progress: Double
    let distanceAhead: Double
    let approximateMinutesAhead: Int?
    let incrementalDriving: TimeInterval
    let totalDetour: TimeInterval
    let score: Double
    let reasons: [String]
    let source: OpportunitySource
    var status: OpportunityStatus
    let expiresAtProgress: Double

    var id: String { place.place.id }
    var isExactTimeAhead: Bool { false }
}

enum SmartSkipReason: String, CaseIterable, Identifiable, Sendable {
    case tooFar, notInterested, maybeLater, alreadyBeen, wrongCategory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tooFar: "Too far"
        case .notInterested: "Not interested"
        case .maybeLater: "Maybe later"
        case .alreadyBeen: "Already been"
        case .wrongCategory: "Wrong category"
        }
    }
}

struct OpportunityContext: Sendable {
    let routeID: UUID
    let routePath: [Coordinate]
    let routeDuration: TimeInterval
    let travelerProgress: Double
    let allowedExtraDriving: TimeInterval
    let selectedNeeds: Set<JourneyNeed>
    let categoryViews: [StopCategory: Int]
    let returnPlaceIDs: Set<String>
    let mission: JourneyMission?
    let rhythm: JourneyRhythmState
    let chapter: JourneyChapter
    let interestingOnly: Bool
}

@MainActor
final class OpportunityRadarEngine {
    private(set) var queue: [JourneyOpportunity] = []
    private(set) var surfacedID: String?
    private(set) var expiredCount = 0
    private(set) var skippedIDs = Set<String>()
    private(set) var shownIDs = Set<String>()
    private(set) var categorySkips: [StopCategory: Int] = [:]
    private(set) var statusByID: [String: OpportunityStatus] = [:]
    private var lastReplacement = Date.distantPast
    private var routeID: UUID?

    var next: JourneyOpportunity? {
        queue.first(where: { $0.id == surfacedID }) ?? queue.first
    }

    func reset() {
        queue = []
        surfacedID = nil
        expiredCount = 0
        skippedIDs = []
        shownIDs = []
        categorySkips = [:]
        statusByID = [:]
        routeID = nil
        lastReplacement = .distantPast
    }

    func prepare(routeID: UUID) {
        if self.routeID != routeID { reset(); self.routeID = routeID }
    }

    func trackDiscovered(_ places: [Place]) {
        for place in places where statusByID[place.id] == nil { statusByID[place.id] = .discovered }
    }

    func trackEvaluating(_ places: [Place]) {
        for place in places where statusByID[place.id] == .discovered { statusByID[place.id] = .evaluating }
    }

    func update(_ recommendations: [StopRecommendation], context: OpportunityContext, now: Date = .now) {
        prepare(routeID: context.routeID)
        let oldIDs = Set(queue.map(\.id))
        let candidates = recommendations.compactMap { item -> JourneyOpportunity? in
            guard !skippedIDs.contains(item.id),
                  item.progress + 0.015 >= context.travelerProgress,
                  item.detourTime <= context.allowedExtraDriving + 1 else { return nil }
            let totalDistance = zip(context.routePath, context.routePath.dropFirst())
                .reduce(0.0) { $0 + GeoMath.distance($1.0, $1.1) }
            let distanceAhead = max(0, item.progress - context.travelerProgress) * totalDistance
            let minutesAhead = totalDistance > 0
                ? Int((context.routeDuration * distanceAhead / totalDistance / 60).rounded()) : nil
            let score = OpportunityValue.score(item, context: context,
                                               shown: shownIDs.contains(item.id),
                                               categorySkips: categorySkips[item.place.category ?? .attractions, default: 0])
            guard !context.interestingOnly || score >= OpportunityValue.interestingThreshold else { return nil }
            var reasons = item.reasons.map(\.text)
            if item.incrementalDetourTime <= 5 * 60 && !reasons.contains("Barely off your route") {
                reasons.append("Barely off your route")
            }
            if let mission = context.mission, mission.matches(item.place.category) {
                reasons.append("Matches your \(mission.title.lowercased()) mission")
            }
            if context.rhythm == .breakWindow && item.needs.contains(.rest) {
                reasons.append("Fits your planned break window")
            }
            if context.returnPlaceIDs.contains(item.id) { reasons.append("Saved for another journey") }
            return JourneyOpportunity(place: PlaceSnapshot(item.place), routeID: context.routeID,
                                      progress: item.progress, distanceAhead: distanceAhead,
                                      approximateMinutesAhead: minutesAhead,
                                      incrementalDriving: item.incrementalDetourTime,
                                      totalDetour: item.detourTime, score: score,
                                      reasons: Array(reasons.prefix(3)),
                                      source: context.returnPlaceIDs.contains(item.id) ? .returnTrip :
                                          (context.mission?.matches(item.place.category) == true ? .mission : .corridor),
                                      status: .verified, expiresAtProgress: min(1, item.progress + 0.015))
        }
        .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let removed = oldIDs.subtracting(Set(candidates.map(\.id)))
        expiredCount += removed.count
        for id in removed { statusByID[id] = .expired }
        for item in candidates { statusByID[item.id] = .verified }
        let top = Array(candidates.prefix(3))
        if let current = candidates.first(where: { $0.id == surfacedID }),
           let challenger = top.first, challenger.id != current.id,
           challenger.score < current.score + 12 || now.timeIntervalSince(lastReplacement) < 180 {
            queue = [current] + top.filter { $0.id != current.id }.prefix(2)
        } else {
            if surfacedID != top.first?.id { lastReplacement = now }
            queue = top
            surfacedID = top.first?.id
        }
        if let surfacedID { shownIDs.insert(surfacedID) }
        if !queue.isEmpty {
            queue[0].status = .surfaced
            statusByID[queue[0].id] = .surfaced
        }
    }

    func skip(_ opportunity: JourneyOpportunity, reason: SmartSkipReason? = nil) {
        skippedIDs.insert(opportunity.id)
        statusByID[opportunity.id] = .skipped
        if reason != .maybeLater, let category = opportunity.place.place.category {
            categorySkips[category, default: 0] += 1
        }
        queue.removeAll { $0.id == opportunity.id }
        surfacedID = queue.first?.id
        if !queue.isEmpty { queue[0].status = .surfaced; statusByID[queue[0].id] = .surfaced }
    }

    func save(_ id: String) {
        skippedIDs.insert(id)
        statusByID[id] = .saved
        queue.removeAll { $0.id == id }
        surfacedID = queue.first?.id
        if !queue.isEmpty { queue[0].status = .surfaced; statusByID[queue[0].id] = .surfaced }
    }

    func accept(_ id: String) {
        statusByID[id] = .accepted
        queue.removeAll { $0.id == id }
        surfacedID = queue.first?.id
        if !queue.isEmpty { queue[0].status = .surfaced; statusByID[queue[0].id] = .surfaced }
    }

    func another() {
        guard let next else { return }
        shownIDs.insert(next.id)
        queue.removeAll { $0.id == next.id }
        var deferred = next
        deferred.status = .verified
        statusByID[deferred.id] = .verified
        queue.append(deferred)
        surfacedID = queue.first?.id
        if !queue.isEmpty { queue[0].status = .surfaced; statusByID[queue[0].id] = .surfaced }
    }
}

enum OpportunityValue {
    static let interestingThreshold = 75.0

    static func score(_ item: StopRecommendation, context: OpportunityContext,
                      shown: Bool, categorySkips: Int) -> Double {
        var value = item.score
        value += Double(item.needs.intersection(context.selectedNeeds).count * 10)
        if let mission = context.mission, mission.matches(item.place.category) { value += 12 }
        if context.rhythm == .breakWindow && item.needs.contains(.rest) { value += 8 }
        if context.chapter == .starting && item.needs.contains(.coffee) { value += 3 }
        if context.chapter == .halfway && item.needs.contains(.rest) { value += 3 }
        if context.chapter == .finalLeg && item.incrementalDetourTime > 10 * 60 { value -= 10 }
        if let category = item.place.category {
            value += Double(min(context.categoryViews[category, default: 0], 3) * 3)
        }
        if context.returnPlaceIDs.contains(item.id) { value += 12 }
        if item.progress < context.travelerProgress { value -= 100 }
        if item.incrementalDetourTime <= 5 * 60 { value += 5 }
        if shown { value -= 15 }
        value -= Double(min(categorySkips, 3) * 8)
        return value
    }
}
