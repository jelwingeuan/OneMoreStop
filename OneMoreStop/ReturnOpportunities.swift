import Foundation
import SwiftData

@Model
final class ReturnOpportunityRecord {
    @Attribute(.unique) var id: String
    var placeData: Data
    var originData: Data?
    var destinationData: Data
    var originalDetourSeconds: Double
    var reasonsData: Data
    var savedAt: Date

    init(opportunity: JourneyOpportunity, route: RoutePlan) {
        id = opportunity.id
        placeData = (try? JSONEncoder().encode(opportunity.place)) ?? Data()
        originData = route.origin.id == "current-origin" ? nil : try? JSONEncoder().encode(PlaceSnapshot(route.origin))
        destinationData = (try? JSONEncoder().encode(PlaceSnapshot(route.destination))) ?? Data()
        originalDetourSeconds = opportunity.totalDetour
        reasonsData = (try? JSONEncoder().encode(opportunity.reasons)) ?? Data()
        savedAt = .now
    }

    init(recommendation: StopRecommendation, route: RoutePlan) {
        id = recommendation.id
        placeData = (try? JSONEncoder().encode(PlaceSnapshot(recommendation.place))) ?? Data()
        originData = route.origin.id == "current-origin" ? nil : try? JSONEncoder().encode(PlaceSnapshot(route.origin))
        destinationData = (try? JSONEncoder().encode(PlaceSnapshot(route.destination))) ?? Data()
        originalDetourSeconds = recommendation.detourTime
        reasonsData = (try? JSONEncoder().encode(recommendation.reasons.map(\.text))) ?? Data()
        savedAt = .now
    }

    func update(opportunity: JourneyOpportunity, route: RoutePlan) {
        placeData = (try? JSONEncoder().encode(opportunity.place)) ?? placeData
        originData = route.origin.id == "current-origin" ? nil : try? JSONEncoder().encode(PlaceSnapshot(route.origin))
        destinationData = (try? JSONEncoder().encode(PlaceSnapshot(route.destination))) ?? destinationData
        originalDetourSeconds = opportunity.totalDetour
        reasonsData = (try? JSONEncoder().encode(opportunity.reasons)) ?? reasonsData
        savedAt = .now
    }

    func update(recommendation: StopRecommendation, route: RoutePlan) {
        placeData = (try? JSONEncoder().encode(PlaceSnapshot(recommendation.place))) ?? placeData
        originData = route.origin.id == "current-origin" ? nil : try? JSONEncoder().encode(PlaceSnapshot(route.origin))
        destinationData = (try? JSONEncoder().encode(PlaceSnapshot(route.destination))) ?? destinationData
        originalDetourSeconds = recommendation.detourTime
        reasonsData = (try? JSONEncoder().encode(recommendation.reasons.map(\.text))) ?? reasonsData
        savedAt = .now
    }

    var snapshot: SavedReturnOpportunity? {
        guard let place = try? JSONDecoder().decode(PlaceSnapshot.self, from: placeData),
              let destination = try? JSONDecoder().decode(PlaceSnapshot.self, from: destinationData) else { return nil }
        return SavedReturnOpportunity(place: place,
            origin: originData.flatMap { try? JSONDecoder().decode(PlaceSnapshot.self, from: $0) },
            destination: destination, originalDetourSeconds: originalDetourSeconds,
            reasons: (try? JSONDecoder().decode([String].self, from: reasonsData)) ?? [], savedAt: savedAt)
    }
}

struct SavedReturnOpportunity: Sendable {
    let place: PlaceSnapshot
    let origin: PlaceSnapshot?
    let destination: PlaceSnapshot
    let originalDetourSeconds: Double
    let reasons: [String]
    let savedAt: Date
}

enum ReturnTripMatcher {
    static func candidates(_ saved: [SavedReturnOpportunity], route: RoutePlan,
                           journey: Journey, travelerProgress: Double) -> [Place] {
        saved.compactMap { item in
            let place = item.place.place
            guard !journey.stops.contains(where: { $0.id == place.id }) else { return nil }
            let projection = GeoMath.routeProximity(place.coordinate, path: journey.path)
            let reversedStart = GeoMath.distance(route.origin.coordinate, item.destination.coordinate) < 30_000
            let reversedEnd = item.origin.map { GeoMath.distance(route.destination.coordinate, $0.coordinate) < 30_000 } ?? true
            let sameDirection = item.origin.map { GeoMath.distance(route.origin.coordinate, $0.coordinate) < 30_000 } ?? false
            guard (reversedStart && reversedEnd || sameDirection),
                  projection.distance < 10_000,
                  projection.progress + 0.02 >= travelerProgress else { return nil }
            return place
        }
    }
}
