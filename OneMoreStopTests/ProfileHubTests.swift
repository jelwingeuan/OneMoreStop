import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import OneMoreStop

struct ProfileHubTests {
    @Test func initialsHandleNamesAndUnicode() {
        #expect(ProfileInitials.from("Alex Tan") == "AT")
        #expect(ProfileInitials.from("Nur Aisyah") == "NA")
        #expect(ProfileInitials.from("Li") == "LI")
        #expect(ProfileInitials.from("李 小龍") == "李小")
        #expect(ProfileInitials.from("  \n ") == nil)
    }

    @Test func avatarStateUsesJourneyPrecedence() {
        #expect(ProfileAvatarState.resolve(hasRoute: false, discovering: false, hasStop: false,
                                           active: false, completed: false, completionMoment: false) == .idle)
        #expect(ProfileAvatarState.resolve(hasRoute: true, discovering: true, hasStop: true,
                                           active: true, completed: false, completionMoment: false) == .journeyActive)
        #expect(ProfileAvatarState.resolve(hasRoute: true, discovering: true, hasStop: true,
                                           active: false, completed: false, completionMoment: false) == .stopSelected)
        #expect(ProfileAvatarState.resolve(hasRoute: true, discovering: false, hasStop: false,
                                           active: false, completed: true, completionMoment: true) == .journeyCompleted)
        #expect(ProfileAvatarState.resolve(hasRoute: true, discovering: false, hasStop: true,
                                           active: false, completed: true, completionMoment: false) == .idle)
    }

    @Test func ringUsesRealSpareAndDeadlineWallets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let spare = TimeBudget.spare(minutes: 20)
        let spareRemaining = spare.remaining(baseline: 3_600, journey: 4_320,
                                              plannedVisits: 900, now: now)
        #expect(ProfileRing.progress(remaining: spareRemaining, original: 1_200) == 0.4)
        let deadline = TimeBudget.arriveBy(now.addingTimeInterval(6_000))
        let original = deadline.allowedExtraDriving(baseline: 3_600, plannedVisits: 600, now: now)
        let remaining = deadline.remaining(baseline: 3_600, journey: 4_320,
                                           plannedVisits: 600, now: now)
        #expect(ProfileRing.progress(remaining: remaining, original: original) == 0.6)
        #expect(ProfileRing.progress(remaining: -100, original: 500) == 0)
        #expect(ProfileRing.progress(remaining: 900, original: 500) == 1)
        #expect(ProfileRing.progress(remaining: 0, original: 0) == 0)
    }

    @Test func personalityRequiresThreeExplicitSelectionsAndClearLead() {
        #expect(TravelPersonality.title(for: ["coffee": 2]) == nil)
        #expect(TravelPersonality.title(for: ["coffee": 3, "scenic": 3]) == nil)
        #expect(TravelPersonality.title(for: ["coffee": 3, "food": 1]) == "Coffee Stopper")
        #expect(TravelPersonality.title(for: ["nature": 2, "park": 2]) == "Nature Seeker")
    }

    @Test @MainActor func profilePersistsAlongsideExistingSavedData() throws {
        let container = try ModelContainer(for: UserProfileRecord.self, SavedPlace.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let writer = ModelContext(container)
        let profile = UserProfileRecord(displayName: "Nur Aisyah", bio: "Coffee breaks", avatarData: Data([1, 2, 3]))
        writer.insert(profile)
        writer.insert(SavedPlace(Place(id: "coffee", name: "Coffee", coordinate:
                                       Coordinate(latitude: 3, longitude: 101), category: .coffee)))
        try writer.save()
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<UserProfileRecord>()).first?.displayName == "Nur Aisyah")
        #expect(try reader.fetch(FetchDescriptor<UserProfileRecord>()).first?.avatarData == Data([1, 2, 3]))
        #expect(try reader.fetch(FetchDescriptor<SavedPlace>()).count == 1)
    }

    @Test @MainActor func failedProfileSaveRestoresEveryField() {
        enum SaveFailure: Error { case simulated }
        let profile = UserProfileRecord(displayName: "Before", bio: "Old bio", avatarData: Data([1]))
        let originalDate = Date(timeIntervalSince1970: 1_000)
        profile.updatedAt = originalDate

        do {
            try profile.saveChanges({
                profile.displayName = "After"
                profile.bio = "New bio"
                profile.avatarData = Data([2])
                profile.updatedAt = .now
            }, save: { throw SaveFailure.simulated })
            Issue.record("The failed save was treated as successful")
        } catch is SaveFailure {
        } catch {
            Issue.record("The original save error was replaced")
        }

        #expect(profile.displayName == "Before")
        #expect(profile.bio == "Old bio")
        #expect(profile.avatarData == Data([1]))
        #expect(profile.updatedAt == originalDate)
    }

    @Test @MainActor func existingStoreOpensAfterProfileModelIsAdded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("OneMoreStop.store")
        try seedExistingStore(at: url)
        let upgraded = try ModelContainer(
            for: SavedPlace.self, RecentPlace.self, SavedCollection.self, RecentJourney.self,
                 UserPreferenceRecord.self, IgnoredPlaceRecord.self, LocalGroupRecord.self,
                 UserProfileRecord.self,
            configurations: ModelConfiguration(url: url))
        let context = ModelContext(upgraded)
        #expect(try context.fetch(FetchDescriptor<SavedPlace>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<UserPreferenceRecord>()).first?.defaultBudgetMinutes == 30)
        context.insert(UserProfileRecord(displayName: "Alex"))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<UserProfileRecord>()).first?.displayName == "Alex")
    }

    @MainActor private func seedExistingStore(at url: URL) throws {
        let legacy = try ModelContainer(
            for: SavedPlace.self, RecentPlace.self, SavedCollection.self, RecentJourney.self,
                 UserPreferenceRecord.self, IgnoredPlaceRecord.self, LocalGroupRecord.self,
            configurations: ModelConfiguration(url: url))
        let context = ModelContext(legacy)
        context.insert(SavedPlace(Place(id: "saved", name: "Saved place",
                                        coordinate: Coordinate(latitude: 3, longitude: 101))))
        context.insert(UserPreferenceRecord(defaultBudgetMinutes: 30))
        try context.save()
    }

    @Test @MainActor func completedRouteIsRecordedOnceAndCanBeSaved() throws {
        let container = try ModelContainer(for: RecentJourney.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinate = Coordinate(latitude: 3, longitude: 101)
        let origin = Place(id: "origin", name: "Start", coordinate: coordinate)
        let destination = Place(id: "destination", name: "Finish", coordinate: coordinate)
        let metrics = RouteMetrics(duration: 3_600, distance: 20_000, path: [coordinate])
        let route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                              baseline: metrics, createdAt: .now)
        let journey = Journey(stops: [], legs: [metrics], baseline: metrics)
        var session = JourneyRecordSession()
        let first = try session.record(route: route, journey: journey, budgetMinutes: 20,
                                       plannedVisits: [:], saved: false, in: context)
        let second = try session.record(route: route, journey: journey, budgetMinutes: 20,
                                        plannedVisits: [:], saved: true, in: context)
        #expect(first.id == second.id)
        #expect(second.saved)
        #expect(try context.fetch(FetchDescriptor<RecentJourney>()).count == 1)
    }

    @Test @MainActor func savedJourneysRemainVisibleBeyondRecentHistoryLimit() {
        let coordinate = Coordinate(latitude: 3, longitude: 101)
        let origin = Place(id: "origin", name: "Start", coordinate: coordinate)
        let destination = Place(id: "destination", name: "Finish", coordinate: coordinate)
        let journeys = (0..<14).map { index in
            let journey = RecentJourney(origin: origin, destination: destination, stops: [],
                                        budgetMinutes: 20, drivingDuration: 3_600,
                                        extraDuration: 0, saved: index == 0 || index == 5)
            journey.createdAt = Date(timeIntervalSince1970: Double(index))
            return journey
        }

        let displayed = JourneyHistory.displayed(from: Array(journeys.reversed()))

        #expect(displayed.count == 12)
        #expect(displayed.filter { !$0.saved }.count == 10)
        #expect(displayed.contains(where: { $0.id == journeys[5].id }))
        #expect(displayed.last?.id == journeys[0].id)
        #expect(!displayed.contains(where: { $0.id == journeys[1].id }))
    }

    @Test @MainActor func localGroupsKeepVotesScopedToTheirChosenRoute() throws {
        let coordinate = Coordinate(latitude: 3, longitude: 101)
        let origin = Place(id: "origin-a", name: "Start A", coordinate: coordinate)
        let destination = Place(id: "destination", name: "Finish", coordinate: coordinate)
        let otherOrigin = Place(id: "origin-b", name: "Start B", coordinate: coordinate)
        let routeKey = try #require(LocalGroupRouteContext.key(origin: origin, destination: destination))
        let otherKey = try #require(LocalGroupRouteContext.key(origin: otherOrigin, destination: destination))
        #expect(routeKey != otherKey)

        let container = try ModelContainer(for: LocalGroupRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let writer = ModelContext(container)
        let legacy = LocalGroupRecord(name: "Older group")
        let current = LocalGroupRecord(name: "Current group", routeContextKey: routeKey,
                                       routeLabel: "Start A → Finish")
        for index in 1...6 { #expect(current.addParticipant("Person \(index)")) }
        #expect(!current.addParticipant("Person 7"))
        current.castVote(participant: "Person 1", placeID: "coffee", placeName: "Coffee")
        current.castVote(participant: "Person 2", placeID: "old-stop", placeName: "Old stop")
        writer.insert(legacy)
        writer.insert(current)
        try writer.save()

        let reader = ModelContext(container)
        let loaded = try #require(reader.fetch(FetchDescriptor<LocalGroupRecord>())
            .first(where: { $0.id == current.id }))
        #expect(loaded.matches(routeContextKey: routeKey))
        #expect(!loaded.matches(routeContextKey: otherKey))
        #expect(!legacy.matches(routeContextKey: routeKey))
        #expect(loaded.votes(among: ["coffee"]) == ["Person 1": "coffee"])
        loaded.clearVotes()
        try reader.save()
        #expect(loaded.votes.isEmpty)
        #expect(loaded.placeNames.isEmpty)
    }

    @Test @MainActor func completingEditedRouteRefreshesOneSavedJourney() throws {
        let container = try ModelContainer(for: RecentJourney.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinate = Coordinate(latitude: 3, longitude: 101)
        let origin = Place(id: "current-origin", name: "Current Location", coordinate: coordinate)
        let destination = Place(id: "destination", name: "Finish", coordinate: coordinate)
        let coffee = Place(id: "coffee", name: "Coffee", coordinate: coordinate, category: .coffee)
        let park = Place(id: "park", name: "Park", coordinate: coordinate, category: .park)
        let baseline = RouteMetrics(duration: 3_600, distance: 20_000, path: [coordinate])
        let route = RoutePlan(id: UUID(), origin: origin, destination: destination,
                              baseline: baseline, createdAt: .now)
        let firstLeg = RouteMetrics(duration: 2_100, distance: 12_000, path: [coordinate])
        let secondLeg = RouteMetrics(duration: 1_800, distance: 9_000, path: [coordinate])
        var session = JourneyRecordSession()
        let original = try session.record(route: route,
                                          journey: Journey(stops: [coffee], legs: [firstLeg, secondLeg], baseline: baseline),
                                          budgetMinutes: 20, plannedVisits: [coffee.id: 15],
                                          saved: true, in: context)
        let originalID = original.id
        let originalDate = original.createdAt
        let thirdLeg = RouteMetrics(duration: 1_200, distance: 6_000, path: [coordinate])
        let refreshed = try session.record(route: route,
                                           journey: Journey(stops: [coffee, park],
                                                            legs: [firstLeg, secondLeg, thirdLeg], baseline: baseline),
                                           budgetMinutes: 45, plannedVisits: [coffee.id: 15, park.id: 30],
                                           saved: false, in: context)

        #expect(try context.fetch(FetchDescriptor<RecentJourney>()).count == 1)
        #expect(refreshed.id == originalID)
        #expect(refreshed.createdAt == originalDate)
        #expect(refreshed.saved)
        #expect(refreshed.originWasCurrent)
        #expect(refreshed.places.first?.coordinate == Coordinate(latitude: 0, longitude: 0))
        #expect(refreshed.places.dropFirst(2).map(\.name) == ["Coffee", "Park"])
        #expect(refreshed.budgetMinutes == 45)
        #expect(refreshed.drivingDuration == 5_100)
        #expect(refreshed.extraDuration == 1_500)
        #expect(refreshed.plannedVisits == [coffee.id: 15, park.id: 30])
    }

    @Test func photoProcessorMakesCompactSquare() async throws {
        let source = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 1_200, height: 800, bitsPerComponent: 8,
                                bytesPerRow: 0, space: source,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 800))
        let image = context.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let data = try await AvatarImageProcessor.shared.process(url)
        #expect(data.count < 1_000_000)
        let decoded = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let square = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(square.width == 512)
        #expect(square.height == 512)
    }
}
