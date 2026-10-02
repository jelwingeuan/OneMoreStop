import ActivityKit
import Foundation

struct JourneyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let destination: String
        let remainingMinutes: Int
        let opportunityName: String?
        let opportunityMinutesAhead: Int?
        let opportunityDetourMinutes: Int?
        let updatedAt: Date
    }

    let routeID: String
}
