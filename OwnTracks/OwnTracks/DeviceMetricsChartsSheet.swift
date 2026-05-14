import SwiftUI
import Charts

// MARK: - Shared metrics chart time window (12h base, optional zoom)

private enum MetricsChartDomainMath {
    /// Minimum visible window when zoomed (10 minutes).
    static let minZoomSpan: TimeInterval = 10 * 60

    static func effectiveVisible(visible: ClosedRange<Date>?, base: ClosedRange<Date>) -> ClosedRange<Date> {
        guard let v = visible else { return base }
        return clampInside(v, base: base)
    }

    static func clampInside(_ inner: ClosedRange<Date>, base: ClosedRange<Date>) -> ClosedRange<Date> {
        let blo = base.lowerBound
        let bhi = base.upperBound
        let lo = max(inner.lowerBound, blo)
        let hi = min(inner.upperBound, bhi)
        if hi <= lo {
            return base
        }
        let maxSpan = bhi.timeIntervalSince(blo)
        let span = hi.timeIntervalSince(lo)
        if span > maxSpan {
            return base
        }
        return lo...hi
    }

    /// `nil` when the window is effectively the full base span (reset zoom binding).
    static func normalizedVisible(domain: ClosedRange<Date>, base: ClosedRange<Date>) -> ClosedRange<Date>? {
        let maxSpan = base.upperBound.timeIntervalSince(base.lowerBound)
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        if span >= maxSpan * 0.995 { return nil }
        return clampInside(domain, base: base)
    }

    static func domainByPinch(
        domain: ClosedRange<Date>,
        base: ClosedRange<Date>,
        magnification: CGFloat,
        anchor: Date
    ) -> ClosedRange<Date> {
        let mag = max(0.01, Double(magnification))
        let span0 = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let maxSpan = base.upperBound.timeIntervalSince(base.lowerBound)
        var span = span0 / mag
        span = min(max(span, minZoomSpan), maxSpan)
        let anchorFrac = anchor.timeIntervalSince(domain.lowerBound) / max(span0, 1e-9)
        let clampedAnchor = min(max(anchor, base.lowerBound), base.upperBound)
        var lo = clampedAnchor.addingTimeInterval(-span * anchorFrac)
        var hi = lo.addingTimeInterval(span)
        if hi > base.upperBound {
            hi = base.upperBound
            lo = hi.addingTimeInterval(-span)
            lo = max(lo, base.lowerBound)
            hi = min(lo.addingTimeInterval(span), base.upperBound)
        }
        if lo < base.lowerBound {
            lo = base.lowerBound
            hi = min(lo.addingTimeInterval(span), base.upperBound)
        }
        if hi <= lo { return base }
        return lo...hi
    }

    static func domainByPan(domain: ClosedRange<Date>, base: ClosedRange<Date>, deltaTime: TimeInterval) -> ClosedRange<Date> {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        var lo = domain.lowerBound.addingTimeInterval(deltaTime)
        var hi = lo.addingTimeInterval(span)
        if hi > base.upperBound {
            hi = base.upperBound
            lo = hi.addingTimeInterval(-span)
        }
        if lo < base.lowerBound {
            lo = base.lowerBound
            hi = lo.addingTimeInterval(span)
        }
        if hi <= lo { return base }
        return lo...hi
    }
}

/// Full-screen sheet: speed, altitude, heart rate, and battery over the same 12-hour window.
/// Shared scrub time + vertical `RuleMark` per chart. Pinch zooms the visible time slice (all charts);
/// when zoomed, drag horizontally to pan. Touch or drag to scrub when not panning.
/// Double-tap a chart or Clear to reset scrub (and zoom). Vertical scrolling works best outside plot areas.
struct DeviceMetricsChartsSheet: View {
    @ObservedObject var vm: DeviceDetailViewModel
    @Environment(\.dismiss) private var dismiss

    /// Shared X position for vertical rules across all charts (same `Date` in `chartXDomain`).
    @State private var scrubTime: Date?
    /// Optional subrange of `baseTimeDomain`; `nil` means show the full 12h base window on all charts.
    @State private var visibleXDomain: ClosedRange<Date>? = nil

    /// VM-backed 12h window (validated); pinch/pan never extend outside this range.
    private var baseTimeDomain: ClosedRange<Date> {
        let a = vm.metricsChartStart
        let b = vm.metricsChartEnd
        let now = Date()
        let fallback = now.addingTimeInterval(-12 * 3600)...now
        if a == .distantPast || b == .distantPast || a > b {
            return fallback
        }
        let span = b.timeIntervalSince(a)
        if span < 60 || span > 25 * 3600 {
            return fallback
        }
        return a...b
    }

