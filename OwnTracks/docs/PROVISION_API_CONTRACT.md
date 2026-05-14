# POST `/api/config/provision` — identity contract (Sauron / dynamic provision)

This repository’s iOS app calls `POST /api/config/provision` with a **Bearer access token** and expects a JSON **OwnTracks configuration** object (same shape as `Settings.fromDictionary:` / `_type: "configuration"`).

## Server responsibilities

1. **Authoritative identity** MUST be derived from the authenticated user (JWT / session), never from untrusted client-only hints.
2. **`deviceId`** MUST be **unique per user** (and stable for the same physical install when hints match). It MUST NOT be a generic host string such as `iPhone`, `iPad`, `Device`, or the raw device marketing name alone.
3. **`username`** (MQTT user / topic user segment) MUST identify the **authenticated account** (slug or stable id), not a shared placeholder.
4. **`clientId`** (MQTT) MUST be **unique** per device record (or per install if you rotate clients); avoid a single shared client id for all phones.
5. **`tid`** is a **short display label** only. It MUST NOT be used for authorization, topic routing, or “same device” detection in clients. Prefer uniqueness when possible, but the canonical identity is **`deviceId` + `username` + publish topic**.
6. **`pubTopicBase`** SHOULD be explicit (`owntracks/{username}/{deviceId}`) OR omit and rely on `%u` / `%d` expansion with the returned `username` and `deviceId` so the effective publish topic is unambiguous.

## Request body (client → server)

The app sends JSON with **hints only** (non-authoritative except where noted):

| Field | Type | Description |
|-------|------|-------------|
| `deviceName` | string | Sanitized `[UIDevice currentDevice].name` (`^[a-zA-Z0-9 ]+$`) for display / default slug generation. |
| `identifierForVendor` | string | iOS `identifierForVendor` UUID for this vendor + install (stable until reinstall). |
| `hardwareMachine` | string | `uname(2)` machine string (e.g. `iPhone15,2`). |
| `bundleIdentifier` | string | App bundle id. |
| `appVersionShort` | string | `CFBundleShortVersionString`. |
| `appBuild` | string | `CFBundleVersion`. |
| `existingDeviceId` | string? | Prior `deviceid_preference` if reprovisioning the same install. |
| `existingTrackerId` | string? | Prior `trackerid_preference` if any. |

The server SHOULD:

- Prefer **reusing** the same device row when `existingDeviceId` matches a device already owned by this user.
- Allocate a new **user-scoped** `deviceId` (e.g. `alice-iphone`, `alice-iphone-2`, or opaque slug + suffix) when creating a new device.

## Response body (server → client)

Must be parseable as `_type: "configuration"` (the app may normalize missing `_type`). Must satisfy the identity rules above so that:

- `owntracks/{username}/{deviceId}` (or equivalent `pubTopicBase`) is unique in your namespace.
- `tid` does not collide across unrelated devices in a way that breaks UI; clients no longer treat `tid` as proof of identity.

## iOS client compatibility (no server change)

If the provision response still contains generic `deviceId` / `tid` values, the iOS app may **rewrite identity fields** (`username`, `deviceId`, `clientId`, `tid`) after `POST /api/config/provision` and before applying settings, so installs can self-heal without backend changes. It does **not** rewrite `pubTopicBase` / publish topic so the device remains the same in backends that key on topic. The preferred contract remains server-issued unique identity.

Installs with already-applied bad identity are detected once the broker host is non-placeholder; the app sets `needs_web_provisioning` so native provision runs again. See `Settings migrateProvisionedIdentityRepairFlagIfNeededInMOC:` and `applyLocalProvisionIdentityRepairToMutableConfiguration:inMOC:`.

## Related

- Native provision trigger: `LocationAPISyncService` → `OwnTracksAppDelegate configFromDictionary:`.
- Embedded web flow: `OwnTracks/docs/REACT_WEBAPP_EMBED_PROMPT.md`.
