import Foundation
import os.log
import SwiftUI
import UserNotifications

private let log = Logger(subsystem: "com.macchill", category: "ThermalMonitor")

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

    var autoLPMEnabled: Bool = UserDefaults.standard.object(forKey: "autoLPMEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoLPMEnabled, forKey: "autoLPMEnabled") }
    }

    var enableTemp: Double = UserDefaults.standard.object(forKey: "enableTemp") as? Double ?? 80 {
        didSet { UserDefaults.standard.set(enableTemp, forKey: "enableTemp") }
    }

    var disableTemp: Double = UserDefaults.standard.object(forKey: "disableTemp") as? Double ?? 60 {
        didSet { UserDefaults.standard.set(disableTemp, forKey: "disableTemp") }
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
    private var lastLPMNotificationTime: Date = .distantPast
    private var lastLPMEnableAttemptTime: Date = .distantPast
    private static let notificationCooldown: TimeInterval = 30  // min seconds between same notifications
    private static let enableRetryInterval: TimeInterval = 10   // don't retry enable more often than this

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

        // 2. Track pressure changes
        previousPressure = newPressure

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

        // 5. Refresh LPM status from system
        LowPowerModeManager.shared.refreshStatus()
        let systemLPM = LowPowerModeManager.shared.isLowPowerModeEnabled

        if autoSwitchedLPM {
            // If we auto-enabled but system says OFF, someone else disabled it — respect that
            if isLowPowerModeEnabled && !systemLPM {
                log.info("System LPM was externally disabled, clearing auto flag")
                isLowPowerModeEnabled = false
                autoSwitchedLPM = false
                cooldownCounter = 0
            }
            // If we auto-enabled and system confirms ON, keep our state
        } else {
            // Not auto-managed — always sync from system
            isLowPowerModeEnabled = systemLPM
        }

        log.debug("temp=\(self.temperature ?? -1, format: .fixed(precision: 0))°C lpm=\(self.isLowPowerModeEnabled) system=\(systemLPM) auto=\(self.autoSwitchedLPM) cooldown=\(self.cooldownCounter)")

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

    // MARK: - Auto Low Power Mode Logic (temperature-based)

    private func handleAutoSwitch(pressure: ThermalPressure) {
        guard autoLPMEnabled, let temp = temperature else { return }

        if temp >= enableTemp && !isLowPowerModeEnabled {
            // CPU too hot → enable LPM (with retry throttle)
            let now = Date()
            guard now.timeIntervalSince(lastLPMEnableAttemptTime) >= Self.enableRetryInterval else {
                log.debug("Skipping LPM enable: too soon since last attempt")
                return
            }
            lastLPMEnableAttemptTime = now

            log.info("Auto-enable LPM: temp=\(temp, format: .fixed(precision: 0))°C >= \(self.enableTemp, format: .fixed(precision: 0))°C")
            LowPowerModeManager.shared.enableLowPowerMode()
            isLowPowerModeEnabled = true
            autoSwitchedLPM = true
            cooldownCounter = 0

            if notifyOnThrottle {
                sendThrottledNotification(
                    title: "Low Power Mode ON",
                    body: "CPU at \(Int(temp))°C — enabled energy saving."
                )
            }
        } else if temp <= disableTemp && isLowPowerModeEnabled && autoSwitchedLPM {
            // CPU cooled down → increment cooldown counter
            cooldownCounter += 1
            log.debug("Cooldown \(self.cooldownCounter)/\(Self.cooldownBeforeDisable) for LPM disable")
            if cooldownCounter >= Self.cooldownBeforeDisable {
                log.info("Auto-disable LPM: temp=\(temp, format: .fixed(precision: 0))°C <= \(self.disableTemp, format: .fixed(precision: 0))°C after \(Self.cooldownBeforeDisable) polls")
                LowPowerModeManager.shared.disableLowPowerMode()
                isLowPowerModeEnabled = false
                autoSwitchedLPM = false
                cooldownCounter = 0
                if notifyOnRecovery {
                    sendThrottledNotification(
                        title: "Low Power Mode OFF",
                        body: "CPU cooled to \(Int(temp))°C — back to normal."
                    )
                }
            }
        }
        // NOTE: cooldown counter is NOT reset when temp rises above disableTemp.
        // This prevents oscillation at the boundary from blocking disable forever.
        // Counter only resets on successful disable or new enable.
    }

    // MARK: - Manual LPM Toggle

    func toggleLowPowerMode() {
        let wantEnabled = !isLowPowerModeEnabled
        log.info("Manual toggle: want LPM=\(wantEnabled)")
        LowPowerModeManager.shared.setLowPowerMode(enabled: wantEnabled)

        // Give pmset a moment to apply, then verify
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            LowPowerModeManager.shared.refreshStatus()
            let systemState = LowPowerModeManager.shared.isLowPowerModeEnabled
            log.info("After toggle: system reports LPM=\(systemState)")
            self.isLowPowerModeEnabled = systemState
            self.autoSwitchedLPM = false  // user took manual control
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendThrottledNotification(title: String, body: String) {
        let now = Date()
        guard now.timeIntervalSince(lastLPMNotificationTime) >= Self.notificationCooldown else {
            log.debug("Notification throttled: \(title)")
            return
        }
        lastLPMNotificationTime = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "lpm-\(title)",  // reuse ID to replace previous
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
