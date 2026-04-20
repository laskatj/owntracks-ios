# Phase 0 — Auth feasibility spike (1–2 days)

## Objective

Decide between **full watch token exchange** (see `WATCH_AUTH_API.md`) vs **temporary Basic/header copy** from the phone.

## Steps

1. **Device test:** Install `SauronWatch` on hardware with LTE; confirm HTTP POST succeeds with credentials synced from the phone while the phone is in airplane mode / out of range.
2. **Token stub:** Optionally seed `WatchAuthKeychain` manually (debug menu or one-off build) and confirm `WatchHTTPIngestClient` sends `Authorization: Bearer`.
3. **Refresh:** Point `oauthRefreshURL` / client id at your issuer; verify `WatchOAuthRefresher` can obtain a new access token (or document blockers).
4. **Decision:** If (2)+(3) are viable, schedule backend bootstrap endpoints; otherwise ship Basic-only and migrate later.

## Pass criteria

- Watch uploads at least one valid OwnTracks `location` JSON with **no iPhone relay** (direct HTTPS).
- Keychain survives app restart on watch.
- Team agrees on token ownership and revocation story.