import SwiftUI

struct ActiveJourneyView: View {
    @Bindable var state: AppState
    let openMaps: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var passenger = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("View", selection: $passenger) {
                        Text("Driver").tag(false)
                        Text("Passenger").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if let route = state.route, let journey = state.journey {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Next").font(.subheadline).foregroundStyle(.secondary)
                            Text(nextPlace(route: route, journey: journey).name)
                                .font(.largeTitle.bold())
                                .minimumScaleFactor(0.7)
                            Text("\(TripFormatting.duration(journey.drivingDuration)) total routed driving")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
                        ProgressView(value: state.travelerProgress)
                            .tint(.orange)
                            .accessibilityLabel("Journey progress")
                            .accessibilityValue("About \(Int(state.travelerProgress * 100)) percent")
                        if let message = state.activeMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.orange)
                        }
                        Button {
                            openMaps()
                        } label: {
                            Label(state.openedLegCount == 0 ? "Open next leg in Apple Maps" : "Continue to next stop",
                                  systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(state.openedLegCount >= journey.legs.count)
                        Text("Apple Maps handles directions one leg at a time. Return here to continue.")
                            .font(.caption).foregroundStyle(.secondary)
                        if passenger {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Verified opportunities").font(.headline)
                                ForEach(state.recommendations.prefix(4)) { item in
                                    HStack {
                                        Image(systemName: item.place.category?.symbol ?? "mappin")
                                        Text(item.place.name).lineLimit(1)
                                        Spacer()
                                        Text(TripFormatting.extraTime(item.incrementalDetourTime))
                                    }
                                    .font(.subheadline)
                                }
                                if state.recommendations.isEmpty {
                                    Text("No verified stop fits the current time budget.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Button("Refresh location and opportunities") {
                                    Task { await state.refreshTravelerProgress() }
                                }
                            }
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Active journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("End") { state.endActiveJourney(); dismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while state.activeJourney && !Task.isCancelled {
                await state.refreshTravelerProgress()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func nextPlace(route: RoutePlan, journey: Journey) -> Place {
        let endpoints = journey.stops + [route.destination]
        return endpoints[min(state.openedLegCount, endpoints.count - 1)]
    }
}
