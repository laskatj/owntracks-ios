import Foundation
import Combine
import CoreLocation
import MapKit

@objc class DeviceDetailViewModel: NSObject, ObservableObject {
    private let waypoint: Waypoint

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

    @Published var speedHistory: [(date: Date, value: Double)] = []
    @Published var altitudeHistory: [(date: Date, value: Double)] = []

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
        let friend = waypoint.belongsTo
        deviceName = friend?.nameOrTopic ?? ""
        topic = friend?.topic ?? ""
        tid = friend?.effectiveTid ?? ""
        avatarData = friend?.image

        lastSeenDate = waypoint.effectiveTimestamp
        connectionText = waypoint.connectionText
        isOnline = (waypoint.effectiveTimestamp.timeIntervalSinceNow) > -300

        batteryLevel = waypoint.batt?.doubleValue ?? -1
        batteryStatusText = waypoint.batteryStatusText

        address = waypoint.placemark ?? ""
        coordinateText = waypoint.coordinateText
        if let acc = waypoint.acc?.doubleValue, acc >= 0 {
            let m = Measurement(value: acc, unit: UnitLength.meters)
            let mf = MeasurementFormatter()
            mf.unitOptions = .naturalScale
            mf.numberFormatter.maximumFractionDigits = 0
            accuracyText = "±\(mf.string(from: m))"
        } else {
            accuracyText = "-"
        }

        if let userLoc = LocationManager.sharedInstance()?.location {
            let dist = waypoint.getDistanceFrom(userLoc)
            distanceText = Waypoint.distanceText(dist)
        }

        timestampText = waypoint.timestampText
        triggerText = waypoint.triggerText
        monitoringText = waypoint.monitoringText

        if let vac = waypoint.vac?.doubleValue, vac > 0, let alt = waypoint.alt?.doubleValue {
            let m = Measurement(value: alt, unit: UnitLength.meters)
            let mf = MeasurementFormatter()
            mf.unitOptions = .naturalScale
            mf.numberFormatter.maximumFractionDigits = 0
            altitudeText = "✈︎ \(mf.string(from: m))"
        } else {
            altitudeText = "-"
        }

        if let vel = waypoint.vel?.doubleValue, vel >= 0 {
            let m = Measurement(value: vel, unit: UnitSpeed.kilometersPerHour)
            let mf = MeasurementFormatter()
            mf.unitOptions = .naturalScale
            mf.numberFormatter.maximumFractionDigits = 0
            speedText = mf.string(from: m)
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

        buildChartData(friend: friend)
    }

    private func buildChartData(friend: Friend?) {
        guard let allSet = friend?.hasWaypoints,
              let allWaypoints = allSet.allObjects as? [Waypoint] else { return }

        let sorted = allWaypoints
            .sorted { ($0.effectiveTimestamp) < ($1.effectiveTimestamp) }
            .suffix(50)

        speedHistory = sorted.compactMap { wp in
            guard let vel = wp.vel?.doubleValue, vel >= 0 else { return nil }
            return (date: wp.effectiveTimestamp, value: vel)
        }
        altitudeHistory = sorted.compactMap { wp in
            guard let alt = wp.alt?.doubleValue,
                  let vac = wp.vac?.doubleValue, vac > 0 else { return nil }
            return (date: wp.effectiveTimestamp, value: alt)
        }
    }

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
