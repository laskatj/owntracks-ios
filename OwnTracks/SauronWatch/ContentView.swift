//
//  ContentView.swift
//  SauronWatch
//

import SwiftUI
import CoreLocation
import WidgetKit

struct ContentView: View {
    @EnvironmentObject private var config: WatchConfigStore
    @EnvironmentObject private var tracker: WatchLocationTracker
    @EnvironmentObject private var scheduler: WatchUploadScheduler

    @AppStorage("watch_tracking_mode") private var modeRaw: String = WatchTrackingMode.passive.rawValue
    @State private var sendNowBusy = false
    @State private var sendNowHint: String?

    private var mode: WatchTrackingMode {
        get { WatchTrackingMode(rawValue: modeRaw) ?? .passive }
        nonmutating set { modeRaw = newValue.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {

                Text("OwnTracks")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Button {
                        modeRaw = WatchTrackingMode.passive.rawValue
                        tracker.apply(mode: .passive)
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        Text("Passive").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(mode == .passive ? .blue : nil)

                    Button {
                        modeRaw = WatchTrackingMode.active.rawValue
                        tracker.apply(mode: .active)
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        Text("Active").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(mode == .active ? .blue : nil)
                }

                Button {
                    sendNowHint = nil
                    Task { @MainActor in
                        sendNowBusy = true
                        defer { sendNowBusy = false }
                        do {
                            try await tracker.enqueueSendNowLocation()
                        } catch {
                            sendNowHint = error.localizedDescription
                        }
                        await scheduler.flushQueueNow(configStore: config)
                    }
                } label: {
                    Text(sendNowBusy ? "Sending…" : "Send Now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sendNowBusy || config.config.effectiveIngestURL.isEmpty)

                if let hint = sendNowHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Text("\(scheduler.queueDepth)")
                            .monospacedDigit()
                    } label: {
                        Text("Queue")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let last = scheduler.lastUpload {
                        LabeledContent {
                            Text(last, style: .relative)
                                .font(.caption2)
                        } label: {
                            Text("Last")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let err = scheduler.lastUploadError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    if let le = tracker.lastError {
                        Text(le)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayPostURL(config.config))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    HStack {
                        Text("Auth")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(config.config.authBasic ? "Basic" : "Bearer")
                            .font(.caption2)
                    }

                    HStack {
                        Text("Sync")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(config.lastSyncMessage)
                            .font(.caption2)
                    }

                    Text(authLabel(tracker.authorization))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .onAppear {
            tracker.apply(mode: mode)
        }
    }

    private func displayPostURL(_ cfg: WatchHTTPConfig) -> String {
        let u = cfg.effectiveIngestURL
        if u.isEmpty { return "(need iPhone sync for auth)" }
        return u
    }

    private func authLabel(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when in use"
        @unknown default: return "unknown"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchConfigStore.shared)
        .environmentObject(WatchLocationTracker())
        .environmentObject(WatchUploadScheduler())
}
