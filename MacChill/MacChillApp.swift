import SwiftUI

@main
struct MacChillApp: App {
    @State private var monitor = ThermalMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        } label: {
            MenuBarIcon(
                pressure: monitor.pressure,
                temperature: monitor.temperature,
                showTemperature: monitor.showTemperatureInMenuBar,
                isLowPowerMode: monitor.isLowPowerModeEnabled
            )
        }
        .menuBarExtraStyle(.window)
    }
}
