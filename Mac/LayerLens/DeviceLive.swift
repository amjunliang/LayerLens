import AppKit
import Foundation
import Darwin

/// Experimental iOS 27 transport, isolated from the simulator's private frameworks.
/// A single helper owns each device and forwards the original compressed frames.
final class DeviceLive {
    static var bridgeURL: URL { Bundle.main.resourceURL!.appendingPathComponent("DeviceBridge/bin/ipb") }
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: bridgeURL.path) }
    static var unavailableReason: String {
        let file = bridgeURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("unavailable.txt")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? "当前安装缺少真机采集组件，请使用包含设备采集组件的 LayerLens 构建。"
    }
    private let queue = DispatchQueue(label: "com.layerlens.device.live")
    private var sessions: [String: DeviceLiveSession] = [:]

    func accept(udid: String, head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        guard head.header("Upgrade")?.lowercased() == "websocket" else {
            connection.respond(.error(400, "Device live stream unavailable")); return
        }
        let socket = WebSocketConnection(connection: connection.detach(), leftover: leftover)
        if !Self.isAvailable {
            guard socket.accept(head) else { socket.close(); return }
            let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "detail": Self.unavailableReason])
            socket.sendText(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}") { _ in socket.close() }
            return
        }
        queue.async { [self] in
            let session = sessions[udid] ?? DeviceLiveSession(udid: udid)
            sessions[udid] = session
            session.add(socket, head: head) { [weak self, weak session] in
                self?.queue.async {
                    if self?.sessions[udid] === session { self?.sessions[udid] = nil }
                }
            }
        }
        // HTTP upgrade parsing is safe after callbacks have been installed by add.
    }
}

private final class DeviceLiveSession {
    private let udid: String
    private let queue = DispatchQueue(label: "com.layerlens.device.session")
    private let inputQueue = DispatchQueue(label: "com.layerlens.device.input")
    private let readQueue = DispatchQueue(label: "com.layerlens.device.frames")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var sessionDirectory: URL?
    private var errorTimer: DispatchSourceTimer?
    private var viewers: [ObjectIdentifier: WebSocketConnection] = [:]
    private var inFlight: [ObjectIdentifier: Int] = [:]
    private var owner: ObjectIdentifier?
    private var orientation = 1
    private var errorText = ""
    private var idleStop: DispatchWorkItem?
    private var stopping = false
    private var onEmpty: (() -> Void)?

    init(udid: String) { self.udid = udid }

    func add(_ socket: WebSocketConnection, head: HTTPRequestHead, onEmpty: @escaping () -> Void) {
        queue.async { [self] in
            idleStop?.cancel()
            idleStop = nil
            let id = ObjectIdentifier(socket)
            self.onEmpty = onEmpty
            socket.onText = { [weak self] text in self?.queue.async { self?.input(text, id: id) } }
            socket.onClose = { [weak self] in self?.queue.async { self?.remove(id) } }
            guard socket.accept(head) else { socket.close(); return }
            viewers[id] = socket
            needsKey.insert(id)
            replay(to: socket, id: id)
            // A very long GOP can exceed the bounded replay cache. Restart the
            // shared session on a new join so every viewer gets a fresh source key.
            if config != nil && gop.isEmpty {
                for viewer in viewers.values { viewer.close() }
                stop()
                return
            }
            if process == nil { start() }
        }
    }

    private func start() {
        let child = Process(), output = Pipe(), errors = Pipe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("layerlens-live-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in ["input", "output"] {
                guard mkfifo(directory.appendingPathComponent(name).path, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            inputHandle = try FileHandle(forUpdating: directory.appendingPathComponent("input"))
            outputHandle = try FileHandle(forUpdating: directory.appendingPathComponent("output"))
            sessionDirectory = directory
        } catch {
            fail(error.localizedDescription); return
        }
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = [DeviceLive.bridgeURL.path, "-s", udid, "mirror", "--seconds", "3600"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["LAYERLENS_SESSION"] = directory.path
        env["LAYERLENS_PARENT_PID"] = String(getpid())
        child.environment = env
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            LiveLog.write("device: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            self?.queue.async {
                guard let self else { return }
                self.errorText = String((self.errorText + text).suffix(3000))
                self.message(["type": "status", "detail": String(self.errorText.suffix(1500))])
            }
        }
        child.terminationHandler = { [weak self] child in
            self?.queue.async {
                guard let self else { return }
                self.fail(self.errorText.isEmpty ? "Device helper exited (\(child.terminationStatus))" : String(self.errorText.suffix(1500)))
                if self.viewers.isEmpty { self.stop() }
            }
        }
        process = child
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let data = try? Data(contentsOf: directory.appendingPathComponent("errors")), !data.isEmpty else { return }
            let text = String(decoding: data.suffix(3000), as: UTF8.self)
            if text != self.errorText {
                self.errorText = text
                LiveLog.write("device GUI: " + text)
                self.message(["type": "status", "detail": String(text.suffix(1500))])
            }
        }
        errorTimer = timer; timer.resume()
        do { try child.run() } catch {
            fail(error.localizedDescription)
            process = nil
            return
        }
        readQueue.async { [weak self] in
            guard let handle = self?.outputHandle else { return }
            func read(_ count: Int) -> Data? {
                var result = Data()
                while result.count < count {
                    guard let chunk = try? handle.read(upToCount: count - result.count), !chunk.isEmpty else { return nil }
                    result.append(chunk)
                }
                return result
            }
            while let header = read(4) {
                let size = header.reduce(0) { ($0 << 8) | Int($1) }
                guard size > 1, size <= 20_000_000, let payload = read(size) else { break }
                // Keep one pending frame; the reader never builds an unbounded dispatch queue.
                let semaphore = DispatchSemaphore(value: 0)
                self?.queue.async {
                    defer { semaphore.signal() }
                    guard let self, !self.stopping else { return }
                    self.forward(payload)

                }
                if self == nil { break }
                semaphore.wait()
            }
            try? handle.close()
        }
    }

