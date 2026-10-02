// ActivityKit owns the Activity instance and serializes its async updates. Remove this
// compatibility import when the SDK marks Activity as Sendable.
@preconcurrency import ActivityKit
import Foundation

@MainActor
protocol LiveActivityProviding {
    var isRunning: Bool { get }
    func start(routeID: UUID, content: JourneyActivityAttributes.ContentState) async
    func update(_ content: JourneyActivityAttributes.ContentState) async
    func end() async
}

@MainActor
final class LiveOpportunityProvider: LiveActivityProviding {
    private var activity: Activity<JourneyActivityAttributes>?
    private var lastContent: JourneyActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var isRunning: Bool { activity != nil }

    func start(routeID: UUID, content: JourneyActivityAttributes.ContentState) async {
        guard isAvailable else { return }
        await end()
        do {
            activity = try Activity.request(attributes: JourneyActivityAttributes(routeID: routeID.uuidString),
                                            content: ActivityContent(state: content, staleDate: nil),
                                            pushType: nil)
            lastContent = content
            lastUpdate = .now
        } catch { activity = nil }
    }

    func update(_ content: JourneyActivityAttributes.ContentState) async {
        guard let activity else { return }
        let changed = lastContent?.opportunityName != content.opportunityName ||
            lastContent?.opportunityDetourMinutes != content.opportunityDetourMinutes ||
            abs((lastContent?.remainingMinutes ?? content.remainingMinutes) - content.remainingMinutes) >= 5
        guard changed, Date.now.timeIntervalSince(lastUpdate) >= 60 else { return }
        await activity.update(ActivityContent(state: content, staleDate: nil))
        lastContent = content
        lastUpdate = .now
    }

    func end() async {
        let active = activity
        activity = nil
        lastContent = nil
        if let active {
            await active.end(nil, dismissalPolicy: .immediate)
        }
    }
}
