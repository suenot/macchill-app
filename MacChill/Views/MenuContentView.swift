import SwiftUI

func colorForTemperature(_ temp: Double) -> Color {
    switch temp {
    case ..<60:  return .green
    case 60..<80: return .yellow
    case 80..<95: return .orange
    default:      return .red
    }
}

struct MenuContentView: View {
    @Bindable var monitor: ThermalMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // MARK: - Status Header
            HStack {
                Text("Thermal Pressure:")
                Text(monitor.pressure.displayName)
                    .foregroundColor(monitor.pressure.color)
                    .fontWeight(.semibold)
                Spacer()
                if let temp = monitor.temperature {
                    Text("\(Int(temp.rounded()))°C")
                        .foregroundColor(colorForTemperature(temp))
                        .fontWeight(.semibold)
                        .help("Source: \(monitor.temperatureSource ?? "Unknown")")
                }
            }
            .font(.headline)

            // MARK: - Low Power Mode Status
            HStack {
                Image(systemName: monitor.isLowPowerModeEnabled ? "bolt.circle.fill" : "bolt.circle")
                    .foregroundColor(monitor.isLowPowerModeEnabled ? .yellow : .secondary)

                Text("Low Power Mode")
                Text(monitor.isLowPowerModeEnabled ? "ON" : "OFF")
                    .fontWeight(.semibold)
                    .foregroundColor(monitor.isLowPowerModeEnabled ? .yellow : .secondary)

                if monitor.autoSwitchedLPM {
                    Text("(auto)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(monitor.isLowPowerModeEnabled ? "Disable" : "Enable") {
                    monitor.toggleLowPowerMode()
                }
                .controlSize(.small)
            }
            .font(.subheadline)

            // MARK: - Fan Speed
            if monitor.hasFans, let fan = monitor.fanSpeed {
                HStack {
                    Image(systemName: "fan.fill")
                        .foregroundColor(.cyan)
                    Text("Fan: \(Int(fan))%")
                    Spacer()
                }
                .font(.subheadline)
            }

            // MARK: - History Graph
            if monitor.history.count >= 2 {
                HistoryGraphView(history: monitor.history, showFanSpeed: monitor.showFanSpeed)
            }

            // MARK: - Statistics
            if !monitor.timeInEachState.isEmpty {
                Divider()
                Text("Statistics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimeBreakdownView(
                    timeInEachState: monitor.timeInEachState,
                    totalDuration: monitor.totalHistoryDuration
                )
            }

            Divider()

            // MARK: - Auto-Switch Settings
            Toggle("Auto Low Power Mode", isOn: $monitor.autoLPMEnabled)
                .controlSize(.small)

            if monitor.autoLPMEnabled {
                HStack {
                    Text("Enable at:")
                        .font(.caption)
                        .frame(width: 65, alignment: .leading)
                    Text("\(Int(monitor.enableTemp))°C")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                        .frame(width: 35)
                    Slider(value: $monitor.enableTemp, in: 30...100, step: 5)
                        .controlSize(.small)
                }
                HStack {
                    Text("Disable at:")
                        .font(.caption)
                        .frame(width: 65, alignment: .leading)
                    Text("\(Int(monitor.disableTemp))°C")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                        .frame(width: 35)
                    Slider(value: $monitor.disableTemp, in: 30...100, step: 5)
                        .controlSize(.small)
                }
            }

            Divider()

            // MARK: - Display Settings
            Text("Display")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show temperature in menu bar", isOn: $monitor.showTemperatureInMenuBar)
                .controlSize(.small)

            if monitor.hasFans {
                Toggle("Show fan speed in graph", isOn: $monitor.showFanSpeed)
                    .controlSize(.small)
            }

            Divider()

            // MARK: - Notifications
            Text("Notifications")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("On throttling", isOn: $monitor.notifyOnThrottle)
                .controlSize(.small)
            Toggle("On recovery", isOn: $monitor.notifyOnRecovery)
                .controlSize(.small)

            Divider()

            // MARK: - Quit
            HStack {
                Spacer()
                Button("Quit MacChill") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
