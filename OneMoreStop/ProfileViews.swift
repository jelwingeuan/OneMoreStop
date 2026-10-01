import PhotosUI
import SwiftData
import SwiftUI
import UIKit

private struct AvatarPortrait: View {
    let profile: UserProfileRecord?
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let initials = ProfileInitials.from(profile?.displayName ?? "") {
                Text(initials).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: Circle())
        .clipShape(Circle())
        .task(id: profile?.avatarData) {
            image = profile?.avatarData.flatMap(UIImage.init(data:))
        }
    }
}

struct ProfileAvatarView: View {
    let profile: UserProfileRecord?
    let state: ProfileAvatarState
    let remaining: TimeInterval
    let original: TimeInterval
    let badgeSymbol: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AvatarPortrait(profile: profile, size: 40)
            .overlay {
                if state != .idle {
                    Circle().stroke(.orange.opacity(state == .planning ? 0.18 : 0.24), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: state == .journeyCompleted ? 1 : ProfileRing.progress(remaining: remaining, original: original))
                        .stroke(remaining <= original * 0.2 ? .red : .orange,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                                   dash: remaining <= original * 0.2 ? [3, 3] : []))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: remaining)
                }
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .bottomTrailing) {
                if let badgeSymbol, state != .idle {
                    Image(systemName: badgeSymbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 18, height: 18)
                        .background(.background, in: Circle())
                        .overlay(Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

struct ProfilePressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85),
                       value: configuration.isPressed)
    }
}

struct ProfileHubView: View {
    let profile: UserProfileRecord
    let state: AppState
    let startInEditor: Bool
    let onSaved: (SavedSection) -> Void
    let onSettings: (Bool) -> Void
    let onRepeat: (RecentJourney) -> Void
    let onViewJourney: () -> Void

