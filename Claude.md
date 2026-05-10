# OwnTracks iOS — Project State

## Project Identity

| Field | Value |
|---|---|
| App name | OwnTracks iOS (internal fork) |
| Codename | Sauron |
| Bundle ID | `org.laskatj.owntracksfork` |
| Version | 19.2.6 |
| Deployment target | iOS 16.0+ |
| Language | Objective-C |
| Source repo | `/Users/laskatj/repos/owntracks-ios` |
| Claude working dir | `/Users/laskatj/owntracks-ios` |
| Build number | Set from `git rev-list --count HEAD` |
| Dev team | CFR426ZH5P |

## Architecture Overview

- **Pattern:** Singleton managers, `UITabBarController` navigation, delegate protocols
- **Data:** Core Data (current model version 18.4.3, 34+ migration versions since 2015)
- **Dependencies (CocoaPods):** `mqttc/MinL`, `Sodium`, `CocoaLumberjack`, `DSJSONSchemaValidation`, `ABStaticTableViewController`
- **Workspace:** `OwnTracks/Sauron.xcworkspace` (target name: "Sauron")

## watchOS companion (`SauronWatch`)

- **Target:** `SauronWatch` (SwiftUI), embedded in the iOS app via the `Embed Watch Content` Copy-Files build phase. Optional install — appears in iPhone → Apple Watch app → Available Apps.
- **Bundle linkage:** `WKApplication = true` + `WKCompanionAppBundleIdentifier = org.laskatj.owntracksfork` in [SauronWatch/Info.plist](OwnTracks/SauronWatch/Info.plist). `WKRunsIndependentlyOfCompanionApp = true`.
- **Config:** iOS pushes HTTP ingest settings via `OwnTracksWatchBridge` + WatchConnectivity (`updateApplicationContext` / `transferUserInfo`).
- **Tracking:** Hybrid passive (coarse updates) vs active (higher frequency); see `docs/watch/TRACKING_MODES.md`.
- **Auth:** Keychain + `WatchOAuthRefresher` stub; see `docs/watch/WATCH_AUTH_API.md`.

### Build gotchas (Xcode 26)

- **`SUPPORTED_PLATFORMS` must be set explicitly** on the SauronWatch target to `"watchos watchsimulator"`. Without it, Xcode 26's explicit-module-build pre-pass inherits the iOS host's platform list and tries to compile the watch's Swift sources with `iPhoneSimulator26.4.sdk` / `arm64-apple-ios-simulator`. The result is `error: unable to resolve module dependency: 'WatchKit'` because WatchKit doesn't exist on iOS. The fix is in both Debug + Release configs of the SauronWatch target. `SDKROOT = watchos` alone is **not** sufficient — the explicit-module pre-pass ignores it. (`platformFilter = watchos;` on the PBXTargetDependency was tried — does not help.)
- **AppIcon must include `idiom: watch` role-specific entries** in [SauronWatch/Assets.xcassets/AppIcon.appiconset/Contents.json](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/Contents.json). A single `idiom: universal` 1024×1024 entry is enough for the watch's home-screen icon, but the **iPhone Apple Watch companion app** (My Watch → Available Apps) reads the watch app's compiled `AppIcon.car` and queries for `role: companionSettings` (29×29 @2x and @3x). When that role is missing it falls back to a tinted system placeholder — appears as a colored circle, not the app icon. Required at minimum: companionSettings @2x + @3x. PNGs are generated from the 1024 master with `sips -z N N AppIcon.png --out AppIcon-...png`.
- **App Store Connect's icon validator (error code 90394) requires the legacy 38mm + 42mm entries** even though `WATCHOS_DEPLOYMENT_TARGET = 10.0` (Series 4+). Local `actool` accepts the asset catalog without them, but `xcodebuild -exportArchive` upload to App Store Connect fails with `Missing Icon. The watch application 'Sauron.app/Watch/SauronWatch.app' is missing icon with name pattern '*NxN@2x.png'`. Must include subtypes `38mm` (notificationCenter 24×24, appLauncher 40×40, quickLook 86×86) and `42mm` (notificationCenter 27.5×27.5, quickLook 98×98), plus the modern `40mm/44mm/45mm/49mm` for crispness on Series 4+. The full list is already in [Contents.json](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/Contents.json) — do not delete legacy entries when reorganizing.
- **AppIcon must also keep an iOS-applicable fallback entry** so `actool` doesn't fail when the iOS host's pre-pass scans the watch asset catalog with `--platform iphonesimulator`. Use one entry with `idiom: universal, platform: ios, size: 1024x1024` alongside the watch entries (and a `idiom: watch-marketing` 1024 for App Store). The `idiom: watch` entries are correctly filtered out by the iOS pre-pass.

