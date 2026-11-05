import Foundation
import Testing
@testable import OneMoreStop

@MainActor
struct OpportunityRadarTests {
    private let a = Coordinate(latitude: 3, longitude: 101)
    private let b = Coordinate(latitude: 3, longitude: 102)

    private func item(_ id: String, progress: Double, score: Double,
                      category: StopCategory = .coffee, detour: Double = 180) -> StopRecommendation {
        let route = RouteMetrics(duration: 600, distance: 1_000, path: [a, b])
        var result = StopRecommendation(place: Place(id: id, name: id, coordinate: a, category: category),
            detourTime: detour, detourDistance: 300, distanceFromRoute: 10,
            progress: progress, score: score, firstLeg: route, secondLeg: route)
        result.incrementalDetourTime = detour
        result.needs = JourneyNeed.verified(for: category)
        return result
    }

    private func context(progress: Double = 0, budget: Double = 600,
                         mission: JourneyMission? = nil, interestingOnly: Bool = false) -> OpportunityContext {
        OpportunityContext(routeID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            routePath: [a, b], routeDuration: 3_600, travelerProgress: progress,
            allowedExtraDriving: budget, selectedNeeds: [.coffee], categoryViews: [:],
            returnPlaceIDs: [], mission: mission,
            rhythm: .settled, chapter: .halfway, interestingOnly: interestingOnly)
    }

    @Test func queueExpiresPassedAndOverBudgetStops() {
        let radar = OpportunityRadarEngine()
        radar.update([item("near", progress: 0.2, score: 90),
                      item("far", progress: 0.7, score: 80),
                      item("costly", progress: 0.8, score: 100, detour: 900)], context: context())
        #expect(radar.queue.map(\.place.name) == ["near", "far"])
        #expect(radar.next?.status == .surfaced)
        radar.update([item("near", progress: 0.2, score: 90), item("far", progress: 0.7, score: 80)],
                     context: context(progress: 0.5))
        #expect(radar.queue.map(\.place.name) == ["far"])
        #expect(radar.expiredCount >= 1)
        #expect(radar.statusByID[Place.key(identifier: nil, name: "near", coordinate: a)] == .expired)
    }

    @Test func removedVerifiedResultCannotRemainActionableDuringReplacementCooldown() {
        let radar = OpportunityRadarEngine()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = item("first", progress: 0.2, score: 90)
        let second = item("second", progress: 0.4, score: 80)
        radar.update([first, second], context: context(), now: start)
        #expect(radar.next?.place.name == first.place.name)

        radar.update([second], context: context(), now: start.addingTimeInterval(10))

        #expect(radar.next?.place.name == second.place.name)
        #expect(!radar.queue.contains(where: { $0.place.name == first.place.name }))
        #expect(radar.statusByID[Place.key(identifier: nil, name: first.place.name, coordinate: a)] == .expired)
    }

    @Test func skipAndDiversityRemainSessionLocal() {
        let radar = OpportunityRadarEngine()
        let items = [item("coffee-1", progress: 0.2, score: 95),
                     item("coffee-2", progress: 0.4, score: 92),
                     item("view", progress: 0.5, score: 90, category: .viewpoint)]
        radar.update(items, context: context())
        let first = radar.next!
        radar.skip(first, reason: .wrongCategory)
        #expect(radar.statusByID[first.id] == .skipped)
        radar.update(items, context: context())
        #expect(radar.next?.id != first.id)
        #expect(radar.categorySkips[.coffee] == 1)
        radar.reset()
        #expect(radar.skippedIDs.isEmpty)
    }