    private var gop: [Data] = []
    private var gopBytes = 0
    private var config: Data?
    private var needsKey: Set<ObjectIdentifier> = []
    private func forward(_ packet: Data) {
        guard let type = packet.first else { return }
        if type == 5 {
            config = packet
            gop = []; gopBytes = 0
            if let metadata = try? JSONSerialization.jsonObject(with: Data(packet.dropFirst())) as? [String: Any] {
                var geometry = metadata
                geometry["type"] = "geometry"
                message(geometry)
            }
            // A new configuration requires a keyframe for every decoder.
            needsKey.formUnion(viewers.keys)
            return
        }
        guard type == 6 || type == 7 else { return }
        if type == 6 { gop = []; gopBytes = 0 }
        if type == 6 || !gop.isEmpty {
            gop.append(packet); gopBytes += packet.count
            if gop.count > 12000 || gopBytes > 12_000_000 { gop = []; gopBytes = 0 }
        }
        for (id, socket) in viewers {
            if (inFlight[id] ?? 0) >= 12 { needsKey.insert(id); continue }
            if needsKey.contains(id) {
                guard type == 6, let config else { continue }
                socket.sendBinary(config) { _ in }
                needsKey.remove(id)
            }
            send(packet, to: socket, id: id)
        }
    }
    private func send(_ packet: Data, to socket: WebSocketConnection, id: ObjectIdentifier) {
        inFlight[id, default: 0] += 1
        socket.sendBinary(packet) { [weak self] _ in self?.queue.async {
            guard let self, self.viewers[id] != nil else { return }
            self.inFlight[id] = max(0, (self.inFlight[id] ?? 1) - 1)
            if self.inFlight[id] == 0 && self.needsKey.contains(id) { self.replay(to: socket, id: id) }
        } }
    }
    private func replay(to socket: WebSocketConnection, id: ObjectIdentifier) {
        guard let config, !gop.isEmpty, gop.first?.first == 6 else { return }
        needsKey.remove(id)
        socket.sendBinary(config) { _ in }
        for packet in gop { send(packet, to: socket, id: id) }
    }
    private func fail(_ detail: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "detail": detail]), let text = String(data: data, encoding: .utf8) else { return }
        for socket in viewers.values { socket.sendText(text) { _ in socket.close() } }
    }
    private func message(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return }
        for socket in viewers.values { socket.sendText(text) }
    }
    private func write(_ text: String) {
        guard let handle = inputHandle else { return }
        inputQueue.async { try? handle.write(contentsOf: Data((text + "\n").utf8)) }
    }
    private func input(_ text: String, id: ObjectIdentifier) {
        guard text.utf8.count < 1_000_000, let data = text.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = m["type"] as? String else { return }
        if type == "touch1-down" { guard owner == nil || owner == id else { return }; owner = id }
        if type.hasPrefix("touch1-") { guard owner == id else { return }; if type == "touch1-up" { owner = nil } }
        if type == "release" { guard owner == nil || owner == id else { return }; owner = nil }
        guard ["touch1-down", "touch1-move", "touch1-up", "button", "key", "paste", "release"].contains(type) else { return }
        write(text)
    }
    private func remove(_ id: ObjectIdentifier) {
        viewers[id] = nil; inFlight[id] = nil; needsKey.remove(id)
        if owner == id { write("{\"type\":\"release\"}"); owner = nil }
        guard viewers.isEmpty, !stopping else { return }
        if process?.isRunning != true { stop(); return }
        // 快速切回同一设备时复用媒体协商结果和 GOP，不重启 helper。
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.viewers.isEmpty else { return }
            self.stop()
        }
        idleStop = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }
    private func stop() {
        guard !stopping else { return }
        idleStop?.cancel(); idleStop = nil
        stopping = true
        errorTimer?.cancel(); errorTimer = nil
        let handle = inputHandle
        inputQueue.async {
            try? handle?.write(contentsOf: Data("{\"type\":\"close\"}\n".utf8))
        }
        if let outputHandle { try? outputHandle.write(contentsOf: Data([0, 0, 0, 0])) }
        if let directory = sessionDirectory {
            queue.asyncAfter(deadline: .now() + 12) { try? FileManager.default.removeItem(at: directory) }
        }
        let child = process
        queue.asyncAfter(deadline: .now() + 3) { if child?.isRunning == true { child?.terminate() } }
        onEmpty?()
    }
}
