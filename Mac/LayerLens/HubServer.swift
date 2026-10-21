//
//  HubServer.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// Mac 端 HTTP 服务: 提供网页、设备列表, 并把 /t/<设备>/<App>/... 转发给对应的 iOS App.
/// 只监听 127.0.0.1, 并校验 Host 防止 DNS 重绑定
final class HubServer {
    static let port: UInt16 = 9523
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    /// 与 iOS 端 LayerLensAPIVersion 对应
    static let apiVersion = 1
    static let maxBodyLength = 1024 * 1024

    let queue = DispatchQueue(label: "com.layerlens.hub")
    let registry: TargetRegistry
    private let xcode = XcodeController()
    private let live = SimulatorLive()
    /// AppleScript 与 simctl 较慢, 不占用服务队列
    private let workQueue = DispatchQueue(label: "com.layerlens.hub.work", attributes: .concurrent)
    private let webRoot: URL
    private var listener: NWListener?
    private let allowedHosts: Set<String> = ["127.0.0.1:\(HubServer.port)", "localhost:\(HubServer.port)"]

    init(registry: TargetRegistry) {
        self.registry = registry
        webRoot = Self.locateWebRoot()
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(Self.port)/")!
    }

    func start(completion: @escaping (Error?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            completion(error)
            return
        }
        var reported = false
        listener.stateUpdateHandler = { state in
            guard !reported else { return }
            switch state {
            case .ready:
                reported = true
                DispatchQueue.main.async { completion(nil) }
            case .failed(let error), .waiting(let error):
                reported = true
                listener.cancel()
                DispatchQueue.main.async { completion(error) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            HubConnection(connection: connection, server: self).start()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Routing

    /// 头部读完后调用; leftover 为已读到的请求体部分
    func handle(_ head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        guard let host = head.header("Host"), allowedHosts.contains(host.lowercased()) else {
            connection.respond(.error(403, "Forbidden host"))
            return
        }
        // 跨站页面可以发起请求但带有其 Origin, 拒绝以防被借用修改 App 或操作 Xcode
        if let origin = head.header("Origin"), !allowedHosts.contains(where: { origin.lowercased() == "http://" + $0 }) {
            connection.respond(.error(403, "Forbidden origin"))
            return
        }
        if head.path.hasPrefix("/t/") {
            proxyToApp(head, leftover: leftover, connection: connection)
            return
        }
        if head.path.hasPrefix("/sim/") {
            handleSimulator(head, leftover: leftover, connection: connection)
            return
        }
        if head.method == "POST" {
            handlePost(head, body: leftover, connection: connection)
            return
        }
        guard head.method == "GET" else {
            connection.respond(.error(405, "Method Not Allowed"))
            return
        }
        switch head.path {
        case "/":
            connection.respond(staticFile("index.html"))
        case "/api/targets":
            var hubInfo: [String: Any] = ["version": Self.version, "apiVersion": Self.apiVersion, "live": SimulatorLive.isAvailable]
            hubInfo["liveError"] = SimBridge.loadError
            registry.snapshot { devices, simulators in
                connection.respond(.json(["hub": hubInfo, "devices": devices, "simulators": simulators]))
            }
        case "/api/hub/run-status":
            let sourceFile = registry.sourceFile(bundleId: head.query["app"] ?? "")
            workQueue.async { [self] in
                switch xcode.status(sourceFile: sourceFile) {
                case .success(let status):
                    connection.respond(.json(["status": status.status, "detail": status.detail]))
                case .failure(let failure):
                    connection.respond(.json(["error": failure.code.rawValue, "message": failure.message], status: 400))
                }
            }
        default:
            if head.path.hasPrefix("/assets/") {
                // 只取文件名, 防止路径穿越
                connection.respond(staticFile((head.path as NSString).lastPathComponent))
            } else {
                connection.respond(.error(404, "Not Found"))
            }
        }
    }

    /// /t/<设备 ID>/<Bundle ID>/<iOS 端路径>
    private func proxyToApp(_ head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        let parts = head.target.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let deviceId = String(parts[2]).removingPercentEncoding,
              let bundleId = String(parts[3].split(separator: "/", maxSplits: 1).first ?? "").removingPercentEncoding else {
            connection.respond(.error(400, "Invalid target"))
            return
        }
        let rest = parts[3].drop { $0 != "/" }
        let upstreamTarget = rest.isEmpty ? "/" : String(rest)
        // 事件流断开表示 App 停止, 目标不可用时直接断开连接让浏览器按网络错误重连, 返回错误码会使其停止重连
        let isEventStream = upstreamTarget.hasPrefix("/api/events")
        let unavailable = {
            isEventStream ? connection.abort() : connection.respond(.error(503, "App is not running"))
        }
        // 挂起期间监听可能被系统回收, App 回到前台后换端口重新监听, 记录过期前连不上旧端口:
        // 连接失败时重新扫描, 端口变了就再试一次
        func forward(rescan: Bool, previous: TargetEndpoint?) {
            registry.resolve(deviceId: deviceId, bundleId: bundleId, rescan: rescan) { [weak self] endpoint in
                guard let self else { return }
                self.queue.async {
                    guard let endpoint, endpoint != previous else {
                        unavailable()
                        return
                    }
                    let retry = { rescan ? unavailable() : forward(rescan: true, previous: endpoint) }
                    switch endpoint {
                    case .local(let port):
                        var data = head.forwarded(target: upstreamTarget, host: "127.0.0.1:\(port)", keepConnection: false)
                        data.append(leftover)
                        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                        connection.tunnel(to: upstream, initialData: data, onFailure: retry)
                    case .usb(let usbDeviceId, let port):
                        var data = head.forwarded(target: upstreamTarget, host: "127.0.0.1:\(port)", keepConnection: false)
                        data.append(leftover)
                        Usbmux.connect(deviceId: usbDeviceId, port: port, queue: self.queue) { upstream, _ in
                            guard let upstream else {
                                retry()
                                return
                            }
                            connection.tunnel(toReady: upstream, initialData: data)
                        }
                    }
                }
            }
        }
        forward(rescan: false, previous: nil)
    }

    private func handlePost(_ head: HTTPRequestHead, body: Data, connection: HubConnection) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch head.path {
        case "/api/hub/run":
            let sourceFile = registry.sourceFile(bundleId: json["app"] as? String ?? "")
            workQueue.async { [self] in
                switch xcode.run(sourceFile: sourceFile, deviceId: json["device"] as? String ?? "") {
                case .success(let switched):
                    connection.respond(.json(["ok": true, "switched": switched]))
                case .failure(let failure):
                    connection.respond(.json(["error": failure.code.rawValue, "message": failure.message], status: 400))
                }
            }
        case "/api/hub/home":
            // 启动 SpringBoard 回到桌面, 没有上滑手势的动画过程
            guard let device = json["device"] as? String, UUID(uuidString: device) != nil else {
                connection.respond(.error(400, "Invalid device"))
                return
            }
            workQueue.async {
                let ok = TargetRegistry.run("/usr/bin/xcrun", ["simctl", "launch", device, "com.apple.springboard"]) != nil
                connection.respond(ok ? .json(["ok": true]) : .error(500, "simctl launch failed"))
            }
        case "/api/hub/simulator":
            // 启动(同时打开 Simulator 窗口)或关闭模拟器, 完成后立即刷新列表, 网页下次轮询即可看到
            guard let device = json["device"] as? String, UUID(uuidString: device) != nil,
                  let action = json["action"] as? String, action == "boot" || action == "shutdown" else {
                connection.respond(.error(400, "Invalid request"))
                return
            }
            workQueue.async { [self] in
                let ok = TargetRegistry.run("/usr/bin/xcrun", ["simctl", action, device]) != nil
                if ok && action == "boot" {
                    _ = TargetRegistry.run("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device])
                }
                LiveLog.write("simulator \(action) \(device): \(ok)")
                registry.refreshSimulatorsNow {
                    connection.respond(ok ? .json(["ok": true]) : .error(500, "simctl \(action) failed"))
                }
            }
        case "/api/hub/logs":
            // 在访达中定位日志文件, 排查问题时方便拿到
            workQueue.async {
                let ok = LiveLog.reveal()
                connection.respond(ok ? .json(["ok": true]) : .error(500, "Open failed"))
            }
        case "/api/hub/activate":
            // 把在后台的 App 切到前台; 已在运行时只激活, 不重启
            guard let device = json["device"] as? String, let app = json["app"] as? String, !device.isEmpty, !app.isEmpty else {
                connection.respond(.error(400, "Invalid target"))
                return
            }
            registry.deviceKind(deviceId: device) { [self] kind in
                guard let kind else {
                    connection.respond(.error(404, "Device not found"))
                    return
                }
                workQueue.async { [self] in
                    let arguments = kind == .simulator
                        ? ["simctl", "launch", device, app]
                        : ["devicectl", "device", "process", "launch", "--device", device, app]
                    guard TargetRegistry.run("/usr/bin/xcrun", arguments) != nil else {
                        connection.respond(.error(500, "Launch failed"))
                        return
                    }
                    // 等 App 在(可能换了的)端口上响应后再返回, 网页随后加载时不会连到旧端口
                    registry.waitForApp(deviceId: device, bundleId: app, timeout: 5) { ready in
                        connection.respond(.json(["ok": true, "ready": ready]))
                    }
                }
            }
        default:
            connection.respond(.error(404, "Not Found"))
        }
    }

    /// /sim/<UDID>/stream 为内置实时画面的 WebSocket, /sim/<UDID>/info 返回屏幕尺寸
    private func handleSimulator(_ head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        let parts = head.path.split(separator: "/").map(String.init)
        // heal 会重启模拟器进程, 只接受 POST
        guard parts.count == 3, SimulatorLive.isAvailable, head.method == (parts[2] == "heal" ? "POST" : "GET") else {
            connection.respond(.error(404, "Not Found"))
            return
        }
        let udid = parts[1]
        switch parts[2] {
        case "heal":
            workQueue.async { [self] in
                let ok = live.healTouch(udid: udid)
                queue.async {
                    connection.respond(ok ? .json(["ok": true]) : .error(500, "Heal failed"))
                }
            }
        case "stream":
            live.accept(udid: udid, head: head, leftover: leftover, connection: connection)
        case "info":
            workQueue.async { [self] in
                let info = live.info(udid: udid)
                queue.async {
                    connection.respond(info.map { .json($0) } ?? .error(404, "Simulator not available"))
                }
            }
        default:
            connection.respond(.error(404, "Not Found"))
        }
    }

    // MARK: - Static files

    private func staticFile(_ name: String) -> HTTPResponse {
        let types = ["html": "text/html; charset=utf-8", "js": "application/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "png": "image/png", "json": "application/json; charset=utf-8"]
        guard let data = try? Data(contentsOf: webRoot.appendingPathComponent(name)) else {
            return .error(404, "Not Found")
        }
        let type = types[(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
        return HTTPResponse(status: 200, contentType: type, body: data, headers: ["Cache-Control": "no-cache"])
    }

    /// Debug 编译直接读取仓库中的 Web 目录, 修改网页后刷新即可生效; 否则读取打包的资源
    private static func locateWebRoot() -> URL {
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Web").standardizedFileURL
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("index.html").path) {
            return source
        }
        #endif
        return Bundle.main.resourceURL!.appendingPathComponent("Web")
    }
}

/// 单个浏览器连接: 读取请求头, 交给 HubServer 路由, 本地响应后关闭或转为透传隧道
final class HubConnection {
    private let connection: NWConnection
    private unowned let server: HubServer
    private var buffer = Data()
    private var tunnel: ProxyTunnel?

    init(connection: NWConnection, server: HubServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: server.queue)
        receiveHead()
    }

    private func receiveHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
            }
            if let parsed = HTTPRequestHead.parse(buffer) {
                guard let head = parsed.head else {
                    respond(.error(400, "Bad Request"))
                    return
                }
                let leftover = buffer.subdata(in: (buffer.startIndex + parsed.length)..<buffer.endIndex)
                buffer = Data()
                route(head, leftover: leftover)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                receiveHead()
            }
        }
    }

    /// 转发请求带着已读到的请求体透传; 本地处理的请求需先读完请求体
    private func route(_ head: HTTPRequestHead, leftover: Data) {
        if head.path.hasPrefix("/t/") || head.path.hasPrefix("/sim/") || head.contentLength <= leftover.count {
            server.handle(head, leftover: leftover, connection: self)
            return
        }
        guard head.contentLength <= HubServer.maxBodyLength else {
            respond(.error(413, "Payload Too Large"))
            return
        }
        receiveBody(head, body: leftover)
    }

    private func receiveBody(_ head: HTTPRequestHead, body: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var body = body
            if let data {
                body.append(data)
            }
            if body.count >= head.contentLength {
                server.handle(head, leftover: body, connection: self)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                receiveBody(head, body: body)
            }
        }
    }

    func respond(_ response: HTTPResponse) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            connection.cancel()
        })
    }

    /// 交出底层连接(如升级为 WebSocket), 之后由接收方负责收发和关闭
    func detach() -> NWConnection {
        connection.stateUpdateHandler = nil
        return connection
    }

    /// 不响应直接断开
    func abort() {
        connection.cancel()
    }

    func tunnel(to upstream: NWConnection, initialData: Data, onFailure: @escaping () -> Void) {
        let tunnel = ProxyTunnel(client: connection, upstream: upstream, initialData: initialData, queue: server.queue) { [self] in
            self.tunnel = nil
            onFailure()
        }
        self.tunnel = tunnel
        tunnel.start()
    }

    /// 上游已连接(如经 usbmuxd), 直接透传
    func tunnel(toReady upstream: NWConnection, initialData: Data) {
        let tunnel = ProxyTunnel(client: connection, upstream: upstream, initialData: initialData, queue: server.queue) {}
        self.tunnel = tunnel
        tunnel.run()
    }
}
