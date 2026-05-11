import Foundation
import Combine
import CoreLocation
import MapKit
import HealthKit

enum DeviceDetailConnectionTransport: Int {
    case wifi = 0
    case cellular = 1
    case noNetwork = 2
    case unknown = 3
}

@objc class DeviceDetailViewModel: NSObject, ObservableObject {
    /// MQTT topic of the `Friend` this screen represents (stable across waypoint inserts).
    private let friendTopic: String
    private let friendObjectID: NSManagedObjectID?
    /// Always the latest `Friend.newestWaypoint` for this friend when sync runs; starts resolved in `init`.
    private var currentWaypoint: Waypoint

    // Unit preference: read from UserDefaults, defaults to false (= imperial)
    static var useMetric: Bool {
        return UserDefaults.standard.bool(forKey: "useMetric")
    }

    @Published var connectionTransport: DeviceDetailConnectionTransport = .unknown

    @Published var deviceName: String = ""
    @Published var topic: String = ""
    @Published var tid: String = ""
    @Published var avatarData: Data? = nil

    @Published var lastSeenDate: Date? = nil
    @Published var connectionText: String = "-"
    @Published var isOnline: Bool = false

    @Published var batteryLevel: Double = -1
    @Published var batteryStatusText: String = ""

    @Published var address: String = ""
    @Published var coordinateText: String = ""
    @Published var accuracyText: String = ""
    @Published var distanceText: String = ""

    @Published var timestampText: String = ""
    @Published var altitudeText: String = ""
    @Published var speedText: String = ""
    @Published var headingText: String = ""
    @Published var triggerText: String = ""
    @Published var monitoringText: String = ""
    @Published var heartRateText: String = "-"
    /// Sample time for the BPM currently shown on the heart tile (waypoint tst, BLE, or HealthKit).
    @Published var heartRateLastSampleDate: Date? = nil

    @Published var ssid: String? = nil
    @Published var bssid: String? = nil
    @Published var regions: [String] = []
    @Published var motionActivities: [String] = []
    @Published var poi: String? = nil
    @Published var tag: String? = nil
    @Published var photoData: Data? = nil
    @Published var zoneName: String? = nil

    private var geocacheObserver: NSObjectProtocol?

    // Chart data values are stored in the display unit (mph/ft or km/h/m)
    @Published var speedHistory: [(date: Date, value: Double)] = []
    @Published var altitudeHistory: [(date: Date, value: Double)] = []
    /// Last 12 hours of HealthKit heart rate samples (own device only); display unit is bpm.
    @Published var heartRateHistory: [(date: Date, value: Double)] = []
    /// Shared 12h window for the aligned metrics sheet (same instants for all charts).
    @Published var metricsChartStart: Date = .distantPast
    @Published var metricsChartEnd: Date = .distantPast
    @Published var metricsChartSpeedHistory: [(date: Date, value: Double)] = []
    @Published var metricsChartAltitudeHistory: [(date: Date, value: Double)] = []
    /// Battery fraction 0…1 (matches `Waypoint.batt` / OwnTracks JSON `batt` as percent/100).
    @Published var metricsChartBatteryHistory: [(date: Date, value: Double)] = []
    /// Own device: legacy slot mirrors local+API merged series for the metrics sheet; friend: sparse waypoint or route API HR.
    @Published var metricsChartHeartRateHistory: [(date: Date, value: Double)] = []
    /// Own device only: local disk samples merged with route API (`hr` / `heartRate`), API wins within ±30s.
    @Published var metricsChartLocalPlusApiHeartRateHistory: [(date: Date, value: Double)] = []
    /// Own device only: HealthKit samples for a second chart (comparison).
    @Published var metricsChartHealthKitOnlyHeartRateHistory: [(date: Date, value: Double)] = []
    @Published var speedUnit: String = ""
    @Published var altitudeUnit: String = ""

    @Published var showCopiedNotice: Bool = false

    /// Own device (general MQTT topic) — show account home/work zone ids from `/api/authorization/user`.
    @Published var showsUserAccountZoneIds: Bool = false
    @Published var homeZoneIdText: String = "-"
    @Published var workZoneIdText: String = "-"

    /// Matches `OTHealthKitHeartRateDidUpdateNotification` in `HealthKitHeartRateManager.m`.
    private static let healthKitHeartRateUpdated = Notification.Name("OTHealthKitHeartRateDidUpdateNotification")
    /// Matches `OTBluetoothHeartRateDidUpdateNotification` in `BluetoothHeartRateManager.m`.
    private static let bluetoothHeartRateUpdated = Notification.Name("OTBluetoothHeartRateDidUpdateNotification")
    /// Same notification name as `ViewController` live map updates (`OwnTracksAppDelegate` posts it).
    private static let liveFriendLocation = Notification.Name("OTLiveFriendLocation")
    private static let heartRateDisplayMaxSampleAge: TimeInterval = 15 * 60
    private static let heartRateHistoryLookbackSeconds: TimeInterval = 12 * 3600

