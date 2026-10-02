import SwiftUI

private struct MeetingSearchSlot: Identifiable {
    let participantID: UUID
    let destination: Bool
    var id: String { "\(participantID)-\(destination)" }
}

struct MeetingPlannerView: View {
    let search: MapSearchService
    let route: RoutePlan
    let onAdd: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var people: [MeetingParticipant]
    @State private var sharedDestination = true
    @State private var minimizeTotal = false
    @State private var searchSlot: MeetingSearchSlot?
    @State private var results = [MeetingResult]()
    @State private var busy = false
    @State private var message: String?
    @State private var lookupTask: Task<Void, Never>?

    init(search: MapSearchService, route: RoutePlan, onAdd: @escaping (Place) -> Void) {
        self.search = search
        self.route = route
        self.onAdd = onAdd
        _people = State(initialValue: [
            MeetingParticipant(name: "You", origin: route.origin, destination: route.destination),
            MeetingParticipant(name: "Friend", destination: route.destination)
        ])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Routes and detours are calculated locally with Apple Maps. Participant details stay on this device; sharing is a static summary.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Participants") {
                    Toggle("Shared destination", isOn: $sharedDestination)
                    ForEach(people) { person in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: Binding(
                                get: { people.first(where: { $0.id == person.id })?.name ?? "" },
                                set: { value in update(person.id) { $0.name = value } }))
                                .textInputAutocapitalization(.words)
                            Button(person.origin?.name ?? "Choose origin") {
                                searchSlot = MeetingSearchSlot(participantID: person.id, destination: false)
                            }
                            if !sharedDestination {
                                Button(person.destination?.name ?? "Choose destination") {
                                    searchSlot = MeetingSearchSlot(participantID: person.id, destination: true)
                                }
                            }
                            DatePicker("Depart", selection: Binding(
                                get: { people.first(where: { $0.id == person.id })?.departure ?? .now },
                                set: { value in update(person.id) { $0.departure = value } }),
                                displayedComponents: [.date, .hourAndMinute])
                            if people.count > 2 {
                                Button("Remove \(person.name)", role: .destructive) {
                                    people.removeAll { $0.id == person.id }
                                    results = []
                                }
                            }
                        }
                    }
                    Button("Add participant") {
                        people.append(MeetingParticipant(name: "Person \(people.count + 1)",
                                                         destination: route.destination))
                    }
                    .disabled(people.count >= 6)
                }
                Section("Compare") {
                    Toggle("Prioritize minimum combined detour", isOn: $minimizeTotal)
                    Text(minimizeTotal ? "May ask one person to drive farther." :
                         "Prioritizes the person with the longest detour, then total detour.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Find meeting places") { find() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !canSearch)
                    if !namesAreUnique {
                        Text("Give each participant a different name.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView("Routing every participant…") }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                if !results.isEmpty {
                    Section("Routed meeting options") {
                        ForEach(results) { result in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.place.name).font(.headline)
                                ForEach(result.costs, id: \.participantName) { cost in
                                    Text("\(cost.participantName): \(TripFormatting.extraTime(cost.detour)) · arrives \(TripFormatting.arrival(cost.arrival))")
                                        .font(.subheadline)
                                }
                                Text("Combined \(TripFormatting.extraTime(result.combinedDetour)) · arrival spread \(TripFormatting.duration(result.arrivalSpread))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Add to my journey") { onAdd(result.place); dismiss() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        ShareLink(item: shareSummary) {
                            Label("Share static meeting summary", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle(people.count == 2 ? "Meet on the way" : "Rendezvous")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .sheet(item: $searchSlot) { slot in
            PlaceSearchView(target: .meetingPlace, search: search,
                            near: route.destination.coordinate) { place in
                update(slot.participantID) { person in
                    if slot.destination { person.destination = place }
                    else { person.origin = place }
                }
                results = []
            } onCurrentLocation: { }
        }
        .onDisappear { lookupTask?.cancel() }
    }

    private var canSearch: Bool {
        people.count >= 2 && namesAreUnique && people.allSatisfy { person in
            !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            person.origin != nil && (sharedDestination || person.destination != nil)
        }
    }

    private var namesAreUnique: Bool {
        Set(people.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == people.count
    }

    private func update(_ id: UUID, change: (inout MeetingParticipant) -> Void) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        change(&people[index])
    }

    private func find() {
        lookupTask?.cancel()
        busy = true
        results = []
        message = nil
        let participants = people.map { person -> MeetingParticipant in
            var copy = person
            if sharedDestination { copy.destination = route.destination }
            return copy
        }
        lookupTask = Task {
            do {
                let options = try await MeetingPlannerService(directions: DirectionsService(), search: search)
                    .find(participants: participants, minimizeTotal: minimizeTotal)
                guard !Task.isCancelled else { return }
                results = options
                message = options.isEmpty ? "No meeting place was verified near all these routes. Try different endpoints." : nil
            } catch is CancellationError { }
            catch { message = "Couldn’t check all routes. Check the endpoints and connection, then retry." }
            busy = false
        }
    }

    private var shareSummary: String {
        guard let first = results.first else { return "" }
        let costs = first.costs.map { "\($0.participantName): \(TripFormatting.extraTime($0.detour))" }.joined(separator: "\n")
        return "Meet at \(first.place.name)\n\(costs)\nStatic OneMoreStop plan; confirm timing together."
    }
}
