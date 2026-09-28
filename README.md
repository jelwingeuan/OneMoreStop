# OneMoreStop

OneMoreStop finds places along a drive that fit an **extra driving time** budget. It is a native iPhone app for iOS 18 and later. It uses SwiftUI, MapKit, CoreLocation, SwiftData, and Swift concurrency. There is no backend, account, API key, or third-party dependency.

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

Choose Current Location or search for a starting place, then search for a destination. The map fits the direct automobile route until you move it. Select a stepped **I can spare** budget, a preset, and a mode: Eat, Coffee, Nature, Scenic, Things to Do, Explore, Useful, or Surprise Me. Optional mood and local-place preferences affect the search and order. The Adventure preset uses a 90-minute budget. EV Journey adds charging searches in Useful, without promising charger availability.

Recommendation cards show only MapKit place information and measured extra driving time. Surprise Me highlights one verified result at a time and can show the other results. Add up to three stops. Drag the stops in the timeline to reorder them, or remove or replace one. The journey is rerouted after each edit. The total added driving time must fit the budget. Arrival estimates include driving time only. The timeline offers optional, category-based visit-time suggestions for planning; these are not MapKit place facts and are excluded from driving ETA.

**Open in Apple Maps** opens the first driving leg. Return to OneMoreStop and use **Continue to next stop** for the next leg. Apple Maps' [documented driving launch](https://developer.apple.com/documentation/mapkit/mkmapitem/openmaps%28with%3Alaunchoptions%3A%29) accepts at most two map items, so the handoff is intentionally one leg at a time.

Saved contains favorites, custom collections, recent stops, and recent journeys. Finish a journey to keep a local summary, with an optional saved marker. Repeat a journey to reroute it. Place details offer available phone, website, and Look Around fields, plus ShareLink to an Apple Maps place URL.

## How discovery works

`AppState` owns main-actor UI and journey state. `LocationService`, `MapSearchService`, and `DirectionsService` own framework requests. `RouteCorridorService` samples the routed path by distance and sends a bounded MapKit search near each sample. It rotates through structured POI categories and natural-language queries for the selected mode. Regional choices include Malaysian local food, mamak, R&R, and surau searches. Search results are deduplicated by MapKit identifier or normalized name and approximate coordinate.

`DetourEngine` cheaply projects candidates onto the route, finds the nearest current journey leg, and routes only a bounded shortlist. Each candidate replaces one leg with two actual automobile legs. Its displayed detour is **new journey driving duration minus the direct route duration**, clamped to zero for small routing discrepancies. Ranking is deterministic: mode and mood match, added driving time, proximity, and ahead/behind progress. A passed stop is penalized unless the user has moved the map to explore an area. Verified cards appear after each batch, then settle into score order.

Search and directions work in batches of at most three. A short-lived in-memory cache suppresses duplicate searches and routed legs. Narrower budgets filter previously verified results immediately; a wider budget searches a larger corridor. Cancellation stops obsolete requests after route, mode, or budget changes. Tuning values live in `DiscoveryTuning`.

`SwiftData` stores simple place and journey values. MapKit objects are transient. A journey records manually selected endpoints and stops; when Current Location was used, its exact coordinate is replaced by a placeholder before saving, and a repeat asks CoreLocation for a fresh position.

## Permissions and accessibility

The app explains location use before its contextual When In Use permission request. Manual origin search works after denial. Location is used to start and update route progress; no precise location trail is saved. The app uses adaptive system materials and type, VoiceOver labels on controls and pins, light and dark appearances, a high-contrast-friendly system palette, and reduced-motion-aware map focus animation. iOS 26 glass APIs are availability-gated; iOS 18 uses material backgrounds.

## Verification and limits

Offline tests cover distance sampling, deduplication, detour math (60 minutes direct; 35 + 37 minutes through a stop; 12 minutes extra), budgets, deterministic ranking, projection and ahead/behind behavior, journey order and ETA, regional modes, units, and persistence mapping. UI tests exercise Explore, Saved, Settings, denied location, a Cyberjaya-to-Melaka drive through a verified stop and Maps handoff, a California route, and an unroutable drive with retry using live MapKit. Live results can vary by network and MapKit coverage; the UI provides retry and no-results states. Light appearance with increased contrast and accessibility text size was visually checked on the simulator. Network disconnection, an empty MapKit search, in-flight cancellation timing, absent Look Around coverage, VoiceOver speech, and reduced-motion behavior still need manual device QA before release.

MapKit may not return a useful stop or driving route for every place. OneMoreStop does not invent ratings, hours, ownership, weather, charger specifications, or turn-by-turn navigation. Journey order is chosen by the user; it is not optimized automatically. Very long routes can miss places between the bounded sample areas. The app does not currently provide community data, WeatherKit, Siri actions, or account sync.

## Roadmap

Possible later work includes explicit charger metadata from a reliable provider, weather context with entitlement, richer visit-duration guidance, shared journeys, and CarPlay. Those integrations should be added only when the data and product need are clear.
