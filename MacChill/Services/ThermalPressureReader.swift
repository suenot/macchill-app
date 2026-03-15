import Foundation

// MARK: - Thermal Pressure Reader
// Uses Darwin notification system to read thermal pressure level.
// Same 5-level granularity as `powermetrics -s thermal`, no root required.

final class ThermalPressureReader {
    nonisolated(unsafe) static let shared = ThermalPressureReader()

    private var token: Int32 = 0
    private var isRegistered = false

    private init() {
        let result = notify_register_check("com.apple.system.thermalpressurelevel", &token)
        isRegistered = (result == notifyStatusOK)
    }

    deinit {
        if isRegistered {
            _ = notify_cancel(token)
        }
    }

    func readPressure() -> ThermalPressure? {
        guard isRegistered else { return nil }

        var state: UInt64 = 0
        let result = notify_get_state(token, &state)
        guard result == notifyStatusOK else { return nil }

        switch state {
        case 0:    return .nominal
        case 1:    return .moderate
        case 2:    return .heavy
        case 3, 4: return .critical
        default:   return .unknown
        }
    }
}

// MARK: - Darwin notify functions

@_silgen_name("notify_register_check")
private func notify_register_check(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<Int32>
) -> UInt32

@_silgen_name("notify_get_state")
private func notify_get_state(
    _ token: Int32,
    _ state: UnsafeMutablePointer<UInt64>
) -> UInt32

@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> UInt32

private let notifyStatusOK: UInt32 = 0
