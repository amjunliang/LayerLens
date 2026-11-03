import Foundation
import XPC
import Darwin

// SimulatorBridge 的外部依赖; 测试不枚举或操作用户设备。
enum TargetRegistry { static func run(_ path: String, _ args: [String]) -> Data? { nil } }
enum LiveLog { static func write(_ message: String) {} }

class UnsupportedDevice: NSObject {
    @objc(lookup:error:)
    func lookup(_ name: NSString, error: AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32 {
        error.pointee = NSError(domain: "com.apple.CoreSimulator.SimError", code: 405)
        return 0
    }
}
final class BootingDevice: UnsupportedDevice {
    @objc var state: Int = 2
}
final class FailedDevice: NSObject {
    @objc(lookup:error:)
    func lookup(_ name: NSString, error: AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32 {
        error.pointee = NSError(domain: "test.lookup", code: 1)
        return 0
    }
}

@main struct Tests {
    static func main() {
        for down in [true, false] {
            let message = SimHomeButton.message(down: down)
            precondition(String(cString: xpc_dictionary_get_string(message, "messageType")!) == "IndigoButtonEvent")
            precondition(!xpc_dictionary_get_bool(message, "isBarrier"))
            let payload = xpc_dictionary_get_value(message, "payload")!
            precondition(xpc_dictionary_get_uint64(payload, "usagePage") == 12)
            precondition(xpc_dictionary_get_uint64(payload, "usageCode") == 64)
            precondition(xpc_dictionary_get_uint64(payload, "state") == (down ? 1 : 2))
        }
        for down in [true, false] {
            let power = SimHomeButton.message(down: down, usage: 0x30)
            let payload = xpc_dictionary_get_value(power, "payload")!
            precondition(xpc_dictionary_get_uint64(payload, "usagePage") == 12)
            precondition(xpc_dictionary_get_uint64(payload, "usageCode") == 48)
            precondition(xpc_dictionary_get_uint64(payload, "state") == (down ? 1 : 2))
        }
        let barrier = SimHomeButton.message(down: false, barrier: true)
        precondition(xpc_dictionary_get_bool(barrier, "isBarrier"))
        let payload = xpc_dictionary_get_value(barrier, "payload")!
        precondition(xpc_dictionary_get_uint64(payload, "usageCode") == 0)
        precondition(xpc_dictionary_get_uint64(payload, "state") == 2)
        precondition(xpc_dictionary_get_value(payload, "usagePage") == nil)
        // 只加载框架以解析符号, 不连接任何实际模拟器。
        _ = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_GLOBAL)
        let legacy = SimHomeButton(device: UnsupportedDevice())
        let clicks = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            legacy.press(legacyPress: { clicks.signal() }, unavailable: { fatalError("legacy unavailable") })
        }
        precondition(clicks.wait(timeout: .now() + 2) == .success)
        precondition(clicks.wait(timeout: .now() + 2) == .success)
        legacy.stop()
        legacy.press(legacyPress: { fatalError("press after stop") }, unavailable: { fatalError("callback after stop") })
        // 瞬时 lookup 失败不能当成不支持, 否则会静默退回无效的 Indigo。
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        let symbols: [String] = ["xpc_endpoint_create_mach_port_4sim", "xpc_connection_create_from_endpoint", "xpc_connection_enable_sim2host_4sim"]
        if symbols.allSatisfy({ name in name.withCString { dlsym(handle, $0) != nil } }) {
            for device in [FailedDevice(), BootingDevice()] {
            let failed = SimHomeButton(device: device)
            let rejected = DispatchSemaphore(value: 0)
            failed.press(legacyPress: { fatalError("incorrect legacy fallback") }, unavailable: { rejected.signal() })
            precondition(rejected.wait(timeout: .now() + 2) == .success)
            failed.stop()
            }
        }
        print("PASS Home wire format, legacy double press, stop, booting and operational failure")
    }
}
