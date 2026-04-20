//
//  LocationPayload.swift
//  SauronWatch
//
//  OwnTracks-compatible `_type: location` JSON for HTTP ingest.
//

import Foundation
import CoreLocation
import WatchKit

struct QueuedLocationPoint: Codable, Identifiable {
    var id: UUID
    var clLatitude: Double
    var clLongitude: Double
    var horizontalAccuracy: Double
    var altitude: Double
    var verticalAccuracy: Double
    var speed: Double
    var course: Double
    var timestamp: TimeInterval
    var idempotencyKey: String

    init(location: CLLocation) {
        self.id = UUID()
        self.clLatitude = location.coordinate.latitude
        self.clLongitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.altitude = location.altitude
        self.verticalAccuracy = location.verticalAccuracy
        self.speed = location.speed
        self.course = location.course
        self.timestamp = location.timestamp.timeIntervalSince1970
        self.idempotencyKey = UUID().uuidString
    }
}

enum LocationPayloadBuilder {
    /// Builds a dictionary matching `OwnTracking waypointAsJSON` shape (subset), plus `deviceId` and `topic` from the phone.
    static func jsonDictionary(for point: QueuedLocationPoint, config: WatchHTTPConfig) -> [String: Any] {
        let ver = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        var json: [String: Any] = [
            "_type": "location",
            "lat": round6(point.clLatitude),
            "lon": round6(point.clLongitude),
            "tst": Int(floor(point.timestamp)),
            "ver": ver,
            "t": "w"
        ]
        if point.horizontalAccuracy >= 0 {
            json["acc"] = Int(round(point.horizontalAccuracy))
        }
        if let tid = config.trackerId, !tid.isEmpty {
            json["tid"] = tid
        }
        let dev = config.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !dev.isEmpty {
            json["deviceId"] = dev
        }
        let topic = config.publishTopic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !topic.isEmpty {
            json["topic"] = topic
        }
        if config.includeExtendedData {
            json["alt"] = Int(round(point.altitude))
            if point.verticalAccuracy >= 0 {
                json["vac"] = Int(round(point.verticalAccuracy))
            }
            if point.speed >= 0 {
                json["vel"] = Int(round(point.speed))
            }
            if point.course >= 0 {
                json["cog"] = Int(round(point.course))
            }
        }
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        let level = WKInterfaceDevice.current().batteryLevel
        if level >= 0 {
            json["batt"] = Int(round(level * 100))
        }
        let state = WKInterfaceDevice.current().batteryState.rawValue
        json["bs"] = state
        return json
    }

    static func jsonData(for point: QueuedLocationPoint, config: WatchHTTPConfig) throws -> Data {
        let obj = jsonDictionary(for: point, config: config)
        return try JSONSerialization.data(withJSONObject: obj, options: [])
    }

    /// Canonical batch envelope for watch HTTP ingest (`HTTP_INGEST_CONTRACT.md`).
    static func batchJsonData(batchId: UUID, points: [QueuedLocationPoint], config: WatchHTTPConfig) throws -> Data {
        let pointObjects = points.map { jsonDictionary(for: $0, config: config) }
        let envelope: [String: Any] = [
            "_type": "batch",
            "batchId": batchId.uuidString,
            "points": pointObjects
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [])
    }

    private static func round6(_ x: Double) -> Double {
        (x * 1_000_000).rounded() / 1_000_000
    }
}