    /// Effective X-axis domain for every chart (shared zoom/pan).
    private var chartXDomain: ClosedRange<Date> {
        MetricsChartDomainMath.effectiveVisible(visible: visibleXDomain, base: baseTimeDomain)
    }

    private var isZoomedBelowBase: Bool {
        let base = baseTimeDomain
        let cur = chartXDomain
        let baseSpan = base.upperBound.timeIntervalSince(base.lowerBound)
        let curSpan = cur.upperBound.timeIntervalSince(cur.lowerBound)
        return curSpan < baseSpan * 0.995
    }

    /// Fixed width for leading Y value labels so plot areas line up and scrub `RuleMark`s align visually.
    private static let yAxisLabelColumnWidth: CGFloat = 56

    /// Primary heart rate series for combined scrub readout (matches dominant HR chart).
    private var combinedReadoutHeartRateHistory: [(date: Date, value: Double)] {
        if vm.showsDualHeartRateMetricsCharts {
            return vm.metricsChartLocalPlusApiHeartRateHistory
        }
        return vm.metricsChartHeartRateHistory
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Leading label width is fixed across charts so vertical RuleMarks at the same Date share one X.
                VStack(alignment: .leading, spacing: 16) {
                    if let t = scrubTime {
                        CombinedScrubReadout(
                            scrubTime: t,
                            speed: nearestPoint(in: vm.metricsChartSpeedHistory, to: t),
                            altitude: nearestPoint(in: vm.metricsChartAltitudeHistory, to: t),
                            heartRate: nearestPoint(in: combinedReadoutHeartRateHistory, to: t),
                            batteryFraction: nearestPoint(in: vm.metricsChartBatteryHistory, to: t),
                            speedUnit: vm.speedUnit,
                            altitudeUnit: vm.altitudeUnit
                        )
                    }

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
                            "Pinch on any chart to zoom the time window (all charts). Drag horizontally to pan when zoomed. Tap or drag to scrub.",
                            comment: "Hint for metrics pinch zoom, pan, and scrub"
                        )
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    AlignedMetricChart(
                        title: NSLocalizedString("Speed", comment: "Chart title"),
                        unit: vm.speedUnit,
                        data: vm.metricsChartSpeedHistory,
                        baseDomain: baseTimeDomain,
                        chartXDomain: chartXDomain,
                        visibleChartXDomain: $visibleXDomain,
                        isZoomedBelowBase: isZoomedBelowBase,
                        color: .blue,
                        scrubTime: $scrubTime,
                        yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                        handlesScrubGesture: true
                    )

                    AlignedMetricChart(
                        title: NSLocalizedString("Altitude", comment: "Chart title"),
                        unit: vm.altitudeUnit,
                        data: vm.metricsChartAltitudeHistory,
                        baseDomain: baseTimeDomain,
                        chartXDomain: chartXDomain,
                        visibleChartXDomain: $visibleXDomain,
                        isZoomedBelowBase: isZoomedBelowBase,
                        color: .indigo,
                        scrubTime: $scrubTime,
                        yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                        handlesScrubGesture: true
                    )

                    if vm.showsDualHeartRateMetricsCharts {
                        AlignedMetricChart(
                            title: NSLocalizedString(
                                "Heart rate (local + server)",
                                comment: "Chart title: on-device HR log merged with backend route samples"
                            ),
                            unit: "bpm",
                            data: vm.metricsChartLocalPlusApiHeartRateHistory,
                            baseDomain: baseTimeDomain,
                            chartXDomain: chartXDomain,
                            visibleChartXDomain: $visibleXDomain,
                            isZoomedBelowBase: isZoomedBelowBase,
                            color: .red,
                            scrubTime: $scrubTime,
                            yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                            handlesScrubGesture: true,
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
                            baseDomain: baseTimeDomain,
                            chartXDomain: chartXDomain,
                            visibleChartXDomain: $visibleXDomain,
                            isZoomedBelowBase: isZoomedBelowBase,
                            color: .pink,
                            scrubTime: $scrubTime,
                            yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                            handlesScrubGesture: true,
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
                            baseDomain: baseTimeDomain,
                            chartXDomain: chartXDomain,
                            visibleChartXDomain: $visibleXDomain,
                            isZoomedBelowBase: isZoomedBelowBase,
                            color: .red,
                            scrubTime: $scrubTime,
                            yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                            handlesScrubGesture: true
                        )
                    }

                    AlignedMetricChart(
                        title: NSLocalizedString("Battery", comment: "Chart title"),
                        unit: "%",
                        data: vm.metricsChartBatteryHistory,
                        baseDomain: baseTimeDomain,
                        chartXDomain: chartXDomain,
                        visibleChartXDomain: $visibleXDomain,
                        isZoomedBelowBase: isZoomedBelowBase,
                        color: .green,
                        valueScale: { $0 * 100 },
                        scrubTime: $scrubTime,
                        yAxisLabelColumnWidth: Self.yAxisLabelColumnWidth,
                        handlesScrubGesture: true
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
                    if scrubTime != nil || visibleXDomain != nil {
                        Button(NSLocalizedString("Clear", comment: "Clear scrub line on metrics charts")) {
                            scrubTime = nil
                            visibleXDomain = nil
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
            .onChange(of: vm.metricsChartStart) { _ in visibleXDomain = nil }
            .onChange(of: vm.metricsChartEnd) { _ in visibleXDomain = nil }
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

// MARK: - Combined scrub readout

private struct CombinedScrubReadout: View {
    let scrubTime: Date
    let speed: (date: Date, value: Double)?
    let altitude: (date: Date, value: Double)?
    let heartRate: (date: Date, value: Double)?
    let batteryFraction: (date: Date, value: Double)?
    let speedUnit: String
    let altitudeUnit: String

    @Environment(\.calendar) private var calendar

    private var scrubTimeFormat: Date.FormatStyle {
        if calendar.isDate(scrubTime, inSameDayAs: Date()) {
            return .dateTime.hour().minute().second()
        }
        return .dateTime.month(.abbreviated).day().hour().minute().second()
    }

    private var emDash: String {
        NSLocalizedString("—", comment: "Placeholder when a metric has no sample at scrub time")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scrubTime, format: scrubTimeFormat)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    chip(
                        title: NSLocalizedString("Speed", comment: "Combined scrub: speed column title"),
                        value: speed.map { "\(Int($0.value.rounded())) \(speedUnit)" } ?? emDash
                    )
                    Text("·").foregroundStyle(.tertiary)
                    chip(
                        title: NSLocalizedString("Alt", comment: "Combined scrub: short altitude label"),
                        value: altitude.map { "\(Int($0.value.rounded())) \(altitudeUnit)" } ?? emDash
                    )
                    Text("·").foregroundStyle(.tertiary)
                    chip(
                        title: NSLocalizedString("HR", comment: "Combined scrub: short heart rate label"),
                        value: heartRate.map { "\(Int($0.value.rounded())) bpm" } ?? emDash
                    )
                    Text("·").foregroundStyle(.tertiary)
                    chip(
                        title: NSLocalizedString("Bat", comment: "Combined scrub: short battery label"),
                        value: batteryFraction.map { "\(Int(($0.value * 100).rounded()))%" } ?? emDash
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func chip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .fontWeight(.semibold)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - AlignedMetricChart

private struct AlignedMetricChart: View {
    let title: String
    let unit: String
    let data: [(date: Date, value: Double)]
    let baseDomain: ClosedRange<Date>
    let chartXDomain: ClosedRange<Date>
    @Binding var visibleChartXDomain: ClosedRange<Date>?
    let isZoomedBelowBase: Bool
    let color: Color
    /// Display values on Y axis labels (e.g. battery fraction → percent).
    var valueScale: (Double) -> Double = { $0 }
    @Binding var scrubTime: Date?
    let yAxisLabelColumnWidth: CGFloat
    /// When true, chart plot accepts pinch, pan, and scrub (shared zoom + `scrubTime`).
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        .onTapGesture(count: 2) {
            scrubTime = nil
            visibleChartXDomain = nil
        }
    }

    private var chartCore: some View {
        Chart {
            if data.count >= 2 {
                PointMark(
                    x: .value("Time", chartXDomain.lowerBound),
                    y: .value(unit, padYForXAxisAnchor)
                )
                .opacity(0)
                PointMark(
                    x: .value("Time", chartXDomain.upperBound),
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
                if let t = scrubTime, t >= chartXDomain.lowerBound, t <= chartXDomain.upperBound {
                    RuleMark(x: .value("Scrub", t))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .chartXScale(domain: chartXDomain)
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
            chartCore.chartMetricsPlotInteractions(
                baseDomain: baseDomain,
                chartXDomain: chartXDomain,
                visibleDomain: $visibleChartXDomain,
                scrubTime: $scrubTime,
                isZoomedBelowBase: isZoomedBelowBase
            )
        } else {
            chartCore
        }
    }
}

// MARK: - Chart overlay (pinch zoom, pan, scrub)

private struct MetricsChartOverlayHost: View {
    let proxy: ChartProxy
    let baseDomain: ClosedRange<Date>
    let chartXDomain: ClosedRange<Date>
    @Binding var visibleDomain: ClosedRange<Date>?
    @Binding var scrubTime: Date?
    let isZoomedBelowBase: Bool

    @State private var pinchStartDomain: ClosedRange<Date>?
    @State private var pinchAnchorDate: Date?
    @State private var dragMode: DragIntent = .undecided
    @State private var panDomainAtLock: ClosedRange<Date>?
    @State private var panTranslationAtLock: CGFloat = 0

    private enum DragIntent {
        case undecided
        case pan
        case scrub
    }

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .simultaneousGesture(magnifyGesture(geo: geo))
                .simultaneousGesture(mainDragGesture(geo: geo))
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            scrubTime = nil
                            visibleDomain = nil
                        }
                )
        }
    }

    private func plotFrame(in geo: GeometryProxy) -> CGRect {
        geo[proxy.plotAreaFrame]
    }

    private func anchorAtPlotCenter(geo: GeometryProxy) -> Date? {
        let pf = plotFrame(in: geo)
        let loc = CGPoint(x: pf.midX - pf.origin.x, y: pf.midY - pf.origin.y)
        return proxy.value(at: loc, as: (Date, Double).self)?.0
    }

    private func magnifyGesture(geo: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { mag in
                if pinchStartDomain == nil {
                    let d0 = MetricsChartDomainMath.effectiveVisible(
                        visible: visibleDomain,
                        base: baseDomain
                    )
                    pinchStartDomain = d0
                    pinchAnchorDate = anchorAtPlotCenter(geo: geo)
                        ?? d0.lowerBound.addingTimeInterval(d0.upperBound.timeIntervalSince(d0.lowerBound) / 2)
                }
                guard let d0 = pinchStartDomain, let anch = pinchAnchorDate else { return }
                let d1 = MetricsChartDomainMath.domainByPinch(
                    domain: d0,
                    base: baseDomain,
                    magnification: mag,
                    anchor: anch
                )
                visibleDomain = MetricsChartDomainMath.normalizedVisible(domain: d1, base: baseDomain)
            }
            .onEnded { _ in
                pinchStartDomain = nil
                pinchAnchorDate = nil
            }
    }

    private func mainDragGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = value.translation
                let dist = hypot(t.width, t.height)
                let pf = plotFrame(in: geo)
                let plotW = max(Double(pf.width), 1)

                if dragMode == .undecided && dist > 14 {
                    if isZoomedBelowBase && abs(t.width) > abs(t.height) + 6 {
                        dragMode = .pan
                        panDomainAtLock = MetricsChartDomainMath.effectiveVisible(
                            visible: visibleDomain,
                            base: baseDomain
                        )
                        panTranslationAtLock = t.width
                    } else {
                        dragMode = .scrub
                    }
                }

                switch dragMode {
                case .pan:
                    guard let dLock = panDomainAtLock else { return }
                    let deltaW = value.translation.width - panTranslationAtLock
                    let span = dLock.upperBound.timeIntervalSince(dLock.lowerBound)
                    let dt = -Double(deltaW) / plotW * span
                    let d1 = MetricsChartDomainMath.domainByPan(domain: dLock, base: baseDomain, deltaTime: dt)
                    visibleDomain = MetricsChartDomainMath.normalizedVisible(domain: d1, base: baseDomain)

                case .scrub, .undecided:
                    let loc = CGPoint(
                        x: value.location.x - pf.origin.x,
                        y: value.location.y - pf.origin.y
                    )
                    if let pair = proxy.value(at: loc, as: (Date, Double).self) {
                        scrubTime = clampedDate(pair.0, to: chartXDomain)
                    }
                }
            }
            .onEnded { _ in
                dragMode = .undecided
                panDomainAtLock = nil
                panTranslationAtLock = 0
            }
    }
}

private extension View {
    /// Pinch zooms time axis (shared `visibleDomain`); when zoomed, dominant horizontal drag pans; otherwise drag scrubs.
    /// Double-tap clears scrub and zoom.
    func chartMetricsPlotInteractions(
        baseDomain: ClosedRange<Date>,
        chartXDomain: ClosedRange<Date>,
        visibleDomain: Binding<ClosedRange<Date>?>,
        scrubTime: Binding<Date?>,
        isZoomedBelowBase: Bool
    ) -> some View {
        chartOverlay { proxy in
            MetricsChartOverlayHost(
                proxy: proxy,
                baseDomain: baseDomain,
                chartXDomain: chartXDomain,
                visibleDomain: visibleDomain,
                scrubTime: scrubTime,
                isZoomedBelowBase: isZoomedBelowBase
            )
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
