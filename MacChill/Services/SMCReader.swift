import Foundation
import IOKit

// MARK: - SMC Temperature Reader
// Based on https://github.com/exelban/stats and https://github.com/angristan/MacThrottle

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyData {
    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)
        self = str.utf8.reduce(0) { sum, character in
            return sum << 8 | UInt32(character)
        }
    }
}

final class SMCReader {
    nonisolated(unsafe) static let shared = SMCReader()

    private var conn: io_connect_t = 0
    private var isConnected = false

    // CPU/GPU temperature keys by chip generation
    private let m1Keys = [
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        "Tg05", "Tg0D", "Tg0L", "Tg0T"
    ]
    private let mProMaxKeys = [
        "TC10", "TC11", "TC12", "TC13",
        "TC20", "TC21", "TC22", "TC23",
        "TC30", "TC31", "TC32", "TC33",
        "TC40", "TC41", "TC42", "TC43",
        "TC50", "TC51", "TC52", "TC53",
        "Tg04", "Tg05", "Tg0C", "Tg0D", "Tg0K", "Tg0L", "Tg0S", "Tg0T"
    ]
    private let m2Keys = [
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
        "Tg0f", "Tg0j"
    ]
    private let m3Keys = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"
    ]
    private let m4Keys = [
        "Te05", "Te0S", "Te09", "Te0H",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"
    ]

    private var cachedFanCount: Int?

    private init() {
        connect()
    }

    deinit {
        if isConnected {
            IOServiceClose(conn)
        }
    }

    private func connect() {
        guard let matchingDict = IOServiceMatching("AppleSMC") else { return }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == kIOReturnSuccess else { return }

        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return }

        let openResult = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        isConnected = (openResult == kIOReturnSuccess)
    }

    // MARK: - Public API

    func readCPUTemperature() -> TemperatureReading? {
        guard isConnected else { return nil }

        var maxTemp: Double = 0
        var maxKey: String = ""

        let allKeys = m1Keys + mProMaxKeys + m2Keys + m3Keys + m4Keys
        for key in allKeys {
            if let temp = readTemperature(key: key), temp > maxTemp && temp < 150 {
                maxTemp = temp
                maxKey = key
            }
        }

        return maxTemp > 0 ? TemperatureReading(value: maxTemp, source: maxKey) : nil
    }

    func readFanSpeed() -> FanSpeed? {
        guard isConnected else { return nil }

        let fanCount = getFanCount()
        guard fanCount > 0 else { return nil }

        var totalRPM: Double = 0
        var totalPercentage: Double = 0
        var validReadings = 0

        for i in 0..<fanCount {
            if let actual = readFanValue(fan: i, key: "Ac"),
               let max = readFanValue(fan: i, key: "Mx"),
               max > 0 {
                totalRPM += actual
                totalPercentage += (actual / max) * 100
                validReadings += 1
            }
        }

        guard validReadings > 0 else { return nil }

        return FanSpeed(
            rpm: totalRPM / Double(validReadings),
            percentage: min(100, totalPercentage / Double(validReadings))
        )
    }

    // MARK: - Private helpers

    private func getFanCount() -> Int {
        if let cached = cachedFanCount { return cached }
        guard let value = readUInt8(key: "FNum") else {
            cachedFanCount = 0
            return 0
        }
        cachedFanCount = Int(value)
        return Int(value)
    }

    private func readFanValue(fan: Int, key: String) -> Double? {
        readFloat(key: "F\(fan)\(key)")
    }

    private func readUInt8(key: String) -> UInt8? {
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = FourCharCode(fromString: key)
        input.data8 = 9  // kSMCReadKeyInfo
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let dataSize = output.keyInfo.dataSize
        guard dataSize >= 1 else { return nil }

        input.keyInfo.dataSize = dataSize
        input.data8 = 5  // kSMCReadBytes
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        return output.bytes.0
    }

    private func readFloat(key: String) -> Double? {
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = FourCharCode(fromString: key)
        input.data8 = 9
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let dataSize = output.keyInfo.dataSize
        input.keyInfo.dataSize = dataSize
        input.data8 = 5
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        if dataSize == 4 {
            let bitPattern = UInt32(output.bytes.0) | (UInt32(output.bytes.1) << 8) |
                            (UInt32(output.bytes.2) << 16) | (UInt32(output.bytes.3) << 24)
            return Double(Float(bitPattern: bitPattern))
        }

        if dataSize == 2 {
            let value = (UInt16(output.bytes.0) << 8) | UInt16(output.bytes.1)
            return Double(value) / 4.0
        }

        return nil
    }

    private func readTemperature(key: String) -> Double? {
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = FourCharCode(fromString: key)
        input.data8 = 9
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let dataSize = output.keyInfo.dataSize
        guard dataSize == 4 else { return nil }

        input.keyInfo.dataSize = dataSize
        input.data8 = 5
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let bitPattern = UInt32(output.bytes.0) | (UInt32(output.bytes.1) << 8) |
                        (UInt32(output.bytes.2) << 16) | (UInt32(output.bytes.3) << 24)
        let value = Double(Float(bitPattern: bitPattern))

        return value > 20 && value < 150 ? value : nil
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize)
    }
}
