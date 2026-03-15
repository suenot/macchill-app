import SwiftUI

// MARK: - History Graph (temperature + fan + thermal pressure background)

struct HistoryGraphView: View {
    let history: [HistoryEntry]
    var showFanSpeed: Bool = true

    private static let maxPoints = 300
    private static let minTempBound: Double = 30
    private static let maxTempBound: Double = 110
    private static let tempPadding: Double = 5

    @State private var hoverLocation: CGPoint?
    @State private var graphWidth: CGFloat = 220

    private var historyDuration: TimeInterval {
        guard let first = history.first else { return 0 }
        return Date().timeIntervalSince(first.timestamp)
    }

    private var sampled: [HistoryEntry] {
        guard history.count > Self.maxPoints else { return history }
        let step = Double(history.count) / Double(Self.maxPoints)
        var result: [HistoryEntry] = []
        result.reserveCapacity(Self.maxPoints)
        for i in 0..<Self.maxPoints {
            let index = min(Int(Double(i) * step), history.count - 1)
            result.append(history[index])
        }
        if let last = history.last, result.last?.timestamp != last.timestamp {
            result[result.count - 1] = last
        }
        return result
    }

    private var tempRange: (min: Double, max: Double) {
        let temps = sampled.compactMap { $0.temperature }
        guard !temps.isEmpty else { return (Self.minTempBound, 100) }
        let lo = max(Self.minTempBound, (temps.min() ?? Self.minTempBound) - Self.tempPadding)
        let hi = min(Self.maxTempBound, (temps.max() ?? 100) + Self.tempPadding)
        return (lo, hi)
    }

    private var hasFanData: Bool {
        showFanSpeed && sampled.contains { $0.fanSpeed != nil }
    }

    private func yForTemp(_ temp: Double, height: CGFloat) -> CGFloat {
        let r = tempRange
        let pad: CGFloat = 4
        let norm = (temp - r.min) / (r.max - r.min)
        return pad + (1.0 - CGFloat(norm)) * (height - pad * 2)
    }

    private func yForFan(_ pct: Double, height: CGFloat) -> CGFloat {
        let pad: CGFloat = 4
        return pad + (1.0 - CGFloat(pct / 100.0)) * (height - pad * 2)
    }

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, size in
                let data = sampled
                guard data.count >= 2, let first = data.first else { return }
                let startTime = first.timestamp
                let endTime = Date()
                let totalDur = endTime.timeIntervalSince(startTime)
                guard totalDur > 0 else { return }

                // Thermal pressure background bands
                var currentP = data[0].pressure
                var segStart: CGFloat = 0
                for entry in data {
                    let x = CGFloat(entry.timestamp.timeIntervalSince(startTime) / totalDur) * size.width
                    if entry.pressure != currentP {
                        let rect = CGRect(x: segStart, y: 0, width: x - segStart, height: size.height)
                        context.fill(Path(rect), with: .color(currentP.color.opacity(0.25)))
                        currentP = entry.pressure
                        segStart = x
                    }
                }
                let finalRect = CGRect(x: segStart, y: 0, width: size.width - segStart, height: size.height)
                context.fill(Path(finalRect), with: .color(currentP.color.opacity(0.25)))

                // Temperature line
                var tempPath = Path()
                var first_ = true
                for entry in data {
                    guard let temp = entry.temperature else { continue }
                    let x = CGFloat(entry.timestamp.timeIntervalSince(startTime) / totalDur) * size.width
                    let y = yForTemp(temp, height: size.height)
                    if first_ { tempPath.move(to: CGPoint(x: x, y: y)); first_ = false }
                    else { tempPath.addLine(to: CGPoint(x: x, y: y)) }
                }
                if let last = data.last, let temp = last.temperature {
                    tempPath.addLine(to: CGPoint(x: size.width, y: yForTemp(temp, height: size.height)))
                }
                context.stroke(tempPath, with: .color(.primary.opacity(0.8)), lineWidth: 1.5)

                // Fan speed line (dashed, cyan)
                if hasFanData {
                    var fanPath = Path()
                    var firstFan = true
                    for entry in data {
                        guard let fan = entry.fanSpeed else { continue }
                        let x = CGFloat(entry.timestamp.timeIntervalSince(startTime) / totalDur) * size.width
                        let y = yForFan(fan, height: size.height)
                        if firstFan { fanPath.move(to: CGPoint(x: x, y: y)); firstFan = false }
                        else { fanPath.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    if let last = data.last, let fan = last.fanSpeed {
                        fanPath.addLine(to: CGPoint(x: size.width, y: yForFan(fan, height: size.height)))
                    }
                    context.stroke(fanPath, with: .color(.cyan.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                }

                // Current point dot
                if let last = data.last, let temp = last.temperature {
                    let y = yForTemp(temp, height: size.height)
                    let circle = Path(ellipseIn: CGRect(x: size.width - 4, y: y - 4, width: 8, height: 8))
                    context.fill(circle, with: .color(.primary))
                }

                // Temp range labels
                let r = tempRange
                let labelFont = Font.system(size: 8)
                let labelColor = Color.secondary.opacity(0.8)
                context.draw(Text("\(Int(r.max))°").font(labelFont).foregroundColor(labelColor),
                             at: CGPoint(x: 4, y: 4), anchor: .topLeading)
                context.draw(Text("\(Int(r.min))°").font(labelFont).foregroundColor(labelColor),
                             at: CGPoint(x: 4, y: size.height - 4), anchor: .bottomLeading)
            }
            .frame(height: 70)
            .drawingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3), lineWidth: 1))

            HStack {
                Text(formatTimeAgo(historyDuration))
                Spacer()
                Text("now")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
    }

    private func formatTimeAgo(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h ago" : "\(hours)h \(mins)m ago"
    }
}

// MARK: - Time Breakdown

struct TimeBreakdownView: View {
    let timeInEachState: [(pressure: ThermalPressure, duration: TimeInterval)]
    let totalDuration: TimeInterval

    private static let allStates: [ThermalPressure] = [.nominal, .moderate, .heavy, .critical]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.allStates, id: \.self) { pressure in
                let duration = timeInEachState.first { $0.pressure == pressure }?.duration ?? 0
                HStack {
                    Circle()
                        .fill(pressure.color)
                        .frame(width: 8, height: 8)
                    HStack(spacing: 2) {
                        Text(pressure.displayName)
                        if pressure.isThrottling {
                            Text("(throttling)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(formatDuration(duration))
                        .foregroundStyle(.secondary)
                    if totalDuration > 0 {
                        Text("(\(Int((duration / totalDuration * 100).rounded()))%)")
                            .foregroundStyle(.secondary)
                            .frame(width: 45, alignment: .trailing)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let total = Int(d)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        else if m > 0 { return String(format: "%dm %ds", m, s) }
        else { return String(format: "%ds", s) }
    }
}
