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
