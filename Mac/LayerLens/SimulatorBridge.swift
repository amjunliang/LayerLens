//
//  SimulatorBridge.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit
import IOSurface
import ObjectiveC
import XPC

/// CoreSimulator / SimulatorKit 私有接口的最小封装: 取模拟器屏幕 IOSurface, 注入触摸

enum SimBridge {
    private static let lock = NSLock()
    private static var loaded = false
    private static var simKit: UnsafeMutableRawPointer?
    /// 私有框架加载失败的原因, 供网页提示
    private(set) static var loadError: String?

    /// 实际加载 SimulatorKit 的 Xcode, 加载前为 xcode-select 选中的 Xcode
    private(set) static var developerDir = selectedDeveloperDir

    /// xcode-select 选中的 Xcode, 与 simctl 一致
    private static let selectedDeveloperDir: String = {
        let output = TargetRegistry.run("/usr/bin/xcode-select", ["-p"]).flatMap { String(data: $0, encoding: .utf8) }
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? "/Applications/Xcode.app/Contents/Developer" : path
    }()

    /// 候选 Xcode 的 Developer 目录, 按优先级:
    /// 1. 正在运行的 Simulator.app 所属的 Xcode: 它已在和系统的 CoreSimulator 配合工作, 用同一个 Xcode 的 SimulatorKit 最稳妥
    /// 2. xcode-select 选中的 Xcode
    /// 3. LaunchServices 登记的所有 Xcode, 按 bundle id 查找, 不受改名影响
    private static func candidateDeveloperDirs() -> [String] {
        var dirs: [String] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator") {
            // <Xcode>/Contents/Developer/Applications/Simulator.app
            if let url = app.bundleURL { dirs.append(url.deletingLastPathComponent().deletingLastPathComponent().path) }
        }
        dirs.append(selectedDeveloperDir)
        dirs += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.dt.Xcode").map { $0.appendingPathComponent("Contents/Developer").path }
        var seen = Set<String>()
        return dirs.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.filter { seen.insert($0).inserted }
    }

    static func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return simKit != nil }
        loaded = true
        guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_GLOBAL) != nil else {
            loadError = "CoreSimulator: " + String(cString: dlerror())
            LiveLog.write(loadError ?? "")
            return false
        }
        let dirs = candidateDeveloperDirs()
        var errors: [String] = []
        for dir in dirs {
            // Xcode 26 及更早在 Developer/Library/PrivateFrameworks, Xcode 27 移到了 Contents/SharedFrameworks
            let paths = [
                dir + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
                dir + "/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            ]
            for path in paths where FileManager.default.fileExists(atPath: path) {
                if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                    simKit = handle
                    developerDir = dir
                    LiveLog.write("SimulatorKit loaded from \(path)")
                    return true
                }
                errors.append(String(cString: dlerror()))
            }
        }
        loadError = "SimulatorKit: " + (errors.isEmpty ? "not found in " + dirs.joined(separator: ", ") : errors.joined(separator: "; "))
        LiveLog.write(loadError ?? "")
        return false
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        simKit.flatMap { dlsym($0, name) }
    }

    static func device(udid: String) -> NSObject? {
        guard load(), let cls = NSClassFromString("SimServiceContext") else { return nil }
        var err: NSError?
        let ctxSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        typealias CtxFn = @convention(c) (AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let meta = object_getClass(cls), let ctxImp = class_getMethodImplementation(meta, ctxSel),
              let ctx = unsafeBitCast(ctxImp, to: CtxFn.self)(cls, ctxSel, developerDir as NSString, &err) as? NSObject else {
            LiveLog.write("service context failed: \(String(describing: err))")
            return nil
        }
        let setSel = NSSelectorFromString("defaultDeviceSetWithError:")
        typealias SetFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let setImp = class_getMethodImplementation(type(of: ctx), setSel),
              let set = unsafeBitCast(setImp, to: SetFn.self)(ctx, setSel, &err) as? NSObject else { return nil }
        let devices = set.value(forKey: "availableDevices") as? [NSObject] ?? []
        return devices.first { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }
    }

    /// 设置设备方向(UIDeviceOrientation: 1 竖屏, 2 倒置, 3 / 4 横屏), 与 Simulator.app 的旋转菜单相同:
    /// 向模拟器的 PurpleWorkspacePort 发送 GSEvent 方向变更消息
    static func setOrientation(_ device: NSObject, _ orientation: UInt32) -> Bool {
        let sel = NSSelectorFromString("lookup:error:")
        guard device.responds(to: sel), let imp = class_getMethodImplementation(type(of: device), sel) else { return false }
        typealias LookupFn = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32
        var err: NSError?
        let port = unsafeBitCast(imp, to: LookupFn.self)(device, sel, "PurpleWorkspacePort", &err)
        guard port != 0 else { return false }
        // mach_msg_header_t(24 字节) + GSEvent, 共 112 字节
        var bytes = [UInt8](repeating: 0, count: 112)
        func write(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        write(0x13, at: 0x00)
        write(108, at: 0x04)
        write(port, at: 0x08)
        write(0x7B, at: 0x14)
        write(50 | 0x20000, at: 0x18)
        write(4, at: 0x48)
        write(orientation, at: 0x4C)
        let result = bytes.withUnsafeMutableBytes { raw in
            mach_msg_send(raw.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self))
        }
        return result == KERN_SUCCESS
    }

    /// 屏幕像素与 point 的比例
    static func screenScale(_ device: NSObject) -> Double {
        (device.value(forKeyPath: "deviceType.mainScreenScale") as? NSNumber)?.doubleValue ?? 3
    }
}

