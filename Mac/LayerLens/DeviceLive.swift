import AppKit
import Foundation
import Darwin
import CoreVideo

/// Device media and HID run in the GUI application; there is no capture helper.
final class DeviceLive {
    static var bridgeURL: URL { Bundle.main.resourceURL!.appendingPathComponent("DeviceBridge/bin/device-resolve") }
    static var libraryURL: URL { bridgeURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libLayerLensDevice.dylib") }
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: bridgeURL.path) && FileManager.default.fileExists(atPath: libraryURL.path) }
    static var unavailableReason: String {
        let file = libraryURL.deletingLastPathComponent().appendingPathComponent("unavailable.txt")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? "当前安装缺少真机采集组件。"
    }
    private let queue = DispatchQueue(label: "com.layerlens.device.live")
    private var sessions: [String: DeviceLiveSession] = [:]

    func shutdown() {
        queue.sync {
            let current = Array(sessions.values)
            sessions.removeAll()
            for session in current { session.shutdown() }
        }
    }
    func accept(udid: String, head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        guard head.header("Upgrade")?.lowercased() == "websocket" else {
            connection.respond(.error(400, "Device live stream unavailable")); return
        }
        let socket = WebSocketConnection(connection: connection.detach(), leftover: leftover)
        func reject(_ reason: String) {
            guard socket.accept(head) else { socket.close(); return }
            let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "detail": reason])
            socket.sendText(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}") { _ in socket.close() }
        }
        guard Self.isAvailable else { reject(Self.unavailableReason); return }
        queue.async { [self] in
            // AVConference's private image queue is routed to one physical device
            // at a time. Simulator sessions remain independent.
            if sessions[udid] == nil {
                for other in sessions.values {
                    guard other.isIdle else { reject("主进程采集一次支持一台真机，请先关闭其他真机观看窗口。"); return }
                }
                let previous = Array(sessions.values)
                sessions.removeAll()
                for other in previous { other.shutdown() }
            }
            let session = sessions[udid] ?? DeviceLiveSession(udid: udid)
            sessions[udid] = session
            session.add(socket, head: head) { [weak self, weak session] in
                self?.queue.async {
                    if self?.sessions[udid] === session { self?.sessions[udid] = nil }
                }
            }
        }
    }
}

private final class NativeDeviceAPI {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UInt8, UnsafeRawPointer?, Int) -> Void
    typealias Create = @convention(c) (UnsafePointer<CChar>?, Callback, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias Input = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Void
    let create: Create
    let input: Input
    let close: Close
    private let library: UnsafeMutableRawPointer
    static let shared: NativeDeviceAPI? = NativeDeviceAPI()
    private init?() {
        guard let handle = dlopen(DeviceLive.libraryURL.path, RTLD_NOW | RTLD_LOCAL),
              let make = dlsym(handle, "LLNativeCreate"), let send = dlsym(handle, "LLNativeInput"), let stop = dlsym(handle, "LLNativeClose") else {
            LiveLog.write("native device library: \(dlerror().map { String(cString: $0) } ?? "symbol unavailable")")
            return nil
        }
        library = handle // Keep private ABI code loaded while callbacks may exist.
        create = unsafeBitCast(make, to: Create.self)
        input = unsafeBitCast(send, to: Input.self)
        close = unsafeBitCast(stop, to: Close.self)
    }
}
private final class NativeDeviceCallback {
    let receive: (UInt8, Data, CVPixelBuffer?) -> Void
    init(_ receive: @escaping (UInt8, Data, CVPixelBuffer?) -> Void) { self.receive = receive }
}
private let nativeDeviceCallback: NativeDeviceAPI.Callback = { context, type, bytes, count in
    guard let context else { return }
    let box = Unmanaged<NativeDeviceCallback>.fromOpaque(context)
    let pixels = type == 10 ? bytes.map { Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeMutableRawPointer(mutating: $0)).takeUnretainedValue() } : nil
    let data = type == 10 ? Data() : bytes.flatMap { count > 0 ? Data(bytes: $0, count: count) : nil } ?? Data()
    box.takeUnretainedValue().receive(type, data, pixels)
    if type == 0 { box.release() }
}

