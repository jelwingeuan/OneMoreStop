import MapKit
import SwiftData
import SwiftUI
import UIKit

struct HomeView: View {
    @State private var state = AppState()
    @State private var tab = 0
    @State private var savedFocus: SavedSection?
    @State private var showIntro = false
    @AppStorage("pendingJourneyAction") private var pendingJourneyAction = ""
    @Environment(\.modelContext) private var modelContext
    @Query private var preferences: [UserPreferenceRecord]
    @Query private var ignoredPlaces: [IgnoredPlaceRecord]
    @Query private var profiles: [UserProfileRecord]

    var body: some View {
        TabView(selection: $tab) {
            ExploreView(state: state, tab: $tab,
                        distanceUnit: preferences.first?.distanceUnit ?? "automatic",
                        savedFocus: $savedFocus)
                .tabItem { Label("Explore", systemImage: "map.fill") }
                .tag(0)
            SavedView(focusSection: $savedFocus) { place in
                state.setDestination(place)
                tab = 0
            } onRepeat: { journey in
                tab = 0
                Task { await state.repeatJourney(journey) }
            }
            .tabItem { Label("Saved", systemImage: "bookmark.fill") }
            .tag(1)
        }
        .tint(.orange)
        .preferredColorScheme(preferences.first?.appearance == "light" ? .light :
                              preferences.first?.appearance == "dark" ? .dark : nil)
        .sheet(isPresented: $showIntro) {
            IntroductionView {
                preferences.first?.hasSeenIntroduction = true
                showIntro = false
            }
            .presentationDetents([.medium])
        }
        .task {
            let preference: UserPreferenceRecord
            if let existing = preferences.first { preference = existing }
            else {
                let defaults = UserDefaults.standard
                preference = UserPreferenceRecord(
                    distanceUnit: defaults.string(forKey: "distanceUnit") ?? "automatic",
                    defaultBudgetMinutes: defaults.object(forKey: "defaultBudget") as? Int ?? 20,
                    localFirst: defaults.bool(forKey: "localFirst"),
                    evJourney: defaults.bool(forKey: "evJourney"),
                    appearance: defaults.string(forKey: "appearance") ?? "system",
                    hasSeenIntroduction: defaults.bool(forKey: "hasSeenIntroduction"))
                modelContext.insert(preference)
            }
            if profiles.isEmpty {
                modelContext.insert(UserProfileRecord())
                try? modelContext.save()
            }
            state.budgetMinutes = preference.defaultBudgetMinutes
            state.defaultBudgetMinutes = preference.defaultBudgetMinutes
            state.localFirst = preference.localFirst
            state.evJourney = preference.evJourney
            state.preferenceCounts = preference.selectedCategoryCounts
            state.ignoredPlaceIDs = Set(ignoredPlaces.map(\.id))
            await state.useCurrentLocationIfAuthorized()
            showIntro = !preference.hasSeenIntroduction
            handleIntentNavigation()
        }
        .onChange(of: pendingJourneyAction) { _, _ in handleIntentNavigation() }
        .onChange(of: preferences.first?.localFirst) { _, value in state.localFirst = value ?? false; state.discover() }
        .onChange(of: preferences.first?.evJourney) { _, value in state.evJourney = value ?? false; state.discover() }
        .onChange(of: preferences.first?.defaultBudgetMinutes) { _, value in state.defaultBudgetMinutes = value ?? 20 }
        .onChange(of: preferences.first?.selectedCategoryCountsData) { _, _ in
            state.preferenceCounts = preferences.first?.selectedCategoryCounts ?? [:]
            state.discover()
        }
        .onChange(of: ignoredPlaces.map(\.id)) { _, values in
            state.ignoredPlaceIDs = Set(values)
            state.discover()
        }
    }

    private func handleIntentNavigation() {
        guard !pendingJourneyAction.isEmpty else { return }
        let action = pendingJourneyAction
        pendingJourneyAction = ""
        if action == "saved" { tab = 1 }
        else if let mode = DiscoveryMode(rawValue: action) {
            tab = 0
            state.selectMode(mode)
        }
    }
}

private enum ProfileAction {
    case saved(SavedSection), settings(Bool), repeatJourney(RecentJourney), viewJourney
}

