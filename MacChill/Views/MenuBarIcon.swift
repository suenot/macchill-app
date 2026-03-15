import SwiftUI

struct MenuBarIcon: View {
    let pressure: ThermalPressure
    let temperature: Double?
    let showTemperature: Bool
    let isLowPowerMode: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(pressure.color, .primary)

            if showTemperature, let temp = temperature {
                Text("\(Int(temp.rounded()))°")
                    .monospacedDigit()
            }

            if isLowPowerMode {
                Image(systemName: "bolt.circle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption2)
            }
        }
    }

    private var iconName: String {
        switch pressure {
        case .nominal:  return "thermometer.low"
        case .moderate: return "thermometer.medium"
        case .heavy:    return "thermometer.high"
        case .critical: return "thermometer.sun.fill"
        case .unknown:  return "thermometer.variable.and.figure"
        }
    }
}
