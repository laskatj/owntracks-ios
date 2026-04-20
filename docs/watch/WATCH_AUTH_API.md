# Watch authentication API (recommended production path)

The watch app stores **device-scoped** credentials in the **watch Keychain** (`WatchAuthKeychain.swift`). The iOS app seeds config via **WatchConnectivity**; for standalone cellular operation the watch must obtain its own tokens.

## Bootstrap (phone → watch → backend)

Intended flow (implemented as client stubs + documentation):

1. **POST** `/api/v1/watch/bootstrap` (example path — replace with your backend)
  - **Auth:** Bearer access token from the logged-in iOS session *or* one-time session proof.
  - **Response:** `{ "bootstrap_token": "<JWT>", "expires_in": 300 }`
2. Watch receives `bootstrap_token` over `WCSession` (alongside HTTP URL metadata).
3. **POST** `/api/v1/watch/token`
  - Body: `{ "bootstrap_token": "<JWT>", "device_name": "Apple Watch", "public_key": "..." }` (optional device attestation / key in future).
  - **Response:**
    ```json
    {
      "access_token": "...",
      "refresh_token": "...",
      "expires_in": 3600,
      "token_type": "Bearer"
    }
    ```
4. Watch saves `access_token` + `refresh_token` in Keychain; uses `Authorization: Bearer` on ingest until expiry.

## Refresh

- **POST** `/oauth/token` or your issuer’s refresh endpoint  
  - `grant_type=refresh_token&refresh_token=...&client_id=...`
- On **401** from ingest, call refresh; on failure, show “Open iPhone app to sign in” and clear stale access token.

## Temporary path (spike / no backend yet)

- Push **Basic HTTP** credentials and URL from the phone (same as `Connection` HTTP mode).
- Optionally push **static Bearer** via custom HTTP headers from Settings.

See `WatchOAuthRefresher.swift` — refresh is wired as a stub until endpoints exist.

## Phase 2 — Location sync / friends (read scopes)

- Issue access tokens with scopes such as `locations:read`, `friends:read` separate from `locations:write`.
- Watch uses the same refresh flow with a broader scope only if the user enables “Friends on watch.”

