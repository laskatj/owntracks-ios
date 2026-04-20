# watchOS hybrid tracking — sampling and escalation

Defaults implemented in `SauronWatch/Tracking/WatchTrackingPolicy.swift`.

## Passive mode (best-effort)

- **Goal:** Low battery use; accept gaps when the system does not deliver locations.
- **CLLocationManager**
  - `desiredAccuracy`: `kCLLocationAccuracyHundredMeters`
  - `distanceFilter`: **200 m**
- **Note:** `significantLocationChangeMonitoring` is **unavailable on watchOS** in current SDKs; passive mode uses **coarse `startUpdatingLocation`** only.
- **Upload cadence (scheduler):** with a **backlog**, sends one POST per point about every **0.5 s** until empty; with an **empty** queue, waits **5 minutes** before the next upload (steady-state throttle).

## Active mode (reliable while user is tracking)

- **Trigger:** User enables **Active tracking** in the watch UI (foreground session).
- **CLLocationManager**
  - `desiredAccuracy`: `kCLLocationAccuracyBest`
  - `distanceFilter`: **10 m**
- **Upload cadence:** backlog drains quickly; steady-state throttle **90 seconds** when the queue is empty.

## Escalation (optional / future)

- Not enabled in v1. A possible rule: if `CLLocation.speed > 3 m/s` for several samples while in passive mode, temporarily tighten `distanceFilter` or switch UI to suggest Active mode.

## Battery budget (targets for field tuning)

- Passive daily wear: aim for **< 10%** extra battery drain vs baseline watch use (measure on hardware).
- Active 1 h outdoor: acceptable **15–25%** drain depending on LTE/Wi‑Fi upload pattern — tune `distanceFilter` and upload interval if exceeded.

## Retry / backoff

See `WatchHTTPIngestClient` and `PendingLocationQueue`: exponential backoff caps at **30 minutes** between upload attempts after repeated failures.