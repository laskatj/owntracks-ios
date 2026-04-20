# Field test checklist — Sauron watch ingest

Use real Apple Watch hardware (simulator does not exercise LTE/GPS the same way).

## Prerequisites

- iPhone paired; Sauron iOS app installed with valid **HTTP** URL and credentials.
- Open iOS app once after install so WatchConnectivity pushes config to the watch.

## Passive mode (24 h)

- Enable passive tracking on watch; wear all day.
- Confirm **queue depth** decreases when Wi‑Fi/LTE available (Status screen).
- Toggle **Airplane mode** on watch for 2 h; confirm points accumulate then flush.

## Active mode (60 min outdoor)

- Start **Active tracking**; walk or run.
- Confirm uploads at higher cadence (~90 s batch window).
- Compare track continuity to phone (expect minor differences).

## Standalone cellular

- Disable Bluetooth on **phone** (or leave phone at home); watch on LTE.
- Confirm uploads still succeed with queued credentials.

## Auth

- Basic HTTP: verify 401 clears after fixing password on phone and re-opening app.
- (When backend ready) Bootstrap token → watch token → refresh after expiry.

## Battery

- Note watch battery % before/after passive day and active session.
- Adjust `WatchTrackingPolicy` constants if drain exceeds targets in `TRACKING_MODES.md`.