import SwiftUI
import SwiftData

struct ActiveJourneyView: View {
    @Bindable var state: AppState
    let openMaps: () -> Void
    let onComplete: () -> Bool
    let onAddOpportunity: (StopRecommendation) -> Void
    let onAddChain: (StopCombination) -> Void
    let onSaveOpportunity: (JourneyOpportunity) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var passenger = false
    @State private var showMeetingPlanner = false
    @State private var showGroup = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("View", selection: $passenger) {
                        Text("Driver").tag(false)
                        Text("Passenger").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if let route = state.route, let journey = state.journey {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Next").font(.subheadline).foregroundStyle(.secondary)
                            Text(nextPlace(route: route, journey: journey).name)
                                .font(.largeTitle.bold())
                                .minimumScaleFactor(0.7)
                            if let arrival = state.activeDrivingArrival {
                                Text("\(route.destination.name) · about \(TripFormatting.arrival(arrival)) driving arrival")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text("\(TripFormatting.duration(journey.drivingDuration)) total routed driving")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("\(state.timeBudget.deadline == nil ? "Adventure Time" : "Arrival margin"): \(TripFormatting.duration(state.remainingTime))")
                                .font(.headline).foregroundStyle(.orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
                        ProgressView(value: state.travelerProgress)
                            .tint(.orange)
                            .accessibilityLabel("Journey progress")
                            .accessibilityValue("About \(Int(state.travelerProgress * 100)) percent")
                        if FeatureFlags.journeyChapters {
                            Text(state.chapter.title)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if let message = state.activeMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.orange)
                        }
                        if FeatureFlags.opportunityRadar {
                            opportunitySurface
                        }
                        Button {
                            openMaps()
                        } label: {
                            Label(state.openedLegCount == 0 ? "Open next leg in Apple Maps" : "Continue to next stop",
                                  systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(state.openedLegCount >= journey.legs.count)
                        Text("Apple Maps handles directions one leg at a time. Return here to continue.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Complete journey", systemImage: "checkmark.circle") {
                            if onComplete() {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        if passenger {
                            PassengerDiscoveryControls(state: state)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Upcoming opportunities").font(.headline)
                                ForEach(state.opportunities) { item in
                                    HStack {
                                        Image(systemName: item.place.place.category?.symbol ?? "mappin")
                                        Text(item.place.name).lineLimit(1)
                                        Spacer()
                                        Text(TripFormatting.extraTime(item.incrementalDriving))
                                    }
                                    .font(.subheadline)
                                }
                                if state.opportunities.isEmpty {
                                    Text("No verified stop fits the current time budget.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Button("Another opportunity") { state.showAnotherOpportunity() }
                                    .disabled(state.opportunities.count < 2)
                                if FeatureFlags.whatWasThat {
                                    Button("What Was That?") { state.findWhatWasThat() }
                                    if state.whatWasThatBusy { ProgressView("Checking nearby places…") }
                                    ForEach(state.whatWasThatResults) { place in
                                        Label(place.name, systemImage: place.category?.symbol ?? "mappin")
                                            .font(.subheadline)
                                    }
                                    if !state.whatWasThatBusy && state.whatWasThatResults.isEmpty {
                                        Text("Recent route positions stay in memory only while this journey is active.")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                if FeatureFlags.detourRoulette { rouletteSurface }
                                if FeatureFlags.journeyChains, !state.chains.isEmpty {
                                    Text("Journey chains").font(.headline)
                                    ForEach(state.chains) { chain in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(chain.first.name) → \(chain.second.name)")
                                                .font(.subheadline.weight(.semibold))
                                            Text("\(TripFormatting.extraTime(chain.incrementalDetour)) added driving for both")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Button("Add both stops") { onAddChain(chain) }
                                        }
                                    }
                                }
                                if FeatureFlags.stopAutopilot {
                                    Text("Suggest when the time fits").font(.headline)
                                    ForEach(state.autopilotRules, id: \.need) { rule in
                                        Toggle("\(rule.need.title) after \(rule.minimumElapsedMinutes) min", isOn: Binding(
                                            get: { state.autopilotRules.first(where: { $0.need == rule.need })?.enabled ?? false },
                                            set: { state.setAutopilotRule(rule.need, enabled: $0) }))
                                    }
                                    Text("Suggestions only. Stops are never added automatically.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if FeatureFlags.meetOnTheWay {
                                    Button("Meet on the way", systemImage: "person.2.fill") {
                                        showMeetingPlanner = true
                                    }
                                }
                                Button("Local group votes", systemImage: "person.3") { showGroup = true }
                                Button("Refresh location and opportunities") {
                                    Task { await state.refreshTravelerProgress() }
                                }
                            }
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Active journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("End active mode") { state.endActiveJourney(); dismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
        .sensoryFeedback(.success, trigger: state.selectedStops.count)
        .sheet(isPresented: $showMeetingPlanner) {
            if let route = state.route {
                MeetingPlannerView(search: state.search, route: route) { place in
                    state.addRoutedPlace(place)
                }
            }
        }
        .sheet(isPresented: $showGroup) {
            LocalGroupView(recommendations: state.recommendations,
                origin: state.route?.origin, destination: state.route?.destination) { name in
                    modelContext.insert(LocalGroupRecord(name: name))
                } usePreference: { mode in
                    state.selectMode(mode)
                    showGroup = false
                }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            var tick = 0
            while state.activeJourney && !Task.isCancelled {
                state.clockNow = .now
                state.refreshOpportunityPolicy()
                if tick.isMultiple(of: 2) { await state.refreshTravelerProgress() }
                tick += 1
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var opportunitySurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let opportunity = state.nextOpportunity {
                Text("NEXT OPPORTUNITY")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(opportunity.place.name).font(.title3.bold()).lineLimit(2)
                    Spacer()
                    Text(TripFormatting.extraTime(opportunity.incrementalDriving))
                        .font(.headline).foregroundStyle(.orange)
                }
                if let minutes = opportunity.approximateMinutesAhead {
                    Text("About \(minutes) min ahead · \(opportunity.place.place.category?.title ?? "Stop")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let reason = opportunity.reasons.first {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add") {
                        if let recommendation = state.recommendations.first(where: { $0.id == opportunity.id }) {
                            onAddOpportunity(recommendation)
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .frame(minWidth: 80, minHeight: 44)
                    Button("Skip") {
                        state.skipOpportunity()
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                        .buttonStyle(.bordered).frame(minWidth: 80, minHeight: 44)
                    if FeatureFlags.saveForReturn {
                        Button("Save") {
                            onSaveOpportunity(opportunity)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
                if passenger {
                    Menu("Skip reason") {
                        ForEach(SmartSkipReason.allCases) { reason in
                            Button(reason.title) { state.skipOpportunity(reason: reason) }
                        }
                    }
                    .font(.caption)
                }
            } else {
                Text("Keep driving").font(.headline)
                Text("Nothing verified ahead fits your time right now.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("One More Stop") { state.showOneMoreStop() }
                    .buttonStyle(.bordered).disabled(state.route == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
        .accessibilityElement(children: .contain)
    }

    private var rouletteSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detour Roulette").font(.headline)
            Picker("Maximum extra driving", selection: $state.rouletteMaximumMinutes) {
                ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            if let choice = state.rouletteChoice {
                Text("Found: \(choice.place.category?.title ?? "Place") · \(TripFormatting.extraTime(choice.detourTime))")
                    .font(.subheadline)
                if state.rouletteRevealed {
                    Text(choice.place.name).font(.headline)
                    Button("Add stop") { onAddOpportunity(choice) }
                } else {
                    Button("Reveal") {
                        state.rouletteRevealed = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                Button("Another") { state.rotateRoulette() }
                    .disabled(state.rouletteCandidates.count < 2)
            } else {
                Text("No verified stop fits this maximum yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private func nextPlace(route: RoutePlan, journey: Journey) -> Place {
        let endpoints = journey.stops + [route.destination]
        return endpoints[min(state.openedLegCount, endpoints.count - 1)]
    }
}

private struct PassengerDiscoveryControls: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Explore ahead").font(.headline)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(TimeMachine.buckets, id: \.self) { minutes in
                        Button(minutes == 90 ? "60+ min" : "\(minutes) min") {
                            state.previewTimeMachine(minutes)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .scrollIndicators(.hidden)
            if let preview = state.timeMachinePreview {
                Text("\(state.timeMachinePreviewCount) verified stops in cache")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use \(preview) min") { state.applyTimeMachine() }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            Menu(state.selectedMission?.title ?? "Choose mission") {
                Button("No mission") { state.chooseMission(nil) }
                ForEach(JourneyMission.allCases) { mission in
                    Button(mission.title) { state.chooseMission(mission) }
                }
            }
            .buttonStyle(.bordered)
            Toggle("Interesting opportunities only", isOn: $state.interestingOnly)
                .onChange(of: state.interestingOnly) { _, _ in state.refreshOpportunityPolicy() }
            if let route = state.route, route.options.count > 1, state.selectedStops.isEmpty {
                Picker("Route comparison", selection: $state.remixMode) {
                    ForEach([DiscoveryMode.explore, .eat, .coffee, .scenic, .nature, .surpriseMe], id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Button("Compare alternate routes") { state.compareAlternateRoutes() }
                    .font(.subheadline)
                ForEach(route.options.indices, id: \.self) { index in
                    if let count = state.routeComparisonCounts[index] {
                        Text("Route \(index + 1): \(count) matching places found nearby")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
        .sensoryFeedback(.selection, trigger: state.timeMachinePreview)
    }
}
