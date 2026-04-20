# HTTP ingest contract (watch → backend)

Aligned with the iOS app’s HTTP POST behavior in `Connection.m` (`sendHTTP:data:`) and OwnTracks location JSON from `OwnTracking waypointAsJSON:`.

## Request

- **Method:** `POST`
- **URL:** By default the watch uses the same URL as iOS **Settings → HTTP → URL** (`url_preference`), pushed via WatchConnectivity. The Sauron watch target also supports a **fixed override** in `WatchTrackingPolicy.ingestURLOverride` (e.g. `http://homeassistant.tlaska.com/api/webhook/applewatch`) so watch traffic can hit a dedicated Home Assistant webhook while auth/headers still come from the phone.
- **Headers**
  - `Content-Type: application/json`
  - `Content-Length`
  - **Basic auth** (when enabled on phone): `Authorization: Basic base64(user:pass)` — same as iOS.
  - `X-Limit-U`: user id string (default `user` from settings).
  - `X-Limit-D`: device id string (from `clientid_preference` on phone, same as MQTT/device in `Connection`).
  - Extra headers from `httpheaders_preference` (newline-separated `Key: Value` lines on phone).
  - `X-Idempotency-Key`: see below (single location vs batch).

## Body modes

### Single location (queue depth = 1)

Same as iPhone HTTP: UTF‑8 JSON for **one** OwnTracks location object (not an array). `X-Idempotency-Key` is the per-point key stored on enqueue (`QueuedLocationPoint.idempotencyKey`).

### Batch (queue depth ≥ 2)

When the watch has **two or more** persisted points, it sends **one** POST whose body is a batch envelope. Limits are `WatchTrackingPolicy.maxBatchSize` (default 40) and `WatchTrackingPolicy.minQueueDepthForBatchIngest` (default 2).

Canonical JSON:

```json
{
  "_type": "batch",
  "batchId": "<uuid>",
  "points": [
    { "_type": "location", "lat": ..., "lon": ..., ... },
    ...
  ]
}
```

Each element of `points` uses the same field rules as the single-location table below (OwnTracks-style `_type: location`, plus watch fields such as `t`, `ver`, optional `deviceId` / `topic`, etc.).

**Idempotency (batch):** `X-Idempotency-Key` equals the **`batchId`** UUID string. Retrying the same failed request reuses the same key so the server can treat the retry as idempotent for the whole batch.

**Broker / Home Assistant:** Many pipelines expect a **single** top-level `lat` / `lon`. Batch mode requires ingest logic that checks for `_type == "batch"` (or presence of `points`) and **iterates** `points` (e.g. HA automation `{% for p in trigger.json.points %}`). If your endpoint only accepts a flat location object, ensure the queue rarely exceeds one point or adapt the server.

## Location JSON (minimal)

Required / typical fields for each location object (single POST or each entry in `points`):


| Field               | Type   | Notes                                                                                |
| ------------------- | ------ | ------------------------------------------------------------------------------------ |
| `_type`             | string | `"location"`                                                                         |
| `lat`               | number | 6 decimal places recommended                                                         |
| `lon`               | number | 6 decimal places                                                                     |
| `tst`               | number | Unix seconds                                                                         |
| `acc`               | number | meters, if ≥ 0                                                                       |
| `t`                 | string | trigger (`"w"` = watch)                                                              |
| `tid`               | string | tracker id from phone `trackerid_preference` when set                                |
| `deviceId`          | string | iOS device id (`theDeviceIdInMOC`), synced from phone; omitted if empty              |
| `topic`             | string | iOS MQTT publish topic (`theGeneralTopicInMOC`), synced from phone; omitted if empty |
| `ver`               | string | watch app `CFBundleVersion`                                                          |
| `batt`              | int    | 0–100 when available                                                                 |
| `bs`                | int    | battery state when available                                                         |
| `vel`/`cog`/`alt`/… |        | included when extended data is enabled in policy                                     |


## Error handling

- **2xx:** dequeue the sent payload — **one** point removed after a single-location POST, or **`points.count`** removed after a successful batch POST.
- **401:** mark auth error; user must re-sync config from phone or refresh tokens (see `WATCH_AUTH_API.md`).
- **429 / 5xx:** keep queue unchanged (no partial dequeue on batch failure), apply backoff on the client.

The iPhone continues to send **one location per POST**; batching is **watch-only** for faster backlog drain.
