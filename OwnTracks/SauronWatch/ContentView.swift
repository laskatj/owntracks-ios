//
//  ContentView.swift
//  SauronWatch
//

import SwiftUI
import CoreLocation

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
            VStack(alignment: .leading, spacing: 8) {
                Text("Sauron Watch")
                    .font(.headline)

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
                    Text(sendNowBusy ? "Sending…" : "Send now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sendNowBusy || config.config.effectiveIngestURL.isEmpty)

                if let hint = sendNowHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Picker("Mode", selection: $modeRaw) {
                    Text("Passive").tag(WatchTrackingMode.passive.rawValue)
                    Text("Active").tag(WatchTrackingMode.active.rawValue)
                }
                .onChange(of: modeRaw) { _, new in
                    let m = WatchTrackingMode(rawValue: new) ?? .passive
                    tracker.apply(mode: m)
                }

                Group {
                    Text("POST URL")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(displayPostURL(config.config))
                        .font(.caption)
                        .lineLimit(4)
                }

                LabeledContent("Auth") {
                    Text(config.config.authBasic ? "Basic" : "Headers / Bearer")
                        .font(.caption2)
                }

                LabeledContent("Queue") {
                    Text("\(scheduler.queueDepth)")
                }

                if let last = scheduler.lastUpload {
                    LabeledContent("Last upload") {
                        Text(last, style: .relative)
                            .font(.caption2)
                    }
                }

                if let err = scheduler.lastUploadError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                LabeledContent("WC") {
                    Text(config.lastSyncMessage)
                        .font(.caption2)
                }

                if let le = tracker.lastError {
                    Text(le)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text("Location auth: \(authLabel(tracker.authorization))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
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
