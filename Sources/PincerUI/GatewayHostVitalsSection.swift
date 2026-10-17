import PincerKit
import SwiftUI

/// Gateway Health → Host: vitals from `system.info` with a short sparkline per metric.
struct GatewayHostVitalsSection: View {
    let model: GatewayHostVitalsModel
    let connected: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { self.sizeClass == .compact }
    #else
    private var compact: Bool { false }
    #endif

    private static let staleAfter: TimeInterval = 30
    private static let dash = "—"

    private static let memoryFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f
    }()

    private static func bytes(_ value: Int64) -> String { self.memoryFormatter.string(fromByteCount: value) }
    private static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
    private static func two(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

    var body: some View {
        let model = self.model
        Section(L("Host")) {
            if !model.isAvailable {
                Text("Unavailable on this Gateway", bundle: .module).foregroundStyle(.secondary)
            } else {
                let latest = self.connected ? model.latest : nil
                let failure: String? = if self.connected, case .failed(let message) = model.state { message } else { nil }
                if latest == nil, let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
                // Each poll appends a sample or fails within the 10 s request timeout, so the model changes
                // (and this re-evaluates) at least every poll while the page is visible.
                let stale = latest.map { Date().timeIntervalSince($0.at) > Self.staleAfter || failure != nil } ?? false
                Group {
                    self.identity(latest?.vitals)
                    self.rows(latest)
                }
                .opacity(stale ? 0.5 : 1)
                if stale, let latest {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last sampled \(latest.at.formatted(.relative(presentation: .named)))")
                        if let failure { Text(failure).foregroundStyle(.red) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else if latest != nil, model.samples.count < 2 {
                    Text("Collecting history…", bundle: .module).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func rows(_ latest: GatewayHostVitalsSample?) -> some View {
        let v = latest?.vitals
        self.cpu(v)
        self.memory(v)
        self.disk(v)
        if let v {
            ForEach(Array(v.disks.dropFirst()), id: \.self) { disk in
                MetricRow(
                    title: L("Disk \(disk.path)"), value: L("\(Self.percent(disk.usedFraction)) used"),
                    caption: L("\(Self.bytes(disk.availableBytes)) free of \(Self.bytes(disk.totalBytes))"),
                    warning: disk.usedFraction >= 0.9, series: [], range: 0...1, wrapCaption: self.compact)
            }
        }
        self.load(v)
        self.ping(latest)
    }

    @ViewBuilder private func identity(_ v: GatewayHostVitals?) -> some View {
        if let v {
            VStack(alignment: .leading, spacing: 2) {
                Text(v.displayName)
                Text(Self.identityCaption(v)).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Not connected", bundle: .module).foregroundStyle(.secondary)
        }
    }

    private static func identityCaption(_ v: GatewayHostVitals) -> String {
        var parts = [v.osLabel, v.arch].filter { !$0.isEmpty }
        if let n = v.cpuCount { parts.append(L("\(n) CPUs")) }
        if let m = v.cpuModel, !m.isEmpty { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    private func row(
        _ metric: GatewayHostVitalsMetric, _ title: String, value: String?, caption: String?,
        floor: Double?, ceiling: Double? = nil, hint: String? = nil
    ) -> some View {
        let series = self.connected ? self.model.series(metric) : []
        let observed = series.lazy.compactMap { $0 }.max() ?? 0
        let upper = ceiling ?? max(observed, floor ?? 1)
        return MetricRow(
            title: title, value: value ?? Self.dash, caption: caption,
            warning: self.connected && self.model.isWarning(metric), series: series,
            range: 0...upper, wrapCaption: self.compact, hint: hint)
    }

    private func cpu(_ v: GatewayHostVitals?) -> some View {
        let caption = v?.processCpuCores.map { L("Gateway \(Self.two($0)) cores") }
        return self.row(.cpu, L("Host CPU"), value: v?.hostCpuUtilization.map(Self.percent), caption: caption,
                        floor: nil, ceiling: 1)
    }

    private func memory(_ v: GatewayHostVitals?) -> some View {
        var value: String?
        var caption: String?
        if let used = v?.memoryUsedBytes, let total = v?.memoryTotalBytes, let f = v?.memoryUsedFraction {
            if self.compact {
                value = Self.percent(f)
                caption = L("\(Self.bytes(used)) of \(Self.bytes(total))")
            } else {
                value = L("\(Self.bytes(used)) of \(Self.bytes(total)) (\(Self.percent(f)))")
            }
        }
        if let rss = v?.processRssBytes {
            let gateway = L("Gateway \(Self.bytes(rss))")
            caption = caption.map { "\($0) · \(gateway)" } ?? gateway
        }
        return self.row(.memory, L("Host memory"), value: value, caption: caption, floor: nil, ceiling: 1)
    }

    private func disk(_ v: GatewayHostVitals?) -> some View {
        let d = v?.primaryDisk
        let caption = d.map { L("\(Self.bytes($0.availableBytes)) free of \(Self.bytes($0.totalBytes))") + " · " + $0.path }
        return self.row(.disk, L("Disk"), value: d.map { L("\(Self.percent($0.usedFraction)) used") }, caption: caption,
                        floor: nil, ceiling: 1)
    }

    private func load(_ v: GatewayHostVitals?) -> some View {
        let value = v?.loadAverage.map { $0.map(Self.two).joined(separator: " · ") }
        let caption = v?.loadPerCore.map { L("per core \(Self.two($0))") }
        return self.row(.load, L("Load"), value: value, caption: caption, floor: Double(v?.cpuCount ?? 1))
    }

    private func ping(_ latest: GatewayHostVitalsSample?) -> some View {
        let value = latest.map { L("\(Int($0.pingMs.rounded())) ms") }
        return self.row(.ping, L("Ping"), value: value, caption: nil, floor: 20,
                        hint: L("Round-trip time for the Gateway diagnostics request"))
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let caption: String?
    let warning: Bool
    let series: [Double?]
    let range: ClosedRange<Double>
    let wrapCaption: Bool
    var hint: String?

    private var accessibilityValue: String {
        var parts = [self.value]
        if let caption, !caption.isEmpty { parts.append(caption) }
        if self.warning { parts.append(L("warning")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                if let caption, !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(self.wrapCaption ? 3 : 1)
                }
            }
            Spacer(minLength: 8)
            self.chart
            if self.warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            }
            Text(self.value)
                .monospacedDigit()
                .foregroundStyle(self.warning ? Color.orange : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.title)
        .accessibilityValue(self.accessibilityValue)
        .accessibilityHint(self.hint ?? "")
    }

    @ViewBuilder private var chart: some View {
        if self.series.count >= 2, self.series.contains(where: { $0 != nil }) {
            Sparkline(values: self.series, range: self.range)
                .stroke(self.warning ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                .frame(width: 72, height: 20)
                .accessibilityHidden(true)
        }
    }
}

/// Line through at most 90 samples; `nil` values break the path. Values are normalized to `range`.
struct Sparkline: Shape {
    let values: [Double?]
    let range: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let values = self.values.suffix(GatewayHostVitalsModel.historyCapacity)
        guard values.count > 0 else { return path }
        let span = max(self.range.upperBound - self.range.lowerBound, .leastNonzeroMagnitude)
        let step = values.count > 1 ? rect.width / CGFloat(values.count - 1) : 0
        var pen = false
        for (i, value) in values.enumerated() {
            guard let value, value.isFinite else { pen = false; continue }
            let n = min(max((value - self.range.lowerBound) / span, 0), 1)
            let point = CGPoint(x: rect.minX + CGFloat(i) * step, y: rect.maxY - CGFloat(n) * rect.height)
            if pen {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                if i + 1 >= values.count || values[values.startIndex + i + 1] == nil {
                    path.addLine(to: CGPoint(x: point.x + 0.01, y: point.y))
                }
                pen = true
            }
        }
        return path
    }
}
