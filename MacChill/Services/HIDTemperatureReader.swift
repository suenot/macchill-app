import Foundation

// MARK: - HID Temperature Reader (fallback for when SMC fails)
// Uses private IOHIDEventSystem API to read PMU tdie sensors

final class HIDTemperatureReader {
    private typealias IOHIDEventSystemClientRef = OpaquePointer
    private typealias IOHIDServiceClientRef = OpaquePointer
    private typealias IOHIDEventRef = OpaquePointer

    private typealias CreateFunc = @convention(c) (CFAllocator?) -> IOHIDEventSystemClientRef?
    private typealias SetMatchingFunc = @convention(c) (IOHIDEventSystemClientRef, CFDictionary?) -> Void
    private typealias CopyServicesFunc = @convention(c) (IOHIDEventSystemClientRef) -> CFArray?
    private typealias CopyEventFunc = @convention(c) (IOHIDServiceClientRef, Int64, Int32, Int64) -> IOHIDEventRef?
    private typealias GetFloatValueFunc = @convention(c) (IOHIDEventRef, UInt32) -> Double
    private typealias ReleaseFunc = @convention(c) (OpaquePointer) -> Void

    private var create: CreateFunc?
    private var setMatching: SetMatchingFunc?
    private var copyServices: CopyServicesFunc?
    private var copyEvent: CopyEventFunc?
    private var getFloatValue: GetFloatValueFunc?
    private var release: ReleaseFunc?
    private var isInitialized = false

    private let kIOHIDEventTypeTemperature: Int64 = 15
    private let kIOHIDEventFieldTemperatureLevel: UInt32 = 0xf0000

    nonisolated(unsafe) static let shared = HIDTemperatureReader()

    private init() {}

    private func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        guard let handle = dlopen(nil, RTLD_NOW) else { return }

        create = unsafeBitCast(dlsym(handle, "IOHIDEventSystemClientCreate"), to: CreateFunc?.self)
        setMatching = unsafeBitCast(dlsym(handle, "IOHIDEventSystemClientSetMatching"), to: SetMatchingFunc?.self)
        copyServices = unsafeBitCast(dlsym(handle, "IOHIDEventSystemClientCopyServices"), to: CopyServicesFunc?.self)
        copyEvent = unsafeBitCast(dlsym(handle, "IOHIDServiceClientCopyEvent"), to: CopyEventFunc?.self)
        getFloatValue = unsafeBitCast(dlsym(handle, "IOHIDEventGetFloatValue"), to: GetFloatValueFunc?.self)
        release = unsafeBitCast(dlsym(handle, "CFRelease"), to: ReleaseFunc?.self)
    }

    func readCPUTemperature() -> TemperatureReading? {
        ensureInitialized()

        guard let create, let setMatching, let copyServices, let copyEvent, let getFloatValue, let release else {
            return nil
        }

        guard let client = create(kCFAllocatorDefault) else { return nil }
        defer { release(client) }

        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching(client, matching as CFDictionary)

        guard let services = copyServices(client) else { return nil }

        var maxTemp: Double = 0
        let count = CFArrayGetCount(services)

        for i in 0..<count {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)

            if let event = copyEvent(service, kIOHIDEventTypeTemperature, 0, 0) {
                let temp = getFloatValue(event, kIOHIDEventFieldTemperatureLevel)
                release(event)
                if temp > maxTemp && temp < 150 {
                    maxTemp = temp
                }
            }
        }

        return maxTemp > 0 ? TemperatureReading(value: maxTemp, source: "HID") : nil
    }
}
