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
    private let waypoint: Waypoint

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
    @Published var speedUnit: String = ""
    @Published var altitudeUnit: String = ""

    @Published var showCopiedNotice: Bool = false

    /// Own device (general MQTT topic) — show account home/work zone ids from `/api/authorization/user`.
    @Published var showsUserAccountZoneIds: Bool = false
    @Published var homeZoneIdText: String = "-"
    @Published var workZoneIdText: String = "-"

    /// Matches `OTHealthKitHeartRateDidUpdateNotification` in `HealthKitHeartRateManager.m`.
    private static let healthKitHeartRateUpdated = Notification.Name("OTHealthKitHeartRateDidUpdateNotification")
    private static let heartRateDisplayMaxSampleAge: TimeInterval = 15 * 60
    private static let heartRateHistoryLookbackSeconds: TimeInterval = 12 * 3600

    private var heartRateObserver: NSObjectProtocol?
    private var oauthSensitiveObserver: NSObjectProtocol?
    private var userProfileObserver: NSObjectProtocol?

    /// When true, user may see MQTT topic and other sensitive fields (JWT location-admin; see `WebAppAuthHelper`).
    @Published var canViewSensitiveLocationDeviceFields: Bool = false

    private static let oauthTokenBecameAvailable = Notification.Name("OwnTracksOAuthAccessTokenBecameAvailable")
    private static let currentUserProfileUpdated = Notification.Name("OwnTracksCurrentUserProfileDidUpdate")

    init(waypoint: Waypoint) {
        self.waypoint = waypoint
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
        registerOAuthSensitiveObserverIfNeeded()
        registerUserProfileObserverIfNeeded()
        waypoint.addObserver(self, forKeyPath: "placemark", options: [.new], context: nil)
        if UserDefaults.standard.integer(forKey: "noRevgeo") > 0 {
            waypoint.getReverseGeoCode()
        } else {
            waypoint.placemark = waypoint.defaultPlacemark
        }
    }

    deinit {
        if let observer = geocacheObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = heartRateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = oauthSensitiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = userProfileObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        waypoint.removeObserver(self, forKeyPath: "placemark")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "placemark" {
            DispatchQueue.main.async { self.address = self.waypoint.placemark ?? "" }
        }
    }

    private func populate() {
        refreshSensitiveDetailVisibility()
        showsUserAccountZoneIds = isOwnWaypoint
        applyAccountZoneIdTexts()
        let useMetric = Self.useMetric
        let friend = waypoint.belongsTo
        deviceName = friend?.nameOrTopic ?? ""
        topic = friend?.topic ?? ""
        tid = friend?.effectiveTid ?? ""
        avatarData = friend?.image

        lastSeenDate = waypoint.effectiveTimestamp
        connectionText = waypoint.connectionText
        connectionTransport = Self.connectionTransport(for: waypoint.conn)
        isOnline = waypoint.effectiveTimestamp.timeIntervalSinceNow > -300

        batteryLevel = waypoint.batt?.doubleValue ?? -1
        batteryStatusText = waypoint.batteryStatusText

        address = waypoint.placemark ?? ""
        coordinateText = waypoint.coordinateText

        if let acc = waypoint.acc?.doubleValue, acc >= 0 {
            accuracyText = "±\(Self.formatLength(meters: acc, useMetric: useMetric, decimals: 0))"
        } else {
            accuracyText = "-"
        }

        if let userLoc = LocationManager.sharedInstance()?.location {
            let dist = waypoint.getDistanceFrom(userLoc)
            distanceText = Self.formatDistance(meters: dist, useMetric: useMetric)
        }

        timestampText = waypoint.timestampText
        triggerText = waypoint.triggerText
        monitoringText = waypoint.monitoringText

        applyHeartRateText()

        if let alt = waypoint.alt?.doubleValue {
            altitudeText = "✈︎ \(Self.formatLength(meters: alt, useMetric: useMetric, decimals: 0))"
        } else {
            altitudeText = "-"
        }

        if let vel = waypoint.vel?.doubleValue, vel >= 0 {
            speedText = Self.formatSpeed(kmh: vel, useMetric: useMetric)
        } else {
            speedText = "-"
        }

        if let cog = waypoint.cog?.doubleValue, cog >= 0 {
            headingText = "\(Int(cog))°"
        } else {
            headingText = "-"
        }

        ssid = (waypoint.ssid?.isEmpty == false) ? waypoint.ssid : nil
        bssid = (waypoint.bssid?.isEmpty == false) ? waypoint.bssid : nil

        if let data = waypoint.inRegions,
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            regions = arr
        }
        if let data = waypoint.motionActivities,
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            motionActivities = arr
        }
        poi = (waypoint.poi?.isEmpty == false) ? waypoint.poi : nil
        tag = (waypoint.tag?.isEmpty == false) ? waypoint.tag : nil
        photoData = waypoint.image.flatMap { $0.count > 0 ? $0 : nil }
        refreshGeocacheLocationLabel()

        speedUnit = useMetric ? "km/h" : "mph"
        altitudeUnit = useMetric ? "m" : "ft"

        buildChartData(friend: friend, useMetric: useMetric)
        refreshHeartRateHistoryFromHealthKit()
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

    /// Loads HealthKit samples for the chart (own device, last 12 hours). Clears history for friends.
    func refreshHeartRateHistoryFromHealthKit() {
        guard isOwnWaypoint else {
            heartRateHistory = []
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            heartRateHistory = []
            return
        }
        let end = Date()
        let start = end.addingTimeInterval(-Self.heartRateHistoryLookbackSeconds)
        HealthKitHeartRateManager.sharedInstance().fetchHeartRateSamples(from: start, to: end) { [weak self] samples, _ in
            guard let self else { return }
            let list = (samples as? [NSDictionary]) ?? []
            self.heartRateHistory = list.compactMap { row in
                guard let date = row["date"] as? Date, let bpm = row["bpm"] as? NSNumber else { return nil }
                return (date: date, value: bpm.doubleValue)
            }
        }
    }

    private var isOwnWaypoint: Bool {
        guard let moc = waypoint.managedObjectContext,
              let topic = waypoint.belongsTo?.topic else { return false }
        let general = Settings.theGeneralTopic(inMOC: moc)
        return topic == general
    }

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

    private func registerOAuthSensitiveObserverIfNeeded() {
        guard oauthSensitiveObserver == nil else { return }
        oauthSensitiveObserver = NotificationCenter.default.addObserver(
            forName: Self.oauthTokenBecameAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSensitiveDetailVisibility()
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
        if let hr = waypoint.heartRate, hr.intValue > 0 {
            heartRateText = Self.formattedBPM(hr.intValue)
            return
        }
        guard isOwnWaypoint else {
            heartRateText = "-"
            return
        }
        if let bt = BluetoothHeartRateManager.sharedInstance().heartRate, bt.intValue > 0 {
            heartRateText = Self.formattedBPM(bt.intValue)
            return
        }
        if let bt = BluetoothHeartRateManager.sharedInstance().heartRateIfSample(within: Self.heartRateDisplayMaxSampleAge),
           bt.intValue > 0 {
            heartRateText = Self.formattedBPM(bt.intValue)
            return
        }
        if let hk = HealthKitHeartRateManager.sharedInstance().heartRate, hk.intValue > 0 {
            heartRateText = Self.formattedBPM(hk.intValue)
            return
        }
        if let hk = HealthKitHeartRateManager.sharedInstance().heartRateIfSample(within: Self.heartRateDisplayMaxSampleAge),
           hk.intValue > 0 {
            heartRateText = Self.formattedBPM(hk.intValue)
            return
        }
        heartRateText = "-"
    }

    private static func formattedBPM(_ value: Int) -> String {
        String(
            format: NSLocalizedString("%d bpm", comment: "Heart rate with unit on device detail"),
            value
        )
    }

    /// Location name from server geolocation cache when the waypoint lies inside an eligible circle (not Destination / not +follow name).
    private func refreshGeocacheLocationLabel() {
        guard let lat = waypoint.lat?.doubleValue,
              let lon = waypoint.lon?.doubleValue else {
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
        guard let lat = waypoint.lat?.doubleValue,
              let lon = waypoint.lon?.doubleValue else { return }
        let place = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        let item = MKMapItem(placemark: place)
        item.name = deviceName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    func copyCoordinates() {
        UIPasteboard.general.string = waypoint.shortCoordinateText
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
