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

- **Target:** `SauronWatch` (SwiftUI), embedded in the iOS app (`Embed Watch Content`).
- **Config:** iOS pushes HTTP ingest settings via `OwnTracksWatchBridge` + WatchConnectivity (`updateApplicationContext` / `transferUserInfo`).
- **Tracking:** Hybrid passive (coarse updates) vs active (higher frequency); see `docs/watch/TRACKING_MODES.md`.
- **Auth:** Keychain + `WatchOAuthRefresher` stub; see `docs/watch/WATCH_AUTH_API.md`.

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
| `ViewController.m` | Main map, friend annotations, map interaction |
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
