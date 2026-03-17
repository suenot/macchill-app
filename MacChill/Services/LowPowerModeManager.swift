import Foundation

// MARK: - Low Power Mode Manager
// Uses `pmset` to toggle macOS Low Power Mode.
// On first use, installs a sudoers entry so future toggles don't need a password.

final class LowPowerModeManager {
    nonisolated(unsafe) static let shared = LowPowerModeManager()

    private(set) var isLowPowerModeEnabled: Bool = false
    private(set) var lastError: String?

    private let sudoersPath = "/etc/sudoers.d/macchill"

    private init() {
        refreshStatus()
    }

    /// Reads current Low Power Mode status via pmset
    func refreshStatus() {
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
            if let output = String(data: data, encoding: .utf8) {
                isLowPowerModeEnabled = output.contains("lowpowermode") &&
                    output.range(of: "lowpowermode\\s+1", options: .regularExpression) != nil
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Enable Low Power Mode
    func enableLowPowerMode() {
        setLowPowerMode(enabled: true)
    }

    /// Disable Low Power Mode
    func disableLowPowerMode() {
        setLowPowerMode(enabled: false)
    }

    /// Toggle Low Power Mode
    func toggle() {
        setLowPowerMode(enabled: !isLowPowerModeEnabled)
    }

    /// Check if sudoers entry is already installed
    private var isSudoersInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// Install sudoers entry so pmset can run without password prompts.
    /// Asks for admin password once via AppleScript.
    private func installSudoers() -> Bool {
        let user = NSUserName()
        // Use printf with escaped newlines — AppleScript strings cannot contain literal newlines
        let line1 = "# Allow MacChill to toggle Low Power Mode without password"
        let line2 = "\(user) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a lowpowermode 0"
        let line3 = "\(user) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a lowpowermode 1"

        let script = "do shell script \"printf '%s\\n' '\(line1)' '\(line2)' '\(line3)' > \(sudoersPath) && chmod 0440 \(sudoersPath)\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        return errorDict == nil
    }

    private func setLowPowerMode(enabled: Bool) {
        let value = enabled ? "1" : "0"

        // Try passwordless sudo (works if sudoers entry is configured)
        if isSudoersInstalled {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", value]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                task.waitUntilExit()

                if task.terminationStatus == 0 {
                    refreshStatus()
                    lastError = nil
                    return
                }
            } catch {
                // Fall through
            }
        }

        // Sudoers not installed — install it (asks password once), then retry
        if !isSudoersInstalled {
            if installSudoers() {
                // Sudoers installed, now retry with passwordless sudo
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                task.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", value]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice

                do {
                    try task.run()
                    task.waitUntilExit()

                    if task.terminationStatus == 0 {
                        refreshStatus()
                        lastError = nil
                        return
                    }
                } catch {
                    // Fall through to direct AppleScript
                }
            }
        }

        // Last resort: direct AppleScript with password prompt
        let script = """
        do shell script "/usr/bin/pmset -a lowpowermode \(value)" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "Failed to set Low Power Mode"
        } else {
            refreshStatus()
            lastError = nil
        }
    }
}
