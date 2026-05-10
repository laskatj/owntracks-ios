# Fix Watch App Icon in iPhone Apple Watch Companion App

## Context

The Sauron watch app icon renders correctly on the watch's app launcher, but in the **iPhone Apple Watch app → My Watch → Available Apps**, Sauron displays as a generic colored placeholder ("just a red circle") rather than the Sauron eye image.

**Why:** The watch's [Assets.xcassets/AppIcon.appiconset/Contents.json](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/Contents.json) contains a single 1024×1024 entry. The iPhone Apple Watch companion view does not render from the 1024 marketing icon — it queries the watch app's compiled `AppIcon.car` for an entry with `role: companionSettings` (29×29 @2x and @3x). When that role is absent, the companion view falls back to a system placeholder, which on the user's device appears as a tinted red circle. The icon image itself ([AppIcon.png](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png) — 1024×1024 RGB, no alpha, fiery red eye) is fine; only the asset catalog metadata is incomplete.

A previous edit removed `"platform": "watchos"` from the universal entry (to fix an `actool` error during the iOS host's pre-pass). That change must be preserved; the new role entries must coexist with it without re-introducing the iOS-side error.

## Approach

All work lives inside [OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/).

### 1. Generate role-specific PNGs from the master 1024×1024

Use `sips` (Apple's built-in image tool) to downscale the master once per required size. Minimum set required for the iPhone Apple Watch companion view:

| Filename | Pixel size | Role / surface |
|---|---|---|
| `AppIcon-29@2x.png` | 58×58 | `companionSettings` @2x — **the one that fixes the red circle** |
| `AppIcon-29@3x.png` | 87×87 | `companionSettings` @3x |

Recommended additional sizes for full coverage of modern watches (40/41/44/45/49 mm) so the icon is also crisp on the watch's own surfaces (Notification Center, App Launcher, Quick Look) instead of being upscaled at runtime from the 1024:

| Filename | Pixel size | Role / surface |
|---|---|---|
| `AppIcon-NotifCenter-40mm@2x.png` | 55×55 | `notificationCenter` @2x, subtype `40mm` (sized 27.5×27.5) |
| `AppIcon-NotifCenter-45mm@2x.png` | 66×66 | `notificationCenter` @2x, subtype `45mm` (sized 33×33) |
| `AppIcon-AppLauncher-40mm@2x.png` | 88×88 | `appLauncher` @2x, subtype `40mm` (sized 44×44) |
| `AppIcon-AppLauncher-44mm@2x.png` | 100×100 | `appLauncher` @2x, subtype `44mm` (sized 50×50) |
| `AppIcon-AppLauncher-45mm@2x.png` | 102×102 | `appLauncher` @2x, subtype `45mm` (sized 51×51) |
| `AppIcon-AppLauncher-49mm@2x.png` | 108×108 | `appLauncher` @2x, subtype `49mm` (sized 54×54) |
| `AppIcon-QuickLook-44mm@2x.png` | 216×216 | `quickLook` @2x, subtype `44mm` (sized 108×108) |
| `AppIcon-QuickLook-45mm@2x.png` | 234×234 | `quickLook` @2x, subtype `45mm` (sized 117×117) |
| `AppIcon-QuickLook-49mm@2x.png` | 258×258 | `quickLook` @2x, subtype `49mm` (sized 129×129) |

Generation command pattern (one example):

```bash
sips -z 58 58 AppIcon.png --out AppIcon-29@2x.png
```

`sips` preserves the source's RGB-no-alpha format, which is what App Store requires anyway.

### 2. Rewrite Contents.json

Replace [Contents.json](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/Contents.json) with one entry per generated PNG plus the existing universal 1024 entry. Use `idiom: watch` for the role-specific entries — these are filtered out by `actool` when invoked with `--platform iphonesimulator` (the iOS host's pre-pass), so they will not regress the AppIcon error we already fixed.

Skeleton:

```json
{
  "images" : [
    { "filename": "AppIcon-29@2x.png", "idiom": "watch", "role": "companionSettings", "scale": "2x", "size": "29x29" },
    { "filename": "AppIcon-29@3x.png", "idiom": "watch", "role": "companionSettings", "scale": "3x", "size": "29x29" },
    { "filename": "AppIcon-NotifCenter-40mm@2x.png", "idiom": "watch", "role": "notificationCenter", "scale": "2x", "size": "27.5x27.5", "subtype": "40mm" },
    { "filename": "AppIcon-NotifCenter-45mm@2x.png", "idiom": "watch", "role": "notificationCenter", "scale": "2x", "size": "33x33", "subtype": "45mm" },
    { "filename": "AppIcon-AppLauncher-40mm@2x.png", "idiom": "watch", "role": "appLauncher", "scale": "2x", "size": "44x44", "subtype": "40mm" },
    { "filename": "AppIcon-AppLauncher-44mm@2x.png", "idiom": "watch", "role": "appLauncher", "scale": "2x", "size": "50x50", "subtype": "44mm" },
    { "filename": "AppIcon-AppLauncher-45mm@2x.png", "idiom": "watch", "role": "appLauncher", "scale": "2x", "size": "51x51", "subtype": "45mm" },
    { "filename": "AppIcon-AppLauncher-49mm@2x.png", "idiom": "watch", "role": "appLauncher", "scale": "2x", "size": "54x54", "subtype": "49mm" },
    { "filename": "AppIcon-QuickLook-44mm@2x.png", "idiom": "watch", "role": "quickLook", "scale": "2x", "size": "108x108", "subtype": "44mm" },
    { "filename": "AppIcon-QuickLook-45mm@2x.png", "idiom": "watch", "role": "quickLook", "scale": "2x", "size": "117x117", "subtype": "45mm" },
    { "filename": "AppIcon-QuickLook-49mm@2x.png", "idiom": "watch", "role": "quickLook", "scale": "2x", "size": "129x129", "subtype": "49mm" },
    { "filename": "AppIcon.png", "idiom": "universal", "size": "1024x1024" }
  ],
  "info" : { "author": "xcode", "version": 1 }
}
```

The universal 1024 entry stays without a platform restriction — that's what keeps the iPhone-host actool pre-pass happy (it sees applicable content for iOS). The watch-idiom entries with explicit roles are what the iPhone Apple Watch companion view (and the watch itself) actually consume.

### 3. Verify with actool

Before opening Xcode, run actool directly against the asset catalog for both platforms to confirm no regressions:

```bash
mkdir -p /tmp/icon-test
xcrun actool OwnTracks/SauronWatch/Assets.xcassets \
  --compile /tmp/icon-test --platform iphonesimulator --minimum-deployment-target 16.0 \
  --app-icon AppIcon --output-partial-info-plist /tmp/icon-test/p.plist \
  --output-format human-readable-text
```

Repeat with `--platform watchsimulator --minimum-deployment-target 10.0`. Both must complete without `error:` lines. Then run the full xcodebuild for the iOS scheme.

## Critical files

- [OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/Contents.json](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/Contents.json) — full rewrite with the entry list above.
- [OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png](OwnTracks/SauronWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png) — keep as the master; new sized PNGs are generated from this with `sips` and dropped alongside it.

## Verification

1. Run the two actool commands above — both succeed.
2. `xcodebuild ... -sdk iphonesimulator ...` for the Sauron scheme — confirm the AppIcon-related actool error stays gone.
3. `xcodebuild -project OwnTracks/Sauron.xcodeproj -target SauronWatch -sdk watchsimulator build` — confirms the watch app still builds standalone with the new asset catalog.
4. Install on a paired iPhone+Watch (or simulator pair). On the iPhone, open the Apple Watch app → My Watch → scroll to Available Apps. Sauron should now show the eye icon (cropped to a circle) instead of a red placeholder. The watch's own home screen should still show the same eye icon (no regression).

---

# Notes for the user about the SDK / simulator situation

(Descriptive — not part of the icon fix; included here so the plan file captures the full context. The actual write-up will be in the chat reply.)

The user's stated goal — "bundle the watch app with the iPhone app and have it be an optional install" — is exactly the supported architecture: iOS host + paired watch app, embedded into the iOS host's bundle via the `Embed Watch Content` Copy Files build phase. The `WKCompanionAppBundleIdentifier = org.laskatj.owntracksfork` in the watch's Info.plist correctly links it to the iOS host. Nothing about that goal is wrong.

The build error (`unable to resolve module dependency: 'WatchKit'` while compiling `LocationPayload.swift` with `-sdk iPhoneSimulator26.4.sdk -target arm64-apple-ios26.4-simulator`) is a separate Xcode 26 quirk: when the iOS Sauron target is built, Xcode's "explicit module build" pre-pass is incorrectly compiling the `SauronWatch` Swift sources with the iOS host's SDK instead of watchsimulator, even though the `SauronWatch` target itself has `SDKROOT = watchos`. Standalone builds of SauronWatch with `-sdk watchsimulator` succeed cleanly, which confirms the watch target's settings are right; the bug is in how the cross-platform dependency is being scanned by the iOS build context. The `PBXTargetDependency` entry that links the iOS Sauron target to SauronWatch lacks any `platformFilter`, which in Xcode 26 may be required to keep the dependency from being scanned by the host platform's module pre-pass. Adding `platformFilter = watchos;` to that PBXTargetDependency is the lowest-risk first attempt; it's a one-line edit to [Sauron.xcodeproj/project.pbxproj](OwnTracks/Sauron.xcodeproj/project.pbxproj) at line 1387. Out of scope for this plan unless you ask.
