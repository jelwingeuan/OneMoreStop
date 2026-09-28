import MapKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @State private var state = AppState()
    @State private var tab = 0
    @State private var showIntro = false
    @AppStorage("hasSeenIntroduction") private var hasSeenIntroduction = false
    @AppStorage("defaultBudget") private var defaultBudget = 20
    @AppStorage("localFirst") private var localFirst = false
    @AppStorage("evJourney") private var evJourney = false
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        TabView(selection: $tab) {
            ExploreView(state: state, tab: $tab)
                .tabItem { Label("Explore", systemImage: "map.fill") }
                .tag(0)
            SavedView { place in
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
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .sheet(isPresented: $showIntro) {
            IntroductionView {
                hasSeenIntroduction = true
                showIntro = false
            }
            .presentationDetents([.medium])
        }
        .task {
            state.budgetMinutes = defaultBudget
            state.defaultBudgetMinutes = defaultBudget
            state.localFirst = localFirst
            state.evJourney = evJourney
            await state.useCurrentLocationIfAuthorized()
            showIntro = !hasSeenIntroduction
        }
        .onChange(of: localFirst) { _, value in state.localFirst = value; state.discover() }
        .onChange(of: evJourney) { _, value in state.evJourney = value; state.discover() }
        .onChange(of: defaultBudget) { _, value in state.defaultBudgetMinutes = value }
    }
}

private struct ExploreView: View {
    @Bindable var state: AppState
    @Binding var tab: Int
    @State private var searchTarget: SearchTarget?
    @State private var detail: StopRecommendation?
    @State private var showJourney = false
    @State private var showSettings = false
    @State private var showSummary = false
    @State private var handoffFailed = false
    @State private var replacingIndex: Int?
    @State private var detent: PresentationDetent = .medium
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("distanceUnit") private var distanceUnit = "automatic"

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
                if state.route == nil { startCard }
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
                            isSelected: state.selectedStops.contains(where: { $0.id == recommendation.id }),
                            canAdd: state.canAddStop) {
                if state.addStop(recommendation) {
                    modelContext.insert(RecentPlace(recommendation.place, kind: "stop"))
                    detail = nil
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { if state.route != nil && tab == 0 { showJourney = true } }) { SettingsView() }
        .sheet(isPresented: $showSummary) {
            if let route = state.route, let journey = state.journey {
                JourneySummaryView(route: route, journey: journey, budget: state.budgetMinutes) { save in
                    modelContext.insert(RecentJourney(origin: route.origin, destination: route.destination,
                                                      stops: journey.stops, budgetMinutes: state.budgetMinutes,
                                                      drivingDuration: journey.drivingDuration,
                                                      extraDuration: journey.extraDuration, saved: save))
                    showSummary = false
                }
            }
        }
        .sheet(isPresented: $showJourney) { journeySheet }
        .alert("Couldn’t open Apple Maps", isPresented: $handoffFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Try again in a moment.") }
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
            Button { showJourney = false; showSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).frame(width: 30, height: 30)
            }
            .accessibilityLabel("Settings")
            Button { showJourney = false; tab = 1 } label: {
                Image(systemName: "bookmark").font(.title3).frame(width: 30, height: 30)
            }
            .accessibilityLabel("Saved")
        }
        .floatingControl()
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
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
    }

    private var journeySheet: some View {
        JourneySheetView(state: state, distanceUnit: distanceUnit,
                         onDetail: { showJourney = false; detail = $0 },
                         onAdd: { recommendation in
                             if state.addStop(recommendation) {
                                 modelContext.insert(RecentPlace(recommendation.place, kind: "stop"))
                             }
                         },
                         onReplace: { index in
                             replacingIndex = index
                             showJourney = false
                             searchTarget = .replacement
                         },
                         onMaps: { handoffFailed = !state.openNextLeg() },
                         onSummary: { showJourney = false; showSummary = true })
        .presentationDetents([.height(220), .medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
    }
}

private struct JourneySheetView: View {
    @Bindable var state: AppState
    let distanceUnit: String
    let onDetail: (StopRecommendation) -> Void
    let onAdd: (StopRecommendation) -> Void
    let onReplace: (Int) -> Void
    let onMaps: () -> Void
    let onSummary: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeader
                if let message = state.journeyMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if state.journeyBusy { ProgressView("Recalculating trip…") }
                if !state.selectedStops.isEmpty { timeline.disabled(state.journeyBusy) }
                budgetControls.disabled(state.journeyBusy)
                modeControls.disabled(state.journeyBusy)
                if state.canAddStop && !state.journeyBusy { recommendations }
                if !state.selectedStops.isEmpty { journeyActions }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Find your one more stop").font(.title2.bold())
            if let route = state.route, let journey = state.journey {
                Text("\(route.origin.name) → \(route.destination.name)")
                    .font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(TripFormatting.duration(journey.drivingDuration), systemImage: "car.fill")
                    Label(TripFormatting.extraTime(journey.extraDuration), systemImage: "plus.circle")
                    Label(TripFormatting.arrival(JourneyMath.arrival(after: journey.legs, startingAt: .now)),
                          systemImage: "clock")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var budgetControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("I can spare").font(.headline)
                Spacer()
                Text("\(state.budgetMinutes) min extra driving")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            }
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
        }
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
        case .calculatingDetours: ProgressView("Checking driving times…").frame(maxWidth: .infinity)
        case .noResults:
            ContentUnavailableView("No stops within \(state.budgetMinutes) minutes",
                                   systemImage: "map",
                                   description: Text("Try more time or another kind of stop."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "wifi.exclamationmark")
            } description: { Text(message) } actions: {
                Button("Retry") { state.discover() }.buttonStyle(.borderedProminent)
            }
        default: EmptyView()
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
                Text(TripFormatting.extraTime(recommendation.detourTime))
                    .font(.headline).foregroundStyle(.orange)
            }
            Text(RecommendationCopyService.phrase(for: recommendation))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(TripFormatting.distance(recommendation.detourDistance, preference: distanceUnit)) extra")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Details") { onDetail(recommendation) }
                Button("Add stop") { onAdd(recommendation) }
                    .buttonStyle(.borderedProminent).tint(.orange)
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
                            Text(stop.category?.suggestedVisitMinutes.map { "Stop \(index + 1) · Suggested visit ~\($0) min" }
                                 ?? "Stop \(index + 1) · Visit time is your choice")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
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
            Text("Drag stops to reorder. Arrival uses driving time only.")
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
            Button {
                onMaps()
            } label: {
                Label(state.openedLegCount == 0 ? "Open in Apple Maps" : "Continue to next stop",
                      systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(state.openedLegCount >= (state.journey?.legs.count ?? 0))
            Text("Maps opens one driving leg at a time. Return here for the next leg.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Finish or save journey", action: onSummary).font(.subheadline)
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