private final class DeviceLiveSession {
    private let udid: String
    private let queue = DispatchQueue(label: "com.layerlens.device.session")
    private let captureQueue = DispatchQueue(label: "com.layerlens.device.encode", qos: .userInteractive)
    private let encoder = LiveVideoEncoder(frameRate: 30)
    private lazy var video = LiveVideoBroadcaster(queue: queue) { [weak self] in
        guard let self else { return }
        self.forceKeyFrame = true
        self.framePending = self.latestPixels != nil
        self.encodePending()
    }
    private var resolver: Process?
    private var native: UnsafeMutableRawPointer?
    private var startupTimer: DispatchSourceTimer?
    private var idleStop: DispatchWorkItem?
    private var viewers: [ObjectIdentifier: WebSocketConnection] = [:]
    private var owner: ObjectIdentifier?
    private var errorText = ""
    private var geometry: [String: Any]?
    private var latestPixels: CVPixelBuffer?
    private var framePending = false
    private var encoding = false
    private var forceKeyFrame = false
    private var stopping = false
    private var onEmpty: (() -> Void)?
    var isIdle: Bool { queue.sync { viewers.isEmpty } }
    init(udid: String) {
        self.udid = udid
        encoder.onOutput = { [weak self] type, data in self?.queue.async {
            guard let self, !self.stopping else { return }
            if type == 0x02 { self.startupTimer?.cancel(); self.startupTimer = nil }
            self.video.broadcast(type, data)
        } }
        encoder.onError = { [weak self] error in self?.queue.async { self?.fail(error) } }
    }

