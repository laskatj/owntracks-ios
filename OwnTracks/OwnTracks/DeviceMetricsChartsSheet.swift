import SwiftUI
import Charts

/// Full-screen sheet: speed, altitude, heart rate, and battery over the same 12-hour window.
/// Shared scrub time + vertical `RuleMark` per chart (Strava-style). Drag on the **speed** chart
/// plot to scrub (avoids fighting `ScrollView`); double-tap any chart or use Clear to reset.
struct DeviceMetricsChartsSheet: View {
    @ObservedObject var vm: DeviceDetailViewModel
    @Environment(\.dismiss) private var dismiss

    /// Shared X position for vertical rules across all charts (same `Date` in `timeDomain`).
    @State private var scrubTime: Date?

    private var timeDomain: ClosedRange<Date> {
        let a = vm.metricsChartStart
        let b = vm.metricsChartEnd
        if a <= b {
            let span = b.timeIntervalSince(a)
            if span >= 60 { return a...b }
        }
        let now = Date()
        return now.addingTimeInterval(-12 * 3600)...now
    }

    /// Fixed width for leading Y value labels so plot areas line up and scrub `RuleMark`s align visually.
    private static let yAxisLabelColumnWidth: CGFloat = 56

    var body: some View {
        NavigationStack {
            ScrollView {
                // Leading label width is fixed across charts so vertical RuleMarks at the same Date share one X.
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        NSLocalizedString(
                            "Last 12 hours",
                            comment: "Subtitle for aligned device metrics charts"
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Text(
                        NSLocalizedString(
                            "Drag on the speed chart to scrub. Double-tap a chart or tap Clear to remove the line.",
                            comment: "Hint for Strava-style metrics scrubbing"
                        )
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    AlignedMetricChart(
                        title: NSLocalizedString("Speed", comment: "Chart title"),
                        unit: vm.speedUnit,
                        data: vm.metricsChartSpeedHistory,
                        timeDomain: timeDomain,
                        color: .blue,
                        scrubTime: $scrubTime,
                        yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                        handlesScrubGesture: true
                    )

                    AlignedMetricChart(
                        title: NSLocalizedString("Altitude", comment: "Chart title"),
                        unit: vm.altitudeUnit,
                        data: vm.metricsChartAltitudeHistory,
                        timeDomain: timeDomain,
                        color: .indigo,
                        scrubTime: $scrubTime,
                        yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                        handlesScrubGesture: false
                    )

                    if vm.showsDualHeartRateMetricsCharts {
                        AlignedMetricChart(
                            title: NSLocalizedString(
                                "Heart rate (local + server)",
                                comment: "Chart title: on-device HR log merged with backend route samples"
                            ),
                            unit: "bpm",
                            data: vm.metricsChartLocalPlusApiHeartRateHistory,
                            timeDomain: timeDomain,
                            color: .red,
                            scrubTime: $scrubTime,
                            yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                            handlesScrubGesture: false,
                            subtitle: NSLocalizedString(
                                "Dense on-device samples with route API overlaid (server wins within ±30s).",
                                comment: "Subtitle explaining local+server heart rate chart merge"
                            )
                        )
                        AlignedMetricChart(
                            title: NSLocalizedString(
                                "Heart rate (Apple Health)",
                                comment: "Chart title: HealthKit-only heart rate series"
                            ),
                            unit: "bpm",
                            data: vm.metricsChartHealthKitOnlyHeartRateHistory,
                            timeDomain: timeDomain,
                            color: .pink,
                            scrubTime: $scrubTime,
                            yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                            handlesScrubGesture: false,
                            subtitle: NSLocalizedString(
                                "HealthKit samples only, for comparison.",
                                comment: "Subtitle for HealthKit-only HR chart"
                            )
                        )
                    } else {
                        AlignedMetricChart(
                            title: NSLocalizedString("Heart rate", comment: "Chart title"),
                            unit: "bpm",
                            data: vm.metricsChartHeartRateHistory,
                            timeDomain: timeDomain,
                            color: .red,
                            scrubTime: $scrubTime,
                            yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                            handlesScrubGesture: false
                        )
                    }

                    AlignedMetricChart(
                        title: NSLocalizedString("Battery", comment: "Chart title"),
                        unit: "%",
                        data: vm.metricsChartBatteryHistory,
                        timeDomain: timeDomain,
                        color: .green,
                        valueScale: { $0 * 100 },
                        scrubTime: $scrubTime,
                        yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                        handlesScrubGesture: false
                    )
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(
                NSLocalizedString("Metrics", comment: "Navigation title for device metrics chart sheet")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if scrubTime != nil {
                        Button(NSLocalizedString("Clear", comment: "Clear scrub line on metrics charts")) {
                            scrubTime = nil
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Done", comment: "Dismiss metrics sheet")) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                vm.refreshRouteHistoryMetricsIfNeeded()
                vm.refreshLiveHeartRateIfNeeded()
                vm.refreshLocalPlusApiHeartRateMetricsIfNeeded()
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Time scrub helpers

/// Clamps `d` to `domain` (inclusive).
private func clampedDate(_ d: Date, to domain: ClosedRange<Date>) -> Date {
    min(max(d, domain.lowerBound), domain.upperBound)
}

/// Nearest sample by time (expects points roughly sorted by `date`; sorts if needed).
private func nearestPoint(in data: [(date: Date, value: Double)], to target: Date) -> (date: Date, value: Double)? {
    guard !data.isEmpty else { return nil }
    var series = data
    if series.count >= 2, series[0].date > series[1].date {
        series.sort { $0.date < $1.date }
    }
    if series.count == 1 {
        return series[0]
    }
    var lo = 0
    var hi = series.count - 1
    while lo < hi {
        let mid = (lo + hi) / 2
        if series[mid].date < target {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    let i = lo
    if i == 0 {
        return series[0]
    }
    let before = series[i - 1]
    let after = series[i]
    let dtBefore = abs(target.timeIntervalSince(before.date))
    let dtAfter = abs(after.date.timeIntervalSince(target))
    return dtBefore <= dtAfter ? before : after
}

// MARK: - AlignedMetricChart

private struct AlignedMetricChart: View {
    let title: String
    let unit: String
    let data: [(date: Date, value: Double)]
    let timeDomain: ClosedRange<Date>
    let color: Color
    /// Display values on Y axis labels (e.g. battery fraction → percent).
    var valueScale: (Double) -> Double = { $0 }
    @Binding var scrubTime: Date?
    let yAxisLabelColumnWidth: CGFloat
    /// Only one chart installs the drag overlay so vertical scrolling stays natural.
    let handlesScrubGesture: Bool
    var subtitle: String? = nil

    /// Invisible anchor Y so edge `PointMark`s sit inside the (data-driven) Y domain.
    private var padYForXAxisAnchor: Double {
        guard data.count >= 2 else { return 0 }
        let ys = data.map(\.value)
        let lo = ys.min() ?? 0
        let hi = ys.max() ?? 0
        return (lo + hi) * 0.5
    }

    /// Y scale from data min/max with padding; `nil` when there are fewer than two samples.
    private var dataDrivenYDomain: ClosedRange<Double>? {
        guard data.count >= 2 else { return nil }
        let values = data.map(\.value).filter { $0.isFinite }
        guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return nil }
        var domain = Self.paddedYDomain(min: lo, max: hi)
        if unit == "%" {
            let loC = Swift.max(0, domain.lowerBound)
            let hiC = Swift.min(1, domain.upperBound)
            if loC < hiC { domain = loC...hiC }
        }
        return domain
    }

    /// ~8% headroom above and below the observed range; expands flat series so a line is visible.
    private static func paddedYDomain(min: Double, max: Double) -> ClosedRange<Double> {
        if min == max {
            let delta = Swift.max(Swift.abs(min) * 0.05, 1)
            return (min - delta)...(max + delta)
        }
        let span = max - min
        let pad = Swift.max(span * 0.08, 1e-9)
        return (min - pad)...(max + pad)
    }

    private var scrubReadoutText: String? {
        guard let t = scrubTime, data.count >= 2, let pt = nearestPoint(in: data, to: t) else { return nil }
        let timeStr = pt.date.formatted(.dateTime.hour().minute().second())
        let shown = valueScale(pt.value)
        if unit == "%" {
            return String(
                format: NSLocalizedString("%@ — %d%%", comment: "Scrub readout: time and battery percent"),
                timeStr,
                Int(shown.rounded())
            )
        }
        return String(
            format: NSLocalizedString("%@ — %d %@", comment: "Scrub readout: time, rounded value, and unit"),
            timeStr,
            Int(shown.rounded()),
            unit
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let readout = scrubReadoutText {
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            if data.count < 2 {
                Text(
                    NSLocalizedString(
                        "Not enough data in this window.",
                        comment: "Shown when a metric has fewer than two samples in the chart range"
                    )
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            chartWithOptionalScrubOverlay
                .onTapGesture(count: 2) {
                    scrubTime = nil
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    private var chartCore: some View {
        Chart {
            if data.count >= 2 {
                PointMark(
                    x: .value("Time", timeDomain.lowerBound),
                    y: .value(unit, padYForXAxisAnchor)
                )
                .opacity(0)
                PointMark(
                    x: .value("Time", timeDomain.upperBound),
                    y: .value(unit, padYForXAxisAnchor)
                )
                .opacity(0)
                ForEach(Array(data.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(unit, point.value)
                    )
                    .foregroundStyle(color)
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value(unit, point.value)
                    )
                    .foregroundStyle(color.opacity(0.12))
                }
                if let t = scrubTime, t >= timeDomain.lowerBound, t <= timeDomain.upperBound {
                    RuleMark(x: .value("Scrub", t))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .chartXScale(domain: timeDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.hour().minute())
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .modifier(OptionalYDomainModifier(domain: dataDrivenYDomain))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        let shown = valueScale(n)
                        if unit == "%" {
                            Text("\(Int(shown.rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .frame(minWidth: yAxisLabelColumnWidth, alignment: .trailing)
                        } else {
                            Text("\(Int(shown.rounded())) \(unit)")
                                .font(.caption2.monospacedDigit())
                                .frame(minWidth: yAxisLabelColumnWidth, alignment: .trailing)
                        }
                    }
                }
                AxisGridLine()
            }
        }
        .frame(height: 140)
    }

    @ViewBuilder
    private var chartWithOptionalScrubOverlay: some View {
        if handlesScrubGesture, data.count >= 2 {
            chartCore.chartScrubOverlay(timeDomain: timeDomain, scrubTime: $scrubTime)
        } else {
            chartCore
        }
    }
}

// MARK: - Scrub overlay (ChartProxy)

private extension View {
    /// Horizontal scrub: `minimumDistance` reduces accidental picks while scrolling the sheet.
    func chartScrubOverlay(timeDomain: ClosedRange<Date>, scrubTime: Binding<Date?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 14)
                            .onChanged { value in
                                let trans = value.translation
                                guard abs(trans.width) >= abs(trans.height) - 2 else { return }
                                let origin = geo[proxy.plotAreaFrame].origin
                                let loc = CGPoint(
                                    x: value.location.x - origin.x,
                                    y: value.location.y - origin.y
                                )
                                if let pair = proxy.value(at: loc, as: (Date, Double).self) {
                                    scrubTime.wrappedValue = clampedDate(pair.0, to: timeDomain)
                                }
                            }
                    )
            }
        }
    }
}

private struct OptionalYDomainModifier: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
    }
}
