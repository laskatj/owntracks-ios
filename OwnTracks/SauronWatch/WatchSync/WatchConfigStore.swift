//
//  WatchConfigStore.swift
//  SauronWatch
//

import Foundation
import WatchConnectivity

final class WatchConfigStore: NSObject, ObservableObject {
    static let shared = WatchConfigStore()

    @Published private(set) var config: WatchHTTPConfig = .empty
    @Published private(set) var lastSyncMessage: String = "—"

    private let defaults = UserDefaults.standard
    private let key = "watch_http_config_json"

    override private init() {
        super.init()
        if let data = defaults.data(forKey: key),
           let c = try? JSONDecoder().decode(WatchHTTPConfig.self, from: data) {
            config = c
        }
        if WCSession.isSupported() {
            let s = WCSession.default
            s.delegate = self
            s.activate()
        }
    }

    func applyFromPhone(_ dict: [String: Any]) {
        let url = dict["httpURL"] as? String ?? ""
        let override = WatchTrackingPolicy.ingestURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty && override.isEmpty {
            lastSyncMessage = "No HTTP URL"
            return
        }
        let authBasic = dict["authBasic"] as? Bool ?? false
        let user = dict["user"] as? String ?? "user"
        let pass = dict["pass"] as? String ?? ""
        let limitU = dict["limitU"] as? String ?? user
        let limitD = dict["limitD"] as? String ?? "device"
        let lines = dict["httpHeaderLines"] as? String ?? ""
        let tid = dict["trackerId"] as? String
        let rawDeviceId = dict["deviceId"] as? String ?? limitD
        let rawTopic = dict["publishTopic"] as? String
        let ext = dict["includeExtendedData"] as? Bool ?? true
        let refresh = dict["oauthRefreshURL"] as? String
        let client = dict["oauthClientId"] as? String

        let c = WatchHTTPConfig(
            httpURL: url,
            authBasic: authBasic,
            user: user,
            pass: pass,
            limitU: limitU,
            limitD: limitD,
            httpHeaderLines: lines,
            trackerId: tid,
            deviceId: rawDeviceId.isEmpty ? nil : rawDeviceId,
            publishTopic: rawTopic.flatMap { $0.isEmpty ? nil : $0 },
            includeExtendedData: ext,
            oauthRefreshURL: refresh,
            oauthClientId: client
        )
        config = c
        if let data = try? JSONEncoder().encode(c) {
            defaults.set(data, forKey: key)
        }
        lastSyncMessage = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    }
}

extension WatchConfigStore: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.lastSyncMessage = "WC error: \(error.localizedDescription)"
            } else {
                self.lastSyncMessage = "WC active"
            }
            self.consumeContext(session)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.applyFromPhone(applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.applyFromPhone(message)
        }
    }

    private func consumeContext(_ session: WCSession) {
        if !session.applicationContext.isEmpty {
            applyFromPhone(session.applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async {
            self.applyFromPhone(userInfo)
        }
    }
}
