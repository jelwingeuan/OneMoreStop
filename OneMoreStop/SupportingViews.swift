import MapKit
import SwiftData
import SwiftUI

struct PlaceSearchView: View {
    let target: SearchTarget
    let search: MapSearchService
    let near: Coordinate?
    let onSelect: (Place) -> Void
    let onCurrentLocation: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecentPlace.usedAt, order: .reverse) private var recents: [RecentPlace]
    @State private var query = ""
    @State private var suggestions: [MKLocalSearchCompletion] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var explainLocation = false

    var body: some View {
        NavigationStack {
            List {
                if target == .origin {
                    Button { explainLocation = true } label: {
                        Label("Current Location", systemImage: "location.fill")
                    }
                }
                if !query.isEmpty {
                    ForEach(suggestions, id: \.self) { completion in
                        Button {
                            loading = true
                            Task {
                                do {
                                    let place = try await search.resolve(completion)
                                    onSelect(place)
                                    dismiss()
                                } catch { errorMessage = "Couldn’t find that place. Try another result." }
                                loading = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(completion.title).foregroundStyle(.primary)
                                Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section(target == .origin ? "Recent starts" : target == .replacement ? "Recent stops" : "Recent destinations") {
                        ForEach(Array(recents.filter { $0.kind == (target == .replacement ? "stop" : target.rawValue) }.prefix(8))) { recent in
                            Button {
                                onSelect(recent.place)
                                dismiss()
                            } label: {
                                Label(recent.name, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(target == .origin ? "Starting place" : target == .replacement ? "Replacement stop" : "Destination")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search places")
            .onChange(of: query) { _, value in
                errorMessage = nil
                search.suggestions(for: value, near: near) { suggestions = $0 }
            }
            .onDisappear { search.cancelSuggestions() }
            .overlay {
                if loading { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Use your location?", isPresented: $explainLocation) {
                Button("Continue") { onCurrentLocation(); dismiss() }
                Button("Choose manually", role: .cancel) {}
            } message: {
                Text("OneMoreStop uses your current position to plan this drive and find stops ahead. You can choose a starting place instead.")
            }
        }
    }
}

struct PlaceDetailView: View {
    let recommendation: StopRecommendation
    let distanceUnit: String
    let isSelected: Bool
    let canAdd: Bool
    let onAdd: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var saved: [SavedPlace]
    @Query(sort: \SavedCollection.createdAt) private var collections: [SavedCollection]
    @State private var lookAroundScene: MKLookAroundScene?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let lookAroundScene {
                        LookAroundPreview(initialScene: lookAroundScene)
                            .frame(height: 215)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .accessibilityLabel("Look Around preview of \(recommendation.place.name)")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recommendation.place.name).font(.largeTitle.bold())
                        Text(recommendation.place.category?.title ?? "Place")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let address = recommendation.place.address, !address.isEmpty {
                            Text(address).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 26) {
                        metric("Extra driving", TripFormatting.extraTime(recommendation.detourTime))
                        metric("Extra distance", TripFormatting.distance(recommendation.detourDistance, preference: distanceUnit))
                    }
                    if let phone = recommendation.place.phone { LabeledContent("Phone", value: phone) }
                    if let website = recommendation.place.website { Link("Website", destination: website) }
                    HStack {
                        Button {
                            if let existing = saved.first(where: { $0.id == recommendation.place.id }) {
                                modelContext.delete(existing)
                                for collection in collections {
                                    collection.placeIDs.removeAll { $0 == recommendation.place.id }
                                }
                            } else { modelContext.insert(SavedPlace(recommendation.place)) }
                        } label: {
                            Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: shareURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    if isSaved && !collections.isEmpty {
                        Menu("Add to collection") {
                            ForEach(collections) { collection in
                                Button(collection.name) {
                                    if !collection.placeIDs.contains(recommendation.place.id) {
                                        collection.placeIDs.append(recommendation.place.id)
                                    }
                                }
                            }
                        }
                    }
                    Button(isSelected ? "Added to journey" : "Add stop", action: onAdd)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .frame(maxWidth: .infinity)
                        .disabled(isSelected || !canAdd)
                    if !canAdd && !isSelected { Text("Three stops is the limit for this journey.").font(.caption) }
                }
                .padding(20)
            }
            .navigationTitle("Place details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task(id: recommendation.id) {
                do {
                    try await MapRequestGate.shared.acquire()
                    do {
                        lookAroundScene = try await MKLookAroundSceneRequest(coordinate: recommendation.place.coordinate.clLocation).scene
                        await MapRequestGate.shared.release()
                    } catch {
                        await MapRequestGate.shared.release()
                    }
                } catch { }
            }
        }
    }

    private var isSaved: Bool { saved.contains { $0.id == recommendation.place.id } }
    private var shareURL: URL {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        let point = recommendation.place.coordinate
        parts.queryItems = [
            URLQueryItem(name: "ll", value: "\(point.latitude),\(point.longitude)"),
            URLQueryItem(name: "q", value: recommendation.place.name)
        ]
        return parts.url!
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
        }
    }
}

enum SavedSection: Hashable { case collections, places, journeys }

struct SavedView: View {
    @Binding var focusSection: SavedSection?
    let onChoose: (Place) -> Void
    let onRepeat: (RecentJourney) -> Void
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedPlace.savedAt, order: .reverse) private var saved: [SavedPlace]
    @Query(sort: \SavedCollection.createdAt, order: .reverse) private var collections: [SavedCollection]
    @Query(sort: \RecentPlace.usedAt, order: .reverse) private var recent: [RecentPlace]
    @Query(sort: \RecentJourney.createdAt, order: .reverse) private var journeys: [RecentJourney]
    @State private var showNewCollection = false
    @State private var collectionName = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section("Collections") {
                    if collections.isEmpty {
                        Text("Organize saved places into collections.").foregroundStyle(.secondary)
                    }
                    ForEach(collections) { collection in
                        NavigationLink {
                            CollectionView(collection: collection, saved: saved, onChoose: onChoose)
                        } label: {
                            Label("\(collection.name) · \(collection.placeIDs.count)", systemImage: "square.stack")
                        }
                    }
                    .onDelete { offsets in for index in offsets { modelContext.delete(collections[index]) } }
                    Button("New collection", systemImage: "plus") { showNewCollection = true }
                }
                .id(SavedSection.collections)
                Section("Saved places") {
                    if saved.isEmpty { Text("Places you save will appear here.").foregroundStyle(.secondary) }
                    ForEach(saved) { place in
                        Button { onChoose(place.place) } label: { placeRow(place.name, address: place.address) }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let id = saved[index].id
                            modelContext.delete(saved[index])
                            for collection in collections { collection.placeIDs.removeAll { $0 == id } }
                        }
                    }
                }
                .id(SavedSection.places)
                Section("Journeys") {
                    if journeys.isEmpty {
                        Text("Finish a journey to keep a local summary.").foregroundStyle(.secondary)
                    }
                    ForEach(journeys.prefix(10)) { journey in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(journey.destinationName).font(.headline)
                                if journey.saved { Image(systemName: "bookmark.fill").foregroundStyle(.orange) }
                            }
                            Text("\(journey.places.count - 2) stops · \(TripFormatting.extraTime(journey.extraDuration)) driving")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Repeat journey") { onRepeat(journey) }.font(.caption.weight(.semibold))
                            ShareLink(item: JourneyShare.summary(origin: journey.places.first?.name ?? "Start",
                                                                   destination: journey.destinationName,
                                                                   stops: Array(journey.places.dropFirst(2)))) {
                                Label("Share planned route", systemImage: "square.and.arrow.up")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                    .onDelete { offsets in for index in offsets { modelContext.delete(journeys[index]) } }
                }
                .id(SavedSection.journeys)
                Section("Planning challenges") {
                    let challenges = PlanningChallenges.earned(from: journeys)
                    if challenges.isEmpty {
                        Text("Plan journeys with stops to collect milestones.").foregroundStyle(.secondary)
                    }
                    ForEach(challenges, id: \.self) { name in
                        Label(name, systemImage: "rosette").foregroundStyle(.orange)
                    }
                    Text("These reflect saved plans, not places you drove past.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Recent stops") {
                    ForEach(Array(recent.filter { $0.kind == "stop" }.prefix(8))) { place in
                        Button { onChoose(place.place) } label: { placeRow(place.name, address: place.address) }
                    }
                }
            }
            .navigationTitle("Saved")
            .onAppear {
                if let focusSection { proxy.scrollTo(focusSection, anchor: .top) }
            }
            .onChange(of: focusSection) { _, section in
                if let section { withAnimation(.smooth) { proxy.scrollTo(section, anchor: .top) } }
            }
            .alert("New collection", isPresented: $showNewCollection) {
                TextField("Collection name", text: $collectionName)
                Button("Create") {
                    let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { modelContext.insert(SavedCollection(name: name)) }
                    collectionName = ""
                }
                Button("Cancel", role: .cancel) { collectionName = "" }
            }
            }
        }
    }

    private func placeRow(_ name: String, address: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).foregroundStyle(.primary)
            if let address { Text(address).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct CollectionView: View {
    let collection: SavedCollection
    let saved: [SavedPlace]
    let onChoose: (Place) -> Void

    var body: some View {
        List {
            ForEach(saved.filter { collection.placeIDs.contains($0.id) }) { place in
                Button(place.name) { onChoose(place.place) }
            }
            .onDelete { offsets in
                let members = saved.filter { collection.placeIDs.contains($0.id) }
                for index in offsets { collection.placeIDs.removeAll { $0 == members[index].id } }
            }
        }
        .navigationTitle(collection.name)
        .overlay {
            if collection.placeIDs.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "bookmark",
                                       description: Text("Save a place and add it from its details."))
            }
        }
    }
}

struct SettingsView: View {
    let onResetNotInterested: () -> Void
    var focusTravelPreferences = false
    @Environment(\.dismiss) private var dismiss
    @Query private var preferences: [UserPreferenceRecord]

    var body: some View {
        NavigationStack {
            if let preference = preferences.first {
                SettingsForm(preference: preference, onDone: { dismiss() },
                             focusTravelPreferences: focusTravelPreferences,
                             onResetNotInterested: onResetNotInterested)
            } else {
                ContentUnavailableView("Settings unavailable", systemImage: "gearshape")
            }
        }
    }
}

private struct SettingsForm: View {
    @Bindable var preference: UserPreferenceRecord
    let onDone: () -> Void
    let focusTravelPreferences: Bool
    let onResetNotInterested: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Query private var ignoredPlaces: [IgnoredPlaceRecord]
    #if DEBUG
    @State private var requestMetrics: MapRequestGate.Metrics?
    #endif

    var body: some View {
        ScrollViewReader { proxy in
        Form {
                Section("Driving") {
                    Picker("Distance units", selection: $preference.distanceUnit) {
                        Text("Automatic").tag("automatic")
                        Text("Kilometers").tag("kilometers")
                        Text("Miles").tag("miles")
                    }
                    Picker("Default extra time", selection: $preference.defaultBudgetMinutes) {
                        ForEach(DiscoveryTuning.budgets, id: \.self) { Text("\($0) minutes").tag($0) }
                        Text("90 minutes").tag(90)
                    }
                    LabeledContent("Travel mode", value: "Driving")
                }
                .id("travelPreferences")
                Section("Discover") {
                    Toggle("Show local places first", isOn: $preference.localFirst)
                    Toggle("EV Journey", isOn: $preference.evJourney)
                    Text("EV Journey includes charging places in Useful. Charger availability and specifications are not verified.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset learned preferences") { preference.resetLearning() }
                    Button("Show temporarily hidden places") { onResetNotInterested() }
                    Button("Show ignored places again") {
                        for place in ignoredPlaces { modelContext.delete(place) }
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $preference.appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section("Privacy") {
                    Text("Saved places and journey summaries stay on this device. Current Location is resolved when you use it; precise location trails are not stored. Apple Maps provides search and driving routes.")
                        .font(.subheadline)
                }
                #if DEBUG
                Section("MapKit request metrics · debug") {
                    if let requestMetrics {
                        LabeledContent("Started", value: "\(requestMetrics.started)")
                        LabeledContent("Active", value: "\(requestMetrics.active)")
                        LabeledContent("Peak active", value: "\(requestMetrics.peak)")
                        LabeledContent("Waiting", value: "\(requestMetrics.waiting)")
                    }
                    Button("Refresh metrics") {
                        Task { requestMetrics = await MapRequestGate.shared.metrics() }
                    }
                }
                #endif
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done", action: onDone) } }
        .onAppear {
            if focusTravelPreferences { proxy.scrollTo("travelPreferences", anchor: .top) }
        }
        #if DEBUG
        .task { requestMetrics = await MapRequestGate.shared.metrics() }
        #endif
        }
    }
}

struct IntroductionView: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 44, weight: .bold)).foregroundStyle(.orange)
            Text("A little time. A better drive.").font(.largeTitle.bold())
            Text("Tell us where you're going and how many extra driving minutes you can spare. We'll check real routes for stops along the way.")
                .font(.body).foregroundStyle(.secondary)
            Text("Choose Current Location when you need it, or set a starting place yourself.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Start exploring", action: onContinue)
                .buttonStyle(.borderedProminent).tint(.orange)
                .frame(maxWidth: .infinity)
        }
        .padding(28)
    }
}

