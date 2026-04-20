//
//  WatchLocationTracker.swift
//  SauronWatch
//

import Foundation
import CoreLocation

enum WatchSendNowError: LocalizedError {
    case locationAuthDenied
    case invalidLocation
    case sendNowAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .locationAuthDenied: return "Location not authorized"
        case .invalidLocation: return "Could not get a valid fix"
        case .sendNowAlreadyInProgress: return "Send now already running"
        }
    }
}

final class WatchLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?
    @Published var lastError: String?

    private let manager = CLLocationManager()
    private(set) var mode: WatchTrackingMode = .passive
    /// Last point we sent to the upload queue (active-mode throttle only).
    private var lastEnqueuedLocation: CLLocation?
    private var lastEnqueueWallTime: Date?

    private var pendingSendNowOneShot = false
    private var sendNowContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
    }

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// One-shot `requestLocation` fix, enqueued regardless of active-mode throttle.
    func enqueueSendNowLocation() async throws {
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            throw WatchSendNowError.locationAuthDenied
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if self.sendNowContinuation != nil {
                cont.resume(throwing: WatchSendNowError.sendNowAlreadyInProgress)
                return
            }
            self.sendNowContinuation = cont
            self.pendingSendNowOneShot = true
            self.manager.requestLocation()
        }
    }

    func apply(mode: WatchTrackingMode) {
        self.mode = mode
        lastEnqueuedLocation = nil
        lastEnqueueWallTime = nil

        manager.stopUpdatingLocation()
        // Significant-location APIs are unavailable on watchOS; use coarse vs best continuous updates.
        switch mode {
        case .passive:
            manager.desiredAccuracy = WatchTrackingPolicy.passiveDesiredAccuracy
            manager.distanceFilter = WatchTrackingPolicy.passiveDistanceFilter
            manager.startUpdatingLocation()
        case .active:
            manager.desiredAccuracy = WatchTrackingPolicy.activeDesiredAccuracy
            manager.distanceFilter = WatchTrackingPolicy.activeDistanceFilter
            manager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        lastError = nil

        if pendingSendNowOneShot {
            pendingSendNowOneShot = false
            let cont = sendNowContinuation
            sendNowContinuation = nil

            guard CLLocationCoordinate2DIsValid(loc.coordinate), loc.horizontalAccuracy >= 0 else {
                cont?.resume(throwing: WatchSendNowError.invalidLocation)
                return
            }

            PendingLocationQueue.shared.append(QueuedLocationPoint(location: loc))
            lastEnqueuedLocation = loc
            lastEnqueueWallTime = Date()
            NotificationCenter.default.post(name: .watchDidUpdateLocation, object: loc)
            cont?.resume()
            return
        }

        guard shouldEnqueueForUpload(loc) else { return }
        guard CLLocationCoordinate2DIsValid(loc.coordinate) else { return }
        guard loc.horizontalAccuracy >= 0 else { return }

        PendingLocationQueue.shared.append(QueuedLocationPoint(location: loc))
        NotificationCenter.default.post(name: .watchDidUpdateLocation, object: loc)
    }

    /// Passive: every delivery is enqueued. Active: throttle stationary drift — min time **or** min displacement.
    private func shouldEnqueueForUpload(_ loc: CLLocation) -> Bool {
        switch mode {
        case .passive:
            return true
        case .active:
            guard let last = lastEnqueuedLocation, let t = lastEnqueueWallTime else {
                lastEnqueuedLocation = loc
                lastEnqueueWallTime = Date()
                return true
            }
            let dt = Date().timeIntervalSince(t)
            let dist = loc.distance(from: last)
            if dt >= WatchTrackingPolicy.activeMinEnqueueInterval
                || dist >= WatchTrackingPolicy.activeMinDisplacementMeters {
                lastEnqueuedLocation = loc
                lastEnqueueWallTime = Date()
                return true
            }
            return false
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
        if let cont = sendNowContinuation {
            sendNowContinuation = nil
            pendingSendNowOneShot = false
            cont.resume(throwing: error)
        }
    }
}

extension Notification.Name {
    static let watchDidUpdateLocation = Notification.Name("watchDidUpdateLocation")
}
