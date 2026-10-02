import Foundation
import SwiftUI

struct JourneyRecap: Sendable {
    let destination: String
    let selectedStops: [String]
    let routedDistance: Double
    let routedDriving: TimeInterval
    let extraDrivingUsed: TimeInterval
    let originalAllowance: TimeInterval
    let skippedOpportunities: Int
    let savedForReturn: Int
}

struct JourneyRecapView: View {
    let recap: JourneyRecap
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Planned journey") {
                    LabeledContent("Destination", value: recap.destination)
                    LabeledContent("Routed distance", value: TripFormatting.distance(recap.routedDistance))
                    LabeledContent("Routed driving", value: TripFormatting.duration(recap.routedDriving))
                }
                Section("Adventure Time") {
                    Text("\(TripFormatting.duration(recap.extraDrivingUsed)) of \(TripFormatting.duration(recap.originalAllowance)) extra driving used")
                    Text("Only driving time is counted. Selected visits are separate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Choices") {
                    LabeledContent("Selected stops", value: "\(recap.selectedStops.count)")
                    ForEach(recap.selectedStops, id: \.self) { Text($0) }
                    LabeledContent("Opportunities skipped", value: "\(recap.skippedOpportunities)")
                    LabeledContent("Saved for return", value: "\(recap.savedForReturn)")
                }
                Text("This is a record of your plan and app choices, not proof of places visited.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Journey recap")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
