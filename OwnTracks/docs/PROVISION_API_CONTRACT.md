# POST `/api/config/provision` — identity contract (Sauron / dynamic provision)

The iOS app prefers a **two-step guided** flow when the server supports `POST /api/config/provision/options`; otherwise it uses a **legacy** single `POST /api/config/provision`. Both ultimately apply a JSON **OwnTracks configuration** (`_type: "configuration"`, same shape as `Settings.fromDictionary:`).

## Guided native provision (preferred)

1. **`POST /api/config/provision/options`** — JSON body: `{ "deviceName": "<sanitized visible device name>" }` (`^[a-zA-Z0-9 ]+$`). Response (example shape):
   - `user`: `{ "id", "displayName", "topicUser" }` (for UI context).
   - `existingDevices`: array of `{ "trackedDeviceId", "displayName", "deviceId", "pubTopicBase", "lastSeenAt" (ISO-8601), "lastTrackerId" }`.
   - `newDevice`: optional preview only — **not** applied by the client; final settings come from step 2.

2. **Device choice (iOS)** — If `existingDevices` is non-empty, the app shows an alert: “Is this one of your existing Sauron devices?” with a numbered summary (topic, last seen). The user picks an existing row, **This is a new device**, or **Cancel** (aborts native provision; embedded web may continue).

3. **`POST /api/config/provision`** — Body = same **hints** as the legacy flow (`deviceName`, `identifierForVendor`, `hardwareMachine`, …) **plus**:
   - `mode`: `"new"` or `"existing"`.
   - `trackedDeviceId`: server id (number) when `mode` is `"existing"`; omitted for `"new"`.

4. **Apply response** — Only the final `_type: "configuration"` JSON from step 3 is applied. When `mode` was sent, the client **does not** run `applyLocalProvisionIdentityRepairToMutableConfiguration:` on validation failure (server identity is authoritative). If `POST /options` returns **404**, the app uses the **legacy** single `POST /provision` without `mode` and may still apply client-side repair on failed validation.

## Legacy single-step `POST /api/config/provision`

If `/api/config/provision/options` is unavailable (404), the app POSTs hints-only JSON to `/api/config/provision` as before.

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

If the provision response still contains generic `deviceId` / `tid` values, the iOS app may **rewrite identity fields** (`username`, `deviceId`, `clientId`, `tid`) after **legacy** `POST /api/config/provision` (no `mode` in the request) and before applying settings, so installs can self-heal without backend changes. **Guided** provision (request included `mode`) does **not** apply that rewrite. The app does **not** rewrite `pubTopicBase` / publish topic in either path.

Installs with a placeholder broker host are detected via `migrateWebProvisioningFlagIfNeededInMOC:`; the app sets `needs_web_provisioning` so native/Web provision can run. Server-side corrections can be pushed with a remote `setConfiguration` cmd after the client publishes its config (QoS 2 dump on foreground). See `applyLocalProvisionIdentityRepairToMutableConfiguration:inMOC:` for legacy single-step provision repair.

## Related

- Native provision: `LocationAPISyncService` `provisionRemoteDeviceConfigurationIfNeededWithCompletion:` (`POST /api/config/provision/options` when available, then `POST /api/config/provision`) → `OwnTracksAppDelegate configFromDictionary:`.
- Embedded web flow: `OwnTracks/docs/REACT_WEBAPP_EMBED_PROMPT.md`.