/// 屏幕帧: 注册帧回调, 每次回调取当前 IOSurface
final class SimScreen {
    private let queue: DispatchQueue
    private var descriptors: [NSObject] = []
    private var uuids: [NSUUID] = []
    var onFrame: ((IOSurface) -> Void)?

    init?(device: NSObject, queue: DispatchQueue) {
        self.queue = queue
        guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else { return nil }
        var found = Self.descriptors(io: io)
        if found.isEmpty {
            io.perform(NSSelectorFromString("updateIOPorts"))
            found = Self.descriptors(io: io)
        }
        guard !found.isEmpty else { return nil }
        descriptors = found
    }

    private static func descriptors(io: NSObject) -> [NSObject] {
        let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] ?? []
        return ports.compactMap { port in
            guard let pid = port.perform(NSSelectorFromString("portIdentifier"))?.takeUnretainedValue(),
                  "\(pid)" == "com.apple.framebuffer.display",
                  let desc = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: NSSelectorFromString("framebufferSurface")) else { return nil }
            return desc
        }
    }

    func surface() -> IOSurface? {
        // 多个 display 时取面积最大的(手机主屏)
        var best: (IOSurface, Int)?
        for desc in descriptors {
            guard let obj = desc.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() else { continue }
            let surf = unsafeBitCast(obj, to: IOSurface.self)
            let area = IOSurfaceGetWidth(surf) * IOSurfaceGetHeight(surf)
            if area > (best?.1 ?? 0) { best = (surf, area) }
        }
        return best?.0
    }

    func start() {
        let sel = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void
        for desc in descriptors where desc.responds(to: sel) {
            let uuid = NSUUID()
            uuids.append(uuid)
            let frame: @convention(block) () -> Void = { [weak self] in self?.emit() }
            let changed: @convention(block) () -> Void = { [weak self] in self?.emit() }
            let props: @convention(block) () -> Void = {}
            guard let imp = class_getMethodImplementation(type(of: desc), sel) else { continue }
            unsafeBitCast(imp, to: Fn.self)(desc, sel, uuid, queue as AnyObject, frame as AnyObject, changed as AnyObject, props as AnyObject)
        }
        queue.async { [weak self] in self?.emit() }
    }

    func stop() {
        let sel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for (desc, uuid) in zip(descriptors, uuids) where desc.responds(to: sel) {
            desc.perform(sel, with: uuid)
        }
        uuids.removeAll()
    }

    private func emit() {
        autoreleasepool {
            if let surf = surface() { onFrame?(surf) }
        }
    }
}

