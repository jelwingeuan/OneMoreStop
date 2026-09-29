import Foundation
import MapKit
import SwiftData

struct Coordinate: Hashable, Codable, Sendable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

struct Place: Identifiable, Hashable, Sendable {
    let id: String
    let mapKitIdentifier: String?
    let name: String
    let address: String?
    let coordinate: Coordinate
    let category: StopCategory?
    let phone: String?
    let website: URL?

    init(item: MKMapItem, category: StopCategory? = nil) {
        let coordinate = Coordinate(item.placemark.coordinate)
        self.coordinate = coordinate
        mapKitIdentifier = item.identifier?.rawValue
        name = item.name ?? "Unnamed place"
        address = item.placemark.title
        self.category = category
        phone = item.phoneNumber
        website = item.url
        id = Self.key(identifier: item.identifier?.rawValue, name: item.name ?? "", coordinate: coordinate)
    }

    init(id: String, mapKitIdentifier: String? = nil, name: String, address: String? = nil, coordinate: Coordinate, category: StopCategory? = nil, phone: String? = nil, website: URL? = nil) {
        self.id = id
        self.mapKitIdentifier = mapKitIdentifier
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.category = category
        self.phone = phone
        self.website = website
    }

    static func key(identifier: String?, name: String, coordinate: Coordinate) -> String {
        if let identifier { return "mapkit:\(identifier)" }
        let normalized = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        return "fallback:\(normalized):\(Int((coordinate.latitude * 10_000).rounded())):\(Int((coordinate.longitude * 10_000).rounded()))"
    }

    func mapItem() -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.clLocation))
        item.name = name
        return item
    }
}

enum StopCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case food, coffee, scenic, nature, attractions, park, shopping, dessert, fuel, restStop
    case localFood, nasiLemak, mamak, restArea, surau, beach, waterfall, viewpoint, charging
    case atm, pharmacy, groceries

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restStop: "Rest stop"
        case .localFood: "Local food"
        case .nasiLemak: "Nasi lemak"
        case .restArea: "R&R"
        case .surau: "Surau / mosque"
        case .charging: "EV charging"
        case .atm: "ATM"
        case .pharmacy: "Pharmacy"
        case .groceries: "Groceries"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .food, .localFood, .nasiLemak, .mamak: "fork.knife"
        case .coffee: "cup.and.saucer.fill"
        case .scenic, .viewpoint: "mountain.2.fill"
        case .nature, .waterfall: "leaf.fill"
        case .attractions: "sparkles"
        case .park: "tree.fill"
        case .shopping: "bag.fill"
        case .dessert: "birthday.cake.fill"
        case .fuel: "fuelpump.fill"
        case .restStop, .restArea: "car.side.fill"
        case .surau: "building.columns.fill"
        case .beach: "water.waves"
        case .charging: "bolt.car.fill"
        case .atm: "banknote.fill"
        case .pharmacy: "cross.case.fill"
        case .groceries: "basket.fill"
        }
    }

    var suggestedVisitMinutes: Int? {
        switch self {
        case .coffee, .dessert, .restStop, .restArea, .fuel, .charging, .surau, .atm, .pharmacy: 15
        case .food, .localFood, .nasiLemak, .mamak: 30
        case .park, .nature, .scenic, .viewpoint, .beach, .waterfall: 45
        case .attractions, .shopping, .groceries: 60
        }
    }
}

