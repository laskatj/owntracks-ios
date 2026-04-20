# Sauron watchOS (hybrid tracking)

## Layout

- **App sources:** `[OwnTracks/SauronWatch/](../../OwnTracks/SauronWatch/)` — SwiftUI app, location pipeline, HTTP ingest, Keychain token stubs.
- **iOS bridge:** `[OwnTracks/OwnTracks/OwnTracksWatchBridge.m](../../OwnTracks/OwnTracks/OwnTracksWatchBridge.m)` — `WCSession` push of HTTP settings to the watch.
- **Docs:** this folder.

## Quick links


| Doc                                                        | Purpose                                        |
| ---------------------------------------------------------- | ---------------------------------------------- |
| [TRACKING_MODES.md](TRACKING_MODES.md)                     | Passive vs active sampling and upload cadence  |
| [HTTP_INGEST_CONTRACT.md](HTTP_INGEST_CONTRACT.md)         | Request shape, headers, OwnTracks JSON         |
| [WATCH_AUTH_API.md](WATCH_AUTH_API.md)                     | Recommended bootstrap + OAuth refresh contract |
| [PHASE2_LOCATIONSYNC_AUTH.md](PHASE2_LOCATIONSYNC_AUTH.md) | Friends / map API scopes                       |
| [FIELD_TEST_CHECKLIST.md](FIELD_TEST_CHECKLIST.md)         | Manual validation steps                        |
| [AUTH_SPIKE.md](AUTH_SPIKE.md)                             | Phase 0 go/no-go for auth approach             |


## Xcode

- Scheme `**SauronWatch`** builds the watch app; scheme `**OwnTracks`** builds the iOS app and embeds `SauronWatch.app` under **Embed Watch Content**.