struct JourneySummaryView: View {
    let route: RoutePlan
    let journey: Journey
    let budget: Int
    let onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "flag.checkered").font(.largeTitle).foregroundStyle(.orange)
                Text("Your drive").font(.largeTitle.bold())
                Text("\(route.origin.name) to \(route.destination.name)")
                    .font(.headline)
                Text("\(journey.stops.count) stops · \(TripFormatting.duration(journey.drivingDuration)) driving · \(TripFormatting.extraTime(journey.extraDuration)) versus direct · \(budget) minute budget")
                    .foregroundStyle(.secondary)
                ForEach(Array(journey.stops.enumerated()), id: \.element.id) { index, place in
                    Label("\(index + 1). \(place.name)", systemImage: place.category?.symbol ?? "mappin")
                }
                Text("Share preview: \(route.origin.name) → \(journey.stops.map(\.name).joined(separator: " → ")) → \(route.destination.name)")
                    .font(.caption).foregroundStyle(.secondary)
                ShareLink(item: JourneyShare.summary(origin: route.origin.name,
                                                       destination: route.destination.name,
                                                       stops: journey.stops)) {
                    Label("Share this planned route", systemImage: "square.and.arrow.up")
                }
                Spacer()
                Button("Save summary") { onDone(true) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                Button("Done without saving") { onDone(false) }
            }
            .padding(24)
            .navigationTitle("Journey summary")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

enum SearchTarget: String, Identifiable {
    case origin, destination, replacement
    var id: String { rawValue }
}