private struct ExploreView: View {
    @Bindable var state: AppState
    @Binding var tab: Int
    let distanceUnit: String
    @State private var searchTarget: SearchTarget?
    @State private var detail: StopRecommendation?
    @State private var showJourney = false
    @State private var showSettings = false
    @State private var showProfile = false
    @State private var profileStartsInEditor = false
    @State private var pendingProfileAction: ProfileAction?
    @State private var settingsFocusTravel = false
    @State private var recordingSession = JourneyRecordSession()
    @State private var journeySaveFailed = false
    @State private var showSummary = false
    @State private var showSpontaneous = false
    @State private var showGroup = false
    @State private var reopenJourneyAfterGroup = false
    @State private var showActive = false
    @State private var spontaneousInitialKind: SpontaneousKind = .driveUntil
    @State private var handoffFailed = false
    @State private var replacingIndex: Int?
    @State private var detent: PresentationDetent = .medium
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Query private var preferences: [UserPreferenceRecord]
    @Query private var profiles: [UserProfileRecord]
    @Query(sort: \RecentJourney.createdAt, order: .reverse) private var recentJourneys: [RecentJourney]
    @Binding var savedFocus: SavedSection?

    var body: some View {
        ZStack(alignment: .top) {
            routeMap
            VStack(spacing: 12) {
                header
                if state.route != nil { destinationPill }
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        state.exploringArea = false
                        state.fitCamera(to: state.journey?.path ?? state.route?.baseline.path ?? [])
                    } label: { Image(systemName: "scope").font(.title3).frame(width: 48, height: 48) }
                        .floatingControl()
                        .accessibilityLabel("Recenter route")
                }
                if state.route == nil {
                    if state.spontaneousPlan != nil { spontaneousActiveCard }
                    else { startCard }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .sheet(item: $searchTarget, onDismiss: { if state.route != nil && tab == 0 { showJourney = true } }) { target in
            PlaceSearchView(target: target, search: state.search,
                            near: state.origin?.coordinate ?? state.destination?.coordinate) { place in
                if target == .origin { state.setOrigin(place) }
                else if target == .destination { state.setDestination(place) }
                else if let index = replacingIndex { state.replaceStop(at: index, with: place); replacingIndex = nil }
                modelContext.insert(RecentPlace(place, kind: target == .replacement ? "stop" : target.rawValue))
            } onCurrentLocation: {
                Task { await state.useCurrentLocation() }
            }
        }
        .sheet(item: $detail, onDismiss: { if state.route != nil && tab == 0 { showJourney = true } }) { recommendation in
            PlaceDetailView(recommendation: recommendation,
                            distanceUnit: distanceUnit,
                            isSelected: state.selectedStops.contains(where: { $0.id == recommendation.id }),
                            canAdd: state.canAddStop) {
                if state.addStop(recommendation) {
                    modelContext.insert(RecentPlace(recommendation.place, kind: "stop"))
                    preferences.first?.recordSelection(recommendation.place.category)
                    detail = nil
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { if state.route != nil && tab == 0 { showJourney = true } }) {
            SettingsView(onResetNotInterested: { state.clearNotInterested() },
                         focusTravelPreferences: settingsFocusTravel)
        }
        .sheet(isPresented: $showProfile, onDismiss: finishProfilePresentation) {
            if let profile = profiles.first {
                ProfileHubView(profile: profile, state: state, startInEditor: profileStartsInEditor,
                               onSaved: { queueProfileAction(.saved($0)) },
                               onSettings: { queueProfileAction(.settings($0)) },
                               onRepeat: { queueProfileAction(.repeatJourney($0)) },
                               onViewJourney: { queueProfileAction(.viewJourney) })
            }
        }
        .sheet(isPresented: $showSummary) {
            if let route = state.route, let journey = state.journey {
                JourneySummaryView(route: route, journey: journey, budget: state.budgetMinutes) { save in
                    if recordJourney(route: route, journey: journey, saved: save) { showSummary = false }
                }
            }
        }
        .sheet(isPresented: $showSpontaneous) {
            SpontaneousPlannerView(state: state, initialKind: spontaneousInitialKind, chooseOrigin: {
                showSpontaneous = false
                searchTarget = .origin
            }, openMaps: { handoffFailed = !state.openSpontaneousNextLeg() })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showGroup, onDismiss: {
            if reopenJourneyAfterGroup { showJourney = true; reopenJourneyAfterGroup = false }
        }) {
            LocalGroupView(recommendations: state.recommendations,
                           origin: state.route?.origin, destination: state.route?.destination) { name in
                let group = LocalGroupRecord(name: name)
                modelContext.insert(group)
            } usePreference: { mode in
                state.selectMode(mode)
                reopenJourneyAfterGroup = state.route != nil
                showGroup = false
            }
        }
        .sheet(isPresented: $showActive) {
            ActiveJourneyView(state: state, openMaps: { handoffFailed = !state.openNextLeg() },
                              onComplete: completeJourney)
        }
        .sheet(isPresented: $showJourney) { journeySheet }
        .alert("Couldn’t open Apple Maps", isPresented: $handoffFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Try again in a moment.") }
        .alert("Couldn’t save journey", isPresented: $journeySaveFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Try completing the journey again.") }
        .onChange(of: state.route?.id) { _, routeID in
            showJourney = routeID != nil && tab == 0
        }
        .onChange(of: tab) { _, value in showJourney = value == 0 && state.route != nil }
        .onChange(of: state.camera.positionedByUser) { _, moved in
            if moved { state.cameraWasMovedByUser = true; state.exploringArea = true }
        }
        .onChange(of: state.focusedRecommendationID) { _, id in
            guard let id, let recommendation = state.recommendations.first(where: { $0.id == id }) else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                state.camera = .region(MKCoordinateRegion(center: recommendation.place.coordinate.clLocation,
                                                          latitudinalMeters: 10_000, longitudinalMeters: 10_000))
            }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await state.refreshTravelerProgress() } }
        }
    }

    private var routeMap: some View {
        Map(position: $state.camera) {
            if let route = state.route {
                if state.showDensity, let coverage = state.discoveryCoverage {
                    ForEach(Array(coverage.successfulCenters.enumerated()), id: \.offset) { item in
                        let center = item.element
                        let count = OpportunityCoverage.density(at: center, places: coverage.places)
                        MapCircle(center: center.clLocation, radius: 3_000)
                            .foregroundStyle(.orange.opacity(count == 0 ? 0.08 : min(0.3, Double(count) * 0.04 + 0.1)))
                    }
                }
                MapPolyline(coordinates: route.baseline.path.map(\.clLocation))
                    .stroke(.blue.opacity(state.selectedStops.isEmpty ? 0.9 : 0.35), lineWidth: 4)
                if let journey = state.journey, !journey.stops.isEmpty {
                    ForEach(journey.legs.indices, id: \.self) { index in
                        MapPolyline(coordinates: journey.legs[index].path.map(\.clLocation))
                            .stroke(.orange, lineWidth: 5)
                    }
                }
                Marker("Start", systemImage: "circle.fill", coordinate: route.origin.coordinate.clLocation)
                    .tint(.blue)
                Marker("Destination", systemImage: "flag.checkered", coordinate: route.destination.coordinate.clLocation)
                    .tint(.blue)
                ForEach(Array(state.selectedStops.enumerated()), id: \.element.id) { index, stop in
                    Marker("\(index + 1). \(stop.name)", systemImage: stop.category?.symbol ?? "mappin",
                           coordinate: stop.coordinate.clLocation).tint(.orange)
                }
                ForEach(state.recommendations) { recommendation in
                    Annotation(recommendation.place.name, coordinate: recommendation.place.coordinate.clLocation) {
                        Button { state.focusedRecommendationID = recommendation.id } label: {
                            Image(systemName: recommendation.place.category?.symbol ?? "mappin")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(state.focusedRecommendationID == recommendation.id ? Color.orange : Color.indigo, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                        .accessibilityLabel("\(recommendation.place.name), \(TripFormatting.extraTime(recommendation.detourTime)) driving")
                    }
                }
            }
            if let plan = state.spontaneousPlan, state.route == nil {
                MapPolyline(coordinates: plan.path.map(\.clLocation))
                    .stroke(.orange, lineWidth: 5)
                Marker("Outing", systemImage: plan.place.category?.symbol ?? "mappin",
                       coordinate: plan.place.coordinate.clLocation).tint(.orange)
                if let second = plan.secondPlace {
                    Marker("Second stop", systemImage: second.category?.symbol ?? "mappin",
                           coordinate: second.coordinate.clLocation).tint(.orange)
                }
                Marker("Start", systemImage: "circle.fill", coordinate: plan.origin.coordinate.clLocation)
                    .tint(.blue)
            }
            if state.origin?.id == "current-origin" { UserAnnotation() }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.headline.weight(.bold))
                .foregroundStyle(.orange)
            Text("OneMoreStop").font(.headline.weight(.bold))
            Spacer()
            Button { showJourney = false; searchTarget = .origin } label: {
                Image(systemName: "location.circle").font(.title3).frame(width: 30, height: 30)
            }
            .accessibilityLabel("Choose starting place")
            profileControl
            if FeatureFlags.groupMode {
                Button { showJourney = false; showGroup = true } label: {
                    Image(systemName: "person.2.fill").font(.title3).frame(width: 30, height: 30)
                }
                .accessibilityLabel("Local group")
            }
            Button { showJourney = false; tab = 1 } label: {
                Image(systemName: "bookmark").font(.title3).frame(width: 30, height: 30)
            }
            .accessibilityLabel("Saved")
        }
        .floatingControl()
    }

    private var profileControl: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let avatarState = state.profileAvatarState
            let remaining = state.profileRemainingTime(at: context.date)
            Button { presentProfile() } label: {
                ProfileAvatarView(profile: profiles.first, state: avatarState,
                                  remaining: remaining, original: state.profileOriginalAllowance,
                                  badgeSymbol: profileBadge(for: avatarState))
            }
            .buttonStyle(ProfilePressStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(profileAccessibilityLabel(remaining: remaining, state: avatarState))
            .contextMenu {
                Button("Edit profile", systemImage: "person.crop.circle") { presentProfile(edit: true) }
                Button("Saved places", systemImage: "bookmark") { queueProfileAction(.saved(.places)) }
                Button("Recent journeys", systemImage: "clock.arrow.circlepath") { queueProfileAction(.saved(.journeys)) }
                Button("Collections", systemImage: "square.stack") { queueProfileAction(.saved(.collections)) }
                if state.route != nil {
                    Button("View journey", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                        queueProfileAction(.viewJourney)
                    }
                }
                if let latest = recentJourneys.first {
                    Button("Repeat journey", systemImage: "arrow.clockwise") {
                        queueProfileAction(.repeatJourney(latest))
                    }
                }
                Button("Travel preferences", systemImage: "slider.horizontal.3") { queueProfileAction(.settings(true)) }
                Button("Settings", systemImage: "gearshape") { queueProfileAction(.settings(false)) }
            }
        }
    }

    private func profileBadge(for avatarState: ProfileAvatarState) -> String? {
        switch avatarState {
        case .idle: nil
        case .planning, .journeyActive: "map.fill"
        case .discovering: state.mode.symbol
        case .stopSelected: state.selectedStops.last?.category?.symbol ?? "mappin"
        case .journeyCompleted: "checkmark"
        }
    }

    private func profileAccessibilityLabel(remaining: TimeInterval, state avatarState: ProfileAvatarState) -> String {
        let name = profiles.first.flatMap { $0.displayName.isEmpty ? nil : $0.displayName } ?? "your profile"
        guard avatarState != .idle else { return "Profile, \(name)" }
        let activity: String
        switch avatarState {
        case .discovering: activity = "Finding \(state.mode.title.lowercased()) stops."
        case .journeyActive: activity = "Journey active."
        case .stopSelected: activity = "Stop selected."
        case .journeyCompleted: activity = "Journey completed."
        case .planning: activity = "Planning journey."
        case .idle: activity = ""
        }
        return "Profile, \(name). \(TripFormatting.duration(remaining)) Adventure Time remaining. \(activity)"
    }

    private func presentProfile(edit: Bool = false) {
        showJourney = false
        profileStartsInEditor = edit
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showProfile = true
    }

    private func queueProfileAction(_ action: ProfileAction) {
        if showProfile {
            pendingProfileAction = action
            showProfile = false
        } else { performProfileAction(action) }
    }

    private func finishProfilePresentation() {
        if let action = pendingProfileAction {
            pendingProfileAction = nil
            performProfileAction(action)
        } else if state.route != nil && tab == 0 {
            showJourney = true
        }
    }

    private func performProfileAction(_ action: ProfileAction) {
        switch action {
        case .saved(let section):
            savedFocus = section
            tab = 1
        case .settings(let travel):
            showJourney = false
            settingsFocusTravel = travel
            showSettings = true
        case .repeatJourney(let journey):
            tab = 0
            Task { await state.repeatJourney(journey) }
        case .viewJourney:
            if state.activeJourney { showActive = true }
            else { showJourney = true }
        }
    }

    private func recordJourney(route: RoutePlan, journey: Journey, saved: Bool) -> Bool {
        do {
            _ = try recordingSession.record(route: route, journey: journey,
                                            budgetMinutes: state.budgetMinutes,
                                            plannedVisits: state.plannedVisitMinutes,
                                            saved: saved, in: modelContext)
            return true
        } catch {
            journeySaveFailed = true
            return false
        }
    }

    private func completeJourney() -> Bool {
        guard state.activeJourney, let route = state.route, let journey = state.journey,
              recordJourney(route: route, journey: journey, saved: false) else { return false }
        state.completeActiveJourney()
        return true
    }

    private var destinationPill: some View {
        Button { showJourney = false; searchTarget = .destination } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                Text(state.destination?.name ?? "Where to?").lineLimit(1)
                Spacer()
                Image(systemName: "square.and.pencil")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .destinationSurface()
        .accessibilityLabel("Destination, \(state.destination?.name ?? "choose a place")")
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A little time. A better drive.").font(.title2.bold())
            Text("Choose where you're going, then find stops that fit your extra driving time.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let message = state.locationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let message) = state.phase {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Try route again") { state.calculateRoute() }
            }
            if state.origin == nil {
                Button("Choose starting place", systemImage: "location") { searchTarget = .origin }
                    .buttonStyle(.bordered)
            }
            Button { searchTarget = .destination } label: {
                Label(state.destination?.name ?? "Where are you going?", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            if FeatureFlags.spontaneousJourneys {
                HStack {
                    Button("Drive Until", systemImage: "steeringwheel") {
                        spontaneousInitialKind = .driveUntil
                        showSpontaneous = true
                    }
                    Spacer()
                    Button("Escape Mode", systemImage: "arrow.uturn.backward") {
                        spontaneousInitialKind = .escape
                        showSpontaneous = true
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
    }

    private var spontaneousActiveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = state.spontaneousPlan {
                Text(plan.stops.map(\.name).joined(separator: " → ")).font(.headline)
                Text("\(TripFormatting.duration(plan.drivingDuration)) routed driving · \(plan.returnsHome ? "round trip" : "one way")")
                    .font(.caption).foregroundStyle(.secondary)
                Button(state.spontaneousOpenedLegCount == 0 ? "Open in Apple Maps" : "Continue to next leg") {
                    handoffFailed = !state.openSpontaneousNextLeg()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(state.spontaneousOpenedLegCount >= plan.legs.count)
                Button("Change outing") { showSpontaneous = true }
                    .font(.caption)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var journeySheet: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            JourneySheetView(state: state, distanceUnit: distanceUnit,
                             onDetail: { showJourney = false; detail = $0 },
                             onAdd: { recommendation in
                                 if state.addStop(recommendation) {
                                     modelContext.insert(RecentPlace(recommendation.place, kind: "stop"))
                                     preferences.first?.recordSelection(recommendation.place.category)
                                 }
                             },
                             onAddCombo: { combination in
                                 if state.addCombination(combination) {
                                     modelContext.insert(RecentPlace(combination.first, kind: "stop"))
                                     modelContext.insert(RecentPlace(combination.second, kind: "stop"))
                                     preferences.first?.recordSelection(combination.first.category)
                                     preferences.first?.recordSelection(combination.second.category)
                                 }
                             },
                             onReplace: { index in
                                 replacingIndex = index
                                 showJourney = false
                                 searchTarget = .replacement
                             },
                             onMaps: { handoffFailed = !state.openNextLeg() },
                             onSummary: { showJourney = false; showSummary = true },
                             onActive: { showJourney = false; state.startActiveJourney(); showActive = true })
                .onChange(of: context.date, initial: true) { _, date in state.refreshDeadline(at: date) }
        }
        .presentationDetents([.height(220), .medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
    }
}

private struct JourneySheetView: View {
    @Bindable var state: AppState
    @Environment(\.modelContext) private var modelContext
    let distanceUnit: String
    let onDetail: (StopRecommendation) -> Void
    let onAdd: (StopRecommendation) -> Void
    let onAddCombo: (StopCombination) -> Void
    let onReplace: (Int) -> Void
    let onMaps: () -> Void
    let onSummary: () -> Void
    let onActive: () -> Void
    @State private var arrivalDraft = Date.now.addingTimeInterval(2 * 3_600)
    @State private var showingArrivalPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeader
                if let message = state.journeyMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if state.journeyBusy { ProgressView("Recalculating trip…") }
                if let route = state.route, route.options.count > 1, state.selectedStops.isEmpty {
                    routeOptions(route)
                }
                if FeatureFlags.searchDensity, let coverage = state.discoveryCoverage, coverage.successfulSearches > 0 {
                    Toggle("Show found-place density", isOn: $state.showDensity)
                        .font(.subheadline)
                    Text("Circles show places returned by successful searches for this mode. Other areas may have places too.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !state.selectedStops.isEmpty { timeline.disabled(state.journeyBusy) }
                budgetControls.disabled(state.journeyBusy)
                modeControls.disabled(state.journeyBusy)
                if FeatureFlags.journeyNeeds { needControls.disabled(state.journeyBusy) }
                if state.mode == .surpriseMe { surpriseControls }
                if [.useful, .restStop, .ev].contains(state.mode), let useful = state.usefulAhead {
                    usefulAheadCard(useful)
                }
                if state.fewPlacesAhead {
                    Label("Few matching places found in the searched corridor ahead.", systemImage: "binoculars")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let comparison = state.betterAhead { aheadComparison(comparison) }
                if state.canAddStop && !state.journeyBusy { recommendations }
                if !state.combinations.isEmpty && !state.journeyBusy { combinationCards }
                if !state.selectedStops.isEmpty { journeyActions }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 32)
        }
        .sensoryFeedback(.selection, trigger: state.budgetMinutes)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            if !state.selectedStops.isEmpty {
                Button(action: onMaps) {
                    Label(state.openedLegCount == 0 ? "Open in Apple Maps" : "Continue to next stop",
                          systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(state.openedLegCount >= (state.journey?.legs.count ?? 0))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Find your one more stop").font(.title2.bold())
            if let route = state.route, let journey = state.journey {
                Text("\(route.origin.name) → \(route.destination.name)")
                    .font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { journeyMetrics(journey) }
                    VStack(alignment: .leading, spacing: 4) { journeyMetrics(journey) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.timeBudget.deadline == nil ? "Extra driving left" : "Arrival margin")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(TripFormatting.duration(state.remainingTime)).font(.title.bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Driving arrival").font(.caption).foregroundStyle(.secondary)
                        if let arrival = state.drivingArrival { Text(TripFormatting.arrival(arrival)).font(.subheadline.bold()) }
                    }
                }
                .padding(14)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
                if state.plannedVisitSeconds > 0, let arrival = state.plannedArrival {
                    Text("With planned visits: \(TripFormatting.arrival(arrival))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func journeyMetrics(_ journey: Journey) -> some View {
        Label(TripFormatting.duration(journey.drivingDuration), systemImage: "car.fill")
        Label(TripFormatting.extraTime(journey.extraDuration), systemImage: "plus.circle")
        Label(TripFormatting.arrival(JourneyMath.arrival(after: journey.legs, startingAt: .now)),
              systemImage: "clock")
    }

    private func routeOptions(_ route: RoutePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Driving routes").font(.headline)
            ForEach(route.options.indices, id: \.self) { index in
                let option = route.options[index]
                Button {
                    state.selectRouteOption(index)
                } label: {
                    HStack {
                        Text(index == 0 ? "Fastest" : "Alternate \(index)")
                        Spacer()
                        Text(TripFormatting.duration(option.duration))
                        if let count = state.routeComparisonCounts[index] {
                            Text("\(count) found nearby")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if let successful = state.routeComparisonSearches[index], successful == 0 {
                            Text("Search unavailable")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if state.selectedRouteIndex == index { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .buttonStyle(.bordered)
                .tint(state.selectedRouteIndex == index ? .orange : .secondary)
            }
            if FeatureFlags.alternateRouteComparison {
                Button("Compare places found on these routes") { state.compareAlternateRoutes() }
                    .font(.caption.weight(.semibold))
                    .disabled(state.routeComparisonBusy)
            }
            if state.routeComparisonBusy { ProgressView("Searching each route…") }
            if !state.routeComparisonSearches.isEmpty {
                Text("Counts use up to four successful corridor searches per route for the current mode. They are not a rating or a complete inventory.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var budgetControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                Button("I can spare") {
                    showingArrivalPicker = false
                    state.selectBudget(state.defaultBudgetMinutes)
                }
                .font(.headline)
                .buttonStyle(.bordered)
                .tint(state.timeBudget.deadline == nil ? .orange : .secondary)
                Button("Arrive By") {
                    showingArrivalPicker = true
                    arrivalDraft = state.timeBudget.deadline ?? Date.now.addingTimeInterval(2 * 3_600)
                }
                .font(.headline)
                .buttonStyle(.bordered)
                .tint(state.timeBudget.deadline == nil ? .secondary : .orange)
                }
                Text("\(state.budgetMinutes) min extra driving available")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            }
            if showingArrivalPicker || state.timeBudget.deadline != nil {
                DatePicker("I need to arrive by", selection: $arrivalDraft,
                           in: Date.now...Date.now.addingTimeInterval(7 * 86_400),
                           displayedComponents: [.date, .hourAndMinute])
                Button("Use arrival time") { state.selectDeadline(arrivalDraft) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                Text("Only visits you plan count toward this deadline. Suggested visits are separate.")
                    .font(.caption).foregroundStyle(.secondary)
                if let deadline = state.timeBudget.deadline, let baseline = state.route?.baseline.duration,
                   deadline.timeIntervalSince(state.clockNow) < baseline + state.plannedVisitSeconds {
                    Label("The direct drive and planned visits exceed this arrival time.",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(DiscoveryTuning.budgets, id: \.self) { minutes in
                            Button("\(minutes) min") { state.selectBudget(minutes) }
                                .buttonStyle(.bordered)
                                .tint(state.budgetMinutes == minutes ? .orange : .primary)
                                .accessibilityAddTraits(state.budgetMinutes == minutes ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(DiscoveryPreset.allCases) { preset in
                            Button("\(preset.title) · \(preset.minutes)m") { state.selectPreset(preset) }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(state.budgetMinutes == preset.minutes && state.mode == preset.mode ? .orange : .secondary)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var modeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What sounds good?").font(.headline)
                Spacer()
                Menu {
                    ForEach(DiscoveryMood.allCases) { mood in
                        Button(mood.title) { state.selectMood(mood) }
                    }
                } label: { Label(state.mood.title, systemImage: "slider.horizontal.3").font(.caption) }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(DiscoveryMode.allCases) { mode in
                        Button { state.selectMode(mode) } label: {
                            Label(mode.title, systemImage: mode.symbol)
                        }
                        .buttonStyle(.bordered)
                        .tint(state.mode == mode ? .orange : .primary)
                        .accessibilityAddTraits(state.mode == mode ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            if state.mode == .zeroRegret {
                Text("Zero Regret shows routed stops within about 1 km of the route and 5 minutes extra driving. It does not rate the place.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var needControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Need something specific?").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(JourneyNeed.allCases) { need in
                        Button { state.toggleNeed(need) } label: {
                            Label(need.title, systemImage: need.symbol)
                        }
                        .buttonStyle(.bordered)
                        .tint(state.selectedNeeds.contains(need) ? .orange : .secondary)
                        .accessibilityAddTraits(state.selectedNeeds.contains(need) ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var surpriseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button("Use full time budget") { state.updateSurprise { $0.maxExtraMinutes = nil } }
                Button("Under 10 min") { state.updateSurprise { $0.maxExtraMinutes = 10 } }
                Button("Under 20 min") { state.updateSurprise { $0.maxExtraMinutes = 20 } }
            } label: {
                Label(state.surpriseConstraints.maxExtraMinutes.map { "Under \($0) min" } ?? "Any fitting detour",
                      systemImage: "timer")
            }
            VStack(alignment: .leading) {
            Toggle("Only ahead", isOn: Binding(
                get: { state.surpriseConstraints.onlyAhead },
                set: { value in state.updateSurprise { $0.onlyAhead = value } }))
            Toggle("No food", isOn: Binding(
                get: { state.surpriseConstraints.noFood },
                set: { value in state.updateSurprise { $0.noFood = value } }))
            }
        }
        .font(.caption)
    }

    private func usefulAheadCard(_ recommendation: StopRecommendation) -> some View {
        let remainingMeters = max(0, (recommendation.progress - state.travelerProgress) * (state.route?.baseline.distance ?? 0))
        return HStack {
            Image(systemName: "car.side.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text("Useful stop ahead").font(.subheadline.bold())
                Text("\(recommendation.place.name) · about \(TripFormatting.distance(remainingMeters, preference: distanceUnit)) along the route")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(TripFormatting.extraTime(recommendation.incrementalDetourTime)).font(.caption.bold())
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
    }

    private func aheadComparison(_ comparison: AheadComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Better option ahead", systemImage: "arrow.forward.circle.fill")
                .font(.headline)
            Text("\(comparison.nearby.place.name): \(TripFormatting.extraTime(comparison.nearby.incrementalDetourTime)). \(comparison.later.place.name): \(TripFormatting.extraTime(comparison.later.incrementalDetourTime)).")
                .font(.subheadline)
            Text("Waiting for the later stop saves about \(Int((comparison.savings / 60).rounded())) minutes of driving detour.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Show later stop") { state.focusedRecommendationID = comparison.later.id }
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
    }

    @ViewBuilder
    private var recommendations: some View {
        if state.mode == .surpriseMe, let featured = state.surpriseChoice {
            VStack(alignment: .leading, spacing: 10) {
                Text("A stop for you").font(.headline)
                recommendationCard(featured)
                HStack {
                    Button("Surprise Again", systemImage: "shuffle") {
                        state.surpriseIndex += 1
                        state.focusedRecommendationID = state.surpriseChoice?.id
                    }
                    .disabled(state.recommendations.count < 2)
                    Spacer()
                    Button(state.showSurpriseAlternatives ? "Hide others" : "Show others") {
                        state.showSurpriseAlternatives.toggle()
                    }
                }
                .font(.subheadline)
                if state.showSurpriseAlternatives {
                    ForEach(state.recommendations.filter { $0.id != featured.id }) { recommendation in
                        recommendationCard(recommendation)
                    }
                }
            }
        } else {
            if !state.recommendations.isEmpty { Text("Along your route").font(.headline) }
            ForEach(state.recommendations) { recommendation in recommendationCard(recommendation) }
        }
        switch state.phase {
        case .discoveringPlaces: ProgressView("Finding stops…").frame(maxWidth: .infinity)
        case .calculatingDetours:
            if state.recommendations.isEmpty {
                ForEach(state.checkingPlaces, id: \.id) { place in
                    HStack {
                        Image(systemName: place.category?.symbol ?? "mappin")
                        Text(place.name).lineLimit(1)
                        Spacer()
                        ProgressView()
                    }
                    .font(.subheadline)
                    .accessibilityLabel("Checking driving time for \(place.name)")
                }
            }
            ProgressView("Checking driving times…").frame(maxWidth: .infinity)
        case .noResults:
            ContentUnavailableView("Keep driving",
                                   systemImage: "map",
                                   description: Text("No verified stops fit your \(state.budgetMinutes)-minute driving budget. Try more time or another kind of stop."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "wifi.exclamationmark")
            } description: { Text(message) } actions: {
                Button("Retry") { state.discover() }.buttonStyle(.borderedProminent)
            }
        default: EmptyView()
        }
    }

    private var combinationCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Two places, one route change").font(.headline)
            ForEach(state.combinations) { combination in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(combination.first.name) + \(combination.second.name)").font(.subheadline.bold())
                    Text("Two locations · \(TripFormatting.extraTime(combination.incrementalDetour)) added driving")
                        .font(.caption)
                    Text("\(combination.first.name): \(JourneyNeed.verified(for: combination.first.category).map(\.title).sorted().joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(combination.second.name): \(JourneyNeed.verified(for: combination.second.category).map(\.title).sorted().joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Add both stops") { onAddCombo(combination) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
            }
        }
    }

    private func recommendationCard(_ recommendation: StopRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: recommendation.place.category?.symbol ?? "mappin")
                    .font(.title3).foregroundStyle(.orange).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.place.name).font(.headline)
                    Text(recommendation.place.category?.title ?? "Stop")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(TripFormatting.extraTime(recommendation.incrementalDetourTime))
                    .font(.headline).foregroundStyle(.orange)
            }
            Text("Adds to this journey · \(TripFormatting.extraTime(recommendation.detourTime)) total versus direct")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(TripFormatting.duration(max(0, state.allowedExtraDriving - recommendation.detourTime))) driving budget left if added")
                .font(.caption2).foregroundStyle(.secondary)
            Text(OpportunityAssessment.detourLabel(recommendation.incrementalDetourTime))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(recommendation.reasons.first?.text ?? RecommendationCopyService.phrase(for: recommendation))
                .font(.caption).foregroundStyle(.secondary)
            if !recommendation.needs.isEmpty {
                Text(recommendation.needs.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if state.mode == .ev, let nearby = state.evNearby[recommendation.id], !nearby.isEmpty {
                Text("Nearby from MapKit search: \(nearby.map(\.name).joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Separate places; added driving time to them has not been checked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(TripFormatting.distance(recommendation.detourDistance, preference: distanceUnit)) extra")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Details") { onDetail(recommendation) }
                Button("Add stop") { onAdd(recommendation) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                Menu {
                    Button("Not interested") { state.notInterested(recommendation.place) }
                    Button("Don't suggest this place again") {
                        state.ignore(recommendation.place)
                        modelContext.insert(IgnoredPlaceRecord(recommendation.place))
                    }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More actions for \(recommendation.place.name)")
            }
            .font(.caption.weight(.semibold))
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { state.focusedRecommendationID = recommendation.id }
        .accessibilityElement(children: .contain)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your journey · \(state.selectedStops.count)/3 stops").font(.headline)
            if let route = state.route {
                timelineRow(route.origin.name, symbol: "circle.fill", subtitle: "Start")
                ForEach(Array(state.selectedStops.enumerated()), id: \.element.id) { index, stop in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(stop.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(state.plannedVisitMinutes[stop.id].map { "Stop \(index + 1) · Planned visit \($0) min" }
                                 ?? stop.category?.suggestedVisitMinutes.map { "Stop \(index + 1) · Suggested visit ~\($0) min" }
                                 ?? "Stop \(index + 1) · Visit time is your choice")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach([0, 10, 15, 20, 30, 45, 60, 90], id: \.self) { minutes in
                                Button(minutes == 0 ? "No planned visit" : "\(minutes) minutes") {
                                    state.setPlannedVisit(minutes: minutes, for: stop)
                                }
                            }
                        } label: { Image(systemName: "clock.badge.checkmark") }
                        .accessibilityLabel("Plan visit time for \(stop.name)")
                        Button { onReplace(index) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .accessibilityLabel("Replace \(stop.name)")
                        Button { state.removeStop(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Remove \(stop.name)")
                    }
                    .padding(.vertical, 5)
                    .draggable(stop.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first,
                              let source = state.selectedStops.firstIndex(where: { $0.id == id }) else { return false }
                        state.moveStop(from: source, to: source < index ? index + 1 : index)
                        return true
                    }
                }
                timelineRow(route.destination.name, symbol: "flag.checkered", subtitle: "Destination")
            }
            Text("Drag stops to reorder. Driving arrival and planned visits are shown separately.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func timelineRow(_ name: String, symbol: String, subtitle: String) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.orange).frame(width: 22)
            VStack(alignment: .leading) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var journeyActions: some View {
        VStack(spacing: 8) {
            if let journey = state.journey {
                Text("Driving \(TripFormatting.duration(journey.drivingDuration)) · \(TripFormatting.extraTime(journey.extraDuration)) versus direct")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Maps opens one driving leg at a time. Return here for the next leg.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Finish or save journey", action: onSummary).font(.subheadline)
            if FeatureFlags.liveOpportunities {
                Button("Start active journey", systemImage: "car.side.fill", action: onActive)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

private extension View {
    @ViewBuilder func floatingControl() -> some View {
        if #available(iOS 26.0, *) {
            self.padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder func destinationSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
