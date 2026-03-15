import Foundation
import SwiftUI
import UserNotifications

// MARK: - Central Thermal Monitor
// Polls temperature, thermal pressure, fan speed every 2 seconds.
// Auto-switches Low Power Mode based on configurable threshold.

@Observable
final class ThermalMonitor {
    // MARK: - Constants
    private static let historyDuration: TimeInterval = 600   // 10 minutes
    private static let pollInterval: TimeInterval = 2.0
    private static let cooldownBeforeDisable: Int = 5         // polls before turning LPM off

    // MARK: - Published State
    private(set) var pressure: ThermalPressure = .unknown
    private(set) var temperature: Double?
    private(set) var temperatureSource: String?
    private(set) var fanSpeed: Double?
    private(set) var hasFans: Bool = false
    private(set) var history: [HistoryEntry] = []
    private(set) var isLowPowerModeEnabled: Bool = false
    private(set) var autoSwitchedLPM: Bool = false  // true if LPM was turned on by auto-switch

    // MARK: - Settings (persisted via UserDefaults)

    var autoSwitchThreshold: AutoSwitchThreshold {
        get {
            let raw = UserDefaults.standard.string(forKey: "autoSwitchThreshold") ?? "heavy"
            return AutoSwitchThreshold(rawValue: raw) ?? .heavy
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "autoSwitchThreshold")
        }
    }

    var showTemperatureInMenuBar: Bool = UserDefaults.standard.object(forKey: "showTempMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTemperatureInMenuBar, forKey: "showTempMenuBar") }
    }

    var showFanSpeed: Bool = UserDefaults.standard.object(forKey: "showFanSpeed") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFanSpeed, forKey: "showFanSpeed") }
    }

    var notifyOnThrottle: Bool = UserDefaults.standard.object(forKey: "notifyOnThrottle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnThrottle, forKey: "notifyOnThrottle") }
    }

    var notifyOnRecovery: Bool = UserDefaults.standard.object(forKey: "notifyOnRecovery") as? Bool ?? false {
        didSet { UserDefaults.standard.set(notifyOnRecovery, forKey: "notifyOnRecovery") }
    }

    // MARK: - Private
    private var timer: Timer?
    private var previousPressure: ThermalPressure = .unknown
    private var cooldownCounter: Int = 0

    // MARK: - Computed

    var timeInEachState: [(pressure: ThermalPressure, duration: TimeInterval)] {
        guard history.count >= 2 else { return [] }
        var durations: [ThermalPressure: TimeInterval] = [:]

        for i in 0..<(history.count - 1) {
            let current = history[i]
            let next = history[i + 1]
            durations[current.pressure, default: 0] += next.timestamp.timeIntervalSince(current.timestamp)
        }

        if let last = history.last {
            durations[last.pressure, default: 0] += Date().timeIntervalSince(last.timestamp)
        }

        return durations.map { (pressure: $0.key, duration: $0.value) }
            .sorted { $0.duration > $1.duration }
    }

    var totalHistoryDuration: TimeInterval {
        guard let first = history.first else { return 0 }
        return Date().timeIntervalSince(first.timestamp)
    }

    // MARK: - Lifecycle

    init() {
        requestNotificationPermission()
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        updateState()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.updateState()
        }
    }

    private func updateState() {
        // 1. Read thermal pressure
        let newPressure = ThermalPressureReader.shared.readPressure() ?? .unknown

        // 2. Notifications on pressure change
        if newPressure != previousPressure {
            if notifyOnThrottle && newPressure.isThrottling && !previousPressure.isThrottling {
                sendNotification(
                    title: "Thermal Throttling",
                    body: newPressure == .critical
                        ? "Your Mac is severely throttled! Low Power Mode activated."
                        : "Thermal pressure is Heavy. Low Power Mode activated."
                )
            }
            if notifyOnRecovery && previousPressure.isThrottling && !newPressure.isThrottling && newPressure != .unknown {
                sendNotification(
                    title: "Thermal Pressure Recovered",
                    body: "Your Mac is no longer being throttled."
                )
            }
            previousPressure = newPressure
        }

        pressure = newPressure

        // 3. Read CPU temperature (SMC primary, HID fallback)
        if let smcReading = SMCReader.shared.readCPUTemperature() {
            temperature = smcReading.value
            temperatureSource = smcReading.source
        } else if let hidReading = HIDTemperatureReader.shared.readCPUTemperature() {
            temperature = hidReading.value
            temperatureSource = hidReading.source
        } else {
            temperature = nil
            temperatureSource = nil
        }

        // 4. Read fan speed
        if let fan = SMCReader.shared.readFanSpeed() {
            fanSpeed = fan.percentage
            if !hasFans { hasFans = true }
        }

        // 5. Refresh LPM status
        LowPowerModeManager.shared.refreshStatus()
        isLowPowerModeEnabled = LowPowerModeManager.shared.isLowPowerModeEnabled

        // 6. Auto-switch Low Power Mode
        handleAutoSwitch(pressure: newPressure)

        // 7. Record history
        let entry = HistoryEntry(
            pressure: newPressure,
            temperature: temperature,
            fanSpeed: fanSpeed,
            lowPowerMode: isLowPowerModeEnabled,
            timestamp: Date()
        )
        history.append(entry)

        // Trim old entries
        let cutoff = Date().addingTimeInterval(-Self.historyDuration)
        history.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - Auto Low Power Mode Logic

    private func handleAutoSwitch(pressure: ThermalPressure) {
        let threshold = autoSwitchThreshold
        guard threshold != .off else { return }

        if threshold.shouldEnableLPM(for: pressure) && !isLowPowerModeEnabled {
            // Temperature is high → enable LPM
            LowPowerModeManager.shared.enableLowPowerMode()
            isLowPowerModeEnabled = true
            autoSwitchedLPM = true
            cooldownCounter = 0
        } else if threshold.shouldDisableLPM(for: pressure) && isLowPowerModeEnabled && autoSwitchedLPM {
            // Temperature dropped → wait for cooldown then disable
            cooldownCounter += 1
            if cooldownCounter >= Self.cooldownBeforeDisable {
                LowPowerModeManager.shared.disableLowPowerMode()
                isLowPowerModeEnabled = false
                autoSwitchedLPM = false
                cooldownCounter = 0
            }
        } else if !threshold.shouldDisableLPM(for: pressure) {
            cooldownCounter = 0
        }
    }

    // MARK: - Manual LPM Toggle

    func toggleLowPowerMode() {
        LowPowerModeManager.shared.toggle()
        LowPowerModeManager.shared.refreshStatus()
        isLowPowerModeEnabled = LowPowerModeManager.shared.isLowPowerModeEnabled
        autoSwitchedLPM = false  // user took manual control
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