    @Test func missionAndInterestingOnlyHaveDeterministicWeights() {
        let coffee = item("coffee", progress: 0.5, score: 65)
        let context = context(mission: .coffee)
        #expect(OpportunityValue.score(coffee, context: context, shown: false, categorySkips: 0) >
                OpportunityValue.score(coffee, context: context, shown: true, categorySkips: 2))
        let viewed = OpportunityContext(routeID: context.routeID, routePath: context.routePath,
            routeDuration: context.routeDuration, travelerProgress: context.travelerProgress,
            allowedExtraDriving: context.allowedExtraDriving, selectedNeeds: context.selectedNeeds,
            categoryViews: [.coffee: 2], returnPlaceIDs: [], mission: .coffee,
            rhythm: .settled, chapter: .halfway, interestingOnly: false)
        #expect(OpportunityValue.score(coffee, context: viewed, shown: false, categorySkips: 0) >
                OpportunityValue.score(coffee, context: context, shown: false, categorySkips: 0))
        let radar = OpportunityRadarEngine()
        radar.update([item("weak", progress: 0.5, score: 10)], context: self.context(interestingOnly: true))
        #expect(radar.next == nil)
    }

    @Test func timeMachineFiltersRoutedTotals() {
        let items = [item("five", progress: 0.2, score: 80, detour: 300),
                     item("fifteen", progress: 0.4, score: 90, detour: 900)]
        #expect(TimeMachine.filtered(items, minutes: 5).map(\.id) == ["five"])
        #expect(TimeMachine.filtered(items, minutes: 15).count == 2)
    }

    @Test func rhythmUsesOnlyJourneyTiming() {
        #expect(JourneyRhythmService.state(elapsed: 20 * 60, remaining: 3_600,
                                           timeSinceLastSelectedStop: nil) == .earlyJourney)
        #expect(JourneyRhythmService.state(elapsed: 100 * 60, remaining: 3_600,
                                           timeSinceLastSelectedStop: nil) == .breakWindow)
        #expect(JourneyRhythmService.state(elapsed: 100 * 60, remaining: 15 * 60,
                                           timeSinceLastSelectedStop: nil) == .nearDestination)
    }

    @Test func autopilotUsesTheSmallerOfItsRuleCapAndRemainingWallet() {
        let rules = [JourneyRule(need: .coffee, enabled: true,
                                 minimumElapsedMinutes: 90, maximumDetourMinutes: 10)]
        let fiveMinuteWallet = JourneyRhythmService.suggestedLimits(
            rules: rules, elapsed: 90 * 60, remainingBudget: 5 * 60)
        #expect(fiveMinuteWallet[.coffee] == 300.0)
        #expect(JourneyRhythmService.suggestedNeeds(
            rules: rules, elapsed: 90 * 60, remainingBudget: 5 * 60) == [.coffee])
        #expect(JourneyRhythmService.permitsSuggestion(
            needs: [.coffee], incrementalDetour: 3 * 60, limits: fiveMinuteWallet))
        #expect(!JourneyRhythmService.permitsSuggestion(
            needs: [.coffee], incrementalDetour: 6 * 60, limits: fiveMinuteWallet))

        let wideWallet = JourneyRhythmService.suggestedLimits(
            rules: rules, elapsed: 90 * 60, remainingBudget: 20 * 60)
        #expect(wideWallet[.coffee] == 600.0)
        #expect(!JourneyRhythmService.permitsSuggestion(
            needs: [.coffee], incrementalDetour: 11 * 60, limits: wideWallet))
        #expect(!JourneyRhythmService.permitsSuggestion(
            needs: [.fuel], incrementalDetour: 3 * 60, limits: wideWallet))
        #expect(JourneyRhythmService.suggestedLimits(
            rules: rules, elapsed: 89 * 60, remainingBudget: 5 * 60).isEmpty)
    }

    @Test func autopilotOnlyResultsRespectTheirRoutedDetourCap() {
        let origin = Place(id: "origin", name: "Start", coordinate: a)
        let destination = Place(id: "destination", name: "Finish", coordinate: b)
        let baseline = RouteMetrics(duration: 120 * 60, distance: 80_000, path: [a, b])
        let state = AppState()
        state.route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                                baseline: baseline, createdAt: .now)
        state.journey = Journey(stops: [], legs: [baseline], baseline: baseline)
        state.mode = .nature
        state.budgetMinutes = 20
        state.travelerProgress = 0.8
        state.autopilotRules = [JourneyRule(need: .coffee, enabled: true,
                                             minimumElapsedMinutes: 90, maximumDetourMinutes: 10)]
        let short = item("short coffee", progress: 0.9, score: 90, detour: 3 * 60)
        let long = item("long coffee", progress: 0.95, score: 95, detour: 11 * 60)
        state.recommendations = [short, long]

        state.refreshOpportunityPolicy()
        #expect(state.opportunities.map(\.place.name) == [short.place.name])
        #expect(state.opportunities.first?.reasons.contains("Fits your coffee suggestion limit") == true)

        state.selectedNeeds = [.coffee]
        state.refreshOpportunityPolicy()
        #expect(state.opportunities.contains(where: { $0.place.name == long.place.name }))
    }

    @Test func visibleOpportunitySurvivesAChallengerDuringCooldown() {
        let radar = OpportunityRadarEngine()
        let start = Date(timeIntervalSince1970: 1_000)
        radar.update([item("current", progress: 0.2, score: 80)], context: context(), now: start)
        let challengers = [item("first", progress: 0.3, score: 105),
                           item("second", progress: 0.4, score: 104),
                           item("third", progress: 0.5, score: 103)]
        radar.update([item("current", progress: 0.2, score: 80)] + challengers,
                     context: context(), now: start.addingTimeInterval(30))
        #expect(radar.next?.place.name == "current")
        #expect(radar.queue.count == 3)
        radar.update([item("current", progress: 0.2, score: 80)] + challengers,
                     context: context(), now: start.addingTimeInterval(240))
        #expect(radar.next?.place.name == "first")
    }
}
