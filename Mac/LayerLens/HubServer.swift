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
    let baguette: BaguetteManager
    private let xcode = XcodeController()
    /// AppleScript 与 simctl 较慢, 不占用服务队列
    private let workQueue = DispatchQueue(label: "com.layerlens.hub.work", attributes: .concurrent)
    private let webRoot: URL
    private var listener: NWListener?
    private let allowedHosts: Set<String> = ["127.0.0.1:\(HubServer.port)", "localhost:\(HubServer.port)"]

    init(registry: TargetRegistry, baguette: BaguetteManager) {
        self.registry = registry
        self.baguette = baguette
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
        if head.path.hasPrefix("/baguette/") {
            proxyToBaguette(head, leftover: leftover, connection: connection)
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
            let baguetteInfo: [String: Any] = ["installed": baguette.isInstalled, "running": baguette.isRunning]
            registry.snapshot { devices in
                connection.respond(.json(["hub": ["version": Self.version, "apiVersion": Self.apiVersion, "baguette": baguetteInfo], "devices": devices]))
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
        registry.resolve(deviceId: deviceId, bundleId: bundleId) { [weak self] endpoint in
            guard let self else { return }
            self.queue.async {
                guard let endpoint else {
                    isEventStream ? connection.abort() : connection.respond(.error(503, "App is not running"))
                    return
                }
                switch endpoint {
                case .local(let port):
                    var data = head.forwarded(target: upstreamTarget, host: "127.0.0.1:\(port)", keepConnection: false)
                    data.append(leftover)
                    let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                    connection.tunnel(to: upstream, initialData: data) {
                        isEventStream ? connection.abort() : connection.respond(.error(503, "App is not running"))
                    }
                case .usb(let usbDeviceId, let port):
                    var data = head.forwarded(target: upstreamTarget, host: "127.0.0.1:\(port)", keepConnection: false)
                    data.append(leftover)
                    Usbmux.connect(deviceId: usbDeviceId, port: port, queue: self.queue) { upstream in
                        guard let upstream else {
                            isEventStream ? connection.abort() : connection.respond(.error(503, "App is not running"))
                            return
                        }
                        connection.tunnel(toReady: upstream, initialData: data)
                    }
                }
            }
        }
    }

    private func handlePost(_ head: HTTPRequestHead, body: Data, connection: HubConnection) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch head.path {
        case "/api/hub/run":
            let sourceFile = registry.sourceFile(bundleId: json["app"] as? String ?? "")
            workQueue.async { [self] in
                switch xcode.run(sourceFile: sourceFile) {
                case .success:
                    connection.respond(.json(["ok": true]))
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
        default:
            connection.respond(.error(404, "Not Found"))
        }
    }

    /// /baguette/<路径> 转发到 LayerLens 启动的 baguette, 只对 WebSocket 保留 Upgrade 头.
    /// 普通请求必须关闭连接: 隧道是原样转发, 浏览器复用这条 keep-alive 连接时后续请求(如 /)会直接发给 baguette
    private func proxyToBaguette(_ head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        let upstreamTarget = String(head.target.dropFirst("/baguette".count))
        let isUpgrade = head.header("upgrade") != nil
        var data = head.forwarded(target: upstreamTarget, host: "127.0.0.1:\(BaguetteManager.port)", keepConnection: isUpgrade)
        data.append(leftover)
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: BaguetteManager.port)!, using: .tcp)
        connection.tunnel(to: upstream, initialData: data) {
            connection.respond(.error(503, "baguette is not running"))
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
        if head.path.hasPrefix("/t/") || head.path.hasPrefix("/baguette/") || head.contentLength <= leftover.count {
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
