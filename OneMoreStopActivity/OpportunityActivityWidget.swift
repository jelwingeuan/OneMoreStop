import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OpportunityActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JourneyActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text("OneMoreStop · \(context.state.destination)")
                    .font(.headline).lineLimit(1)
                Text("\(context.state.remainingMinutes) min extra driving left")
                    .font(.subheadline)
                if let name = context.state.opportunityName {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let minutes = context.state.opportunityMinutesAhead,
                       let detour = context.state.opportunityDetourMinutes {
                        Text("About \(minutes) min ahead · +\(detour) min driving")
                            .font(.caption)
                    }
                } else {
                    Text("No verified opportunity ahead yet").font(.caption)
                }
                Text("Last checked \(context.state.updatedAt, style: .time)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("OneMoreStop").font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.remainingMinutes) min").font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.opportunityName ?? "Keep driving")
                        .font(.subheadline).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "mappin.and.ellipse")
            } compactTrailing: {
                Text("\(context.state.remainingMinutes)m")
            } minimal: {
                Image(systemName: "mappin.and.ellipse")
            }
        }
    }
}