## Tab Structure

| Tab | Controller | Purpose |
|---|---|---|
| Map | `ViewController.m` | Native map with friend annotations |
| Friends | `FriendsTVC.m` | Friend list with detail views |
| Regions | `RegionsTVC.m` | Geofence management |
| Tours | `ToursTVC.m` | Tour planning |
| History | `HistoryTVC.m` | Location history timeline |
| Web App | `WebAppViewController.m` | Embedded WKWebView + OIDC |
| Settings | `SettingsTVC.m` | MQTT/HTTP config |

## Key Source Files

All under `OwnTracks/OwnTracks/`:

| File | Role |
|---|---|
| `OwnTracksAppDelegate.m` | App lifecycle, connection state, message processing, UI orchestration |
| `LocationManager.m` | GPS, geofencing, motion activity, background wakeup |
| `Connection.m` | MQTT/HTTP connection, thread-based networking, message dispatch |
| `OwnTracking.m` | Message parsing, friend/region updates, MQTT topic routing |
| `Settings.m` | Preference management, MQTT/HTTP config serialization |
| `LocationAPISyncService.m` | REST API polling for friend locations, OAuth token management |
| `WebAppAuthHelper.m` | OAuth 2.0/OIDC flow, Keychain refresh token storage |
| `OTHeartRateMonitoring.m` | Coordinator: source enum (None/Bluetooth/HealthKit), enable/disable, source-priority resolution |
| `BluetoothHeartRateManager.m` | BLE Heart Rate Service (0x180D / 0x2A37), background state restoration, scan/relax fallback |
| `HealthKitHeartRateManager.m` | HealthKit anchored-object query for HR samples, background delivery |
| `ViewController.m` | Main map, friend annotations, map interaction, heart rate map pill |
| `WebAppViewController.m` | Embedded WKWebView, OIDC token injection |
| `SettingsTVC.m` | Settings UI, preference editing |
| `CoreData.m` | Core Data setup and schema migration |

## Core Data Entities

`Friend`, `Waypoint`, `Region`, `History`, `Queue`, `Setting`, `Validation`

## Key Protocols

- `ConnectionDelegate` — MQTT/HTTP state changes and message delivery callbacks
- `LocationManagerDelegate` — location, timer, visit, and region events

## Feature Summary

**Location Tracking Modes:**
- Manual — user-triggered
- SLC — Significant Location Change (iOS background)
- Move — continuous GPS tracking
- Passive — background tracking after app termination
- Visit — CLVisit events

**Transport:**
- MQTT v3/v4/v5 (via `mqttc/MinL`)
- HTTP POST

**Authentication:**
- OAuth 2.0 / OIDC with PKCE
- Silent token refresh via stored Keychain refresh token
- OIDC discovery: `https://identity.tlaska.com/application/o/sauron/.well-known/openid-configuration`
- OAuth client ID: `d8ntY1AOtH6UaYE9QGRfy1AXKmKVH9wmwcl0bSJJ`

**Web App Tab:**
- Embedded WKWebView at `https://sauron.tlaska.com`
- Auto-provisioning via `/.well-known/owntracks-app-auth`
- Native OIDC token injection into web app

**REST Sync:**
- `LocationAPISyncService` polls backend for friend location updates

