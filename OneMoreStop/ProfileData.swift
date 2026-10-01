import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

@Model
final class UserProfileRecord {
    @Attribute(.unique) var id: String
    var displayName: String
    var bio: String
    @Attribute(.externalStorage) var avatarData: Data?
    var createdAt: Date
    var updatedAt: Date

    init(displayName: String = "", bio: String = "", avatarData: Data? = nil) {
        id = "primary"
        self.displayName = displayName
        self.bio = bio
        self.avatarData = avatarData
        createdAt = .now
        updatedAt = .now
    }
}

enum ProfileAvatarState: Equatable {
    case idle, planning, discovering, stopSelected, journeyActive, journeyCompleted

    static func resolve(hasRoute: Bool, discovering: Bool, hasStop: Bool,
                        active: Bool, completed: Bool, completionMoment: Bool) -> Self {
        if completionMoment { return .journeyCompleted }
        if completed || !hasRoute { return .idle }
        if active { return .journeyActive }
        if hasStop { return .stopSelected }
        if discovering { return .discovering }
        return .planning
    }
}

enum ProfileInitials {
    static func from(_ name: String) -> String? {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return nil }
        let characters: [Character] = words.count == 1
            ? Array(first.prefix(2))
            : [first.first, words.last?.first].compactMap { $0 }
        let value = String(characters).uppercased()
        return value.isEmpty ? nil : String(value.prefix(2))
    }
}

enum ProfileRing {
    static func progress(remaining: TimeInterval, original: TimeInterval) -> Double {
        guard original > 0 else { return 0 }
        return min(1, max(0, remaining / original))
    }
}

enum TravelPersonality {
    static func title(for counts: [String: Int]) -> String? {
        let groups: [(String, [StopCategory])] = [
            ("Scenic Explorer", [.scenic, .viewpoint, .beach]),
            ("Coffee Stopper", [.coffee, .dessert]),
            ("Food Hunter", [.food, .localFood, .nasiLemak, .mamak]),
            ("Nature Seeker", [.nature, .park, .waterfall])
        ]
        let ranked = groups.map { title, categories in
            (title, categories.reduce(0) { $0 + counts[$1.rawValue, default: 0] })
        }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first, first.1 >= 3,
              ranked.dropFirst().first?.1 != first.1 else { return nil }
        return first.0
    }
}

@MainActor
struct JourneyRecordSession {
    private var routeID: UUID?
    private var recordID: UUID?

    mutating func record(route: RoutePlan, journey: Journey, budgetMinutes: Int,
                         plannedVisits: [String: Int], saved: Bool,
                         in context: ModelContext) throws -> RecentJourney {
        if routeID == route.id, let recordID,
           let existing = try context.fetch(FetchDescriptor<RecentJourney>()).first(where: { $0.id == recordID }) {
            let wasSaved = existing.saved
            existing.saved = existing.saved || saved
            do { try context.save(); return existing }
            catch { existing.saved = wasSaved; throw error }
        }
        let record = RecentJourney(origin: route.origin, destination: route.destination,
                                   stops: journey.stops, budgetMinutes: budgetMinutes,
                                   drivingDuration: journey.drivingDuration,
                                   extraDuration: journey.extraDuration, saved: saved,
                                   plannedVisits: plannedVisits)
        context.insert(record)
        do { try context.save() }
        catch { context.delete(record); throw error }
        routeID = route.id
        recordID = record.id
        return record
    }
}

struct LocalProfilePhoto: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

actor AvatarImageProcessor {
    static let shared = AvatarImageProcessor()

    func process(_ url: URL) throws -> Data {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw AvatarError.invalidImage
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw AvatarError.invalidImage
        }
        let side = min(thumbnail.width, thumbnail.height)
        let crop = CGRect(x: (thumbnail.width - side) / 2, y: (thumbnail.height - side) / 2,
                          width: side, height: side)
        guard let square = thumbnail.cropping(to: crop),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AvatarError.invalidImage
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.draw(square, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        guard let result = context.makeImage() else { throw AvatarError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AvatarError.invalidImage
        }
        CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AvatarError.invalidImage }
        return output as Data
    }

    enum AvatarError: Error { case invalidImage }
}
