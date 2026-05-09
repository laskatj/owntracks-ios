import SwiftUI
import Charts

struct DeviceDetailView: View {
    @ObservedObject var vm: DeviceDetailViewModel

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    headerCard
                    statusBanner
                    if vm.batteryLevel >= 0 { batteryCard }
                    statsRow
                    locationCard
                    detailGrid
                    if vm.ssid != nil { wifiCard }
                    if !vm.regions.isEmpty { regionsCard }
                    if !vm.motionActivities.isEmpty { motionCard }
                    if vm.poi != nil || vm.tag != nil { poiCard }
                    if vm.photoData != nil { photoCard }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))

            if vm.showCopiedNotice {
                VStack {
                    Text("Copied to clipboard")
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    Spacer()
                }
                .padding(.top, 8)
                .animation(.easeInOut(duration: 0.3), value: vm.showCopiedNotice)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header Card

    var headerCard: some View {
        CardView {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(vm.isOnline ? Color.green : Color.secondary)
                            .frame(width: 10, height: 10)
                        Text(vm.isOnline ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(vm.deviceName)
                        .font(.system(size: 26, weight: .bold))
                    if !vm.topic.isEmpty {
                        Text(vm.topic)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if !vm.tid.isEmpty {
                        Text("TID: \(vm.tid)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                AvatarView(data: vm.avatarData, size: 64)
            }
        }
    }

    // MARK: - Status Banner

    var statusBanner: some View {
        let offline = !vm.isOnline
        let bg: Color = offline ? .red.opacity(0.12) : .blue.opacity(0.08)
        let icon = offline ? "wifi.slash"
            : vm.connectionText.lowercased().contains("wifi") ? "wifi"
            : "antenna.radiowaves.left.and.right"
        let tint: Color = offline ? .red : .blue
        return CardView(background: UIColor(bg)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.connectionText)
                        .font(.headline)
                    if let date = vm.lastSeenDate {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let zone = vm.zoneName {
                    Text(zone)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Battery Card

    var batteryCard: some View {
        let level = vm.batteryLevel
        let color: Color = level >= 0.5 ? .green : level >= 0.2 ? .yellow : .red
        return CardView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(level * 100))%")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(color)
                }
                ProgressView(value: level)
                    .tint(color)
                    .scaleEffect(x: 1, y: 2, anchor: .center)
                if !vm.batteryStatusText.isEmpty {
                    Text(vm.batteryStatusText.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Stats Row

    var statsRow: some View {
        HStack(spacing: 12) {
            ExpandableStatCard(
                icon: "gauge.high",
                iconColor: .blue,
                value: vm.speedText,
                label: "Speed",
                unit: vm.speedUnit,
                chartData: vm.speedHistory
            )
            ExpandableStatCard(
                icon: "airplane",
                iconColor: .indigo,
                value: vm.altitudeText,
                label: "Altitude",
                unit: vm.altitudeUnit,
                chartData: vm.altitudeHistory
            )
        }
    }

    // MARK: - Location Card

    var locationCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.red)
                        .font(.title3)
                    Text("Last Known Location")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                if !vm.address.isEmpty {
                    Text(vm.address)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coordinates")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(vm.coordinateText)
                            .font(.subheadline)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.copyCoordinates() }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Accuracy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(vm.accuracyText)
                            .font(.subheadline)
                    }
                }
                Button(action: vm.navigate) {
                    Label("Navigate", systemImage: "map.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
    }

    // MARK: - Detail Grid

    var detailGrid: some View {
        CardView {
            VStack(spacing: 0) {
                DetailGridRow(
                    left: GridCell(icon: "clock", color: .blue, value: vm.timestampText, label: "Last Seen"),
                    right: GridCell(icon: "wifi", color: .green, value: vm.connectionText, label: "Connection")
                )
                Divider().padding(.vertical, 8)
                DetailGridRow(
                    left: GridCell(icon: "bolt.fill", color: .yellow, value: vm.triggerText, label: "Trigger"),
                    right: GridCell(icon: "eye", color: .purple, value: vm.monitoringText, label: "Monitoring")
                )
                Divider().padding(.vertical, 8)
                DetailGridRow(
                    left: GridCell(icon: "location.north.line", color: .orange, value: vm.headingText, label: "Heading"),
                    right: GridCell(icon: "arrow.left.and.right", color: .teal,
                                   value: vm.distanceText.isEmpty ? "-" : vm.distanceText,
                                   label: "Distance")
                )
            }
        }
    }

    // MARK: - Conditional Cards

    var wifiCard: some View {
        CardView {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .foregroundColor(.blue)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.ssid ?? "").font(.subheadline).bold()
                    if let b = vm.bssid {
                        Text(b).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    var regionsCard: some View {
        CardView {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.red)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Regions").font(.caption).foregroundColor(.secondary)
                    Text(vm.regions.joined(separator: ", ")).font(.subheadline)
                }
            }
        }
    }

    var motionCard: some View {
        CardView {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk")
                    .foregroundColor(.green)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity").font(.caption).foregroundColor(.secondary)
                    Text(vm.motionActivities.joined(separator: ", ")).font(.subheadline)
                }
            }
        }
    }

    var poiCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: 6) {
                if let p = vm.poi {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundColor(.yellow)
                        Text(p).font(.subheadline)
                    }
                }
                if let t = vm.tag {
                    HStack(spacing: 8) {
                        Image(systemName: "tag.fill").foregroundColor(.blue)
                        Text(t).font(.subheadline)
                    }
                }
            }
        }
    }

    var photoCard: some View {
        Group {
            if let data = vm.photoData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
            }
        }
    }
}

// MARK: - ExpandableStatCard

struct ExpandableStatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String
    let unit: String
    let chartData: [(date: Date, value: Double)]

    @State private var isExpanded = false

    private var hasData: Bool { chartData.count >= 2 }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if hasData {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(iconColor)
                        Spacer()
                        if hasData {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if isExpanded, hasData {
                    Chart(chartData, id: \.date) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(unit, point.value)
                        )
                        .foregroundStyle(iconColor)
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value(unit, point.value)
                        )
                        .foregroundStyle(iconColor.opacity(0.12))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                            AxisValueLabel {
                                if let n = v.as(Double.self) {
                                    Text("\(Int(n)) \(unit)")
                                        .font(.caption2)
                                }
                            }
                            AxisGridLine()
                        }
                    }
                    .frame(height: 120)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

// MARK: - Shared Components

struct CardView<Content: View>: View {
    var padding: CGFloat = 16
    var background: UIColor = .systemBackground
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: background))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}

struct GridCell: View {
    let icon: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundColor(color).font(.subheadline)
            Text(value).font(.subheadline).lineLimit(2)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailGridRow: View {
    let left: GridCell
    let right: GridCell

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            left
            Divider()
            right
        }
    }
}

struct AvatarView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
