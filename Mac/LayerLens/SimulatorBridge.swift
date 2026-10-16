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
            NSLog("[live] %@", loadError ?? "")
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
                    NSLog("[live] SimulatorKit loaded from %@", path)
                    return true
                }
                errors.append(String(cString: dlerror()))
            }
        }
        loadError = "SimulatorKit: " + (errors.isEmpty ? "not found in " + dirs.joined(separator: ", ") : errors.joined(separator: "; "))
        NSLog("[live] %@", loadError ?? "")
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
            NSLog("[live] service context failed: %@", String(describing: err))
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
            NSLog("[live] touch symbols missing")
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
            NSLog("[live] HID client init failed: %@", String(describing: err))
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
