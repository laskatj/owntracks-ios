//
//  WatchUploadScheduler.swift
//  SauronWatch
//
//  Drains the queue: batch POST when ≥2 points, else one location per POST (broker-compatible).
//  When the queue is empty, passive/active min intervals throttle the next send.
//

import Foundation
import Combine

final class WatchUploadScheduler: ObservableObject {
    @Published var queueDepth: Int = 0
    @Published var lastUpload: Date?
    @Published var lastUploadError: String?
    @Published var consecutiveFailures: Int = 0

    private var timer: AnyCancellable?
    private var enqueueObserver: AnyCancellable?
    private let client = WatchHTTPIngestClient()
    private let refresher = WatchOAuthRefresher()
    private var nextAttempt: Date = .distantPast

    func start(configStore: WatchConfigStore) {
        timer?.cancel()
        enqueueObserver?.cancel()
        queueDepth = PendingLocationQueue.shared.load().count

        enqueueObserver = NotificationCenter.default.publisher(for: .watchDidUpdateLocation)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshQueueDepth()
            }

        timer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.tick(configStore: configStore) }
            }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        enqueueObserver?.cancel()
        enqueueObserver = nil
    }

    func refreshQueueDepth() {
        queueDepth = PendingLocationQueue.shared.load().count
    }

    /// Upload until the queue is empty or a request fails (same backoff as periodic tick).
    func flushQueueNow(configStore: WatchConfigStore) async {
        nextAttempt = .distantPast

        let cfg = configStore.config
        guard !cfg.effectiveIngestURL.isEmpty else {
            await MainActor.run { self.lastUploadError = "Configure HTTP on iPhone" }
            return
        }

        var bearer = await refreshBearerIfNeeded(config: cfg)

        while true {
            let points = PendingLocationQueue.shared.load()
            await MainActor.run { self.queueDepth = points.count }
            guard !points.isEmpty else {
                await MainActor.run { self.lastUploadError = nil }
                return
            }

            let tokenForUpload = cfg.authBasic ? nil : bearer

            do {
                _ = try await uploadNextFromQueue(config: cfg, bearerToken: tokenForUpload)
                await MainActor.run {
                    self.lastUpload = Date()
                    self.lastUploadError = nil
                    self.consecutiveFailures = 0
                    self.queueDepth = PendingLocationQueue.shared.load().count
                }

                let remaining = PendingLocationQueue.shared.load().count
                if remaining == 0 { return }

                if remaining >= WatchTrackingPolicy.minQueueDepthForBatchIngest {
                    let spacing = WatchTrackingPolicy.backlogBatchSpacing
                    try await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
                } else {
                    let spacing = WatchTrackingPolicy.backlogUploadSpacing
                    try await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
                }
            } catch {
                await MainActor.run {
                    self.consecutiveFailures += 1
                }
                let failures = await MainActor.run { self.consecutiveFailures }
                let backoff = min(WatchTrackingPolicy.uploadBackoffInitial * pow(2.0, Double(min(failures, 8))), WatchTrackingPolicy.uploadBackoffMax)
                nextAttempt = Date().addingTimeInterval(backoff)
                let msg: String
                if (error as? URLError)?.code == .userAuthenticationRequired {
                    msg = "HTTP 401 — check credentials on iPhone"
                } else {
                    msg = error.localizedDescription
                }
                await MainActor.run {
                    self.lastUploadError = msg
                    self.queueDepth = PendingLocationQueue.shared.load().count
                }
                return
            }
        }
    }

    private func tick(configStore: WatchConfigStore) async {
        let mode = UserDefaults.standard.string(forKey: "watch_tracking_mode").flatMap { WatchTrackingMode(rawValue: $0) } ?? .passive
        let steadyStateMinInterval = mode == .active ? WatchTrackingPolicy.activeUploadMinInterval : WatchTrackingPolicy.passiveUploadMinInterval
        guard Date() >= nextAttempt else { return }

        let cfg = configStore.config
        guard !cfg.effectiveIngestURL.isEmpty else {
            await MainActor.run { self.lastUploadError = "Configure HTTP on iPhone" }
            return
        }

        let initialCount = PendingLocationQueue.shared.load().count
        await MainActor.run { self.queueDepth = initialCount }
        guard initialCount > 0 else { return }

        var bearer = await refreshBearerIfNeeded(config: cfg)

        let tokenForUpload = cfg.authBasic ? nil : bearer
        var uploadsThisTick = 0

        while uploadsThisTick < WatchTrackingPolicy.maxUploadsPerSchedulerTick {
            let points = PendingLocationQueue.shared.load()
            guard let first = points.first else {
                nextAttempt = Date().addingTimeInterval(steadyStateMinInterval)
                return
            }

            do {
                _ = try await uploadNextFromQueue(config: cfg, bearerToken: tokenForUpload)
                uploadsThisTick += 1
                await MainActor.run {
                    self.lastUpload = Date()
                    self.lastUploadError = nil
                    self.consecutiveFailures = 0
                    self.queueDepth = PendingLocationQueue.shared.load().count
                }

                let remaining = PendingLocationQueue.shared.load().count
                if remaining == 0 {
                    nextAttempt = Date().addingTimeInterval(steadyStateMinInterval)
                    return
                }

                if remaining >= WatchTrackingPolicy.minQueueDepthForBatchIngest {
                    let spacing = WatchTrackingPolicy.backlogBatchSpacing
                    try await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
                } else {
                    let spacing = WatchTrackingPolicy.backlogUploadSpacing
                    try await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000))
                }
            } catch {
                await MainActor.run {
                    self.consecutiveFailures += 1
                }
                let failures = await MainActor.run { self.consecutiveFailures }
                let backoff = min(WatchTrackingPolicy.uploadBackoffInitial * pow(2.0, Double(min(failures, 8))), WatchTrackingPolicy.uploadBackoffMax)
                nextAttempt = Date().addingTimeInterval(backoff)
                let msg: String
                if (error as? URLError)?.code == .userAuthenticationRequired {
                    msg = "HTTP 401 — check credentials on iPhone"
                } else {
                    msg = error.localizedDescription
                }
                await MainActor.run {
                    self.lastUploadError = msg
                    self.queueDepth = PendingLocationQueue.shared.load().count
                }
                return
            }
        }

        nextAttempt = .distantPast
    }

    /// OAuth refresh when access token near expiry. Returns bearer token (may be nil).
    private func refreshBearerIfNeeded(config cfg: WatchHTTPConfig) async -> String? {
        var bearer: String? = WatchAuthKeychain.loadTokens()?.accessToken
        if let tokens = WatchAuthKeychain.loadTokens(),
           let exp = tokens.accessTokenExpiry,
           Date().timeIntervalSince1970 > exp - 60,
           tokens.refreshToken != nil {
            do {
                let url = cfg.oauthRefreshURL.flatMap { URL(string: $0) }
                let newTok = try await refresher.refreshTokens(current: tokens, refreshURL: url, clientId: cfg.oauthClientId)
                try? WatchAuthKeychain.saveTokens(newTok)
                bearer = newTok.accessToken
            } catch {
                // fall through — Basic auth or static headers may still work
            }
        }
        return bearer
    }

    /// Performs one batch or single upload from the head of the queue.
    private func uploadNextFromQueue(config: WatchHTTPConfig, bearerToken: String?) async throws -> Int {
        let points = PendingLocationQueue.shared.load()
        guard let first = points.first else { return 0 }
        let count = points.count
        if count >= WatchTrackingPolicy.minQueueDepthForBatchIngest {
            let batchSize = min(count, WatchTrackingPolicy.maxBatchSize)
            let slice = Array(points.prefix(batchSize))
            let batchId = UUID()
            try await client.uploadBatch(points: slice, batchId: batchId, config: config, bearerToken: bearerToken)
            PendingLocationQueue.shared.removeFirst(batchSize)
            return batchSize
        } else {
            try await client.upload(point: first, config: config, bearerToken: bearerToken)
            PendingLocationQueue.shared.removeFirst(1)
            return 1
        }
    }
}
