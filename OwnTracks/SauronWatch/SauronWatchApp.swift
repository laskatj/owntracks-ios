//
//  SauronWatchApp.swift
//  SauronWatch
//

import SwiftUI

@main
struct SauronWatchApp: App {
    @StateObject private var tracker = WatchLocationTracker()
    @StateObject private var scheduler = WatchUploadScheduler()

    init() {
        _ = WatchConfigStore.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(WatchConfigStore.shared)
                .environmentObject(tracker)
                .environmentObject(scheduler)
                .onAppear {
                    tracker.requestAuthorization()
                    scheduler.start(configStore: WatchConfigStore.shared)
                }
        }
    }
}
