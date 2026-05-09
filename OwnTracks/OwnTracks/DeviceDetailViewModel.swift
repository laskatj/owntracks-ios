import Foundation
import Combine
import CoreLocation
import MapKit

@objc class DeviceDetailViewModel: NSObject, ObservableObject {
    private let waypoint: Waypoint

    // Unit preference: read from UserDefaults, defaults to false (= imperial)
    static var useMetric: Bool {
        return UserDefaults.standard.bool(forKey: "useMetric")
    }

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

    @Published var ssid: String? = nil
    @Published var bssid: String? = nil
    @Published var regions: [String] = []
    @Published var motionActivities: [String] = []
    @Published var poi: String? = nil
    @Published var tag: String? = nil
    @Published var photoData: Data? = nil
    @Published var zoneName: String? = nil

    // Chart data values are stored in the display unit (mph/ft or km/h/m)
    @Published var speedHistory: [(date: Date, value: Double)] = []
    @Published var altitudeHistory: [(date: Date, value: Double)] = []
    @Published var speedUnit: String = ""
    @Published var altitudeUnit: String = ""

    @Published var showCopiedNotice: Bool = false

    init(waypoint: Waypoint) {
        self.waypoint = waypoint
        super.init()
        populate()
        waypoint.addObserver(self, forKeyPath: "placemark", options: [.new], context: nil)
        if UserDefaults.standard.integer(forKey: "noRevgeo") > 0 {
            waypoint.getReverseGeoCode()
        } else {
            waypoint.placemark = waypoint.defaultPlacemark
        }
    }

    deinit {
        waypoint.removeObserver(self, forKeyPath: "placemark")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "placemark" {
            DispatchQueue.main.async { self.address = self.waypoint.placemark ?? "" }
        }
    }

    private func populate() {
        let useMetric = Self.useMetric
        let friend = waypoint.belongsTo
        deviceName = friend?.nameOrTopic ?? ""
        topic = friend?.topic ?? ""
        tid = friend?.effectiveTid ?? ""
        avatarData = friend?.image

        lastSeenDate = waypoint.effectiveTimestamp
        connectionText = waypoint.connectionText
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
        zoneName = (waypoint.zoneName?.isEmpty == false) ? waypoint.zoneName : nil

        speedUnit = useMetric ? "km/h" : "mph"
        altitudeUnit = useMetric ? "m" : "ft"

        buildChartData(friend: friend, useMetric: useMetric)
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
