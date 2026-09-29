import SwiftData
import SwiftUI

struct LocalGroupView: View {
    let recommendations: [StopRecommendation]
    let origin: Place?
    let destination: Place?
    let createGroup: (String) -> Void
    let usePreference: (DiscoveryMode) -> Void

    @State private var groupName = "Our drive"
    @State private var participantName = ""
    @State private var selectedParticipant = ""
    @Environment(\.dismiss) private var dismiss
    @Query private var groups: [LocalGroupRecord]

    private var group: LocalGroupRecord? { groups.first }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Votes are saved on this device. Sharing sends a static summary; other devices cannot vote here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let group {
                    Section("Group preference") {
                        Picker("Explore as a group", selection: Binding(
                            get: { group.preferredMode },
                            set: { group.preferredMode = $0 })) {
                                ForEach([DiscoveryMode.eat, .coffee, .nature, .scenic,
                                         .thingsToDo, .explore, .useful], id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                        Button("Find this kind of stop") { usePreference(group.preferredMode) }
                            .disabled(origin == nil || destination == nil)
                    }
                    Section("Participants") {
                        HStack {
                            TextField("Name", text: $participantName)
                                .textInputAutocapitalization(.words)
                            Button("Add") {
                                if group.addParticipant(participantName) { participantName = "" }
                            }
                            .disabled(participantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        ForEach(group.participants, id: \.self) { participant in
                            Label(participant, systemImage: group.votes[participant] == nil ? "person" : "checkmark.circle.fill")
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
                                Text("Find verified stops on a route to vote on them.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Share a snapshot") {
                        Text(summary(for: group))
                            .font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: summary(for: group)) {
                            Label("Share group summary", systemImage: "square.and.arrow.up")
                        }
                    }
                } else {
                    Section("Start a local group") {
                        TextField("Group name", text: $groupName)
                        Button("Create group") { createGroup(groupName) }
                            .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle(group?.name ?? "Local group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func summary(for group: LocalGroupRecord) -> String {
        let route = [origin?.name, destination?.name].compactMap { $0 }.joined(separator: " → ")
        let choices = Set(group.votes.values).sorted().map { id in
            "\(group.placeNames[id] ?? id): \(group.voteCount(for: id)) vote(s)"
        }.joined(separator: "\n")
        return "\(group.name)\n\(route)\n\(choices)\nLocal snapshot from OneMoreStop."
    }
}
