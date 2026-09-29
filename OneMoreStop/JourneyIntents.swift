import AppIntents
import Foundation

private enum IntentNavigation {
    static func request(_ action: String) {
        UserDefaults.standard.set(action, forKey: "pendingJourneyAction")
    }
}

struct FindCoffeeStopsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find coffee on my route"
    static let description = IntentDescription("Open coffee discovery in OneMoreStop.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        IntentNavigation.request("coffee")
        return .result()
    }
}

struct FindFoodStopsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find food on my route"
    static let description = IntentDescription("Open food discovery in OneMoreStop.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        IntentNavigation.request("eat")
        return .result()
    }
}

struct FindScenicStopsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find scenic stops on my route"
    static let description = IntentDescription("Open scenic discovery in OneMoreStop.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        IntentNavigation.request("scenic")
        return .result()
    }
}

struct FindChargingStopsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find EV charging stops"
    static let description = IntentDescription("Open EV charging discovery in OneMoreStop. Charger status is not available.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        IntentNavigation.request("ev")
        return .result()
    }
}

struct OpenSavedJourneysIntent: AppIntent {
    static let title: LocalizedStringResource = "Open saved journeys"
    static let description = IntentDescription("Open saved routes to choose one to repeat.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        IntentNavigation.request("saved")
        return .result()
    }
}