**Geofencing:**
- Circular regions
- iBeacon monitoring

**Other:**
- Waypoints/POIs with photo attachment
- Tour planning
- Friend location sharing with history
- 14 localized languages
- Siri Shortcuts via `OwnTracksIntents` extension

## Default Configuration

**MQTT.plist:**
- Host: `host` (placeholder), Port: 8883 (TLS)
- Protocol: MQTTv4, QoS 1, KeepAlive 60s
- Monitoring: SLC, Min distance: 200m, Min time: 180s
- Clean session: false, Retain: true

**HTTP.plist:**
- URL: `https://host:port/path` (placeholder)
- Auth disabled by default for HTTP mode
- Web App URL: `https://sauron.tlaska.com`

## Move + SLC Fallback — Design & Known Challenges

### Intent

**Move mode** uses continuous high-accuracy GPS (`startUpdatingLocation`) while the app is in the foreground. When the app is backgrounded or killed, iOS suspends or terminates it — continuous GPS is no longer viable.

**SLC fallback** (Significant Location Change) keeps tracking alive passively after the app is backgrounded: iOS wakes the app (or relaunches it) whenever it detects a significant location change (~500m displacement or cell tower change). The app publishes the wakeup location to MQTT, then immediately disconnects and lets itself be suspended again. This avoids the kill-wakeup-kill loop that would result from calling `startUpdatingLocation` in the background.

### Code Pattern

**`backgroundWakeup` flag** (`LocationManager.m`) is set to `YES` when the app is launched in the background via `UIApplicationLaunchOptionsLocationKey`. It gates all background-specific behavior:

- `wakeup` method (`LocationManager.m`): if `backgroundWakeup`, suppress `startUpdatingLocation` and run SLC + Visit monitoring only (passive mode)
- `publishLocation:` (`OwnTracksAppDelegate.m`): updates `+follow` geofence to current position on every publish
- `startBackgroundTimer` (`LocationManager.m`): skipped when `applicationState == FOREGROUND` to avoid premature disconnect when app is actually open
- `didUpdateLocations:` (`LocationManager.m`): applies a looser time filter (`-60.0s`) in backgroundWakeup mode to absorb iOS SLC timestamp jitter (see Known Issues)

**Timer cascade on each background wakeup:**
1. `holdTimer` fires after ~10s → triggers MQTT disconnect
2. `bgTimer` polls every 1s checking if publish is complete
3. `disconnectTimer` (25s safety net) force-disconnects if MQTT stalls

### `+follow` Geofence

A special geofence named with a `+` prefix (e.g., `+30`) is a "follow" region — it re-centers on the user's current location at every `publishLocation:` call (in `OwnTracksAppDelegate.m` lines ~1697–1715). The radius is `max(speed × time_seconds, 50m)`. This means the follow geofence always surrounds the user and triggers an SLC exit when they leave it — providing the next background wakeup even if iOS SLC doesn't fire independently.

**Critical gap:** `regionEvent:enter:NO` in `OwnTracksAppDelegate.m` (line ~1005) skips the publish for +follow exits when `monitoring == LocationMonitoringMove`. In foreground this is intentional (continuous GPS produces its own updates). But in `backgroundWakeup` mode this is wrong — the +follow geofence exit IS the wakeup trigger, and the app wakes, does nothing, and goes back to sleep without publishing. This means a large fraction of background wakes in Move+backgroundWakeup mode produce no location update at all. The fix is to also publish on +follow exit when `backgroundWakeup == YES`.

### Known Issues & Fixes Applied

