//
//  PendingLocationQueue.swift
//  SauronWatch
//

import Foundation

final class PendingLocationQueue {
    static let shared = PendingLocationQueue()

    private let fileURL: URL
    private let lock = NSLock()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("sauron_watch_location_queue.json")
    }

    func load() -> [QueuedLocationPoint] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [QueuedLocationPoint] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([QueuedLocationPoint].self, from: data)) ?? []
    }

    private func saveUnlocked(_ points: [QueuedLocationPoint]) {
        let trimmed = Array(points.suffix(WatchTrackingPolicy.maxQueuedPoints))
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func save(_ points: [QueuedLocationPoint]) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(points)
    }

    func append(_ point: QueuedLocationPoint) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadUnlocked()
        all.append(point)
        saveUnlocked(all)
    }

    func removeFirst(_ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadUnlocked()
        if n >= all.count {
            all.removeAll()
        } else {
            all.removeFirst(n)
        }
        saveUnlocked(all)
    }
}
