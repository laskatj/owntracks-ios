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
    private let lifeLock = NSLock()
    private var observationWired = false

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
        reconnectSignalRSession()
    }

    @objc private func handleBackground() {
        connectionTask?.cancel()
        connectionTask = nil
    }

    @objc private func handleOAuthReady() {
        if UIApplication.shared.applicationState == .active {
            reconnectSignalRSession()
        }
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

        do {
            try await hub.start()
        } catch {
            return
        }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        await hub.stop()
    }
}
