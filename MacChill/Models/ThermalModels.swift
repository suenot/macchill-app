import Foundation
import SwiftUI

// MARK: - Thermal Pressure Levels

enum ThermalPressure: String, Codable, CaseIterable {
    case nominal
    case moderate
    case heavy
    case critical
    case unknown

    var displayName: String {
        switch self {
        case .nominal:  return "Nominal"
        case .moderate: return "Moderate"
        case .heavy:    return "Heavy"
        case .critical: return "Critical"
        case .unknown:  return "Unknown"
        }
    }

    var isThrottling: Bool {
        self == .heavy || self == .critical
    }

    var color: Color {
        switch self {
        case .nominal:  return .green
        case .moderate: return .yellow
        case .heavy:    return .orange
        case .critical: return .red
        case .unknown:  return .gray
        }
    }

    /// Should Low Power Mode be activated at this level?
    var shouldEnableLowPowerMode: Bool {
        isThrottling
    }
}

// MARK: - Data Structures

struct TemperatureReading {
    let value: Double
    let source: String  // SMC key or "HID"
}

struct FanSpeed {
    let rpm: Double
    let percentage: Double  // 0–100%
}

struct HistoryEntry {
    let pressure: ThermalPressure
    let temperature: Double?
    let fanSpeed: Double?     // Percentage 0–100%
    let lowPowerMode: Bool
    let timestamp: Date
}

// MARK: - Auto-Switch Threshold

enum AutoSwitchThreshold: String, CaseIterable, Identifiable {
    case moderate   // enable LPM at moderate+
    case heavy      // enable LPM at heavy+  (default)
    case critical   // enable LPM only at critical
    case off        // manual only

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .moderate: return "Moderate"
        case .heavy:    return "Heavy"
        case .critical: return "Critical"
        case .off:      return "Off (Manual)"
        }
    }

    func shouldEnableLPM(for pressure: ThermalPressure) -> Bool {
        switch self {
        case .moderate: return pressure == .moderate || pressure == .heavy || pressure == .critical
        case .heavy:    return pressure == .heavy || pressure == .critical
        case .critical: return pressure == .critical
        case .off:      return false
        }
    }

    func shouldDisableLPM(for pressure: ThermalPressure) -> Bool {
        switch self {
        case .moderate: return pressure == .nominal
        case .heavy:    return pressure == .nominal || pressure == .moderate
        case .critical: return pressure == .nominal || pressure == .moderate || pressure == .heavy
        case .off:      return false
        }
    }
}
