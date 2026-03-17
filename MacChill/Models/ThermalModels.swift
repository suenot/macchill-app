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

