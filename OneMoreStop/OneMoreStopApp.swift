import SwiftData
import SwiftUI

@main
struct OneMoreStopApp: App {
    var body: some Scene {
        WindowGroup { HomeView() }
            .modelContainer(for: [SavedPlace.self, RecentPlace.self, SavedCollection.self, RecentJourney.self,
                                  UserPreferenceRecord.self, IgnoredPlaceRecord.self, LocalGroupRecord.self])
    }
}
