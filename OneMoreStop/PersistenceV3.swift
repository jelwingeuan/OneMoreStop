import Foundation
import SwiftData

@Model
final class UserPreferenceRecord {
    @Attribute(.unique) var id: String
    var distanceUnit: String
    var defaultBudgetMinutes: Int
    var localFirst: Bool
    var evJourney: Bool
    var appearance: String
    var hasSeenIntroduction: Bool
    var selectedCategoryCountsData: Data
    var autopilotRulesData: Data?
    var interestingOnlyDefault: Bool?
    var selectedModeCountsData: Data?

    init(distanceUnit: String = "automatic", defaultBudgetMinutes: Int = 20,
         localFirst: Bool = false, evJourney: Bool = false, appearance: String = "system",
         hasSeenIntroduction: Bool = false) {
        id = "primary"
        self.distanceUnit = distanceUnit
        self.defaultBudgetMinutes = defaultBudgetMinutes
        self.localFirst = localFirst
        self.evJourney = evJourney
        self.appearance = appearance
        self.hasSeenIntroduction = hasSeenIntroduction
        selectedCategoryCountsData = Data()
        autopilotRulesData = nil
        interestingOnlyDefault = nil
        selectedModeCountsData = nil
    }

    var selectedCategoryCounts: [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: selectedCategoryCountsData)) ?? [:]
    }

    func recordSelection(_ category: StopCategory?) {
        guard let category else { return }
        var counts = selectedCategoryCounts
        counts[category.rawValue, default: 0] += 1
        selectedCategoryCountsData = (try? JSONEncoder().encode(counts)) ?? Data()
    }

    func resetLearning() {
        selectedCategoryCountsData = Data()
        selectedModeCountsData = nil
    }

    var autopilotRules: [JourneyRule]? {
        get { autopilotRulesData.flatMap { try? JSONDecoder().decode([JourneyRule].self, from: $0) } }
        set { autopilotRulesData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var selectedModeCounts: [String: Int] {
        (selectedModeCountsData.flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }) ?? [:]
    }

    func recordMode(_ mode: DiscoveryMode) {
        var counts = selectedModeCounts
        counts[mode.rawValue, default: 0] += 1
        selectedModeCountsData = try? JSONEncoder().encode(counts)
    }
}

@Model
final class IgnoredPlaceRecord {
    @Attribute(.unique) var id: String
    var name: String
    var ignoredAt: Date

    init(_ place: Place) {
        id = place.id
        name = place.name
        ignoredAt = .now
    }
}

@Model
final class LocalGroupRecord {
    var id: UUID
    var name: String
    var participantData: Data
    var voteData: Data
    var placeNamesData: Data
    var preferredModeRaw: String
    var createdAt: Date

    init(name: String) {
        id = UUID()
        self.name = name
        participantData = Data()
        voteData = Data()
        placeNamesData = Data()
        preferredModeRaw = DiscoveryMode.explore.rawValue
        createdAt = .now
    }

    var participants: [String] {
        get { (try? JSONDecoder().decode([String].self, from: participantData)) ?? [] }
        set { participantData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var votes: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: voteData)) ?? [:] }
        set { voteData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var placeNames: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: placeNamesData)) ?? [:] }
        set { placeNamesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var preferredMode: DiscoveryMode {
        get { DiscoveryMode(rawValue: preferredModeRaw) ?? .explore }
        set { preferredModeRaw = newValue.rawValue }
    }

    func addParticipant(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !participants.contains(where: {
            $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return false }
        participants.append(trimmed)
        return true
    }

    func castVote(participant: String, placeID: String, placeName: String? = nil) {
        guard participants.contains(participant) else { return }
        votes[participant] = placeID
        if let placeName { placeNames[placeID] = placeName }
    }

    func voteCount(for placeID: String) -> Int { votes.values.filter { $0 == placeID }.count }
}
