//
//  OTInboxRealtimeCoordinator.swift
//  OwnTracks
//

import Foundation
import SignalRClient
import UIKit

private let kOAuthTokenNotification = Notification.Name("OwnTracksOAuthAccessTokenBecameAvailable")

@objc(OTInboxRealtimeCoordinator)
@objcMembers
public final class OTInboxRealtimeCoordinator: NSObject {

    public static let shared = OTInboxRealtimeCoordinator()

    private var connectionTask: Task<Void, Never>?
    private var debounceWork: DispatchWorkItem?
    private var oauthReconnectDebounceWork: DispatchWorkItem?
    private let lifeLock = NSLock()
    private var observationWired = false

    /// After repeated negotiate failures (e.g. HTTP 405 — hub not deployed), pause hub attempts to stop log spam.
    private var suspendRealtimeHubUntil: Date?
    private var hubNegotiateFailureCount: Int = 0
    private static let hubSuspendDuration: TimeInterval = 900
    private static let hubFailuresBeforeSuspend: Int = 2
    private static let oauthReconnectDebounceSeconds: TimeInterval = 2.0

    private override init() {
        super.init()
    }

    /// Call once after launch to observe lifecycle and OAuth readiness.
    @objc public func activate() {
        lifeLock.lock()
        defer { lifeLock.unlock() }
        if observationWired {
            return
        }
        observationWired = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOAuthReady),
            name: kOAuthTokenNotification,
            object: nil
        )

        if UIApplication.shared.applicationState == .active {
            reconnectSignalRSession()
        }
    }

    @objc private func handleForeground() {
        suspendRealtimeHubUntil = nil
        hubNegotiateFailureCount = 0
        oauthReconnectDebounceWork?.cancel()
        oauthReconnectDebounceWork = nil
        reconnectSignalRSession()
    }

    @objc private func handleBackground() {
        connectionTask?.cancel()
        connectionTask = nil
    }

    /// Debounced so each silent refresh does not immediately start another token fetch + negotiate cycle.
    @objc private func handleOAuthReady() {
        guard UIApplication.shared.applicationState == .active else { return }
        oauthReconnectDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconnectSignalRSession()
        }
        oauthReconnectDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.oauthReconnectDebounceSeconds, execute: work)
    }

    private func reconnectSignalRSession() {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            await self?.runHubSession()
        }
    }

    private func postDebouncedInboxRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            debounceWork?.cancel()
            let work = DispatchWorkItem {
                NotificationCenter.default.post(
                    name: .OTInboxShouldRefresh,
                    object: nil,
                    userInfo: [OTInboxShouldRefreshReasonKey: OTInboxShouldRefreshReasonSignalR]
                )
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func fetchAccessTokenAsync() async -> String? {
        await withCheckedContinuation { cont in
            LocationAPISyncService.sharedInstance().obtainOAuthAccessTokenForAPICalls { token in
                cont.resume(returning: token)
            }
        }
    }

    private func runHubSession() async {
        if Task.isCancelled {
            return
        }

        let suspended: Bool = await MainActor.run { [weak self] in
            guard let self else { return false }
            if let until = self.suspendRealtimeHubUntil, Date() < until {
                return true
            }
            return false
        }
        if suspended {
            return
        }

        guard let token = await fetchAccessTokenAsync(), !token.isEmpty else {
            return
        }

        let hubURLString: String? = await MainActor.run {
            OTInboxRealtimeSignalRHubURL(CoreData.sharedInstance().mainMOC, token)?.absoluteString
        }
        guard let hubURLString else {
            return
        }

        let hub = HubConnectionBuilder()
            .withUrl(url: hubURLString)
            .withAutomaticReconnect(retryDelays: [0, 2, 5, 15, 30])
            .withLogLevel(logLevel: .warning)
            .build()

        await hub.on(OTRealtimeInboxSignalREventName as String) { [weak self] in
            self?.postDebouncedInboxRefresh()
        }
        await hub.on(OTRealtimeLocationHubAdminNotificationEventName as String) { [weak self] in
            self?.postDebouncedInboxRefresh()
        }

        do {
            try await hub.start()
            await MainActor.run { [weak self] in
                self?.hubNegotiateFailureCount = 0
                self?.suspendRealtimeHubUntil = nil
            }
        } catch {
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hubNegotiateFailureCount += 1
                if self.hubNegotiateFailureCount >= Self.hubFailuresBeforeSuspend {
                    self.suspendRealtimeHubUntil = Date().addingTimeInterval(Self.hubSuspendDuration)
                    self.hubNegotiateFailureCount = 0
                }
            }
            return
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        await hub.stop()
    }
}
