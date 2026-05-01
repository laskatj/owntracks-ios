# AGENTS.md

## Cursor Cloud specific instructions

### Project overview

OwnTracks iOS is an Objective-C iOS location tracking app (internal fork codename "Sauron"). The primary codebase requires **macOS + Xcode** to build, test, and run the iOS/watchOS/tvOS targets. See `Claude.md` for full architecture details, and `README.md` for Xcode setup steps.

### What works on Linux (Cloud Agent environment)

- **Python utility scripts** in the repo root:
  - `parse_ot_logs.py` — filters OwnTracks device logs for wake/SLC/geofence/kill events. Run: `python3 parse_ot_logs.py <log_dir> [--verbose] [--output FILE]`
  - `mqtt_log_consumer.py` — subscribes to an MQTT broker's log topic and appends to `inbound.log`. Requires a reachable MQTT broker (not available in Cloud Agent by default).
- **Static code review** of Objective-C (`.m`/`.h`) and Swift (`.swift`) source files.

### What does NOT work on Linux

- `xcodebuild` — cannot compile or run the iOS app, tests, or watchOS companion.
- CocoaPods (`pod install`) — requires macOS Ruby toolchain + Xcode integration.
- iOS Simulator — macOS only.
- No linter is configured in this repo (no SwiftLint, no `.clang-format`).

### Dependencies

The Python utility `mqtt_log_consumer.py` requires `paho-mqtt`. The update script installs it via `pip3 install paho-mqtt`.

### Key paths

| Path | Description |
|---|---|
| `OwnTracks/Sauron.xcworkspace` | Xcode workspace (use this, not `.xcodeproj`) |
| `OwnTracks/OwnTracks/` | Main iOS app source (Objective-C) |
| `OwnTracks/OwnTracksTests/` | Unit tests (Objective-C, Xcode-only) |
| `OwnTracks/Podfile` | CocoaPods dependency spec |
| `OwnTracks/Pods/` | Vendored CocoaPods dependencies (checked in) |
| `Claude.md` | Detailed project state, architecture, and recent dev focus |
| `docs/watch/` | watchOS companion documentation |