| Issue | Root Cause | Fix |
|---|---|---|
| First SLC location silently dropped | `lastUsedLocation` initialized to `[NSDate date]` at app launch; SLC timestamp predates launch | `lastUsedLocation` reset to `distantPast` in backgroundWakeup passive mode |
| Second SLC silently dropped | iOS delivers SLC location with timestamp 43ms earlier than the previous `lastUsedLocation` due to jitter | Time filter in `didUpdateLocations:` uses threshold `-60.0s` when `backgroundWakeup==YES` instead of `0.0` |
| MQTT never disconnects after first SLC | `startBackgroundTimer` was not called in background publish path | Added `startBackgroundTimer` call in background-aware publish path |
| `LocationAPISyncService` runs during wakeup | Service starts on every app launch, including background relaunches, generating OAuth network activity during the short wakeup window | Known issue; not yet suppressed during backgroundWakeup |
| +follow geofence exit silently dropped in Move+backgroundWakeup | `regionEvent:enter:NO` skips publish when `monitoring == Move`; designed for foreground but wrong for backgroundWakeup where the geofence IS the wakeup source | **Not yet fixed** — condition at `OwnTracksAppDelegate.m:1005` must also allow publish when `backgroundWakeup == YES` |

### Log Signature for Background Wakeup

Healthy two-wakeup sequence looks like:
```
[OwnTracksAppDelegate] applicationDidFinishLaunching backgroundWakeup=1
[LocationManager] Move mode: background wakeup - passive tracking only
[LocationManager] Location#1: Δs:... delivered in BACKGROUND WAKEUP (passive SLC mode)
[Connection] disconnectInBackground
[OwnTracksAppDelegate] applicationDidFinishLaunching backgroundWakeup=1   ← second wakeup
[LocationManager] Location#1: Δs:... delivered in BACKGROUND WAKEUP (passive SLC mode)
```

If `"BACKGROUND WAKEUP"` never appears after `Location#1`, the location was dropped by the time filter (`Δs:-0` in the log confirms jitter drop).

---

## OAuth / Re-auth Investigation

See [claud-authissues.md](claud-authissues.md) for the full write-up of the re-auth problem, all root causes identified, and the five fixes applied across `WebAppAuthHelper.m`, `LocationAPISyncService.m`, and the web app server.

**TL;DR:** Every 60-second poll was calling the Authentik token endpoint unconditionally, rotating the refresh token ~60×/hour. Rotation races between concurrent callers (poll timer, WebApp tab, background wakeup processes) caused 400s that wiped the Keychain. Five fixes reduce rotation frequency, prevent background Keychain deletion, and suppress OAuth prompts during background wakeups.

---

## Heart Rate — BLE, HealthKit, Map Pill

Two managers + one coordinator, all singletons. Either source can feed BPM into the published location payload and the map UI; Bluetooth is preferred when a strap is connected, HealthKit is the fallback (covers Apple Watch / Polar→Health).

### Components