enum DiscoveryMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case eat, coffee, nature, scenic, thingsToDo, explore, shopping, useful, restStop, ev, microAdventure, zeroRegret, surpriseMe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thingsToDo: "Things to Do"
        case .surpriseMe: "Surprise Me"
        case .restStop: "Rest Stop"
        case .ev: "EV"
        case .microAdventure: "Micro Adventure"
        case .zeroRegret: "Zero Regret"
        default: rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .eat: "fork.knife"
        case .coffee: "cup.and.saucer.fill"
        case .nature: "leaf.fill"
        case .scenic: "mountain.2.fill"
        case .thingsToDo: "sparkles"
        case .explore: "map.fill"
        case .shopping: "bag.fill"
        case .useful: "car.side.fill"
        case .restStop: "car.side.rear.open.fill"
        case .ev: "bolt.car.fill"
        case .microAdventure: "figure.walk"
        case .zeroRegret: "checkmark.seal.fill"
        case .surpriseMe: "shuffle"
        }
    }
    func categories(isMalaysia: Bool, localFirst: Bool, evJourney: Bool, adventure: Bool,
                    mood: DiscoveryMood = .any) -> [StopCategory] {
        let choices: [StopCategory]
        switch self {
        case .eat: choices = isMalaysia ? (localFirst ? [.localFood, .mamak, .food] : [.food, .localFood, .mamak]) : [.food, .coffee]
        case .coffee: choices = [.coffee, .dessert]
        case .nature: choices = [.park, .nature, .waterfall]
        case .scenic: choices = [.scenic, .viewpoint, .beach]
        case .thingsToDo: choices = [.attractions, .shopping]
        case .explore: choices = adventure ? [.nature, .scenic, isMalaysia ? .localFood : .food, .attractions] : [.attractions, .park, .food]
        case .shopping: choices = [.shopping, .groceries]
        case .useful: choices = evJourney ? [isMalaysia ? .restArea : .restStop, .fuel, .charging, isMalaysia ? .surau : .coffee] :
                [isMalaysia ? .restArea : .restStop, .fuel, isMalaysia ? .surau : .coffee]
        case .restStop: choices = [isMalaysia ? .restArea : .restStop, .fuel, isMalaysia ? .surau : .coffee]
        case .ev: choices = [.charging]
        case .microAdventure: choices = [.viewpoint, .park, isMalaysia ? .localFood : .food, .coffee, .attractions]
        case .zeroRegret: choices = [.coffee, .fuel, isMalaysia ? .restArea : .restStop, .food]
        case .surpriseMe: choices = adventure ? [.nature, .scenic, isMalaysia ? .localFood : .food, .attractions, .coffee] : [.food, .coffee, .park, .attractions, .scenic]
        }
        let preferred: [StopCategory]
        switch mood {
        case .any: preferred = []
        case .calm: preferred = [.park, .nature, .scenic, .beach]
        case .curious: preferred = [.attractions, .viewpoint, .waterfall]
        case .hungry: preferred = [.food, .localFood, .mamak, .coffee]
        case .stretch: preferred = [.park, .nature, .restArea, .restStop]
        case .adventure: preferred = [.waterfall, .viewpoint, .attractions, .nature]
        }
        return choices.enumerated().sorted { left, right in
            let leftMatch = preferred.contains(left.element)
            let rightMatch = preferred.contains(right.element)
            return leftMatch == rightMatch ? left.offset < right.offset : leftMatch
        }.map(\.element)
    }
}

enum DiscoveryMood: String, CaseIterable, Identifiable, Codable, Sendable {
    case any, calm, curious, hungry, stretch, adventure
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct RouteMetrics: Sendable {
    let duration: TimeInterval
    let distance: CLLocationDistance
    let path: [Coordinate]
}

struct RoutePlan: Identifiable, Sendable {
    let id: UUID
    let origin: Place
    let destination: Place
    let baseline: RouteMetrics
    let createdAt: Date
    let options: [RouteMetrics]

    init(id: UUID, origin: Place, destination: Place, baseline: RouteMetrics,
         createdAt: Date, options: [RouteMetrics] = []) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.baseline = baseline
        self.createdAt = createdAt
        self.options = options
    }
}

struct StopRecommendation: Identifiable, Sendable {
    let place: Place
    let detourTime: TimeInterval
    let detourDistance: CLLocationDistance
    let distanceFromRoute: CLLocationDistance
    let progress: Double
    let score: Double
    let firstLeg: RouteMetrics
    let secondLeg: RouteMetrics
    var insertionIndex = 0
    var incrementalDetourTime: TimeInterval = 0
    var needs: Set<JourneyNeed> = []
    var reasons: [RecommendationReason] = []
    var confidence: OpportunityConfidence = .routingVerified

    var id: String { place.id }
}

struct Journey: Sendable {
    let stops: [Place]
    let legs: [RouteMetrics]
    let baseline: RouteMetrics

    var drivingDuration: TimeInterval { legs.reduce(0) { $0 + $1.duration } }
    var drivingDistance: CLLocationDistance { legs.reduce(0) { $0 + $1.distance } }
    var extraDuration: TimeInterval { DetourMath.extra(drivingDuration, 0, baseline: baseline.duration) }
    var extraDistance: CLLocationDistance { DetourMath.extra(drivingDistance, 0, baseline: baseline.distance) }
    var path: [Coordinate] { legs.flatMap(\.path) }
}

