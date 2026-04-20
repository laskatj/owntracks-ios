# Phase 2 — Friends / map on watch (`LocationAPISync` style APIs)

## Goals

- Small payloads, infrequent polling, optional complications.
- **Least privilege:** read scopes distinct from location ingest.

## Suggested scopes


| Scope             | Use                            |
| ----------------- | ------------------------------ |
| `locations:write` | POST own location (ingest)     |
| `locations:read`  | Poll friend positions / deltas |
| `friends:read`    | Friend list metadata           |


## Token seeding

- Reuse the same **watch refresh token** as Phase 1, with expanded scopes granted when the user enables Phase 2 features on **iPhone** (authorization code + consent).
- Alternatively issue a **second** watch token pair only for read APIs (better revocation granularity).

## API shaping

- Prefer **delta** or **since=timestamp** query parameters over full snapshots.
- Cap response size server-side for watch clients (`Accept-Encoding: gzip`, limit friends).

## Client

- `WatchOAuthRefresher` supplies `Authorization: Bearer` for `URLSession` requests.
- Consider a dedicated thin `LocationSyncClient` (Swift) calling your existing REST paths used by `LocationAPISyncService.m`.