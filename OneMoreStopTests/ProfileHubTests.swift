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