    func add(_ socket: WebSocketConnection, head: HTTPRequestHead, onEmpty: @escaping () -> Void) {
        queue.async { [self] in
            guard !stopping else { socket.close(); return }
            idleStop?.cancel(); idleStop = nil
            self.onEmpty = onEmpty
            let id = ObjectIdentifier(socket)
            socket.onText = { [weak self] text in self?.queue.async { self?.input(text, id: id) } }
            socket.onClose = { [weak self] in self?.queue.async { self?.remove(id) } }
            guard socket.accept(head) else { socket.close(); return }
            viewers[id] = socket
            if let geometry { message(geometry, to: socket) }
            video.add(socket)
            if resolver == nil && native == nil { start() }
        }
    }
    private func start() {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [DeviceLive.bridgeURL.path, udid]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            LiveLog.write("device resolve: " + text)
            self?.queue.async { self?.errorText = String(((self?.errorText ?? "") + text).suffix(3000)) }
        }
        process.terminationHandler = { [weak self] child in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            try? output.fileHandleForReading.close()
            self?.queue.async {
                guard let self, !self.stopping else { return }
                self.resolver = nil
                guard child.terminationStatus == 0, (try? JSONSerialization.jsonObject(with: data)) is [String],
                      let arguments = String(data: data, encoding: .utf8), let api = NativeDeviceAPI.shared else {
                    self.fail(self.errorText.isEmpty ? "无法初始化主进程设备采集" : self.errorText); return
                }
                let box = Unmanaged.passRetained(NativeDeviceCallback { [weak self] kind, packet, pixels in
                    // At most one native image is waiting on the session queue.
                    let done = DispatchSemaphore(value: 0)
                    guard let self else { return }
                    self.queue.async { self.receive(kind, packet, pixels: pixels); done.signal() }
                    done.wait()
                })
                self.native = arguments.withCString { api.create($0, nativeDeviceCallback, box.toOpaque()) }
                if self.native == nil { box.release(); self.fail("主进程采集创建失败") }
                else { LiveLog.write("device \(self.udid): capture and HID in main process pid=\(getpid())") }
            }
        }
        resolver = process
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20)
        timer.setEventHandler { [weak self] in self?.fail("设备采集初始化超时，请确认设备已连接并解锁。") }
        startupTimer = timer; timer.resume()
        do { try process.run() } catch { fail(error.localizedDescription) }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
    }
    private func receive(_ kind: UInt8, _ data: Data, pixels: CVPixelBuffer?) {
        if kind == 0 {
            if let token = native { native = nil; NativeDeviceAPI.shared?.close(token) }
            if !stopping { fail("设备采集已结束") }
            return
        }
        guard !stopping else { return }
        if kind == 254 { LiveLog.write(String(decoding: data, as: UTF8.self)); return }
        if kind == 255 { fail(String(decoding: data, as: UTF8.self)); return }
        if kind == 9, var info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            info["type"] = "geometry"; geometry = info
            for socket in viewers.values { message(info, to: socket) }
        }
        if let pixels {
            latestPixels = pixels; framePending = true
            encodePending()
        }
    }
    /// Bounded to one encoding submission plus the newest source frame.
    private func encodePending() {
        guard !stopping, !encoding, framePending, let pixels = latestPixels, let geometry,
              let width = geometry["width"] as? Double, let height = geometry["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        encoding = true; framePending = false
        let keyFrame = forceKeyFrame; forceKeyFrame = false
        let target = video.targetSize
        let ratio = target.map { max($0.width / width, $0.height / height) } ?? 1
        let scale = min((ratio * 16).rounded(.up) / 16, 1)
        captureQueue.async { [self] in
            if keyFrame { encoder.requestKeyFrame() }
            encoder.encode(pixels, scale: scale, contentSize: CGSize(width: width, height: height)) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.encoding = false; self.encodePending()
                }
            }
        }
    }
    private func message(_ value: [String: Any], to socket: WebSocketConnection) {
        if let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) { socket.sendText(text) }
    }
    private func fail(_ detail: String) {
        guard !stopping else { return }
        let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "detail": detail])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        for socket in viewers.values { socket.sendText(text) { _ in socket.close() } }
        stop()
    }
    private func write(_ text: String) {
        if let native, let api = NativeDeviceAPI.shared { text.withCString { api.input(native, $0) } }
    }
    private func input(_ text: String, id: ObjectIdentifier) {
        guard text.utf8.count < 1_000_000, let data = text.data(using: .utf8),
              let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = item["type"] as? String else { return }
        if type.hasPrefix("touch1-") {
            guard ["x", "y", "width", "height"].allSatisfy({ key in
                (item[key] as? NSNumber)?.doubleValue.isFinite == true
            }), let width = item["width"] as? NSNumber, let height = item["height"] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0 else { return }
        }
        if type == "button" { guard let button = item["button"] as? String, ["swipe-to-home", "app-switcher"].contains(button) else { return } }
        if type == "key" {
            guard let code = item["code"] as? String, code.count <= 64,
                  item["modifiers"] == nil || item["modifiers"] is [String] else { return }
        }
        if type == "paste" { guard item["text"] is String else { return } }
        if type == "size" {
            guard let width = item["width"] as? Double, let height = item["height"] as? Double else { return }
            video.setSize((width, height), of: id)
            framePending = latestPixels != nil; encodePending(); return
        }
        if type == "keyframe" { video.requestKeyFrame(); return }
        if type == "restart" {
            for socket in viewers.values { socket.close() }; stop(); return
        }
        if type == "touch1-down" { guard owner == nil || owner == id else { return }; owner = id }
        if type.hasPrefix("touch1-") { guard owner == id else { return }; if type == "touch1-up" { owner = nil } }
        if type == "release" { guard owner == nil || owner == id else { return }; owner = nil }
        guard ["touch1-down", "touch1-move", "touch1-up", "button", "key", "paste", "release"].contains(type) else { return }
        write(text)
    }
    private func remove(_ id: ObjectIdentifier) {
        viewers[id] = nil; video.remove(id)
        framePending = latestPixels != nil; encodePending()
        if owner == id { write("{\"type\":\"release\"}"); owner = nil }
        guard viewers.isEmpty, !stopping else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.viewers.isEmpty else { return }; self.stop()
        }
        idleStop?.cancel(); idleStop = work; queue.asyncAfter(deadline: .now() + 30, execute: work)
    }
    func shutdown() { queue.sync { stop() } }
    private func stop() {
        guard !stopping else { return }
        stopping = true; idleStop?.cancel(); startupTimer?.cancel(); latestPixels = nil
        video.reset()
        captureQueue.async { [self] in encoder.invalidate() }
        if let resolver {
            if resolver.isRunning { resolver.terminate() }
            queue.asyncAfter(deadline: .now() + 3) { if resolver.isRunning { kill(resolver.processIdentifier, SIGKILL) } }
        }
        resolver = nil
        if let token = native { native = nil; NativeDeviceAPI.shared?.close(token) }
        onEmpty?()
    }
}
