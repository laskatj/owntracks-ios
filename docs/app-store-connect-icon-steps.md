# App Store Connect — icon on Apps grid

The Apps list icon comes from a build **attached to an App Store version**, not from TestFlight alone.

## Attach build (do once per app)

**Required for Apps grid icons.** TestFlight tiles can show without this step; the Apps list cannot.

### Sauron (iOS)

1. [App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **Sauron**
2. Left sidebar → **iOS App** → **1.0 Prepare for Submission** (or your current version)
3. **Build** → **+** / **Add Build**
4. Select build **924** (19.4.7) after processing completes — includes Info.plist icon fix. Build **923** works for a quick test if already processed.
5. **Save** (top right)

### SauronTV (tvOS)

Same flow under **tvOS App** if you have a version record there.

Wait up to ~2 hours for CDN cache. Hard-refresh (Cmd+Shift+R) or use a private window if the tile stays as a wireframe.

## After uploading a new build (Info.plist icon fix)

1. Xcode → **Product** → **Archive** (scheme **Sauron**, workspace `OwnTracks/Sauron.xcworkspace`)
2. **Distribute App** → App Store Connect → upload
3. When processing finishes, open the version page again, remove the old build if needed, add the new build, **Save**

## Verify marketing icon in IPA (optional)

```bash
# After exporting or downloading IPA
unzip -l YourApp.ipa | grep Assets.car
# 1024 marketing slot should be in compiled asset catalog
sips -g hasAlpha OwnTracks/OwnTracks/Images.xcassets/AppIcon.appiconset/OwnTracks-1024-noalpha.png
# must print: hasAlpha: no
```