/// 触摸注入: IOHIDEvent 数字化仪事件 -> SimulatorKit 包装为 Indigo 消息 -> 补写目标与边缘字段 -> 发送
final class SimTouch {
    enum Phase { case down, move, up }

    private typealias CreateDigitizerFn = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias CreateFingerFn = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias AppendFn = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    private typealias WrapFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias ServiceFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias KeyFn = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?

    private let client: AnyObject
    private let createDigitizer: CreateDigitizerFn
    private let createFinger: CreateFingerFn
    private let append: AppendFn
    private let wrap: WrapFn
    private let key: KeyFn?
    private var identifier: UInt32 = 0
    private static let touchTarget: UInt32 = 0x32

    init?(device: NSObject) {
        let dyld = UnsafeMutableRawPointer(bitPattern: -2)
        guard let d = dlsym(dyld, "IOHIDEventCreateDigitizerEvent"),
              let f = dlsym(dyld, "IOHIDEventCreateDigitizerFingerEvent"),
              let a = dlsym(dyld, "IOHIDEventAppendEvent"),
              let w = SimBridge.symbol("IndigoHIDMessageForTrackpadEventFromHIDEventRef"),
              let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            LiveLog.write("touch symbols missing")
            return nil
        }
        createDigitizer = unsafeBitCast(d, to: CreateDigitizerFn.self)
        createFinger = unsafeBitCast(f, to: CreateFingerFn.self)
        append = unsafeBitCast(a, to: AppendFn.self)
        wrap = unsafeBitCast(w, to: WrapFn.self)
        key = SimBridge.symbol("IndigoHIDMessageForHIDArbitrary").map { unsafeBitCast($0, to: KeyFn.self) }

