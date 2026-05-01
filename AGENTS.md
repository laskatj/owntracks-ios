# AGENTS.md

## Cursor Cloud specific instructions

### Project overview

OwnTracks iOS is an Objective-C iOS/tvOS location tracking app (internal fork codename "Sauron"). See `Claude.md` for full architecture details and `README.md` for Xcode setup steps.

### Dependency management

- **CocoaPods** manages Objective-C dependencies. Pods are vendored (checked into `OwnTracks/Pods/`).
- Run `cd OwnTracks && pod install --allow-root` to refresh dependencies. The `--allow-root` flag is required because the Cloud Agent runs as root.
- The xcodeproj gem (v1.27.0) does not include Xcode project object version `70` in its compatibility map. The update script patches this automatically by adding `70 => 'Xcode 16.0'` to the gem's `constants.rb`. Without this patch, `pod install` will fail with `ArgumentError - [Xcodeproj] Unable to find compatibility version string for object version '70'`.
- **Python dependency**: `paho-mqtt` is needed for `mqtt_log_consumer.py`.

### Objective-C compilation on Linux

- GNUstep provides Foundation framework headers and runtime, allowing basic Objective-C compilation and execution with `clang`.
- Compile flags: `$(gnustep-config --objc-flags) -I/usr/lib/gcc/x86_64-linux-gnu/13/include`
- Link flags: `$(gnustep-config --objc-libs) -lgnustep-base -L/usr/lib/gcc/x86_64-linux-gnu/13 -lobjc`
- Apple-specific frameworks (UIKit, CoreLocation, XCTest, MapKit, etc.) are NOT available. Source files importing these frameworks cannot be compiled on Linux.
- Files using only Foundation (e.g., `NSNumber+decimals.m`) can be syntax-checked with `clang -fsyntax-only`.

### Testing limitations

- Unit tests (`OwnTracksTests/`) use XCTest and depend on iOS SDK — they cannot run on Linux.
- No linter is configured in this repo (no SwiftLint, no `.clang-format`, no `.swiftlint.yml`).
- The Python utility `parse_ot_logs.py` can be tested standalone: `python3 parse_ot_logs.py <log_dir> [--verbose]`.

### Key paths

| Path | Description |
|---|---|
| `OwnTracks/Sauron.xcworkspace` | Xcode workspace (use this, not `.xcodeproj`) |
| `OwnTracks/OwnTracks/` | Main iOS app source (Objective-C) |
| `OwnTracks/OwnTracksTests/` | Unit tests (Objective-C, XCTest — macOS/Xcode only) |
| `OwnTracks/Podfile` | CocoaPods dependency spec |
| `OwnTracks/Pods/` | Vendored CocoaPods dependencies (checked in) |
| `Claude.md` | Detailed project state, architecture, and recent dev focus |
| `docs/watch/` | watchOS companion documentation |
