import Foundation
import MapKit
import Observation
import SwiftUI

@MainActor @Observable
final class AppState {
    var origin: Place?
    var destination: Place?
    var route: RoutePlan?
    var journey: Journey?
    var focusedRecommendationID: String?
    var recommendations = [StopRecommendation]()
    var opportunities = [JourneyOpportunity]()
    var returnOpportunities = [SavedReturnOpportunity]()
    var selectedMission: JourneyMission?
    var interestingOnly = false
    var oneMoreStopPresented = false
    var timeMachinePreview: Int?
    var whatWasThatResults = [Place]()
    var whatWasThatBusy = false
    var rouletteMaximumMinutes = 20
    var rouletteIndex = 0
    var rouletteRevealed = false
    private var recentRoutePositions = [(coordinate: Coordinate, date: Date)]()
    var autopilotRules = [JourneyRule(need: .coffee, enabled: false, minimumElapsedMinutes: 90, maximumDetourMinutes: 10),
                          JourneyRule(need: .rest, enabled: false, minimumElapsedMinutes: 120, maximumDetourMinutes: 10)]
    var combinations = [StopCombination]()
    var chains = [StopCombination]()
    var evNearby: [String: [Place]] = [:]
    var checkingPlaces = [Place]()
    var discoveryCoverage: CandidateDiscovery?
    var phase: DiscoveryPhase = .idle
    var timeBudget: TimeBudget = .spare(minutes: 20)
    var clockNow = Date.now
    var plannedVisitMinutes: [String: Int] = [:]
    var budgetMinutes: Int {
        get { Int((allowedExtraDriving / 60).rounded(.down)) }
        set { timeBudget = .spare(minutes: newValue) }
    }
    var defaultBudgetMinutes = 20
    var mode: DiscoveryMode = .eat
    var mood: DiscoveryMood = .any
    var selectedNeeds = Set<JourneyNeed>()
    var ignoredPlaceIDs = Set<String>()
    var previouslySelectedPlaceIDs = Set<String>()
    var sessionViewedCategories: [StopCategory: Int] = [:]
    var notInterestedIDs = Set<String>()
    var preferenceCounts: [String: Int] = [:]
    var surpriseConstraints = SurpriseConstraints()
    var localFirst = false
    var evJourney = false
    var exploringArea = false
    var showDensity = false
    var travelerProgress = 0.0
    var isTravelerOnRoute = true
    var selectedRouteIndex = 0
    var remixMode: DiscoveryMode = .explore
    var routeComparisonCounts: [Int: Int] = [:]
    var routeComparisonSearches: [Int: Int] = [:]
    var routeComparisonBusy = false
    var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687), latitudinalMeters: 120_000, longitudinalMeters: 120_000))
    var cameraWasMovedByUser = false
    var locationMessage: String?
    var journeyMessage: String?
    var journeyBusy = false
    var openedLegCount = 0
    var surpriseIndex = 0
    var showSurpriseAlternatives = false
    var spontaneousSuggestions = [SpontaneousPlan]()
    var spontaneousPlan: SpontaneousPlan?
    var spontaneousBusy = false
    var spontaneousMessage: String?
    var spontaneousOpenedLegCount = 0
    var activeJourney = false
    var liveActivityRunning = false
    var activeMessage: String?
    var lastActiveDiscoveryAt: Date?
    var lastActiveReminderID: String?
    var completedRouteID: UUID?
    var completionMoment = false
    var lastRecap: JourneyRecap?
    private var sessionSavedReturnIDs = Set<String>()
    var sessionSavedForReturn: Int { sessionSavedReturnIDs.count }
    var activeSkippedCount = 0
    private var deadlineOriginalAllowance: TimeInterval = 0

    var selectedStops: [Place] { journey?.stops ?? [] }
    var canAddStop: Bool { selectedStops.count < DiscoveryTuning.maxStops }
    var betterAhead: AheadComparison? {
        OpportunityAssessment.betterAhead(in: recommendations, travelerProgress: travelerProgress)
    }
    var usefulAhead: StopRecommendation? {
        recommendations.filter { $0.progress + 0.02 >= travelerProgress &&
            !$0.needs.isDisjoint(with: [.fuel, .charging, .rest, .coffee, .food]) }
            .min { $0.progress < $1.progress }
    }
    var fewPlacesAhead: Bool {
        guard let discoveryCoverage, discoveryCoverage.coverageIsUsable, let route else { return false }
        return !discoveryCoverage.places.contains {
            let position = GeoMath.routeProximity($0.coordinate, path: route.baseline.path)
            return position.progress > travelerProgress + 0.15
        }
    }
    var plannedVisitSeconds: TimeInterval {
        selectedStops.reduce(0) { $0 + Double(plannedVisitMinutes[$1.id, default: 0] * 60) }
    }
    var allowedExtraDriving: TimeInterval {
        timeBudget.allowedExtraDriving(baseline: route?.baseline.duration ?? 0,
                                       plannedVisits: plannedVisitSeconds, now: clockNow)
    }
    var remainingTime: TimeInterval {
        timeBudget.remaining(baseline: route?.baseline.duration ?? 0,
                             journey: journey?.drivingDuration ?? route?.baseline.duration ?? 0,
                             plannedVisits: plannedVisitSeconds, now: clockNow)
    }
    var drivingArrival: Date? { journey.map { clockNow.addingTimeInterval($0.drivingDuration) } }
    var activeDrivingArrival: Date? {
        journey.map { clockNow.addingTimeInterval($0.drivingDuration * max(0, 1 - travelerProgress)) }
    }
    var plannedArrival: Date? { drivingArrival?.addingTimeInterval(plannedVisitSeconds) }
    var profileOriginalAllowance: TimeInterval {
        switch timeBudget {
        case .spare(let minutes): Double(minutes * 60)
        case .arriveBy: deadlineOriginalAllowance
        }
    }
    func profileRemainingTime(at now: Date) -> TimeInterval {
        timeBudget.remaining(baseline: route?.baseline.duration ?? 0,
                             journey: journey?.drivingDuration ?? route?.baseline.duration ?? 0,
                             plannedVisits: plannedVisitSeconds, now: now)
    }
    var profileAvatarState: ProfileAvatarState {
        ProfileAvatarState.resolve(hasRoute: route != nil,
                                   discovering: phase == .discoveringPlaces || phase == .calculatingDetours,
                                   hasStop: !selectedStops.isEmpty, active: activeJourney,
                                   completed: completedRouteID == route?.id,
                                   completionMoment: completionMoment)
    }
    var surpriseChoice: StopRecommendation? {
        guard !recommendations.isEmpty else { return nil }
        return recommendations[surpriseIndex % recommendations.count]
    }

    private let location = LocationService()
    let search = MapSearchService()
    private let directions = DirectionsService()
    private var discoveryTask: Task<Void, Never>?
    private var budgetDiscoveryTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var journeyTask: Task<Void, Never>?
    private var spontaneousTask: Task<Void, Never>?
    private var routeComparisonTask: Task<Void, Never>?
    private var routeComparisonID = UUID()
    private var verified: [StopRecommendation] = []
    private var verifiedBudget = 0
    private var verifiedMode: DiscoveryMode?
    private var verifiedRouteID: UUID?
    private var verifiedStopIDs = [String]()
    private var discoveryID = UUID()
    private let radar = OpportunityRadarEngine()
    @ObservationIgnored private let liveOpportunity: any LiveActivityProviding

    init(liveOpportunity: any LiveActivityProviding = LiveOpportunityProvider()) {
        self.liveOpportunity = liveOpportunity
    }
    var nextOpportunity: JourneyOpportunity? { opportunities.first }
    var driverOpportunity: DriverOpportunitySnapshot? { DriverOpportunitySnapshot(nextOpportunity) }
    var rouletteCandidates: [StopRecommendation] {
        recommendations.filter { $0.progress + 0.02 >= travelerProgress &&
            $0.detourTime <= Double(rouletteMaximumMinutes * 60) }
            .sorted { $0.id < $1.id }
    }
    var rouletteChoice: StopRecommendation? {
        let candidates = rouletteCandidates
        return candidates.isEmpty ? nil : candidates[rouletteIndex % candidates.count]
    }
    var timeMachinePreviewCount: Int {
        guard let timeMachinePreview else { return recommendations.count }
        let source = verifiedRouteID == route?.id && verifiedStopIDs == selectedStops.map(\.id)
            ? verified : recommendations
        return TimeMachine.filtered(source, minutes: timeMachinePreview)
            .filter { !radar.skippedIDs.contains($0.id) }.count
    }
    var timeMachinePreviewRecommendations: [StopRecommendation] {
        guard let timeMachinePreview else { return [] }
        let source = verifiedRouteID == route?.id && verifiedStopIDs == selectedStops.map(\.id)
            ? verified : recommendations
        return Array(TimeMachine.filtered(source, minutes: timeMachinePreview)
            .filter { !radar.skippedIDs.contains($0.id) }.prefix(6))
    }
    var radarExpiredCount: Int { radar.expiredCount }
    var radarSkippedCount: Int { radar.skippedIDs.count }
    var chapter: JourneyChapter { JourneyChapter.at(progress: travelerProgress) }
    var routeOpportunitySummary: [(String, Int)] {
        guard let discoveryCoverage, let route else { return [] }
        return RouteOpportunitySummary.counts(discoveryCoverage, path: journey?.path ?? route.baseline.path)
    }
    var rhythmState: JourneyRhythmState {
        guard let route else { return .earlyJourney }
        let duration = journey?.drivingDuration ?? route.baseline.duration
        let elapsed = duration * travelerProgress
        let lastStopProgress = selectedStops.map {
            GeoMath.routeProximity($0.coordinate, path: journey?.path ?? route.baseline.path).progress
        }.filter { $0 <= travelerProgress }.max()
        let sinceStop = lastStopProgress.map { max(0, travelerProgress - $0) * duration }
        return JourneyRhythmService.state(elapsed: elapsed,
            remaining: max(0, duration - elapsed),
            timeSinceLastSelectedStop: sinceStop)
    }

    func useCurrentLocationIfAuthorized() async {
        if location.isAuthorized && origin == nil { await useCurrentLocation() }
    }

    func useCurrentLocation() async {
        do {
            let position = try await location.currentLocation()
            let coordinate = Coordinate(position.coordinate)
            origin = Place(id: "current-origin", name: "Current Location", coordinate: coordinate)
            locationMessage = location.hasReducedAccuracy
                ? "Approximate location is on. Choose a starting place for more precise detours."
                : nil
            if destination != nil { calculateRoute(resetBudget: route == nil) }
        } catch { locationMessage = error.localizedDescription }
    }

    func refreshTravelerProgress() async {
        guard location.isAuthorized, let route else { return }
        if let position = try? await location.currentLocation() {
            let coordinate = Coordinate(position.coordinate)
            let projection = GeoMath.routeProgress(coordinate,
                                                   path: journey?.path ?? route.baseline.path)
            guard projection.isOnRoute else {
                if activeJourney { activeMessage = "You may be off the planned route. Recheck the route when safe." }
                isTravelerOnRoute = false
                opportunities = []
                if activeJourney, let content = liveActivityContent {
                    Task { [liveOpportunity] in await liveOpportunity.update(content) }
                }
                return
            }
            if !isTravelerOnRoute { activeMessage = nil }
            isTravelerOnRoute = true
            if activeJourney {
                let now = Date.now
                recentRoutePositions.removeAll { now.timeIntervalSince($0.date) > 30 * 60 }
                if recentRoutePositions.last.map({ GeoMath.distance($0.coordinate, coordinate) > 500 }) ?? true {
                    recentRoutePositions.append((coordinate, now))
                    recentRoutePositions = Array(recentRoutePositions.suffix(5))
                }
            }
            let progress = projection.fraction
            if abs(progress - travelerProgress) > 0.02 {
                travelerProgress = progress
                if activeJourney {
                    let now = Date.now
                    if lastActiveDiscoveryAt.map({ now.timeIntervalSince($0) >= 600 }) ?? true {
                        lastActiveDiscoveryAt = now
                        discover()
                    }
                } else { discover() }
            }
            if activeJourney { clockNow = .now; updateRadar() }
        }
    }

    func startActiveJourney() {
        guard let route, journey != nil else { return }
        completedRouteID = nil
        completionMoment = false
        sessionSavedReturnIDs = []
        activeSkippedCount = 0
        activeJourney = true
        activeMessage = location.isAuthorized ? nil : "Location is off. Apple Maps directions still work; live progress needs location access."
        lastActiveDiscoveryAt = nil
        lastActiveReminderID = nil
        if FeatureFlags.liveActivityOpportunity, let content = liveActivityContent {
            Task { [weak self] in
                guard let self else { return }
                guard activeJourney, self.route?.id == route.id else { return }
                await liveOpportunity.start(routeID: route.id, content: content)
                if activeJourney, self.route?.id == route.id {
                    liveActivityRunning = liveOpportunity.isRunning
                } else { await liveOpportunity.end() }
            }
        }
    }

    func endActiveJourney() {
        activeJourney = false
        activeMessage = nil
        lastActiveDiscoveryAt = nil
        lastActiveReminderID = nil
        radar.reset()
        opportunities = []
        oneMoreStopPresented = false
        sessionViewedCategories = [:]
        recentRoutePositions = []
        whatWasThatResults = []
        whatWasThatBusy = false
        liveActivityRunning = false
        Task { [liveOpportunity] in await liveOpportunity.end() }
    }

    func completeActiveJourney() {
        guard activeJourney, let route, let journey else { return }
        lastRecap = JourneyRecap(destination: route.destination.name,
            selectedStops: journey.stops.map(\.name), routedDistance: journey.drivingDistance,
            routedDriving: journey.drivingDuration, extraDrivingUsed: journey.extraDuration,
            originalAllowance: profileOriginalAllowance, skippedOpportunities: activeSkippedCount,
            savedForReturn: sessionSavedForReturn)
        endActiveJourney()
        completedRouteID = route.id
        completionMoment = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.completedRouteID == route.id else { return }
            self.completionMoment = false
        }
    }

    func noteSavedForReturn(id: String) { sessionSavedReturnIDs.insert(id) }

    func markOpportunitySaved(_ id: String) {
        radar.save(id)
        opportunities = radar.queue
        recommendations.removeAll { $0.id == id }
    }

    func setOrigin(_ place: Place) {
        origin = place
        locationMessage = nil
        if destination != nil { calculateRoute(resetBudget: route == nil) }
    }

    func setDestination(_ place: Place) {
        destination = place
        spontaneousPlan = nil
        if origin != nil { calculateRoute(resetBudget: true) }
    }

    private func cancelWork() {
        routeTask?.cancel()
        discoveryTask?.cancel()
        budgetDiscoveryTask?.cancel()
        journeyTask?.cancel()
        spontaneousTask?.cancel()
        routeComparisonTask?.cancel()
        directions.cancelAll()
        search.cancelAll()
    }

    func calculateRoute(resetBudget: Bool = false) {
        cancelWork()
        endActiveJourney()
        guard let origin, let destination else { return }
        if resetBudget { budgetMinutes = defaultBudgetMinutes }
        journeyBusy = false
        journeyMessage = nil
        route = nil
        routeComparisonCounts = [:]
        routeComparisonSearches = [:]
        routeComparisonBusy = false
        journey = nil
        plannedVisitMinutes = [:]
        openedLegCount = 0
        cameraWasMovedByUser = false
        recommendations = []
        opportunities = []
        radar.reset()
        timeMachinePreview = nil
        rouletteIndex = 0
        rouletteRevealed = false
        combinations = []
        chains = []
        evNearby = [:]
        checkingPlaces = []
        discoveryCoverage = nil
        verified = []
        verifiedRouteID = nil
        phase = .findingRoute
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let options = try await directions.routeOptions(from: origin, to: destination)
                guard let baseline = options.first else { throw DirectionsService.DirectionsError.noRoute }
                try Task.checkCancellation()
                let plan = RoutePlan(id: UUID(), origin: origin, destination: destination,
                                     baseline: baseline, createdAt: .now, options: options)
                route = plan
                selectedRouteIndex = 0
                if case .arriveBy = timeBudget {
                    deadlineOriginalAllowance = allowedExtraDriving
                }
                journey = Journey(stops: [], legs: [baseline], baseline: baseline)
                travelerProgress = 0
                isTravelerOnRoute = true
                if !cameraWasMovedByUser { fitCamera(to: baseline.path) }
                discover()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed("Couldn’t find a driving route. Check the places and try again.")
            }
        }
    }

    func selectBudget(_ minutes: Int) {
        guard !journeyBusy, timeBudget != .spare(minutes: minutes) else { return }
        budgetDiscoveryTask?.cancel()
        budgetMinutes = minutes
        let cacheMatches = verifiedMode == mode && verifiedRouteID == route?.id &&
            verifiedStopIDs == selectedStops.map(\.id)
        if cacheMatches {
            discoveryTask?.cancel()
            recommendations = Array(StopScoringService.withinBudget(verified, minutes: minutes)
                .filter { !radar.skippedIDs.contains($0.id) }
                .prefix(DiscoveryTuning.maxRecommendations))
            phase = recommendations.isEmpty ? .noResults : .loaded
            updateRadar()
        }
        guard !cacheMatches || minutes > verifiedBudget else { return }
        discoveryTask?.cancel()
        directions.cancelAll()
        search.cancelAll()
        let routeID = route?.id
        budgetDiscoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.route?.id == routeID,
                  self.timeBudget == .spare(minutes: minutes) else { return }
            self.discover()
        }
    }

    func selectDeadline(_ deadline: Date) {
        guard !journeyBusy, deadline > clockNow else { return }
        timeBudget = .arriveBy(deadline)
        deadlineOriginalAllowance = allowedExtraDriving
        discover()
    }

    func refreshDeadline(at date: Date) {
        let oldBudget = budgetMinutes
        clockNow = date
        guard case .arriveBy = timeBudget, budgetMinutes != oldBudget else { return }
        if verifiedMode == mode && verifiedRouteID == route?.id && verifiedStopIDs == selectedStops.map(\.id),
           budgetMinutes <= verifiedBudget {
            recommendations = Array(StopScoringService.withinBudget(verified, minutes: budgetMinutes)
                .filter { !radar.skippedIDs.contains($0.id) }
                .prefix(DiscoveryTuning.maxRecommendations))
            phase = recommendations.isEmpty ? .noResults : .loaded
            updateRadar()
        } else { discover() }
    }

    func setPlannedVisit(minutes: Int, for place: Place) {
        guard selectedStops.contains(where: { $0.id == place.id }) else { return }
        plannedVisitMinutes[place.id] = max(0, min(minutes, 240))
        if case .arriveBy = timeBudget { discover() }
    }

    func selectMode(_ value: DiscoveryMode) {
        guard !journeyBusy, mode != value else { return }
        mode = value
        if selectedMission?.mode != value { selectedMission = nil }
        resetRouteComparison()
        surpriseIndex = 0
        showSurpriseAlternatives = false
        discover()
    }

    func selectRouteOption(_ index: Int) {
        guard !journeyBusy, let route, selectedStops.isEmpty, route.options.indices.contains(index) else { return }
        resetRouteComparison()
        let selected = route.options[index]
        self.route = RoutePlan(id: UUID(), origin: route.origin, destination: route.destination,
                               baseline: selected, createdAt: .now, options: route.options)
        if case .arriveBy = timeBudget { deadlineOriginalAllowance = allowedExtraDriving }
        selectedRouteIndex = index
        journey = Journey(stops: [], legs: [selected], baseline: selected)
        travelerProgress = 0
        isTravelerOnRoute = true
        if !cameraWasMovedByUser { fitCamera(to: selected.path) }
        discover()
    }

    private func resetRouteComparison() {
        routeComparisonTask?.cancel()
        routeComparisonID = UUID()
        routeComparisonBusy = false
        routeComparisonCounts = [:]
        routeComparisonSearches = [:]
    }

    func compareAlternateRoutes() {
        guard let route, route.options.count > 1 else { return }
        routeComparisonTask?.cancel()
        let requestID = UUID()
        routeComparisonID = requestID
        routeComparisonBusy = true
        routeComparisonCounts = [:]
        routeComparisonSearches = [:]
        let mode = remixMode
        let needs = Set<JourneyNeed>()
        let budget = budgetMinutes
        routeComparisonTask = Task { [weak self] in
            guard let self else { return }
            for (index, option) in route.options.enumerated() {
                if Task.isCancelled || self.route?.id != route.id || routeComparisonID != requestID { break }
                let samples = PolylineSampling.sample(option.path,
                    spacing: DiscoveryTuning.sampleSpacing(for: option.distance),
                    limit: DiscoveryTuning.maxAlternateSamples)
                let requests = QueryPlanner.plan(samples: samples,
                    radius: DiscoveryTuning.searchRadius(for: budget), mode: mode, mood: mood,
                    needs: needs, isMalaysia: RegionProfile.isMalaysia(route.destination.coordinate),
                    localFirst: localFirst, evJourney: evJourney, adventure: budget >= 60,
                    limit: DiscoveryTuning.maxAlternateSamples)
                var found = [Place]()
                var successful = 0
                for request in requests {
                    if Task.isCancelled { break }
                    do {
                        found += try await search.discover(around: request.center, radius: request.radius,
                                                           category: request.category)
                        successful += 1
                    } catch is CancellationError { break }
                    catch { continue }
                }
                guard !Task.isCancelled, routeComparisonID == requestID else { break }
                routeComparisonSearches[index] = successful
                if successful > 0 {
                    routeComparisonCounts[index] = OpportunityCoverage.nearbyCount(
                        CandidateDeduplication.unique(found), path: option.path,
                        radius: DiscoveryTuning.searchRadius(for: budget))
                }
            }
            if routeComparisonID == requestID { routeComparisonBusy = false }
        }
    }

    func selectMood(_ value: DiscoveryMood) {
        guard !journeyBusy, mood != value else { return }
        mood = value
        resetRouteComparison()
        discover()
    }

    func toggleNeed(_ need: JourneyNeed) {
        guard !journeyBusy else { return }
        if !selectedNeeds.insert(need).inserted { selectedNeeds.remove(need) }
        resetRouteComparison()
        discover()
    }

    func updateSurprise(_ change: (inout SurpriseConstraints) -> Void) {
        guard !journeyBusy else { return }
        change(&surpriseConstraints)
        discover()
    }

    func ignore(_ place: Place) {
        ignoredPlaceIDs.insert(place.id)
        recommendations.removeAll { $0.id == place.id }
    }

    func notInterested(_ place: Place) {
        notInterestedIDs.insert(place.id)
        recommendations.removeAll { $0.id == place.id }
    }

    func clearNotInterested() {
        notInterestedIDs.removeAll()
        discover()
    }

    func selectPreset(_ preset: DiscoveryPreset) {
        guard !journeyBusy else { return }
        mode = preset.mode
        resetRouteComparison()
        budgetMinutes = preset.minutes
        switch preset {
        case .needFuel: selectedNeeds = [.fuel]
        case .needFood: selectedNeeds = [.food]
        case .restStop: selectedNeeds = [.rest]
        case .evBreak: selectedNeeds = [.charging]
        default: selectedNeeds = []
        }
        surpriseIndex = 0
        showSurpriseAlternatives = false
        discover()
    }

    func chooseMission(_ mission: JourneyMission?) {
        selectedMission = mission
        if let mission { mode = mission.mode }
        discover()
    }

    func setAutopilotRule(_ need: JourneyNeed, enabled: Bool) {
        guard let index = autopilotRules.firstIndex(where: { $0.need == need }) else { return }
        autopilotRules[index].enabled = enabled
        discover()
    }

    func skipOpportunity(reason: SmartSkipReason? = nil) {
        guard let nextOpportunity else { return }
        radar.skip(nextOpportunity, reason: reason)
        if activeJourney { activeSkippedCount += 1 }
        opportunities = radar.queue
        if reason == .notInterested { notInterestedIDs.insert(nextOpportunity.id) }
        recommendations.removeAll { $0.id == nextOpportunity.id }
    }

    func showAnotherOpportunity() {
        radar.another()
        opportunities = radar.queue
        oneMoreStopPresented = true
    }

    func showOneMoreStop() {
        guard route != nil else { return }
        oneMoreStopPresented = true
        updateRadar()
        if opportunities.isEmpty && phase != .discoveringPlaces && phase != .calculatingDetours { discover() }
    }

    func findWhatWasThat() {
        guard activeJourney, !whatWasThatBusy,
              let center = (recentRoutePositions.dropLast().last ?? recentRoutePositions.last)?.coordinate else { return }
        whatWasThatBusy = true
        whatWasThatResults = []
        Task { [weak self] in
            guard let self else { return }
            var found = [Place]()
            for category in [StopCategory.food, .attractions, .fuel] {
                if Task.isCancelled || !activeJourney { break }
                if let places = try? await search.discover(around: center, radius: 1_500, category: category) {
                    found += places
                }
            }
            guard activeJourney else { return }
            whatWasThatResults = Array(CandidateDeduplication.unique(found)
                .sorted { GeoMath.distance($0.coordinate, center) < GeoMath.distance($1.coordinate, center) }
                .prefix(6))
            whatWasThatBusy = false
        }
    }

    func rotateRoulette() {
        rouletteIndex += 1
        rouletteRevealed = false
    }

    func previewTimeMachine(_ minutes: Int) {
        timeMachinePreview = minutes
    }

    func refreshOpportunityPolicy() { updateRadar() }

    func noteViewed(_ recommendation: StopRecommendation) {
        guard let category = recommendation.place.category else { return }
        sessionViewedCategories[category, default: 0] += 1
        updateRadar()
    }

    func applyTimeMachine() {
        guard let timeMachinePreview else { return }
        self.timeMachinePreview = nil
        selectBudget(timeMachinePreview)
    }

    private func updateRadar() {
        guard let route, let journey, isTravelerOnRoute else { opportunities = []; return }
        let elapsed = journey.drivingDuration * travelerProgress
        let additionalNeeds = JourneyRhythmService.suggestedNeeds(rules: autopilotRules,
            elapsed: elapsed, remainingBudget: remainingTime)
        let context = OpportunityContext(routeID: route.id, routePath: journey.path,
            routeDuration: journey.drivingDuration, travelerProgress: travelerProgress,
            allowedExtraDriving: allowedExtraDriving, selectedNeeds: selectedNeeds.union(additionalNeeds),
            categoryViews: sessionViewedCategories,
            returnPlaceIDs: Set(returnOpportunities.map { $0.place.place.id }),
            mission: selectedMission, rhythm: rhythmState, chapter: chapter,
            interestingOnly: interestingOnly)
        radar.update(recommendations, context: context)
        opportunities = radar.queue
        if activeJourney, FeatureFlags.liveActivityOpportunity, let content = liveActivityContent {
            Task { [liveOpportunity] in await liveOpportunity.update(content) }
        }
    }

    private var liveActivityContent: JourneyActivityAttributes.ContentState? {
        guard let route else { return nil }
        return JourneyActivityAttributes.ContentState(destination: route.destination.name,
            remainingMinutes: max(0, Int((remainingTime / 60).rounded())),
            opportunityName: nextOpportunity?.place.name,
            opportunityMinutesAhead: nextOpportunity?.approximateMinutesAhead,
            opportunityDetourMinutes: nextOpportunity.map { Int(($0.incrementalDriving / 60).rounded()) },
            updatedAt: .now)
    }

    func discover() {
        budgetDiscoveryTask?.cancel()
        budgetDiscoveryTask = nil
        guard !journeyBusy else { return }
        discoveryTask?.cancel()
        directions.cancelAll()
        search.cancelAll()
        verifiedRouteID = nil
        verified = []
        checkingPlaces = []
        discoveryCoverage = nil
        combinations = []
        chains = []
        evNearby = [:]
        guard let route, let journey, canAddStop else {
            recommendations = []
            opportunities = []
            radar.reset()
            phase = .loaded
            return
        }
        let mode = mode
        let mood = mood
        let budget = budgetMinutes
        let elapsed = journey.drivingDuration * travelerProgress
        let discoveryNeeds = selectedNeeds.union(JourneyRhythmService.suggestedNeeds(
            rules: autopilotRules, elapsed: elapsed, remainingBudget: remainingTime))
        let requestID = UUID()
        discoveryID = requestID
        recommendations = []
        phase = .discoveringPlaces
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let discovery = try await RouteCorridorService(search: search).candidates(
                    for: route, journey: journey, mode: mode, mood: mood, needs: discoveryNeeds,
                    surprise: surpriseConstraints, budgetMinutes: budget,
                    localFirst: localFirst, evJourney: evJourney)
                try Task.checkCancellation()
                guard discoveryID == requestID else { return }
                discoveryCoverage = discovery
                checkingPlaces = Array(discovery.places.prefix(3))
                radar.prepare(routeID: route.id)
                radar.trackDiscovered(discovery.places)
                radar.trackEvaluating(checkingPlaces)
                phase = .calculatingDetours
                let returnPlaces = ReturnTripMatcher.candidates(returnOpportunities, route: route,
                                                                 journey: journey, travelerProgress: travelerProgress)
                let allCandidates = CandidateDeduplication.unique(discovery.places + returnPlaces)
                let ranked = try await DetourEngine(directions: directions).recommendations(
                    for: route, journey: journey, candidates: allCandidates, mode: mode, mood: mood,
                    localFirst: localFirst, evJourney: evJourney, needs: discoveryNeeds,
                    ignoredIDs: ignoredPlaceIDs.union(notInterestedIDs).union(
                        selectedMission == .newPlace ? previouslySelectedPlaceIDs : []),
                    preferenceCounts: preferenceCounts,
                    surprise: surpriseConstraints, travelerProgress: travelerProgress,
                    exploringArea: exploringArea, budgetMinutes: budget) { [weak self] partial in
                        guard let self, discoveryID == requestID else { return }
                        recommendations = Array(partial.filter {
                            !ignoredPlaceIDs.contains($0.id) && !notInterestedIDs.contains($0.id) &&
                            !radar.skippedIDs.contains($0.id)
                        }.prefix(DiscoveryTuning.maxRecommendations))
                        if opportunities.isEmpty { updateRadar() }
                    }
                try Task.checkCancellation()
                guard discoveryID == requestID else { return }
                verified = ranked
                checkingPlaces = []
                verifiedBudget = budget
                verifiedMode = mode
                verifiedRouteID = route.id
                verifiedStopIDs = journey.stops.map(\.id)
                recommendations = Array(StopScoringService.withinBudget(ranked, minutes: budget)
                    .filter { !ignoredPlaceIDs.contains($0.id) && !notInterestedIDs.contains($0.id) &&
                        !radar.skippedIDs.contains($0.id) }
                    .prefix(DiscoveryTuning.maxRecommendations))
                phase = recommendations.isEmpty ? .noResults : .loaded
                updateRadar()
                if activeJourney, let useful = usefulAhead, lastActiveReminderID != useful.id {
                    lastActiveReminderID = useful.id
                    activeMessage = "Optional stop ahead: \(useful.place.name), \(TripFormatting.extraTime(useful.incrementalDetourTime)) added driving."
                }
                if FeatureFlags.stopCombinations && journey.stops.count <= 1 {
                    combinations = try await StopCombinationService(directions: directions).combinations(
                        for: route, journey: journey, verified: recommendations,
                        allowedExtraDriving: allowedExtraDriving)
                }
                if FeatureFlags.journeyChains && journey.stops.count <= 1 {
                    chains = try await JourneyChainEngine(directions: directions).chains(
                        route: route, journey: journey, candidates: recommendations,
                        budget: allowedExtraDriving)
                }
                if mode == .ev {
                    for charging in recommendations.filter({ $0.place.category == .charging })
                        .prefix(DiscoveryTuning.maxEVNearbyCenters) {
                        try Task.checkCancellation()
                        var found = [Place]()
                        for category in [StopCategory.coffee, .food] {
                            if let places = try? await search.discover(around: charging.place.coordinate,
                                                                       radius: 1_000, category: category) {
                                found += places
                            }
                        }
                        guard discoveryID == requestID else { return }
                        evNearby[charging.id] = Array(CandidateDeduplication.unique(found)
                            .filter { $0.id != charging.id &&
                                GeoMath.distance(charging.place.coordinate, $0.coordinate) <= 1_500 }
                            .prefix(DiscoveryTuning.maxEVNearbyPlaces))
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, discoveryID == requestID else { return }
                checkingPlaces = []
                phase = .failed("Couldn’t check stops right now. Check your connection and try again.")
            }
        }
    }

    func addStop(_ recommendation: StopRecommendation) -> Bool {
        guard !journeyBusy, let journey, canAddStop else { return false }
        let index = min(recommendation.insertionIndex, journey.stops.count)
        var legs = journey.legs
        legs.replaceSubrange(index...index, with: [recommendation.firstLeg, recommendation.secondLeg])
        let updated = Journey(stops: JourneyMath.inserted(recommendation.place, into: journey.stops, at: index),
                              legs: legs, baseline: journey.baseline)
        guard updated.extraDuration <= allowedExtraDriving + 1 else {
            journeyMessage = "This stop now exceeds your extra driving time budget. Try a wider budget."
            return false
        }
        self.journey = updated
        radar.accept(recommendation.id)
        opportunities = radar.queue
        openedLegCount = 0
        focusedRecommendationID = recommendation.id
        journeyMessage = nil
        discover()
        return true
    }

    func addCombination(_ combination: StopCombination) -> Bool {
        guard !journeyBusy, let route, let journey,
              route.id == combination.routeID,
              journey.stops.map(\.id) == combination.originalStopIDs,
              combination.journey.stops.count <= DiscoveryTuning.maxStops,
              combination.journey.extraDuration <= allowedExtraDriving + 1 else { return false }
        self.journey = combination.journey
        radar.accept(combination.first.id)
        radar.accept(combination.second.id)
        opportunities = radar.queue
        openedLegCount = 0
        journeyMessage = nil
        discover()
        return true
    }

    func removeStop(at index: Int) {
        guard !journeyBusy, let journey, journey.stops.indices.contains(index) else { return }
        var stops = journey.stops
        stops.remove(at: index)
        rebuildJourney(with: stops)
    }

    func moveStop(from source: Int, to destination: Int) {
        guard !journeyBusy, let journey else { return }
        rebuildJourney(with: JourneyMath.moved(journey.stops, from: source, to: destination))
    }

    func replaceStop(at index: Int, with place: Place) {
        guard !journeyBusy, let journey, journey.stops.indices.contains(index) else { return }
        var stops = journey.stops
        stops[index] = place
        rebuildJourney(with: stops)
    }

    func addRoutedPlace(_ place: Place) {
        guard !journeyBusy, canAddStop, !selectedStops.contains(where: { $0.id == place.id }) else { return }
        rebuildJourney(with: selectedStops + [place])
    }

    private func rebuildJourney(with stops: [Place]) {
        guard let route else { return }
        journeyTask?.cancel()
        discoveryTask?.cancel()
        directions.cancelAll()
        recommendations = []
        journeyBusy = true
        journeyMessage = nil
        journeyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let points = [route.origin] + stops + [route.destination]
                var legs = [RouteMetrics]()
                for index in 0..<(points.count - 1) {
                    try Task.checkCancellation()
                    legs.append(try await directions.route(from: points[index], to: points[index + 1]))
                }
                try Task.checkCancellation()
                let updated = Journey(stops: stops, legs: legs, baseline: route.baseline)
                guard updated.extraDuration <= allowedExtraDriving + 1 ||
                        stops.count < (journey?.stops.count ?? 0) else {
                    journeyMessage = "That order exceeds your time budget. Your previous trip is still here."
                    journeyBusy = false
                    discover()
                    return
                }
                journey = updated
                plannedVisitMinutes = plannedVisitMinutes.filter { key, _ in stops.contains { $0.id == key } }
                openedLegCount = 0
                journeyBusy = false
                discover()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                journeyMessage = "Couldn’t recalculate this trip. Try again when routing is available."
                journeyBusy = false
                phase = .loaded
            }
        }
    }

    func repeatJourney(_ saved: RecentJourney) async {
        let places = saved.places
        guard places.count >= 2 else { return }
        if saved.originWasCurrent {
            do {
                let position = try await location.currentLocation()
                origin = Place(id: "current-origin", name: "Current Location", coordinate: Coordinate(position.coordinate))
            } catch {
                locationMessage = error.localizedDescription
                return
            }
        } else { origin = places[0] }
        destination = places[1]
        budgetMinutes = saved.budgetMinutes
        plannedVisitMinutes = saved.plannedVisits
        cancelWork()
        guard let origin, let destination else { return }
        journeyBusy = false
        journeyMessage = nil
        route = nil
        journey = nil
        recommendations = []
        openedLegCount = 0
        phase = .findingRoute
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let options = try await directions.routeOptions(from: origin, to: destination)
                guard let baseline = options.first else { throw DirectionsService.DirectionsError.noRoute }
                try Task.checkCancellation()
                let plan = RoutePlan(id: UUID(), origin: origin, destination: destination,
                                     baseline: baseline, createdAt: .now, options: options)
                let stops = Array(places.dropFirst(2))
                let points = [origin] + stops + [destination]
                var legs = [RouteMetrics]()
                for index in 0..<(points.count - 1) {
                    try Task.checkCancellation()
                    legs.append(try await directions.route(from: points[index], to: points[index + 1]))
                }
                try Task.checkCancellation()
                route = plan
                selectedRouteIndex = 0
                journey = Journey(stops: stops, legs: legs, baseline: baseline)
                if let journey, journey.extraDuration > Double(budgetMinutes * 60) + 1 {
                    journeyMessage = "Current routes put this journey over its saved time budget."
                }
                fitCamera(to: baseline.path)
                discover()
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed("Couldn’t repeat this journey right now.")
            }
        }
    }

    func fitCamera(to path: [Coordinate]) {
        guard !path.isEmpty else { return }
        let points = path.map { MKMapPoint($0.clLocation) }
        var rect = MKMapRect.null
        for point in points { rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0)) }
        camera = .rect(rect.insetBy(dx: -rect.width * 0.16 - 2_000, dy: -rect.height * 0.16 - 2_000))
        cameraWasMovedByUser = false
    }

    func findSpontaneous(kind: SpontaneousKind, minutes: Int, mode: DiscoveryMode, returnsHome: Bool) {
        guard let origin else {
            spontaneousMessage = "Choose a starting place first."
            return
        }
        spontaneousTask?.cancel()
        spontaneousSuggestions = []
        spontaneousPlan = nil
        spontaneousBusy = true
        spontaneousMessage = nil
        spontaneousTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plans = try await SpontaneousJourneyService(search: search, directions: directions)
                    .suggestions(origin: origin, kind: kind, minutes: minutes,
                                 mode: mode, returnsHome: returnsHome)
                try Task.checkCancellation()
                spontaneousSuggestions = plans
                spontaneousMessage = plans.isEmpty ? "No routed outing fit that drive time. Try another mode or more time." : nil
                spontaneousBusy = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                spontaneousBusy = false
                spontaneousMessage = "Couldn’t search for outings right now. Try again."
            }
        }
    }

    func selectSpontaneous(_ plan: SpontaneousPlan) {
        spontaneousPlan = plan
        spontaneousOpenedLegCount = 0
        fitCamera(to: plan.path)
    }

    @discardableResult
    func openSpontaneousNextLeg() -> Bool {
        guard let plan = spontaneousPlan, spontaneousOpenedLegCount < plan.legs.count else { return false }
        let endpoints = plan.stops + (plan.returnsHome ? [plan.origin] : [])
        guard endpoints.indices.contains(spontaneousOpenedLegCount) else { return false }
        let source = spontaneousOpenedLegCount == 0
            ? (plan.origin.id == "current-origin" ? MKMapItem.forCurrentLocation() : plan.origin.mapItem())
            : MKMapItem.forCurrentLocation()
        let opened = MKMapItem.openMaps(with: [source, endpoints[spontaneousOpenedLegCount].mapItem()],
                                        launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        if opened { spontaneousOpenedLegCount += 1 }
        return opened
    }

    @discardableResult
    func openNextLeg() -> Bool {
        guard let route, let journey, openedLegCount < journey.legs.count else { return false }
        let endpoints = journey.stops + [route.destination]
        let source = openedLegCount == 0
            ? (route.origin.id == "current-origin" ? MKMapItem.forCurrentLocation() : route.origin.mapItem())
            : MKMapItem.forCurrentLocation()
        let opened = MKMapItem.openMaps(with: [source, endpoints[openedLegCount].mapItem()],
                                        launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        if opened { openedLegCount += 1 }
        return opened
    }
}

enum DiscoveryPreset: String, CaseIterable, Identifiable {
    case quickBreak, coffeeRun, explore, adventure, needFuel, needFood, restStop, evBreak
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quickBreak: "Quick Break"
        case .coffeeRun: "Coffee Run"
        case .explore: "Explore"
        case .adventure: "Adventure"
        case .needFuel: "Need Fuel"
        case .needFood: "Need Food"
        case .restStop: "Rest Stop"
        case .evBreak: "EV Break"
        }
    }
    var minutes: Int {
        switch self {
        case .quickBreak: 10
        case .coffeeRun: 15
        case .explore: 30
        case .adventure: 60
        case .needFuel: 10
        case .needFood: 20
        case .restStop: 15
        case .evBreak: 20
        }
    }
    var mode: DiscoveryMode {
        switch self {
        case .quickBreak: .useful
        case .coffeeRun: .coffee
        case .explore: .explore
        case .adventure: .surpriseMe
        case .needFuel, .restStop: .useful
        case .needFood: .eat
        case .evBreak: .ev
        }
    }
}