| File | Role |
|---|---|
| [OTHeartRateMonitoring.m](OwnTracks/OwnTracks/OTHeartRateMonitoring.m) | Coordinator. `+isMonitoringEnabled`, `+setMonitoringEnabled:`, `+resolvedHeartRateBPMWithMaxSampleAge:outSource:` (returns BPM + `OTHeartRateSource` of None/Bluetooth/HealthKit). |
| [BluetoothHeartRateManager.m](OwnTracks/OwnTracks/BluetoothHeartRateManager.m) | CoreBluetooth central scanning the BLE Heart Rate Service (`0x180D` / characteristic `0x2A37`). Handles state restoration via `kCentralRestoreIdentifier = "org.owntracks.heartrate"` so background BLE resumes survive app suspend. Two-phase scan: strict (`[180D]` filter) for ~8s, then relaxed (name/UUID heuristic — many chest straps don't advertise the 180D service). Stale-reading window: `kHeartRateMaxAge = 30s`. Trouble hint exposed via `-connectionTroubleHint`. |
| [HealthKitHeartRateManager.m](OwnTracks/OwnTracks/HealthKitHeartRateManager.m) | `HKAnchoredObjectQuery` on `HKQuantityType.heartRate`, background delivery enabled (covers Apple Watch / 3rd-party straps that publish to Health). |

### Notification names

UI subscribes to all three on the main queue; each fires when source state changes:

- `OTBluetoothHeartRateDidUpdateNotification`
- `OTHealthKitHeartRateDidUpdateNotification`
- `OTHeartRateMonitoringEnabledDidChangeNotification`

### Map heart rate pill (top-right of map)

Lives in [ViewController.m](OwnTracks/OwnTracks/ViewController.m) (`setupMapHeartRateIndicator` + `updateMapHeartRateIndicatorAppearance`). Visual contract:

- Same height (32 pt) and corner radius (8 pt) as the Quiet/Manual/Significant/Move `UISegmentedControl` next to it. Width hugs content (`≥64 pt` floor).
- Heart symbol: SF `heart.fill` at 14 pt. Pink when monitoring is on, tertiary-label when off.
- BPM label: 13 pt monospaced semibold.
- **Source badge**: 11 pt circular plate overhanging the heart's bottom-right by 3 pt. Bluetooth-blue circle with white runic glyph (drawn from a 6-vertex even-odd `UIBezierPath` — SF Symbols ships **no** `bluetooth` glyph, do not call `systemImageNamed:@"bluetooth"`, it returns nil). Apple-Health-red circle with white `heart.fill` for HealthKit. Helper: `+OT_hrSourceBadgeImageForSource:`.
- Tap toggles monitoring (`heartRateMapChipTapped` → `OTHeartRateMonitoring setMonitoringEnabled:`).
- BLE trouble hint surfaces only via `accessibilityValue` (VoiceOver), not as a visible label — keeps the pill from growing vertically.

### Source-priority logic (in `updateMapHeartRateIndicatorAppearance`)

1. BLE peripheral connected → BT badge (full alpha if BPM is currently from BLE; faded if BPM is from HealthKit because the strap is momentarily quiet).
2. BPM resolved from Bluetooth, no live peripheral → BT badge (recently-disconnected sample within `kMaxAge = 15 min`).
3. BPM resolved from HealthKit → HK badge.
4. No BPM but HealthKit has a stale recent sample → HK badge, faded.
5. BLE trouble hint present → BT badge, very faded.

### Required Info.plist + entitlements (both `org.laskatj.owntracksfork`)

Already in place — listed here so they don't get accidentally stripped:

- `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSBluetoothAlwaysUsageDescription` in [Base.lproj/OwnTracks-Info.plist](OwnTracks/OwnTracks/Base.lproj/OwnTracks-Info.plist).
- `UIBackgroundModes` includes `bluetooth-central` (for state-restored HR resume).
- `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` in [OwnTracks.entitlements](OwnTracks/OwnTracks/OwnTracks.entitlements). HealthKit is **not** declared as a `UIBackgroundModes` entry — it's driven entirely by the entitlement (per Apple, declaring `healthkit` in BackgroundModes triggers App Store review rejection).

### Charting

[DeviceMetricsChartsSheet.swift](OwnTracks/OwnTracks/DeviceMetricsChartsSheet.swift) and [DeviceDetailView.swift](OwnTracks/OwnTracks/DeviceDetailView.swift) render historical HR alongside other device metrics (Strava-style scrub interaction).

---

## Recent Development Focus

From git log (most recent first):

1. SLC fallback debug logging + app icon cleanup
2. Native map and friends wired to REST APIs; `offline_access` scope fix
3. OIDC token and refresh token management hardening
4. Background wakeup debugging
5. Web app bottom inset fix
6. Move mode: added SLC fallback when CLLocationManager is unavailable
7. Fix: SLC wakeup location dropped due to timestamp filter
8. iOS location tracking modes implementation (PR #2)
9. Passive background tracking for Move mode
10. OAuth fix: store refresh token, implement silent refresh (PR #1)

## Entitlements

- Location Always + When In Use
- Background location updates
- Background fetch
- Remote notifications
- App Groups: `group.org.owntracks.OwnTracks`
- Motion activity (home activity sensor)
- HealthKit + HealthKit background delivery (for HR fallback when no BLE strap)
- Bluetooth Always usage (for HR strap)
- `UIBackgroundModes` includes `bluetooth-central` (background BLE state restoration)
