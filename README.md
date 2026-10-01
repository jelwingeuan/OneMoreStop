# OneMoreStop

OneMoreStop finds places along a drive that fit a driving-time budget. It is a native iPhone app for iOS 18 and later. It uses SwiftUI, MapKit, CoreLocation, SwiftData, App Intents, and Swift concurrency. There is no backend, account, API key, or third-party dependency.

## Build and run

Open `OneMoreStop.xcodeproj` with Xcode 27 or later and run the OneMoreStop scheme on an iPhone or simulator. MapKit search and automobile directions need network access and regional coverage. The project uses Swift 6 and complete strict concurrency checking.

```sh
xcodebuild -project OneMoreStop.xcodeproj -scheme OneMoreStop \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For tests, select an available iPhone simulator and run:

```sh
xcodebuild -project OneMoreStop.xcodeproj -scheme OneMoreStop \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

## Use

Choose Current Location or search for a starting place, then search for a destination. The map fits the direct automobile route until you move it. **I can spare** limits extra driving time. **Arrive By** calculates the remaining driving allowance from the deadline, the direct route, and only visit minutes you explicitly plan. The clock refreshes while the journey sheet is visible. Driving arrival and arrival with planned visits have separate labels. Suggested visits do not silently count toward the deadline.

Modes include Eat, Coffee, Nature, Scenic, Things to Do, Explore, Shopping, Useful, Rest Stop, EV, Micro Adventure, Zero Regret, and Surprise Me. Needs and moods can refine discovery. The Adventure preset is 60 minutes; saved 90-minute journeys still load. EV Journey adds charging searches in Useful, without promising charger availability.

Recommendation cards show MapKit place information, measured incremental and total detour driving time, and reasons based on route geometry or a matched place category. Surprise Me highlights one verified result at a time. "Better option ahead" compares two routed results serving the same need. Add up to three stops. Nearby complementary places may appear as a routed two-location combination; accepting one requires the complete proposed journey to fit the budget. Drag stops to reorder, or remove or replace one. "Not interested" hides a result; "Don't suggest again" keeps that place in a local ignore list that can be reset in Settings.

Drive Until finds a one-way destination or routed return outing within the chosen total driving time. Escape Mode checks return drives with one or two stops. These are separate from the extra-detour budget of destination journeys. An explicitly started active journey offers a minimal driver view, a passenger opportunity view, and foreground location checks. Apple Maps remains responsible for navigation.

Local group voting stores named participants and one current vote per participant on this device. Its share action sends a static snapshot, not a live ballot. Search-density circles show places found in successful corridor searches for the selected mode; areas without circles are not guaranteed to lack places. The optional alternate-route comparison makes up to four bounded searches per route and shows found-place counts, not a route rating or full inventory.

**Open in Apple Maps** opens the first driving leg. Return to OneMoreStop and use **Continue to next stop** for the next leg. Apple Maps' [documented driving launch](https://developer.apple.com/documentation/mapkit/mkmapitem/openmaps%28with%3Alaunchoptions%3A%29) accepts at most two map items, so the handoff is intentionally one leg at a time.

Saved contains favorites, custom collections, recent stops, recent journeys, and planning milestones. Finish a journey to keep a local summary, with an optional saved marker. Repeat a journey to reroute it. Journey sharing requires an intentional Share action and previews the route's endpoints and stops. Place details offer available phone, website, and Look Around fields, plus ShareLink to an Apple Maps place URL. App Intents open food, coffee, scenic, EV, or saved-journey flows in the app.

The Explore avatar opens a profile hub for the current route, recent plans, saved places, collections, and travel preferences. A route is labeled planning until active mode begins. **End active mode** stops live progress; **Complete journey** records one recent journey for that route. Reopening its summary updates the existing record. Profile name, bio, and optional photo stay on device. PhotosPicker gives the app only the selected image, which is oriented, center cropped, and stored as a compact avatar; no Photos library permission or upload is used.

## How discovery works

`AppState` owns main-actor UI and journey state. `LocationService`, `MapSearchService`, and `DirectionsService` own framework requests. `RouteCorridorService` samples the routed path by distance and sends a bounded MapKit search near each sample. It rotates through structured POI categories and natural-language queries for the selected mode. Regional choices include Malaysian local food, mamak, R&R, and surau searches. Search results are deduplicated by MapKit identifier or normalized name and approximate coordinate.

`DetourEngine` cheaply projects candidates onto the route, finds the nearest current journey leg, and routes only a bounded shortlist. Each candidate replaces one leg with two actual automobile legs. Its displayed detour is **new journey driving duration minus the direct route duration**, clamped to zero for small routing discrepancies. Ranking is deterministic: mode and mood match, added driving time, proximity, and ahead/behind progress. A passed stop is penalized unless the user has moved the map to explore an area. Verified cards appear after each batch, then settle into score order.

Search and directions work in batches of at most three. A shared gate limits simultaneous autocomplete, search, directions, and Look Around requests to three. A short-lived in-memory cache suppresses duplicate searches and routed legs. Narrower budgets filter previously verified results immediately; a wider budget searches a larger corridor. Cancellation stops obsolete requests after route, mode, or budget changes. Tuning values live in `DiscoveryTuning`.

`SwiftData` stores simple place, journey, profile, preference, ignored-place, and local-group values. MapKit objects are transient. A journey records manually selected endpoints and stops; when Current Location was used, its exact coordinate is replaced by a placeholder before saving, and a repeat asks CoreLocation for a fresh position. Previous app preferences in UserDefaults are copied into SwiftData on first launch. The profile model is additive, so existing saved records remain available.

## Permissions and accessibility

The app explains location use before its contextual When In Use permission request. Manual origin search works after denial. Location is used to start and update route progress; no precise location trail is saved. The app uses adaptive system materials and type, VoiceOver labels on controls and pins, light and dark appearances, a high-contrast-friendly system palette, and reduced-motion-aware map focus animation. iOS 26 glass APIs are availability-gated; iOS 18 uses material backgrounds.

## Verification and limits

Offline tests cover distance sampling, deduplication, detour math (60 minutes direct; 35 + 37 minutes through a stop; 12 minutes extra), deadlines, planned visits, budgets, deterministic ranking, route projection and ahead comparison, needs, combinations, spontaneous driving time, group votes, planning milestones, units, and persistence mapping. Profile tests cover Unicode initials, state precedence, both budget rings, image processing, completion deduplication, personality thresholds, and migration beside existing records. UI tests exercise Explore, the profile shortcuts, Saved, Settings, denied location, a Cyberjaya-to-Melaka drive through a verified stop and Maps handoff, a California route, an unroutable drive with retry, and the Drive Until/Escape controls. Live results vary by network and MapKit coverage; retry and no-results states are provided.

MapKit may not return a useful stop or driving route for every place. OneMoreStop does not invent ratings, hours, ownership, toilets, price, weather, charger availability or specifications, or turn-by-turn navigation. A weather-provider interface exists but no source is configured, so weather and sunset features are hidden. Journey order is chosen by the user; it is not optimized automatically. Very long routes can miss places between bounded sample areas. There is no remote voting, community data, or account sync. Simulator checks for network disconnection, empty search, in-flight cancellation timing, absent Look Around coverage, VoiceOver speech, and reduced motion still need manual release QA.

## Roadmap

Possible later work includes explicit charger metadata from a reliable provider, weather context with entitlement, richer visit-duration guidance, shared journeys, and CarPlay. Those integrations should be added only when the data and product need are clear.