        let initSel = NSSelectorFromString("initWithDevice:error:")
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let meta = object_getClass(cls),
              let allocImp = class_getMethodImplementation(meta, NSSelectorFromString("alloc")),
              let allocated = unsafeBitCast(allocImp, to: AllocFn.self)(cls, NSSelectorFromString("alloc")),
              let initImp = class_getMethodImplementation(cls, initSel) else { return nil }
        var err: NSError?
        guard let c = unsafeBitCast(initImp, to: InitFn.self)(allocated, initSel, device, &err) else {
            LiveLog.write("HID client init failed: \(String(describing: err))")
            return nil
        }
        client = c
        // 与 Simulator.app 一致, 先创建 pointer / mouse 服务
        for name in ["IndigoHIDMessageToCreatePointerService", "IndigoHIDMessageToCreateMouseService"] {
            if let sym = SimBridge.symbol(name), let msg = unsafeBitCast(sym, to: ServiceFn.self)() {
                _ = send(msg)
                usleep(20_000)
            }
        }
    }

    /// point 为 0~1 的归一化坐标; edge: 0 无, 1 底部(上滑回桌面), 8 顶部
    @discardableResult
    func send(phase: Phase, x: Double, y: Double, edge: UInt8 = 0) -> Bool {
        if phase == .down {
            identifier &+= 1
            if identifier == 0 { identifier = 1 }
        }
        let mask: UInt32 = phase == .up ? 0x06 : 0x07
        let touching = phase != .up
        let now = mach_absolute_time()
        guard let parent = createDigitizer(nil, now, 2, 0, identifier, mask, 0, x, y, 0, 0, 0, touching, touching, 0)?.takeRetainedValue() else { return false }
        if let finger = createFinger(nil, now, 0, identifier, mask, x, y, 0, 0, 0, touching, touching, 0)?.takeRetainedValue() {
            append(parent, finger, 0)
        }
        let raw: UnsafeMutableRawPointer? = withExtendedLifetime(parent) {
            wrap(Unmanaged.passUnretained(parent as AnyObject).toOpaque())
        }
        guard let msg = raw else { return false }
        // 包装函数未初始化的字段: 两条记录的目标(0x6c / 0x10c)和边缘标记(0x3a~0x3b / 0xda~0xdb)
        let size = malloc_size(msg)
        msg.storeBytes(of: Self.touchTarget, toByteOffset: 0x6c, as: UInt32.self)
        if size >= 0x110 { msg.storeBytes(of: Self.touchTarget, toByteOffset: 0x10c, as: UInt32.self) }
        let present: UInt8 = edge == 0 ? 0 : 0x04
        msg.storeBytes(of: present, toByteOffset: 0x3a, as: UInt8.self)
        msg.storeBytes(of: edge, toByteOffset: 0x3b, as: UInt8.self)
        if size >= 0xdc {
            msg.storeBytes(of: present, toByteOffset: 0xda, as: UInt8.self)
            msg.storeBytes(of: edge, toByteOffset: 0xdb, as: UInt8.self)
        }
        return send(msg)
    }

    /// 键盘按键, usage 为 HID 键盘页(0x07)的用法码
    @discardableResult
    func sendKey(usage: UInt32, down: Bool) -> Bool {
        guard let key, let msg = key(Self.touchTarget, 0x07, usage, down ? 1 : 2) else { return false }
        return send(msg)
    }

    /// Xcode 26 的硬件按键服务; Home source=0, hardware target=0x33。
    @discardableResult
    func sendHome(down: Bool) -> Bool {
        typealias ButtonFn = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
        guard let symbol = SimBridge.symbol("IndigoHIDMessageForButton"),
              let message = unsafeBitCast(symbol, to: ButtonFn.self)(0, down ? 1 : 2, 0x33) else { return false }
        return send(message)
    }

    private func send(_ message: UnsafeMutableRawPointer) -> Bool {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client), let method = class_getInstanceMethod(cls, sel) else {
            free(message)
            return false
        }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue?, (@convention(block) (NSError?) -> Void)?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(client, sel, message, true, nil, nil)
        return true
    }
}

/// 仅负责 Home: 新模拟器使用 dtuhidd, 不支持该服务的 Xcode 26 保留 Indigo。
/// 协议参考 facebook/idb 的 DTUHIDModels / SimulatorXPCConnection (MIT)。
/// https://github.com/facebook/idb/tree/main/FBSimulatorControl/HID
/// 独立队列预热, 不让服务启动或超时阻塞触摸和画面。
final class SimHomeButton {
    private static let service = "com.apple.coredevice.feature.remote.hid.digitizer"
    private let device: NSObject
    private let queue = DispatchQueue(label: "com.layerlens.live.home")
    private let replyQueue = DispatchQueue(label: "com.layerlens.live.home.reply")
    private let lock = NSLock()
    private var stopped = false
    private var connection: xpc_connection_t?
    private var legacy = false // 仅在确定服务/符号不支持时回退
    private var failed = false
    private var generation = UUID()
    private var pendingPresses = 0

    init(device: NSObject) {
        self.device = device
        queue.async { [weak self] in self?.connect() }
    }

    func stop() {
        lock.lock()
        stopped = true
        generation = UUID()
        let old = connection
        connection = nil
        lock.unlock()
        if let old { xpc_connection_cancel(old) }
    }
    deinit { stop() }