    private var heartRateObserver: NSObjectProtocol?
    private var bluetoothHeartRateObserver: NSObjectProtocol?
    private var liveFriendLocationObserver: NSObjectProtocol?
    private var oauthSensitiveObserver: NSObjectProtocol?
    private var userProfileObserver: NSObjectProtocol?
    private var localHeartRateStoreObserver: NSObjectProtocol?

    /// Incremented only when a debounced route fetch actually starts; completions with a lower serial are ignored.
    private var routeMetricsRequestSerial: Int = 0
    private var routeMetricsRefreshWorkItem: DispatchWorkItem?
    private static let routeMetricsRefreshDebounce: TimeInterval = 0.35
    /// Avoids stacked `GET .../route` calls while LAS is still completing one request.
    private var routeMetricsFetchInFlight: Bool = false
    /// After a successful overlay, skip identical refetches for a while (SwiftUI / notifications still call refresh often).
    private var lastRouteMetricsSuccessfulApply: Date?
    private static let routeMetricsMinimumRefetchInterval: TimeInterval = 120
    /// Bucket `end` to wall-clock minutes so `LocationAPISyncService` route cache keys match across rapid triggers.
    private static let routeMetricsUnixBucketSeconds: Int = 60
    /// Route API HR samples for own-device merge (last successful `GET .../route` parse).
    private var lastRouteApiHeartRateSamples: [(date: Date, value: Double)] = []

    /// When true, user may see MQTT topic and other sensitive fields (JWT location-admin; see `WebAppAuthHelper`).
    @Published var canViewSensitiveLocationDeviceFields: Bool = false

    private static let oauthTokenBecameAvailable = Notification.Name("OwnTracksOAuthAccessTokenBecameAvailable")
    private static let currentUserProfileUpdated = Notification.Name("OwnTracksCurrentUserProfileDidUpdate")
    private static let localHeartRateSamplesDidUpdate = Notification.Name("OTLocalHeartRateSamplesDidUpdateNotification")

    init(waypoint: Waypoint) {
        let friend = waypoint.belongsTo
        self.friendTopic = friend?.topic ?? ""
        self.friendObjectID = friend?.objectID
        self.currentWaypoint = friend?.newestWaypoint ?? waypoint
        super.init()
        geocacheObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("OwnTracksGeolocationCacheDidUpdate"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshGeocacheLocationLabel()
        }
        populate()
        registerHeartRateObserverIfNeeded()
        registerBluetoothHeartRateObserverIfNeeded()
        registerLiveFriendLocationObserverIfNeeded()
        registerOAuthSensitiveObserverIfNeeded()
        registerUserProfileObserverIfNeeded()
        registerLocalHeartRateStoreObserverIfNeeded()
        currentWaypoint.addObserver(self, forKeyPath: "placemark", options: [.new], context: nil)
        if UserDefaults.standard.integer(forKey: "noRevgeo") > 0 {
            currentWaypoint.getReverseGeoCode()
        } else {
            currentWaypoint.placemark = currentWaypoint.defaultPlacemark
        }
    }

    deinit {
        if let observer = geocacheObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = heartRateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = bluetoothHeartRateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = liveFriendLocationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = oauthSensitiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = userProfileObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = localHeartRateStoreObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        currentWaypoint.removeObserver(self, forKeyPath: "placemark")
        routeMetricsRefreshWorkItem?.cancel()
        routeMetricsRefreshWorkItem = nil
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "placemark" {
            DispatchQueue.main.async { self.address = self.currentWaypoint.placemark ?? "" }
        }
    }

