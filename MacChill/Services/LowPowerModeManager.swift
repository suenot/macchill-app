import Foundation
import os.log

private let log = Logger(subsystem: "com.macchill", category: "LowPowerMode")

// MARK: - Low Power Mode Manager
// Uses `pmset` to toggle macOS power mode.
// Supports both legacy `lowpowermode` and modern `powermode` keys.
// On first use, installs a sudoers entry so future toggles don't need a password.

final class LowPowerModeManager {
    nonisolated(unsafe) static let shared = LowPowerModeManager()

    private(set) var isLowPowerModeEnabled: Bool = false
    private(set) var lastError: String?

    private let sudoersPath = "/etc/sudoers.d/macchill"

    // Detect which pmset key this system uses
    private var usesModernPowerMode: Bool = false

    private init() {
        detectPowerModeKey()
        refreshStatus()
    }

    /// Detect whether system uses `powermode` (macOS Sequoia+) or `lowpowermode` (older)
    private func detectPowerModeKey() {
        let output = runPmsetGet()
        // Modern macOS uses "powermode" (0=low, 1=auto, 2=high)
        // Older macOS uses "lowpowermode" (0=off, 1=on)
        if output.range(of: #"^\s*powermode\s+"#, options: .regularExpression, range: nil, locale: nil) != nil
            || output.range(of: #"\n\s*powermode\s+"#, options: .regularExpression) != nil {
            usesModernPowerMode = true
            log.info("Detected modern 'powermode' key")
        } else {
            usesModernPowerMode = false
            log.info("Using legacy 'lowpowermode' key")
        }
    }

    private func runPmsetGet() -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// Reads current Low Power Mode status via pmset
    func refreshStatus() {
        let output = runPmsetGet()

        if usesModernPowerMode {
            // powermode: 0 = Low Power, 1 = Automatic, 2 = High Performance
            if let match = output.range(of: #"powermode\s+(\d+)"#, options: .regularExpression) {
                let matched = String(output[match])
                let digits = matched.filter { $0.isNumber }
                let value = Int(digits) ?? 1
                isLowPowerModeEnabled = (value == 0)
                log.debug("powermode=\(value) → isLowPower=\(self.isLowPowerModeEnabled)")
            }
        } else {
            // lowpowermode: 0 = off, 1 = on
            isLowPowerModeEnabled = output.range(of: #"lowpowermode\s+1"#, options: .regularExpression) != nil
            log.debug("lowpowermode check → isLowPower=\(self.isLowPowerModeEnabled)")
        }

        lastError = nil
    }

    /// Enable Low Power Mode
    func enableLowPowerMode() {
        setLowPowerMode(enabled: true)
    }

    /// Disable Low Power Mode (back to Automatic)
    func disableLowPowerMode() {
        setLowPowerMode(enabled: false)
    }

    /// Toggle Low Power Mode
    func toggle() {
        setLowPowerMode(enabled: !isLowPowerModeEnabled)
    }

    /// Set Low Power Mode on or off
    func setLowPowerMode(enabled: Bool) {
        let pmsetKey: String
        let pmsetValue: String

        if usesModernPowerMode {
            pmsetKey = "powermode"
            pmsetValue = enabled ? "0" : "1"  // 0=Low Power, 1=Automatic
        } else {
            pmsetKey = "lowpowermode"
            pmsetValue = enabled ? "1" : "0"
        }

        log.info("setLowPowerMode(\(enabled)) key=\(pmsetKey) value=\(pmsetValue) sudoers=\(self.isSudoersInstalled)")

        // Try passwordless sudo first
        if isSudoersInstalled {
            if runSudoPmset(key: pmsetKey, value: pmsetValue) {
                log.info("sudo pmset succeeded")
                refreshStatus()
                lastError = nil
                return
            }
        }

        // Sudoers not installed — install it (asks password once), then retry
        if !isSudoersInstalled {
            log.info("Installing sudoers entry...")
            if installSudoers() {
                log.info("Sudoers installed, retrying pmset")
                if runSudoPmset(key: pmsetKey, value: pmsetValue) {
                    log.info("sudo pmset succeeded after sudoers install")
                    refreshStatus()
                    lastError = nil
                    return
                }
                log.error("sudo pmset failed after sudoers install")
            } else {
                log.error("Failed to install sudoers entry")
            }
        }

        // Last resort: AppleScript with password prompt
        log.info("Falling back to AppleScript with password prompt")
        let script = """
        do shell script "/usr/bin/pmset -a \(pmsetKey) \(pmsetValue)" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            log.error("AppleScript pmset failed: \(msg)")
            lastError = msg
        } else {
            log.info("AppleScript pmset succeeded")
            refreshStatus()
            lastError = nil
        }
    }

    // MARK: - Private Helpers

    private var isSudoersInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    private func runSudoPmset(key: String, value: String) -> Bool {
        let task = Process()
        let errPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/usr/bin/pmset", "-a", key, value]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return true
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? ""
            log.error("sudo pmset failed: status=\(task.terminationStatus) err=\(errMsg)")
        } catch {
            log.error("sudo pmset exception: \(error.localizedDescription)")
        }
        return false
    }

    /// Install sudoers entry for passwordless pmset.
    /// Covers both legacy and modern keys.
    private func installSudoers() -> Bool {
        let user = NSUserName()
        let line1 = "# Allow MacChill to toggle power mode without password"
        let line2 = "\(user) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a powermode *"
        let line3 = "\(user) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a lowpowermode *"

        let script = "do shell script \"printf '%s\\n' '\(line1)' '\(line2)' '\(line3)' > \(sudoersPath) && chmod 0440 \(sudoersPath)\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        return errorDict == nil
    }
}