    @Query(sort: \SavedPlace.savedAt, order: .reverse) private var saved: [SavedPlace]
    @Query(sort: \SavedCollection.createdAt) private var collections: [SavedCollection]
    @Query(sort: \RecentJourney.createdAt, order: .reverse) private var journeys: [RecentJourney]
    @Query private var preferences: [UserPreferenceRecord]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path = NavigationPath()
    @State private var detent: PresentationDetent = .height(250)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let route = state.route, let journey = state.journey,
                       state.completedRouteID != route.id {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            journeyCard(route: route, journey: journey, now: context.date)
                        }
                    }
                    stats
                    quickActions
                    if let latest = journeys.first { recentJourney(latest) }
                    if !saved.isEmpty { savedPreview }
                    if !collections.isEmpty { collectionsPreview }
                }
                .padding(20)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { onSettings(false) }
                }
            }
            .navigationDestination(for: ProfilePage.self) { _ in EditProfileView(profile: profile) }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(250), .medium, .large],
                             selection: $detent)
        .presentationDragIndicator(.visible)
        .task {
            if dynamicTypeSize.isAccessibilitySize { detent = .large }
            if startInEditor { openEditor() }
        }
    }

    private enum ProfilePage: Hashable { case edit }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AvatarPortrait(profile: profile, size: 78)
                .overlay(Circle().stroke(.orange.opacity(0.2), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName.isEmpty ? "Your profile" : profile.displayName)
                    .font(.title2.bold())
                if !profile.bio.isEmpty {
                    Text(profile.bio).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(TravelPersonality.title(for: preferences.first?.selectedCategoryCounts ?? [:])
                     ?? "Your travel style grows with your choices")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Edit profile", action: openEditor)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openEditor() {
        detent = .large
        path.append(ProfilePage.edit)
    }

    private func journeyCard(route: RoutePlan, journey: Journey, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(state.activeJourney ? "Active journey" : "Planning journey", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(route.origin.name) → \(route.destination.name)")
                .font(.headline).lineLimit(2)
            VStack(alignment: .leading, spacing: 4) {
                Label(TripFormatting.duration(state.profileRemainingTime(at: now)) + " Adventure Time left",
                      systemImage: "clock")
                Text("Routed driving ETA from start: \(TripFormatting.arrival(now.addingTimeInterval(journey.drivingDuration)))")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !journey.stops.isEmpty {
                Text("Stops: \(journey.stops.map(\.name).joined(separator: ", "))")
                    .font(.caption).lineLimit(2)
            }
            Button("View journey", action: onViewJourney)
                .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: DesignValues.cardRadius))
    }

    private var stats: some View {
        HStack(spacing: 18) {
            stat(saved.count, label: "Saved places")
            stat(journeys.count, label: "Planned journeys")
            stat(collections.count, label: "Collections")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func stat(_ count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count.formatted()).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var quickActions: some View {
        VStack(spacing: 0) {
            actionRow("Saved places", symbol: "bookmark", action: { onSaved(.places) })
            Divider()
            actionRow("Collections", symbol: "square.stack", action: { onSaved(.collections) })
            Divider()
            actionRow("Recent journeys", symbol: "clock.arrow.circlepath", action: { onSaved(.journeys) })
            Divider()
            actionRow("Travel preferences", symbol: "slider.horizontal.3", action: { onSettings(true) })
        }
    }

    private func actionRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentJourney(_ journey: RecentJourney) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent journey").font(.headline)
            Text("\(journey.places.first?.name ?? "Start") → \(journey.destinationName)")
                .font(.subheadline)
            Button("Repeat journey") { onRepeat(journey) }
                .font(.subheadline.weight(.semibold))
        }
    }

    private var savedPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved places").font(.headline)
            ForEach(saved.prefix(3)) { place in
                Text(place.name).font(.subheadline).lineLimit(1)
            }
            Button("See all saved places") { onSaved(.places) }
                .font(.subheadline.weight(.semibold))
        }
    }

    private var collectionsPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collections").font(.headline)
            ForEach(collections.prefix(3)) { collection in
                Text(collection.name).font(.subheadline).lineLimit(1)
            }
            Button("See collections") { onSaved(.collections) }
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct EditProfileView: View {
    let profile: UserProfileRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var bio: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoTask: Task<Void, Never>?
    @State private var photoRequestID = UUID()
    @State private var isProcessing = false
    @State private var errorMessage: String?

    init(profile: UserProfileRecord) {
        self.profile = profile
        _name = State(initialValue: profile.displayName)
        _bio = State(initialValue: profile.bio)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    AvatarPortrait(profile: profile, size: 112)
                    Spacer()
                }
                PhotosPicker(profile.avatarData == nil ? "Choose photo" : "Replace photo",
                             selection: $selectedPhoto, matching: .images)
                if profile.avatarData != nil {
                    Button("Remove photo", role: .destructive) {
                        photoTask?.cancel()
                        photoRequestID = UUID()
                        selectedPhoto = nil
                        isProcessing = false
                        let previous = profile.avatarData
                        profile.avatarData = nil
                        profile.updatedAt = .now
                        do {
                            try modelContext.save()
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } catch {
                            profile.avatarData = previous
                            errorMessage = "Couldn’t remove the photo. Try again."
                        }
                    }
                }
                if isProcessing { ProgressView("Preparing photo…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            }
            Section("About you") {
                TextField("Display name", text: $name)
                    .textContentType(.name)
                TextField("Short bio (optional)", text: $bio, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Text("Your profile photo and details stay on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    profile.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.updatedAt = .now
                    do {
                        try modelContext.save()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    } catch { errorMessage = "Couldn’t save your profile. Try again." }
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in loadPhoto(item) }
        .onDisappear { photoTask?.cancel() }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        photoTask?.cancel()
        let requestID = UUID()
        photoRequestID = requestID
        guard let item else { return }
        errorMessage = nil
        isProcessing = true
        photoTask = Task {
            do {
                guard let imported = try await item.loadTransferable(type: LocalProfilePhoto.self) else {
                    throw AvatarImageProcessor.AvatarError.invalidImage
                }
                defer { try? FileManager.default.removeItem(at: imported.url) }
                let data = try await AvatarImageProcessor.shared.process(imported.url)
                try Task.checkCancellation()
                guard photoRequestID == requestID else { return }
                let previous = profile.avatarData
                profile.avatarData = data
                profile.updatedAt = .now
                do { try modelContext.save() }
                catch { profile.avatarData = previous; throw error }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
            } catch {
                if photoRequestID == requestID {
                    errorMessage = "Couldn’t use that photo. Choose another image."
                }
            }
            if photoRequestID == requestID { isProcessing = false }
        }
    }
}
