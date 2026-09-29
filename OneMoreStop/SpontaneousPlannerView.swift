import SwiftUI

struct SpontaneousPlannerView: View {
    @Bindable var state: AppState
    let initialKind: SpontaneousKind
    let chooseOrigin: () -> Void
    let openMaps: () -> Void

    @State private var kind: SpontaneousKind = .driveUntil
    @State private var minutes = 60
    @State private var mode: DiscoveryMode = .scenic
    @State private var returnsHome = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose a drive time. Each suggestion is checked against a driving route before it appears.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker("Plan", selection: $kind) {
                        ForEach(SpontaneousKind.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    if kind == .driveUntil {
                        Toggle("Return to start", isOn: $returnsHome)
                    } else {
                        Text("Escape Mode includes the drive back to your start.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Driving time", selection: $minutes) {
                        ForEach(kind == .escape ? [60, 90, 120, 180, 240] : [30, 45, 60, 90, 120], id: \.self) {
                            Text("\($0) min").tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Find", selection: $mode) {
                        ForEach([DiscoveryMode.scenic, .nature, .eat, .coffee, .thingsToDo, .explore], id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    if let origin = state.origin {
                        Label("From \(origin.name)", systemImage: "location.fill")
                            .font(.subheadline)
                    } else {
                        Button("Choose a starting place", action: chooseOrigin)
                    }
                    Button {
                        state.findSpontaneous(kind: kind, minutes: minutes, mode: mode,
                                              returnsHome: kind == .escape || returnsHome)
                    } label: {
                        Label("Find routed outings", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(state.origin == nil || state.spontaneousBusy)
                    if state.spontaneousBusy { ProgressView("Checking driving routes…") }
                    if let message = state.spontaneousMessage {
                        ContentUnavailableView(message, systemImage: "map")
                    }
                    ForEach(state.spontaneousSuggestions) { plan in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(plan.stops.map(\.name).joined(separator: " → ")).font(.headline)
                            if let address = plan.place.address {
                                Text(address).font(.caption).foregroundStyle(.secondary)
                            }
                            Label("\(TripFormatting.duration(plan.drivingDuration)) routed driving\(plan.returnsHome ? " round trip" : " one way")", systemImage: "car.fill")
                                .font(.subheadline)
                            Button("Choose this outing") { state.selectSpontaneous(plan) }
                                .buttonStyle(.bordered)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
                    }
                    if let plan = state.spontaneousPlan {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Selected outing: \(plan.stops.map(\.name).joined(separator: " → "))")
                                .font(.headline)
                            Text("Apple Maps opens one driving leg at a time. Return here to continue.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(state.spontaneousOpenedLegCount == 0 ? "Open in Apple Maps" : "Continue to next leg",
                                   action: openMaps)
                                .buttonStyle(.borderedProminent)
                                .disabled(state.spontaneousOpenedLegCount >= plan.legs.count)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Explore by time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onAppear { kind = initialKind; if initialKind == .escape { returnsHome = true } }
        .onChange(of: kind) { _, value in
            if value == .escape { returnsHome = true }
        }
    }
}