    func press(legacyPress: @escaping () -> Void, unavailable: @escaping () -> Void) {
        lock.lock()
        guard !stopped, pendingPresses < 2 else { lock.unlock(); return }
        pendingPresses += 1
        lock.unlock()
        let deadline = DispatchTime.now() + .milliseconds(500)
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pendingPresses -= 1
                self.lock.unlock()
            }
            self.lock.lock()
            let active = !self.stopped
            let needsConnect = (self.connection == nil || self.failed) && !self.legacy
            self.lock.unlock()
            guard active else { return }
            guard DispatchTime.now() < deadline else { unavailable(); return }
            if needsConnect { self.connect() }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.stopped else { return }
            // 不补发等待过久的点击, 防止切换目标后突然出现 Home 或连击。
            guard DispatchTime.now() < deadline else { unavailable(); return }
            if self.legacy { legacyPress(); return }
            guard let connection = self.connection, !self.failed else { unavailable(); return }
            xpc_connection_send_message(connection, Self.message(down: true))
            usleep(30_000)
            xpc_connection_send_message(connection, Self.message(down: false))
        }
    }

    static func message(down: Bool, barrier: Bool = false) -> xpc_object_t {
        let payload = xpc_dictionary_create(nil, nil, 0)
        if !barrier { xpc_dictionary_set_uint64(payload, "usagePage", 0x0c) }
        xpc_dictionary_set_uint64(payload, "usageCode", barrier ? 0 : 0x40)
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", barrier ? "IndigoKeyboardButtonEvent" : "IndigoButtonEvent")
        xpc_dictionary_set_string(message, "featureIdentifier", service)
        xpc_dictionary_set_bool(message, "isBarrier", barrier)
        xpc_dictionary_set_value(message, "payload", payload)
        return message
    }

    private func connect() {
        typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
        typealias Connection = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
        typealias Enable = @convention(c) (xpc_connection_t) -> Void
        lock.lock()
        let active = !stopped
        let old = connection
        connection = nil
        generation = UUID()
        let token = generation
        lock.unlock()
        if let old { xpc_connection_cancel(old) }
        guard active else { return }
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let e = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let c = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let enable = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
            legacy = true
            return
        }
        let selector = NSSelectorFromString("lookup:error:")
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t
        guard let method = class_getInstanceMethod(type(of: device), selector) else { legacy = true; return }
        var error: NSError?
        let port = unsafeBitCast(method_getImplementation(method), to: Lookup.self)(device, selector, Self.service as NSString, &error)
        guard port != MACH_PORT_NULL else {
            let state = device.responds(to: NSSelectorFromString("state")) ? (device.value(forKey: "state") as? NSNumber)?.intValue : nil
            // 启动中也可能返回 405, 不能因此永久选到旧通道。SimDeviceStateBooted=3。
            legacy = (state == nil || state == 3) && error?.domain == "com.apple.CoreSimulator.SimError" && error?.code == 405
            LiveLog.write("Home service lookup: \(String(describing: error)); legacy=\(legacy)")
            return
        }
        // endpoint 接管 lookup 返回的 send right; 两个 create 都返回 +1。
        guard let endpoint = unsafeBitCast(e, to: Endpoint.self)(port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
              let peer = unsafeBitCast(c, to: Connection.self)(endpoint)?.takeRetainedValue() as? xpc_connection_t else { return }
        unsafeBitCast(enable, to: Enable.self)(peer)
        xpc_connection_set_target_queue(peer, replyQueue)
        xpc_connection_set_event_handler(peer) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR, let self else { return }
            self.lock.lock()
            if self.generation == token { self.failed = true }
            self.lock.unlock()
        }
        lock.lock()
        guard !stopped else { lock.unlock(); xpc_connection_cancel(peer); return }
        connection = peer
        failed = false
        lock.unlock()
        xpc_connection_resume(peer)
        let answered = DispatchSemaphore(value: 0)
        // 只有有效的 barrier 回复才表示 daemon 可用。
        xpc_connection_send_message_with_reply(peer, Self.message(down: false, barrier: true), replyQueue) { reply in
            if xpc_get_type(reply) != XPC_TYPE_ERROR { answered.signal() }
        }
        let ready = answered.wait(timeout: .now() + .seconds(4)) == .success
        if ready { usleep(200_000) }
        lock.lock()
        let accepted = ready && !stopped && !failed
        if !accepted { connection = nil }
        lock.unlock()
        if !accepted { xpc_connection_cancel(peer) }
        LiveLog.write("Home dtuhidd ready=\(accepted)")
    }
}
