import Foundation

// A CarPlay target can consume this value after the app receives an eligible entitlement.
// It deliberately carries one verified stop and no browsing or map controls.
struct DriverOpportunitySnapshot: Sendable {
    let placeID: String
    let title: String
    let approximateMinutesAhead: Int?
    let addedDrivingMinutes: Int

    init?(_ opportunity: JourneyOpportunity?) {
        guard let opportunity, opportunity.status == .verified || opportunity.status == .surfaced else { return nil }
        placeID = opportunity.id
        title = opportunity.place.name
        approximateMinutesAhead = opportunity.approximateMinutesAhead
        addedDrivingMinutes = Int((opportunity.incrementalDriving / 60).rounded())
    }
}
