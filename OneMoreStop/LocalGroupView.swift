import SwiftData
import SwiftUI

enum LocalGroupRouteContext {
    static func key(origin: Place?, destination: Place?) -> String? {
        guard let origin, let destination else { return nil }
        return [origin.id, destination.id].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct LocalGroupView: View {
    let recommendations: [StopRecommendation]
    let origin: Place?
    let destination: Place?
    let usePreference: (DiscoveryMode) -> Void

    @State private var groupName = "Our drive"
    @State private var participantName = ""
    @State private var selectedParticipant = ""
    @State private var showClearVotes = false
    @State private var showDeleteGroup = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocalGroupRecord.createdAt, order: .reverse) private var groups: [LocalGroupRecord]

    private var routeContextKey: String? { LocalGroupRouteContext.key(origin: origin, destination: destination) }
    private var routeLabel: String? {
        guard let origin, let destination else { return nil }
        return "\(origin.name) → \(destination.name)"
    }
    private var group: LocalGroupRecord? { groups.first { $0.matches(routeContextKey: routeContextKey) } }
    private var previousGroups: [LocalGroupRecord] { groups.filter { $0.id != group?.id } }
    private var availablePlaceIDs: Set<String> { Set(recommendations.map(\.id)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Votes stay on this device. Sharing sends a static summary; other devices cannot vote here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let group {
                    Section("Group preference") {
                        Picker("Explore as a group", selection: Binding(
                            get: { group.preferredMode },
                            set: { group.preferredMode = $0; save() })) {
                                ForEach([DiscoveryMode.eat, .coffee, .nature, .scenic,
                                         .thingsToDo, .explore, .useful], id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                        Button("Find this kind of stop") { usePreference(group.preferredMode) }
                    }
                    Section("Participants") {
                        HStack {
                            TextField("Name", text: $participantName)
                                .textInputAutocapitalization(.words)
                            Button("Add") {
                                if group.addParticipant(participantName) {
                                    participantName = ""
                                    save()
                                }
                            }
                            .disabled(participantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      group.participants.count >= 6)
                        }
                        ForEach(group.participants, id: \.self) { participant in
                            Label(participant, systemImage: group.votes(among: availablePlaceIDs)[participant] == nil
                                  ? "person" : "checkmark.circle.fill")
                        }
                        if group.participants.count >= 6 {
                            Text("A local group supports up to six people.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !group.participants.isEmpty {
                        Section("One choice per person") {
                            Picker("Voting as", selection: $selectedParticipant) {
                                Text("Choose a person").tag("")
                                ForEach(group.participants, id: \.self) { Text($0).tag($0) }
                            }
                            ForEach(recommendations) { recommendation in
                                Button {
                                    group.castVote(participant: selectedParticipant,
                                                   placeID: recommendation.id,
                                                   placeName: recommendation.place.name)
                                    save()
                                } label: {
                                    HStack {
                                        Text(recommendation.place.name)
                                        Spacer()
                                        Text("\(group.voteCount(for: recommendation.id))")
                                        if group.votes[selectedParticipant] == recommendation.id {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                    }
                                }
                                .disabled(selectedParticipant.isEmpty)
                            }
                            if recommendations.isEmpty {
                                Text("Find verified stops on this route to vote on them.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Share a snapshot") {
                        Text("Only votes for currently verified stops appear in this summary.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(summary(for: group))
                            .font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: summary(for: group)) {
                            Label("Share group summary", systemImage: "square.and.arrow.up")
                        }
                    }
                    Section("Manage group") {
                        Button("Clear votes", role: .destructive) { showClearVotes = true }
                            .disabled(group.votes.isEmpty)
                        Button("Delete group", role: .destructive) { showDeleteGroup = true }
                    }
                } else if routeContextKey != nil {
                    Section("Start a local group for this route") {
                        Text(routeLabel ?? "Current route").foregroundStyle(.secondary)
                        TextField("Group name", text: $groupName)
                        Button("Create group") { createGroup() }
                            .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Section("Choose a route") {
                        Text("Choose a starting place and destination before starting a local vote.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !previousGroups.isEmpty {
                    Section("Previous local groups") {
                        ForEach(previousGroups) { previous in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(previous.name).font(.headline)
                                Text(previous.routeLabel ?? "Route unavailable")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(previous.participants.count) people · \(previous.votes.count) saved votes")
                                    .font(.caption).foregroundStyle(.secondary)
                                if group == nil, routeContextKey != nil {
                                    Button("Use members for this route") { createGroup(copying: previous) }
                                        .font(.caption.weight(.semibold))
                                }
                                ForEach(Set(previous.votes.values).sorted(), id: \.self) { placeID in
                                    Text("\(previous.placeNames[placeID] ?? placeID): \(previous.voteCount(for: placeID)) vote(s)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { modelContext.delete(previousGroups[index]) }
                            save()
                        }
                    }
                }
            }
            .navigationTitle(group?.name ?? "Local group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear this group's votes?", isPresented: $showClearVotes) {
                Button("Clear votes", role: .destructive) {
                    group?.clearVotes()
                    save()
                }
            }
            .confirmationDialog("Delete this local group?", isPresented: $showDeleteGroup) {
                Button("Delete group", role: .destructive) {
                    if let group { modelContext.delete(group); save() }
                }
            }
            .alert("Couldn't save group", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                    Button("OK") { saveError = nil }
                } message: { Text(saveError ?? "Try again.") }
            .onChange(of: group?.id) { _, _ in selectedParticipant = "" }
        }
    }

    private func createGroup(copying previous: LocalGroupRecord? = nil) {
        guard let routeContextKey else { return }
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let newGroup = LocalGroupRecord(name: previous?.name ?? name,
                                        routeContextKey: routeContextKey, routeLabel: routeLabel)
        if let previous {
            newGroup.participants = previous.participants
            newGroup.preferredMode = previous.preferredMode
        }
        modelContext.insert(newGroup)
        save()
    }

    private func save() {
        do { try modelContext.save() }
        catch { saveError = error.localizedDescription }
    }

    private func summary(for group: LocalGroupRecord) -> String {
        let choices = Set(group.votes(among: availablePlaceIDs).values).sorted().map { id in
            "\(group.placeNames[id] ?? id): \(group.voteCount(for: id)) vote(s)"
        }.joined(separator: "\n")
        return "\(group.name)\n\(routeLabel ?? "Route unavailable")\n\(choices.isEmpty ? "No current verified votes" : choices)\nLocal snapshot from OneMoreStop."
    }
}
