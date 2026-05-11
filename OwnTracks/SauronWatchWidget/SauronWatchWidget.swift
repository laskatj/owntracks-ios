//
//  SauronWatchWidget.swift
//  SauronWatchWidget
//

import WidgetKit
import SwiftUI

// MARK: - Shared data

// On watchOS, widget extensions run in-process with the watch app during complication
// rendering, so UserDefaults.standard is accessible directly.
private struct WidgetData {
    let mode: String
    let queueDepth: Int
    let lastUpload: Date?

    static func load() -> WidgetData {
        let d = UserDefaults.standard
        return WidgetData(
            mode: d.string(forKey: "watch_tracking_mode") ?? "passive",
            queueDepth: d.integer(forKey: "widget_queue_depth"),
            lastUpload: d.object(forKey: "widget_last_upload") as? Date
        )
    }
}

// MARK: - Timeline provider

struct SauronTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SauronEntry {
        SauronEntry(date: Date(), mode: "passive", queueDepth: 0, lastUpload: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SauronEntry) -> Void) {
        let data = WidgetData.load()
        completion(SauronEntry(date: Date(), mode: data.mode, queueDepth: data.queueDepth, lastUpload: data.lastUpload))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SauronEntry>) -> Void) {
        let data = WidgetData.load()
        let entry = SauronEntry(date: Date(), mode: data.mode, queueDepth: data.queueDepth, lastUpload: data.lastUpload)
        // Refresh every 15 minutes; the app also calls WidgetCenter.shared.reloadAllTimelines on state change.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SauronEntry: TimelineEntry {
    let date: Date
    let mode: String
    let queueDepth: Int
    let lastUpload: Date?
}

// MARK: - Complication views

struct CircularView: View {
    let entry: SauronEntry
    private var isActive: Bool { entry.mode == "active" }

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.blue.opacity(0.25) : Color.gray.opacity(0.15))
            VStack(spacing: 1) {
                Image(systemName: isActive ? "location.fill" : "location.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? .blue : .secondary)
                if entry.queueDepth > 0 {
                    Text("\(entry.queueDepth)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

struct CornerView: View {
    let entry: SauronEntry
    private var isActive: Bool { entry.mode == "active" }

    var body: some View {
        Image(systemName: isActive ? "location.fill" : "location.slash")
            .foregroundStyle(isActive ? .blue : .secondary)
            .widgetLabel {
                Text(isActive ? "Active" : "Passive")
            }
    }
}

struct RectangularView: View {
    let entry: SauronEntry
    private var isActive: Bool { entry.mode == "active" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isActive ? "location.fill" : "location.slash")
                .foregroundStyle(isActive ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(isActive ? "Active" : "Passive")
                    .font(.headline)
                if let last = entry.lastUpload {
                    Text(last, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No uploads yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.queueDepth > 0 {
                Text("\(entry.queueDepth)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct InlineView: View {
    let entry: SauronEntry
    private var isActive: Bool { entry.mode == "active" }

    var body: some View {
        Label {
            Text(isActive ? "Active" : "Passive")
        } icon: {
            Image(systemName: isActive ? "location.fill" : "location.slash")
        }
    }
}

// MARK: - Widget entry view dispatcher

struct SauronWidgetEntryView: View {
    var entry: SauronEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularView(entry: entry)
        case .accessoryCorner:
            CornerView(entry: entry)
        case .accessoryRectangular:
            RectangularView(entry: entry)
        case .accessoryInline:
            InlineView(entry: entry)
        default:
            CircularView(entry: entry)
        }
    }
}

// MARK: - Widget declaration

struct SauronWatchWidget: Widget {
    let kind = "SauronWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SauronTimelineProvider()) { entry in
            SauronWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("OwnTracks")
        .description("Tracking mode and queue status.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Entry point

@main
struct SauronWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        SauronWatchWidget()
    }
}