struct RouteProgress: Sendable {
    let fraction: Double
    let distanceFromRoute: CLLocationDistance
    let distanceAlongRoute: CLLocationDistance
    let distanceRemaining: CLLocationDistance

    var isOnRoute: Bool { distanceFromRoute < 2_000 }
    func isAhead(_ candidateFraction: Double) -> Bool { candidateFraction + 0.02 >= fraction }
}

struct PlaceSnapshot: Codable, Sendable {
    let identifier: String?
    let name: String
    let address: String?
    let coordinate: Coordinate
    let categoryRawValue: String?

    init(_ place: Place) {
        identifier = place.mapKitIdentifier
        name = place.name
        address = place.address
        coordinate = place.coordinate
        categoryRawValue = place.category?.rawValue
    }
    var place: Place {
        Place(id: Place.key(identifier: identifier, name: name, coordinate: coordinate),
              mapKitIdentifier: identifier, name: name, address: address, coordinate: coordinate,
              category: categoryRawValue.flatMap(StopCategory.init(rawValue:)))
    }
}

enum DiscoveryPhase: Equatable {
    case idle, findingRoute, discoveringPlaces, calculatingDetours, loaded, noResults, failed(String)
}

@Model
final class SavedPlace {
    @Attribute(.unique) var id: String
    var mapKitIdentifier: String?
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var categoryRawValue: String?
    var savedAt: Date

    init(_ place: Place) {
        id = place.id
        mapKitIdentifier = place.mapKitIdentifier
        name = place.name
        address = place.address
        latitude = place.coordinate.latitude
        longitude = place.coordinate.longitude
        categoryRawValue = place.category?.rawValue
        savedAt = .now
    }

    var place: Place {
        Place(id: id, mapKitIdentifier: mapKitIdentifier, name: name, address: address,
              coordinate: Coordinate(latitude: latitude, longitude: longitude),
              category: categoryRawValue.flatMap(StopCategory.init(rawValue:)))
    }
}

@Model
final class RecentPlace {
    var id: UUID
    var kind: String
    var name: String
    var mapKitIdentifier: String?
    var address: String?
    var latitude: Double
    var longitude: Double
    var usedAt: Date

    init(_ place: Place, kind: String) {
        id = UUID()
        self.kind = kind
        name = place.name
        mapKitIdentifier = place.mapKitIdentifier
        address = place.address
        latitude = place.coordinate.latitude
        longitude = place.coordinate.longitude
        usedAt = .now
    }

    var place: Place {
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        return Place(id: Place.key(identifier: mapKitIdentifier, name: name, coordinate: coordinate),
                     mapKitIdentifier: mapKitIdentifier, name: name, address: address, coordinate: coordinate)
    }
}

@Model
final class SavedCollection {
    var id: UUID
    var name: String
    var placeIDs: [String]
    var createdAt: Date

    init(name: String) {
        id = UUID()
        self.name = name
        placeIDs = []
        createdAt = .now
    }
}

@Model
final class RecentJourney {
    var id: UUID
    var destinationName: String
    var snapshotData: Data
    var originWasCurrent: Bool
    var budgetMinutes: Int
    var drivingDuration: Double
    var extraDuration: Double
    var createdAt: Date
    var saved: Bool
    var plannedVisitsData: Data?

    init(origin: Place, destination: Place, stops: [Place], budgetMinutes: Int,
         drivingDuration: Double, extraDuration: Double, saved: Bool = false,
         plannedVisits: [String: Int] = [:]) {
        id = UUID()
        destinationName = destination.name
        let storedOrigin = origin.id == "current-origin"
            ? Place(id: "current-origin", name: "Current Location", coordinate: Coordinate(latitude: 0, longitude: 0))
            : origin
        let places = [storedOrigin, destination] + stops
        snapshotData = (try? JSONEncoder().encode(places.map(PlaceSnapshot.init))) ?? Data()
        originWasCurrent = origin.id == "current-origin"
        self.budgetMinutes = budgetMinutes
        self.drivingDuration = drivingDuration
        self.extraDuration = extraDuration
        createdAt = .now
        self.saved = saved
        plannedVisitsData = try? JSONEncoder().encode(plannedVisits)
    }

    var places: [Place] { ((try? JSONDecoder().decode([PlaceSnapshot].self, from: snapshotData)) ?? []).map(\.place) }
    var plannedVisits: [String: Int] {
        guard let plannedVisitsData else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: plannedVisitsData)) ?? [:]
    }
}
