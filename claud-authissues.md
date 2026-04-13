# OAuth / OIDC Re-auth Investigation

## Summary

`LocationAPISyncService` polls `GET /api/location` every 60 seconds and calls the Authentik token endpoint on every poll to exchange the stored refresh token for a new access token. Authentik is configured with refresh token rotation (`threshold=seconds=0`), meaning every use of the refresh token invalidates it and issues a new one. Under this configuration, excessive token endpoint calls cause rotation race conditions between concurrent callers (foreground poll timer, WebApp tab, background wakeup processes). The result: a 400 response to one caller invalidates the shared Keychain entry and forces a full re-auth.

---

## Authentik Configuration

| Setting | Value |
|---|---|
| Access Token Validity | `minutes=5` |
| Refresh Token Validity | `days=60` |
| Refresh Token Threshold | `seconds=0` (rotate on every use) |

Refresh tokens are **opaque strings** (not JWTs) — their `exp` cannot be decoded client-side. Access tokens are JWTs with 5-minute lifetime.

---

## Root Causes & Fixes Applied

### Fix 1 — OAuth prompt during background wakeups
**Problem:** `LocationAPISyncService.scheduleInteractiveOAuthIfNoTokenAfterFailure` presented `ASWebAuthenticationSession` during background wakeup processes. iOS killed the process ~13ms after the sheet appeared. The once-per-session static flag (`gLocationAPIOAuthPromptScheduledThisSession`) reset on each process restart, so the prompt fired again on the next wakeup.

**Fix:** Added `applicationState != UIApplicationStateActive` guard before the flag is set. Background wakeups skip the prompt without consuming the flag, so the next foreground poll retries.

**File:** `OwnTracks/OwnTracks/LocationAPISyncService.m` — `scheduleInteractiveOAuthIfNoTokenAfterFailure`

---

### Fix 2 — Background 400/401 silently wipes Keychain
**Problem:** `WebAppAuthHelper.performRefreshWithTokenData:` deleted the Keychain entry on any 400/401 response, even during a background wakeup where no interactive re-auth can follow. Token expired or rotation raced → background process wipes Keychain → next foreground launch starts with no token.

**Fix:** Keychain deletion on 400/401 is now gated on `applicationState == UIApplicationStateActive`. Background wakeups that receive a 400/401 preserve the entry for the next foreground re-auth attempt.

**File:** `OwnTracks/OwnTracks/WebAppAuthHelper.m` — `performRefreshWithTokenData:forWebAppURL:matchedAccount:completion:`

---

### Fix 3 — User cancel immediately re-triggered the prompt
**Problem:** On cancel, `WebAppAuthHelper` called `finishWithError:nil`. `LocationAPISyncService` checked `error.domain == ASWebAuthenticationSessionErrorDomain` to detect cancel — with `nil` error this was always `NO`, so the once-per-session flag was reset and the prompt immediately re-appeared.

**Fix:** Cancel now passes the actual `ASWebAuthenticationSessionErrorCodeCanceledLogin` error through to `finishWithError:`. The cancel detection in `LocationAPISyncService` works correctly and the flag stays set for the session.

**File:** `OwnTracks/OwnTracks/WebAppAuthHelper.m` — `ASWebAuthenticationSession` completion handler

---

### Fix 4 — `owntracks-app-auth` returning HTML
**Problem:** `https://sauron.tlaska.com/.well-known/owntracks-app-auth` returned the React SPA catch-all (HTML) instead of JSON. `LocationAPISyncService` could not cache the `client_id` from discovery, causing Keychain lookups to use the wrong key and miss stored tokens.

**Fix (server-side):** Web app now serves the correct JSON at that path before the SPA catch-all route.

```json
{
  "authorization_endpoint": "https://identity.tlaska.com/application/o/sauron/authorize/",
  "token_endpoint": "https://identity.tlaska.com/application/o/sauron/token/",
  "client_id": "d8ntY1AOtH6UaYE9QGRfy1AXKmKVH9wmwcl0bSJJ",
  "scope": "openid offline_access",
  "login_path": "/login"
}
```

---

### Fix 5 — Access token not cached; every 60-second poll rotated the refresh token
**Problem:** `LocationAPISyncService.fetchAndApply` called `obtainAccessTokenForLocationAPIWithCompletion:` on every 60-second timer tick, unconditionally calling the Authentik token endpoint. With `threshold=seconds=0`, each call rotated the refresh token. At 60 calls/hour, rotation races between the poll timer and other callers (WebApp tab, background wakeup processes) caused frequent 400s.

Log evidence (Apr 13):
```
03:01:54 → refresh → new RT stored
03:02:44 → refresh → new RT stored   (50s later)
03:03:09 → refresh → new RT stored   (25s later)
03:03:14 → refresh → new RT stored   (5s later — WebApp tab concurrent caller)
03:03:23 → refresh → new RT stored   (9s later)
04:29:16 → 400 — rotation race, Keychain wiped
```

**Fix:** `fetchAndApply` now caches the last access token with its `exp` claim. If the cached token has >60 seconds remaining it is reused directly, skipping the refresh grant entirely. With 5-minute access tokens, this cuts token endpoint calls from ~60/hour to ~12/hour. On a 401 from the API, the cache is cleared and a fresh token is fetched.

New property: `cachedAccessTokenExpiry` (unix timestamp of cached token's `exp`).

**File:** `OwnTracks/OwnTracks/LocationAPISyncService.m` — `fetchAndApply`, `performGET:accessToken:allowRetryOn401:`

---

## Diagnostic Instrumentation Added

`WebAppAuthHelper` now decodes and logs the JWT `iat`/`exp` claims at every token lifecycle point:

- **Point A** — Code exchange (initial sign-in): logs access token and refresh token lifetimes
- **Point B** — Before silent refresh POST: logs the stored refresh token's claims
- **Point C** — After silent refresh success: logs new access and refresh token claims, notes if no new RT was returned
- **Point D** — Keychain store: logs the token being stored

New class methods (declared in `WebAppAuthHelper.h`):
- `+jwtPayloadClaimsFromToken:` — decodes JWT payload without signature verification
- `+jwtLifetimeSummaryFromClaims:` — returns human-readable `"iat=... exp=... Xd Yh remaining"` string

**Key finding from logs:** Authentik's refresh tokens are opaque (not JWTs), so their `exp` cannot be read client-side. Access tokens are 5-minute JWTs and their `exp` is now used to drive the cache decision in Fix 5.

---

## Current Status

All five fixes are applied. The expected steady-state is:
- Sign in once → token valid 60 days server-side
- Each foreground poll reuses cached access token for up to ~4 minutes, calls token endpoint only when it expires (~12×/hour instead of ~60×/hour)
- Background wakeups skip OAuth entirely (no prompt, no Keychain deletion on failure)
- A re-auth prompt appears at most once per session when no token exists, and only when the app is foreground-active

## Outstanding Unknown

Whether Authentik's 60-day refresh token lifetime applies correctly to this client. The opaque token format means we cannot verify `exp` client-side. If 400s recur well before 60 days, the Authentik provider configuration (not the iOS code) should be verified — specifically that the `offline_access` scope and the correct application/provider are configured with the `days=60` policy.