    private func populate() {
        refreshSensitiveDetailVisibility()
        showsUserAccountZoneIds = isOwnWaypoint
        applyAccountZoneIdTexts()
        let useMetric = Self.useMetric
        let friend = currentWaypoint.belongsTo
        deviceName = friend?.nameOrTopic ?? ""
        topic = friend?.topic ?? ""
        tid = friend?.effectiveTid ?? ""
        avatarData = friend?.image

        lastSeenDate = currentWaypoint.effectiveTimestamp
        connectionText = currentWaypoint.connectionText
        connectionTransport = Self.connectionTransport(for: currentWaypoint.conn)
        isOnline = currentWaypoint.effectiveTimestamp.timeIntervalSinceNow > -300

        batteryLevel = currentWaypoint.batt?.doubleValue ?? -1
        batteryStatusText = currentWaypoint.batteryStatusText

        address = currentWaypoint.placemark ?? ""
        coordinateText = currentWaypoint.coordinateText

        if let acc = currentWaypoint.acc?.doubleValue, acc >= 0 {
            accuracyText = "±\(Self.formatLength(meters: acc, useMetric: useMetric, decimals: 0))"
        } else {
            accuracyText = "-"
        }

        if let userLoc = LocationManager.sharedInstance()?.location {
            let dist = currentWaypoint.getDistanceFrom(userLoc)
            distanceText = Self.formatDistance(meters: dist, useMetric: useMetric)
        }

        timestampText = currentWaypoint.timestampText
        triggerText = currentWaypoint.triggerText
        monitoringText = currentWaypoint.monitoringText

        applyHeartRateText()

        if let alt = currentWaypoint.alt?.doubleValue {
            altitudeText = "✈︎ \(Self.formatLength(meters: alt, useMetric: useMetric, decimals: 0))"
        } else {
            altitudeText = "-"
        }

        if let vel = currentWaypoint.vel?.doubleValue, vel >= 0 {
            speedText = Self.formatSpeed(kmh: vel, useMetric: useMetric)
        } else {
            speedText = "-"
        }

        if let cog = currentWaypoint.cog?.doubleValue, cog >= 0 {
            headingText = "\(Int(cog))°"
        } else {
            headingText = "-"
        }

        ssid = (currentWaypoint.ssid?.isEmpty == false) ? currentWaypoint.ssid : nil
        bssid = (currentWaypoint.bssid?.isEmpty == false) ? currentWaypoint.bssid : nil

        if let data = currentWaypoint.inRegions,
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            regions = arr
        }
        if let data = currentWaypoint.motionActivities,
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            motionActivities = arr
        }
        poi = (currentWaypoint.poi?.isEmpty == false) ? currentWaypoint.poi : nil
        tag = (currentWaypoint.tag?.isEmpty == false) ? currentWaypoint.tag : nil
        photoData = currentWaypoint.image.flatMap { $0.count > 0 ? $0 : nil }
        refreshGeocacheLocationLabel()

        speedUnit = useMetric ? "km/h" : "mph"
        altitudeUnit = useMetric ? "m" : "ft"

        buildChartData(friend: friend, useMetric: useMetric)
        refreshHeartRateHistoryFromHealthKit()
        rebuildMetricsChartSeries()
        refreshRouteHistoryMetricsIfNeeded()
    }

    /// Re-reads OAuth-derived admin flag (e.g. after token refresh or when the detail screen appears).
    func refreshSensitiveDetailVisibility() {
        canViewSensitiveLocationDeviceFields = LocationAPISyncService.sharedInstance()
            .currentUserMayViewSensitiveLocationDeviceFields()
        applyAccountZoneIdTexts()
    }

    /// Re-query HealthKit when opening device details for this device so the UI is not stuck on a stale waypoint value.
    func refreshLiveHeartRateIfNeeded() {
        guard isOwnWaypoint else { return }
        HealthKitHeartRateManager.sharedInstance().refreshLatestSampleForUI { [weak self] in
            self?.applyHeartRateText()
            self?.refreshHeartRateHistoryFromHealthKit()
        }
    }

    /// Re-read local HR store from disk (e.g. when opening metrics) so Chart A is current.
    func refreshLocalPlusApiHeartRateMetricsIfNeeded() {
        guard showsDualHeartRateMetricsCharts else { return }
        recomputeOwnDeviceMetricsHeartRateCharts()
    }

    /// Loads HealthKit samples for the chart (own device, last 12 hours). Clears history for friends.
    func refreshHeartRateHistoryFromHealthKit() {
        guard isOwnWaypoint else {
            heartRateHistory = []
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            heartRateHistory = []
            metricsChartHealthKitOnlyHeartRateHistory = []
            recomputeOwnDeviceMetricsHeartRateCharts()
            return
        }
        let end = Date()
        let start = end.addingTimeInterval(-Self.heartRateHistoryLookbackSeconds)
        HealthKitHeartRateManager.sharedInstance().fetchHeartRateSamples(from: start, to: end) { [weak self] samples, _ in
            guard let self else { return }
            let list = (samples as? [NSDictionary]) ?? []
            let parsed = list.compactMap { row -> (date: Date, value: Double)? in
                guard let date = row["date"] as? Date, let bpm = row["bpm"] as? NSNumber else { return nil }
                return (date: date, value: bpm.doubleValue)
            }
            self.heartRateHistory = parsed
            self.recomputeOwnDeviceMetricsHeartRateCharts()
        }
    }

    private var isOwnWaypoint: Bool {
        guard let moc = currentWaypoint.managedObjectContext,
              let topic = currentWaypoint.belongsTo?.topic else { return false }
        let general = Settings.theGeneralTopic(inMOC: moc)
        return topic == general
    }

    /// Own device metrics sheet shows two HR charts (local+API vs HealthKit only).
    var showsDualHeartRateMetricsCharts: Bool { isOwnWaypoint }

    private func registerHeartRateObserverIfNeeded() {
        guard isOwnWaypoint, heartRateObserver == nil else { return }
        heartRateObserver = NotificationCenter.default.addObserver(
            forName: Self.healthKitHeartRateUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHeartRateText()
            self?.refreshHeartRateHistoryFromHealthKit()
        }
    }

    private func registerBluetoothHeartRateObserverIfNeeded() {
        guard isOwnWaypoint, bluetoothHeartRateObserver == nil else { return }
        bluetoothHeartRateObserver = NotificationCenter.default.addObserver(
            forName: Self.bluetoothHeartRateUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHeartRateText()
        }
    }

    private func registerLiveFriendLocationObserverIfNeeded() {
        guard liveFriendLocationObserver == nil, !friendTopic.isEmpty else { return }
        liveFriendLocationObserver = NotificationCenter.default.addObserver(
            forName: Self.liveFriendLocation,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let noteTopic = note.userInfo?["topic"] as? String
            guard self.liveNotificationTopicMatches(noteTopic) else { return }
            self.refreshFromLiveFriendLocation()
        }
    }

    /// Mirrors `ViewController` `isSelectedFriendEquivalentToOwnDeviceForLiveTopic` for own-device topic alias.
    private func liveNotificationTopicMatches(_ noteTopic: String?) -> Bool {
        guard let noteTopic, !noteTopic.isEmpty else { return false }
        if noteTopic == friendTopic { return true }
        guard let moc = currentWaypoint.managedObjectContext ?? CoreData.sharedInstance()?.mainMOC else {
            return false
        }
        let general = Settings.theGeneralTopic(inMOC: moc)
        guard !general.isEmpty, noteTopic == general else { return false }
        if friendTopic == general { return true }
        let ownTid = Settings.string(forKey: "trackerid_preference", inMOC: moc) ?? ""
        guard !ownTid.isEmpty, let oid = friendObjectID else { return false }
        guard let friend = try? moc.existingObject(with: oid) as? Friend else { return false }
        let tid = friend.effectiveTid
        return !tid.isEmpty && tid == ownTid
    }

    private func refreshFromLiveFriendLocation() {
        guard let oid = friendObjectID else { return }
        guard let moc = CoreData.sharedInstance()?.mainMOC else { return }
        guard let friend = try? moc.existingObject(with: oid) as? Friend else { return }
        guard let newest = friend.newestWaypoint else { return }
        switchToWaypointIfNeeded(newest)
    }

    private func switchToWaypointIfNeeded(_ newest: Waypoint) {
        if newest.objectID == currentWaypoint.objectID {
            populate()
            return
        }
        currentWaypoint.removeObserver(self, forKeyPath: "placemark")
        currentWaypoint = newest
        currentWaypoint.addObserver(self, forKeyPath: "placemark", options: [.new], context: nil)
        if UserDefaults.standard.integer(forKey: "noRevgeo") > 0 {
            currentWaypoint.getReverseGeoCode()
        } else {
            currentWaypoint.placemark = currentWaypoint.defaultPlacemark
        }
        populate()
    }

    private func registerOAuthSensitiveObserverIfNeeded() {
        guard oauthSensitiveObserver == nil else { return }
        oauthSensitiveObserver = NotificationCenter.default.addObserver(
            forName: Self.oauthTokenBecameAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSensitiveDetailVisibility()
            self?.refreshRouteHistoryMetricsIfNeeded()
        }
    }

    private func registerUserProfileObserverIfNeeded() {
        guard userProfileObserver == nil else { return }
        userProfileObserver = NotificationCenter.default.addObserver(
            forName: Self.currentUserProfileUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSensitiveDetailVisibility()
            self?.refreshRouteHistoryMetricsIfNeeded()
        }
    }

    private func registerLocalHeartRateStoreObserverIfNeeded() {
        guard localHeartRateStoreObserver == nil, isOwnWaypoint else { return }
        localHeartRateStoreObserver = NotificationCenter.default.addObserver(
            forName: Self.localHeartRateSamplesDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recomputeOwnDeviceMetricsHeartRateCharts()
        }
    }

    private func applyAccountZoneIdTexts() {
        guard isOwnWaypoint else {
            homeZoneIdText = "-"
            workZoneIdText = "-"
            return
        }
        let las = LocationAPISyncService.sharedInstance()
        if let h = las.authorizationUserHomeZoneId() {
            homeZoneIdText = "\(h.intValue)"
        } else {
            homeZoneIdText = "-"
        }
        if let w = las.authorizationUserWorkZoneId() {
            workZoneIdText = "\(w.intValue)"
        } else {
            workZoneIdText = "-"
        }
    }

    private func applyHeartRateText() {
        heartRateLastSampleDate = nil

        if !isOwnWaypoint {
            if let hr = currentWaypoint.heartRate, hr.intValue > 0 {
                heartRateText = Self.formattedBPM(hr.intValue)
                heartRateLastSampleDate = currentWaypoint.effectiveTimestamp
            } else {
                heartRateText = "-"
            }
            return
        }

        struct HeartSample {
            let bpm: Int
            let date: Date
        }
        var samples: [HeartSample] = []

        if let hr = currentWaypoint.heartRate, hr.intValue > 0 {
            samples.append(HeartSample(bpm: hr.intValue, date: currentWaypoint.effectiveTimestamp))
        }

        let bt = BluetoothHeartRateManager.sharedInstance()
        if let btDate = bt.lastReadingDate {
            if let bpm = bt.heartRate, bpm.intValue > 0 {
                samples.append(HeartSample(bpm: bpm.intValue, date: btDate))
            } else if let bpm = bt.heartRateIfSample(within: Self.heartRateDisplayMaxSampleAge), bpm.intValue > 0 {
                samples.append(HeartSample(bpm: bpm.intValue, date: btDate))
            }
        }

        let hk = HealthKitHeartRateManager.sharedInstance()
        if let hkDate = hk.lastReadingDate {
            if let bpm = hk.heartRate, bpm.intValue > 0 {
                samples.append(HeartSample(bpm: bpm.intValue, date: hkDate))
            } else if let bpm = hk.heartRateIfSample(within: Self.heartRateDisplayMaxSampleAge), bpm.intValue > 0 {
                samples.append(HeartSample(bpm: bpm.intValue, date: hkDate))
            }
        }

        guard let best = samples.max(by: { $0.date < $1.date }) else {
            heartRateText = "-"
            return
        }
        heartRateText = Self.formattedBPM(best.bpm)
        heartRateLastSampleDate = best.date
    }

    private static func formattedBPM(_ value: Int) -> String {
        String(
            format: NSLocalizedString("%d bpm", comment: "Heart rate with unit on device detail"),
            value
        )
    }

    /// Location name from server geolocation cache when the waypoint lies inside an eligible circle (not Destination / not +follow name).
    private func refreshGeocacheLocationLabel() {
        guard let lat = currentWaypoint.lat?.doubleValue,
              let lon = currentWaypoint.lon?.doubleValue else {
            zoneName = nil
            return
        }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coord) else {
            zoneName = nil
            return
        }
        zoneName = LocationAPISyncService.sharedInstance().geolocationItemContaining(coord)?.displayName
    }

    private func buildChartData(friend: Friend?, useMetric: Bool) {
        guard let allSet = friend?.hasWaypoints else { return }
        let allWaypoints = Array(allSet)

        let sorted = allWaypoints
            .sorted { $0.effectiveTimestamp < $1.effectiveTimestamp }
            .suffix(50)

        speedHistory = sorted.compactMap { wp in
            guard let vel = wp.vel?.doubleValue, vel >= 0 else { return nil }
            let displayValue = useMetric ? vel : vel * 0.621371
            return (date: wp.effectiveTimestamp, value: displayValue)
        }
        altitudeHistory = sorted.compactMap { wp in
            guard let alt = wp.alt?.doubleValue else { return nil }
            let displayValue = useMetric ? alt : alt * 3.28084
            return (date: wp.effectiveTimestamp, value: displayValue)
        }
    }

    /// Refreshes waypoint-derived series and the shared 12h domain for the metrics sheet. Heart rate
    /// for the **own** device is updated asynchronously by `refreshHeartRateHistoryFromHealthKit`;
    /// this copies the current `heartRateHistory` when available and rebuilds waypoint HR for friends.
    func rebuildMetricsChartSeries() {
        let end = Date()
        let start = end.addingTimeInterval(-Self.heartRateHistoryLookbackSeconds)
        metricsChartStart = start
        metricsChartEnd = end
        let useMetric = Self.useMetric

        guard let friend = currentWaypoint.belongsTo, let allSet = friend.hasWaypoints else {
            metricsChartSpeedHistory = []
            metricsChartAltitudeHistory = []
            metricsChartBatteryHistory = []
            if isOwnWaypoint {
                recomputeOwnDeviceMetricsHeartRateCharts()
            } else {
                metricsChartHeartRateHistory = []
            }
            return
        }

        let filtered = Array(allSet)
            .filter { $0.effectiveTimestamp >= start && $0.effectiveTimestamp <= end }
            .sorted { $0.effectiveTimestamp < $1.effectiveTimestamp }

        metricsChartSpeedHistory = filtered.compactMap { wp in
            guard let vel = wp.vel?.doubleValue, vel >= 0 else { return nil }
            let displayValue = useMetric ? vel : vel * 0.621371
            return (date: wp.effectiveTimestamp, value: displayValue)
        }
        metricsChartAltitudeHistory = filtered.compactMap { wp in
            guard let alt = wp.alt?.doubleValue else { return nil }
            let displayValue = useMetric ? alt : alt * 3.28084
            return (date: wp.effectiveTimestamp, value: displayValue)
        }
        metricsChartBatteryHistory = filtered.compactMap { wp in
            guard let raw = wp.batt?.doubleValue, raw >= 0 else { return nil }
            let frac = raw > 1.0 ? raw / 100.0 : raw
            guard frac <= 1.001 else { return nil }
            let clamped = min(1.0, max(0.0, frac))
            return (date: wp.effectiveTimestamp, value: clamped)
        }

        if isOwnWaypoint {
            recomputeOwnDeviceMetricsHeartRateCharts()
        } else {
            metricsChartHeartRateHistory = filtered.compactMap { wp in
                guard let hr = wp.heartRate?.doubleValue, hr > 0 else { return nil }
                return (date: wp.effectiveTimestamp, value: hr)
            }
        }
    }

    /// Schedules `GET .../history/.../route` when `currentUserMayViewRouteHistory` allows and merges into chart series.
    /// Does not rebuild the Core Data baseline here — that runs from `populate()` only, so OAuth/profile-driven
    /// refreshes do not oscillate charts between CD-only and route-overlay data.
    /// Route GET is debounced so SwiftUI `onAppear` bursts do not stack requests.
    func refreshRouteHistoryMetricsIfNeeded() {
        guard LocationAPISyncService.sharedInstance().currentUserMayViewRouteHistory() else {
            return
        }
        guard let friend = currentWaypoint.belongsTo,
              currentWaypoint.managedObjectContext != nil,
              Self.routeAPIUserAndDevice(for: friend) != nil else {
            return
        }

        routeMetricsRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startDebouncedRouteHistoryMetricsFetch()
        }
        routeMetricsRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.routeMetricsRefreshDebounce, execute: work)
    }

    private func startDebouncedRouteHistoryMetricsFetch() {
        guard LocationAPISyncService.sharedInstance().currentUserMayViewRouteHistory() else { return }
        guard let friend = currentWaypoint.belongsTo,
              let moc = currentWaypoint.managedObjectContext,
              let routePair = Self.routeAPIUserAndDevice(for: friend) else {
            return
        }

        if routeMetricsFetchInFlight {
            return
        }
        if let last = lastRouteMetricsSuccessfulApply,
           Date().timeIntervalSince(last) < Self.routeMetricsMinimumRefetchInterval {
            return
        }

        routeMetricsFetchInFlight = true
        routeMetricsRequestSerial += 1
        let serial = routeMetricsRequestSerial
        let bucket = Self.routeMetricsUnixBucketSeconds
        let rawEnd = Int(Date().timeIntervalSince1970)
        let endUnix = bucket > 1 ? (rawEnd / bucket) * bucket : rawEnd
        let startUnix = endUnix - Int(Self.heartRateHistoryLookbackSeconds)
        let useMetric = Self.useMetric

        LocationAPISyncService.sharedInstance().fetchRouteHistoryPoints(
            forRouteUser: routePair.user,
            routeDevice: routePair.device,
            startUnix: startUnix,
            endUnix: endUnix,
            managedObjectContext: moc
        ) { [weak self] points, error in
            guard let self else { return }
            defer { self.routeMetricsFetchInFlight = false }
            guard serial == self.routeMetricsRequestSerial else {
                return
            }
            if let error {
                NSLog("[DeviceDetailVM] route API error: %@", error.localizedDescription)
                return
            }
            guard let nsArray = points as NSArray? else {
                NSLog("[DeviceDetailVM] route API returned nil points array")
                return
            }
            let plist = nsArray.compactMap { $0 as? NSDictionary }
            if plist.isEmpty {
                return
            }
            self.applyRouteHistoryPointsToMetricsCharts(plist, useMetric: useMetric)
            self.lastRouteMetricsSuccessfulApply = Date()
        }
    }

    /// Same user/device resolution as `ViewController` route fetch (`owntracks/{user}/{device}` fallback).
    private static func routeAPIUserAndDevice(for friend: Friend) -> (user: String, device: String)? {
        var routeUser = (friend.routeAPIUser ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var routeDevice = (friend.tid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if routeUser.isEmpty || routeDevice.isEmpty {
            let topic = friend.topic ?? ""
            let parts = topic.split(separator: "/").map(String.init)
            if parts.count >= 3 {
                routeUser = parts[1]
                routeDevice = parts.dropFirst(2).joined(separator: "/")
            }
        }
        if routeUser.isEmpty || routeDevice.isEmpty { return nil }
        return (routeUser, routeDevice)
    }

    private func applyRouteHistoryPointsToMetricsCharts(_ points: [NSDictionary], useMetric: Bool) {
        var speeds: [(date: Date, value: Double)] = []
        var alts: [(date: Date, value: Double)] = []
        var batts: [(date: Date, value: Double)] = []
        var hrs: [(date: Date, value: Double)] = []

        for pt in points {
            let unix = OTRouteHistoryPointUnixTime(pt)
            if unix.isNaN || !unix.isFinite { continue }
            let date = Date(timeIntervalSince1970: unix)

            if let vel = Self.doubleValue(from: pt, keys: ["vel", "velocity"]), vel >= 0 {
                let displayValue = useMetric ? vel : vel * 0.621371
                speeds.append((date: date, value: displayValue))
            }
            if let altM = Self.doubleValue(from: pt, keys: ["alt", "altitude"]) {
                let displayValue = useMetric ? altM : altM * 3.28084
                alts.append((date: date, value: displayValue))
            }
            if let rawBatt = Self.doubleValue(from: pt, keys: ["batt", "battery"]), rawBatt >= 0 {
                let frac = rawBatt > 1.0 ? rawBatt / 100.0 : rawBatt
                if frac <= 1.001 {
                    batts.append((date: date, value: min(1.0, max(0.0, frac))))
                }
            }
            if let hr = Self.doubleValue(from: pt, keys: ["hr", "heartRate"]), hr > 0 {
                hrs.append((date: date, value: hr))
            }
        }

        if speeds.count >= 2 {
            speeds.sort { $0.date < $1.date }
            metricsChartSpeedHistory = speeds
        }
        if alts.count >= 2 {
            alts.sort { $0.date < $1.date }
            metricsChartAltitudeHistory = alts
        }
        if batts.count >= 2 {
            batts.sort { $0.date < $1.date }
            metricsChartBatteryHistory = batts
        }
        if isOwnWaypoint {
            hrs.sort { $0.date < $1.date }
            lastRouteApiHeartRateSamples = hrs
        } else if hrs.count >= 2 {
            hrs.sort { $0.date < $1.date }
            metricsChartHeartRateHistory = hrs
        }
        // Keep chart X domain aligned to “now” once when overlay applies (not on every OAuth/profile ping).
        let chartEnd = Date()
        metricsChartEnd = chartEnd
        metricsChartStart = chartEnd.addingTimeInterval(-Self.heartRateHistoryLookbackSeconds)
        if isOwnWaypoint {
            recomputeOwnDeviceMetricsHeartRateCharts()
        }
    }

    /// Local dense samples plus route API; API replaces local points within `mergeEpsilonSeconds`.
    private static func mergedLocalPlusApiHeartRateSeries(
        local: [(date: Date, value: Double)],
        api: [(date: Date, value: Double)],
        mergeEpsilonSeconds: TimeInterval
    ) -> [(date: Date, value: Double)] {
        let apiSorted = api.sorted { $0.date < $1.date }
        var locals = local.sorted { $0.date < $1.date }
        for apiPt in apiSorted {
            locals.removeAll { abs($0.date.timeIntervalSince(apiPt.date)) <= mergeEpsilonSeconds }
        }
        var combined = locals + apiSorted
        combined.sort { $0.date < $1.date }
        var folded: [(date: Date, value: Double)] = []
        for cur in combined {
            if let last = folded.last {
                let dt = cur.date.timeIntervalSince(last.date)
                if dt < 1.0 && abs(cur.value - last.value) < 0.5 {
                    continue
                }
            }
            folded.append(cur)
        }
        return folded
    }

    private func recomputeOwnDeviceMetricsHeartRateCharts() {
        guard isOwnWaypoint else { return }
        let start = metricsChartStart
        let end = metricsChartEnd
        guard start != .distantPast, start <= end else { return }

        let store = OTLocalHeartRateTimeSeriesStore.shared()
        let localRows = store.samples(from: start, to: end) as? [NSDictionary] ?? []
        let localTuples: [(date: Date, value: Double)] = localRows.compactMap { row in
            guard let d = row["date"] as? Date,
                  let bpm = row["bpm"] as? NSNumber,
                  bpm.doubleValue > 0 else { return nil }
            return (date: d, value: bpm.doubleValue)
        }
        let merged = Self.mergedLocalPlusApiHeartRateSeries(
            local: localTuples,
            api: lastRouteApiHeartRateSamples,
            mergeEpsilonSeconds: 30
        )
        metricsChartLocalPlusApiHeartRateHistory = merged
        metricsChartHealthKitOnlyHeartRateHistory = heartRateHistory
        metricsChartHeartRateHistory = merged
    }

    private static func doubleValue(from dict: NSDictionary, keys: [String]) -> Double? {
        for key in keys {
            if let n = dict[key] as? NSNumber {
                return n.doubleValue
            }
            if let s = dict[key] as? String, let v = Double(s) {
                return v
            }
        }
        return nil
    }

    private static func connectionTransport(for conn: String?) -> DeviceDetailConnectionTransport {
        let raw = conn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch raw {
        case "w", "wifi", "wlan":
            return .wifi
        case "m", "wwan", "cellular", "mobile":
            return .cellular
        case "o", "offline", "none":
            return .noNetwork
        default:
            return .unknown
        }
    }

    // MARK: - Unit Formatting Helpers

    private static func formatSpeed(kmh: Double, useMetric: Bool) -> String {
        if useMetric {
            return "\(Int(kmh.rounded())) km/h"
        } else {
            let mph = kmh * 0.621371
            return "\(Int(mph.rounded())) mph"
        }
    }

    private static func formatLength(meters: Double, useMetric: Bool, decimals: Int) -> String {
        let mf = MeasurementFormatter()
        mf.unitStyle = .short
        mf.unitOptions = .providedUnit
        mf.numberFormatter.maximumFractionDigits = decimals
        mf.numberFormatter.minimumFractionDigits = 0
        if useMetric {
            return mf.string(from: Measurement(value: meters, unit: UnitLength.meters))
        } else {
            let feet = meters * 3.28084
            return mf.string(from: Measurement(value: feet, unit: UnitLength.feet))
        }
    }

    private static func formatDistance(meters: Double, useMetric: Bool) -> String {
        let mf = MeasurementFormatter()
        mf.unitStyle = .short
        mf.unitOptions = .providedUnit
        mf.numberFormatter.minimumFractionDigits = 0
        if useMetric {
            if meters < 1000 {
                mf.numberFormatter.maximumFractionDigits = 0
                return mf.string(from: Measurement(value: meters, unit: UnitLength.meters))
            } else {
                mf.numberFormatter.maximumFractionDigits = 1
                return mf.string(from: Measurement(value: meters / 1000, unit: UnitLength.kilometers))
            }
        } else {
            let miles = meters / 1609.344
            if miles < 0.1 {
                mf.numberFormatter.maximumFractionDigits = 0
                return mf.string(from: Measurement(value: meters * 3.28084, unit: UnitLength.feet))
            } else {
                mf.numberFormatter.maximumFractionDigits = 1
                return mf.string(from: Measurement(value: miles, unit: UnitLength.miles))
            }
        }
    }

    // MARK: - Actions

    func navigate() {
        guard let lat = currentWaypoint.lat?.doubleValue,
              let lon = currentWaypoint.lon?.doubleValue else { return }
        let place = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        let item = MKMapItem(placemark: place)
        item.name = deviceName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    func copyCoordinates() {
        UIPasteboard.general.string = currentWaypoint.shortCoordinateText
        flashCopied()
    }

    func copyTopic() {
        guard canViewSensitiveLocationDeviceFields, !topic.isEmpty else { return }
        UIPasteboard.general.string = topic
        flashCopied()
    }

    private func flashCopied() {
        showCopiedNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.showCopiedNotice = false
        }
    }
}
