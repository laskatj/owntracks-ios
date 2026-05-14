//
//  WatchWidgetSync.swift
//  SauronWatch
//

import Foundation
import WidgetKit

enum WatchWidgetSync {
    static func push(queueDepth: Int, lastUpload: Date?) {
        let d = UserDefaults.standard
        d.set(queueDepth, forKey: "widget_queue_depth")
        if let date = lastUpload {
            d.set(date, forKey: "widget_last_upload")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
