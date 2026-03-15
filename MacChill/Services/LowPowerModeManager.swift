import Foundation

// MARK: - Low Power Mode Manager
// Uses `pmset` to toggle macOS Low Power Mode.
// Requires the app to be run with admin privileges or the user to have
// added a sudoers entry for pmset.

final class LowPowerModeManager {
    nonisolated(unsafe) static let shared = LowPowerModeManager()

    private(set) var isLowPowerModeEnabled: Bool = false
    private(set) var lastError: String?

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
                // Look for "lowpowermode   1" or "lowpowermode   0"
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

    private func setLowPowerMode(enabled: Bool) {
        let value = enabled ? "1" : "0"

        // Try without sudo first (works if app has proper entitlements)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-a", "lowpowermode", value]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                isLowPowerModeEnabled = enabled
                lastError = nil
                return
            }
        } catch {
            // Fall through to AppleScript method
        }

        // Fallback: use AppleScript to run with admin privileges
        let script = """
        do shell script "pmset -a lowpowermode \(value)" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "Failed to set Low Power Mode"
        } else {
            isLowPowerModeEnabled = enabled
            lastError = nil
        }
    }
}
