//
//  MCPHTTPService.swift
//  LayerLens
//

import Foundation

/// App 内置的只读 MCP endpoint。Streamable HTTP 的普通请求使用 JSON 响应；
/// 当前工具不产生服务端通知，因此 GET/SSE 明确返回 405。
final class MCPHTTPService {
    /// 由新到旧。客户端请求的版本在列表中就原样返回，否则返回第一个。
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let store: MCPContextStore
    private let registry: TargetRegistry
    private let git: GitController
    private let appLogs: AppLogRecorder
    private let network: NetworkRecorder
    private let workQueue: DispatchQueue
    private let captureCanvas: (MCPWindowContext, @escaping (Data?) -> Void) -> Void

    init(store: MCPContextStore, registry: TargetRegistry, git: GitController,
         appLogs: AppLogRecorder, network: NetworkRecorder, workQueue: DispatchQueue,
         captureCanvas: @escaping (MCPWindowContext, @escaping (Data?) -> Void) -> Void) {
        self.captureCanvas = captureCanvas
        self.store = store
        self.registry = registry
        self.git = git
        self.appLogs = appLogs
        self.network = network
        self.workQueue = workQueue
    }

    static func negotiatedVersion(_ requested: String?) -> String {
        guard let requested, supportedProtocolVersions.contains(requested) else { return supportedProtocolVersions[0] }
        return requested
    }

    func handle(_ head: HTTPRequestHead, body: Data, connection: HubConnection) {
        guard head.method == "POST" else {
            connection.respond(.error(405, head.method == "GET" ? "MCP GET stream is not used" : "Method Not Allowed"))
            return
        }
        // initialize 之后客户端会带上协商结果；不认识的版本按规范返回 400。
        if let version = head.header("MCP-Protocol-Version"), !Self.supportedProtocolVersions.contains(version) {
            respond(Self.rpcError(id: NSNull(), code: -32600, message: "Unsupported MCP-Protocol-Version: \(version)"),
                    status: 400, connection: connection)
            return
        }
        guard let payload = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            respond(Self.rpcError(id: NSNull(), code: -32700, message: "Parse error"), status: 400, connection: connection)
            return
        }
        if let batch = payload as? [Any] {
            // 2025-03-26 允许 JSON-RPC 批量请求；更新的版本不会发送数组，保留兼容即可。
            guard !batch.isEmpty else {
                respond(Self.rpcError(id: NSNull(), code: -32600, message: "Empty batch"), status: 400, connection: connection)
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var responses = [[String: Any]?](repeating: nil, count: batch.count)
            for (index, item) in batch.enumerated() {
                group.enter()
                process(item) { response in
                    lock.lock()
                    responses[index] = response
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: workQueue) { [self] in
                let values = responses.compactMap { $0 }
                if values.isEmpty { accepted(connection) } else { respondJSON(values, status: 200, connection: connection) }
            }
            return
        }
        process(payload) { [self] response in
            if let response { respond(response, status: 200, connection: connection) } else { accepted(connection) }
        }
    }

    /// 处理单条 JSON-RPC 消息。通知和客户端发来的响应没有返回值，回调 nil。
    private func process(_ payload: Any, completion: @escaping ([String: Any]?) -> Void) {
        guard let request = payload as? [String: Any] else {
            completion(Self.rpcError(id: NSNull(), code: -32600, message: "Invalid Request"))
            return
        }
        guard let method = request["method"] as? String else {
            // 客户端对服务端请求的响应；本服务不发请求，直接接受。
            completion(request["result"] != nil || request["error"] != nil ? nil
                       : Self.rpcError(id: request["id"] ?? NSNull(), code: -32600, message: "Invalid Request"))
            return
        }
        guard let id = request["id"], !(id is NSNull) else {
            // notifications/initialized 等通知没有响应体；客户端据此继续发送 tools/list。
            completion(nil)
            return
        }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            completion(Self.rpcResult(id: id, [
                "protocolVersion": Self.negotiatedVersion(params["protocolVersion"] as? String),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "LayerLens", "title": "LayerLens", "version": HubServer.version],
                "instructions": Self.instructions,
            ]))
        case "ping":
            completion(Self.rpcResult(id: id, [:]))
        case "tools/list":
            completion(Self.rpcResult(id: id, ["tools": Self.toolDefinitions]))
        case "tools/call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                completion(Self.rpcError(id: id, code: -32602, message: "Invalid params: name is required"))
                return
            }
            guard Self.toolNames.contains(name) else {
                completion(Self.rpcError(id: id, code: -32602, message: "Unknown tool: \(name)"))
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            callTool(name, arguments: arguments) { result in
                completion(Self.rpcResult(id: id, result))
            }
        default:
            completion(Self.rpcError(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Tools

    private func callTool(_ name: String, arguments: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        switch name {
        case "get_context":
            if let unknown = arguments.keys.sorted().first {
                completion(Self.toolError("invalid_arguments: get_context takes no arguments (got \(unknown))."))
                return
            }
            guard let context = store.latest(), context.hasTarget else {
                completion(Self.toolError(Self.noTarget))
                return
            }
            workQueue.async { [self] in
                let sourceFile = registry.sourceFile(deviceId: context.deviceId, bundleId: context.bundleId)
                let sourceRoot: String?
                if XcodeSourcePath.isLocalLayerLensPackage(sourceFile) {
                    let derivedData = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
                    let project = XcodeSourcePath.savedLocalHostProject(deviceId: context.deviceId, bundleId: context.bundleId, sourceFile: sourceFile) ??
                        XcodeSourcePath.localPackageHostProject(bundleId: context.bundleId, derivedData: derivedData)
                    let host = project.map { ($0 as NSString).deletingLastPathComponent }
                    sourceRoot = host.flatMap { git.repository(sourceFile: $0 + "/LayerLensHost") ?? $0 }
                } else {
                    sourceRoot = git.repository(sourceFile: sourceFile) ?? XcodeSourcePath.sourceDirectory(for: sourceFile)
                }
                guard let snapshot = store.snapshot(context: context, sourceRoot: sourceRoot) else {
                    completion(Self.toolError(Self.staleSnapshot))
                    return
                }
                activity(snapshot.context) { activity in
                    var value = snapshot.json()
                    if !activity.isEmpty { value["activity"] = activity }
                    completion(Self.toolValue(value))
                }
            }
        case "get_canvas_screenshot":
            do {
                let snapshot = try pinned(MCPRecords.Arguments(arguments, known: ["snapshotId"]))
                DispatchQueue.main.async { [self] in
                    captureCanvas(snapshot.context) { data in
                        guard self.store.isCanvasCurrent(snapshot) else {
                            completion(Self.toolError("canvas_changed: the target, mode or annotation changed; call get_context again."))
                            return
                        }
                        guard let data else {
                            completion(Self.toolError("canvas_unavailable: the pinned LayerLens page is unavailable or could not capture its canvas."))
                            return
                        }
                        completion(["content": [["type": "image", "mimeType": "image/png",
                                                 "data": data.base64EncodedString()]], "isError": false])
                    }
                }
            } catch {
                completion(Self.toolError(Self.message(error)))
            }
        case "search_logs":
            do {
                let args = try MCPRecords.Arguments(arguments, known: ["snapshotId", "query", "cursor", "limit"])
                let snapshot = try pinned(args)
                let query = try args.query()
                let cursor = try args.int("cursor", default: 0, range: 0...Int.max)
                let limit = try args.int("limit", default: 50, range: 1...MCPRecords.logLimitMax)
                let context = snapshot.context
                appLogs.mcpEntries(deviceId: context.deviceId, bundleId: context.bundleId, instanceId: context.instanceId) { [self] entries in
                    guard store.isCurrent(snapshot) else { return completion(Self.toolError(Self.staleSnapshot)) }
                    completion(Self.toolValue(MCPRecords.logs(entries, query: query, after: cursor, limit: limit)))
                }
            } catch {
                completion(Self.toolError(Self.message(error)))
            }
        case "list_requests":
            do {
                let args = try MCPRecords.Arguments(arguments, known: ["snapshotId", "query", "failedOnly", "inBody", "cursor", "limit"])
                let snapshot = try pinned(args)
                let query = try args.query()
                let failedOnly = try args.bool("failedOnly", default: false)
                let inBody = try args.bool("inBody", default: false)
                if inBody && query == nil { throw MCPRecords.Failure(message: "inBody needs a query.") }
                let cursor = UInt64(try args.int("cursor", default: 0, range: 0...Int.max))
                let limit = try args.int("limit", default: 20, range: 1...MCPRecords.requestLimitMax)
                let context = snapshot.context
                network.mcpSession(deviceId: context.deviceId, bundleId: context.bundleId, instanceId: context.instanceId) { [self] session in
                    workQueue.async { [self] in
                        guard store.isCurrent(snapshot) else { return completion(Self.toolError(Self.staleSnapshot)) }
                        if session.records.isEmpty && !session.capture {
                            return completion(Self.toolError(Self.captureOff))
                        }
                        // 响应内容只扫描最新的一批, 避免一次读入整个会话
                        let scanned = inBody ? Set(session.records.suffix(Self.bodyScanMax).map(\.id)) : []
                        var value = MCPRecords.requests(session.records, after: cursor, limit: limit) { id, record in
                            if failedOnly && !MCPRecords.failed(record) { return false }
                            if MCPRecords.matches(query, MCPRecords.searchText(record)) { return true }
                            guard scanned.contains(id), let data = try? Data(contentsOf: session.bodyURL(id, "res")) else { return false }
                            return MCPRecords.matches(query, String(decoding: data, as: UTF8.self))
                        }
                        if !session.capture { value["capture"] = "off" }
                        if inBody && session.records.count > Self.bodyScanMax { value["bodyScan"] = "newest \(Self.bodyScanMax) requests" }
                        completion(Self.toolValue(value))
                    }
                }
            } catch {
                completion(Self.toolError(Self.message(error)))
            }
        case "get_request":
            do {
                let args = try MCPRecords.Arguments(arguments, known: ["snapshotId", "id", "part", "path", "maxChars"])
                let snapshot = try pinned(args)
                let id = UInt64(try args.int("id", default: 0, range: 1...Int.max))
                let part = try args.choice("part", ["summary", "request", "response"], default: "response")
                let path = try args.string("path")
                let maxChars = try args.int("maxChars", default: MCPRecords.bodyCharsDefault,
                                            range: 200...MCPRecords.bodyCharsMax)
                if part == "summary" && !path.isEmpty { throw MCPRecords.Failure(message: "path applies to request or response.") }
                let context = snapshot.context
                network.mcpSession(deviceId: context.deviceId, bundleId: context.bundleId, instanceId: context.instanceId) { [self] session in
                    workQueue.async { [self] in
                        guard store.isCurrent(snapshot) else { return completion(Self.toolError(Self.staleSnapshot)) }
                        guard let record = session.records.first(where: { $0.id == id })?.record else {
                            return completion(Self.toolError("request_not_found: #\(id) is not in this launch; call list_requests."))
                        }
                        if part == "summary" { return completion(Self.toolValue(MCPRecords.summary(id: id, record: record))) }
                        let side = part == "request" ? "req" : "res"
                        guard let data = try? Data(contentsOf: session.bodyURL(id, side)) else {
                            return completion(Self.toolError(MCPRecords.bodyUnavailable(record, side: side)))
                        }
                        let headers = record[side == "req" ? "requestHeaders" : "responseHeaders"] as? [String: String] ?? [:]
                        let mime = headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
                            ?? (side == "res" ? record["mime"] as? String ?? "" : "")
                        switch MCPRecords.body(data, mime: mime, path: path, maxChars: maxChars) {
                        case .success(var value):
                            value["id"] = id
                            if !mime.isEmpty { value["mime"] = MCPRecords.shortMime(mime) }
                            completion(Self.toolValue(value))
                        case .failure(let error):
                            completion(Self.toolError("invalid_arguments: \(error.message)"))
                        }
                    }
                }
            } catch {
                completion(Self.toolError(Self.message(error)))
            }
        default:
            completion(Self.toolError("Unknown tool: \(name)"))
        }
    }

    /// 由 snapshotId 取回固定的窗口和 App; 失效时抛出可直接返回给 Agent 的错误。
    private func pinned(_ args: MCPRecords.Arguments) throws -> MCPContextSnapshot {
        let id = try args.snapshotId()
        guard let snapshot = store.snapshot(id: id) else { throw ToolError("snapshot_not_found: call get_context again.") }
        guard store.isCurrent(snapshot) else { throw ToolError(Self.staleSnapshot) }
        guard snapshot.context.hasTarget else { throw ToolError(Self.noTarget) }
        return snapshot
    }

    /// get_context 附带的计数, 让 Agent 判断是否值得查日志或抓包。为 0 的项省略。
    private func activity(_ context: MCPWindowContext, completion: @escaping ([String: Any]) -> Void) {
        let group = DispatchGroup()
        var logs = 0
        var session: NetworkRecorder.MCPSession?
        group.enter()
        appLogs.mcpEntries(deviceId: context.deviceId, bundleId: context.bundleId, instanceId: context.instanceId) { entries in
            logs = entries.count
            group.leave()
        }
        group.enter()
        network.mcpSession(deviceId: context.deviceId, bundleId: context.bundleId, instanceId: context.instanceId) { value in
            session = value
            group.leave()
        }
        group.notify(queue: workQueue) {
            var value: [String: Any] = [:]
            if logs > 0 { value["logs"] = logs }
            let records = session?.records ?? []
            if !records.isEmpty { value["requests"] = records.count }
            let failed = records.filter { MCPRecords.failed($0.record) }.count
            if failed > 0 { value["failedRequests"] = failed }
            if session?.capture == false { value["networkCapture"] = "off" }
            completion(value)
        }
    }

    private struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? ToolError { return error.message }
        if let error = error as? MCPRecords.Failure { return "invalid_arguments: \(error.message)" }
        return error.localizedDescription
    }

    private static let staleSnapshot = "snapshot_stale: window or App changed, call get_context again."
    private static let noTarget = "no_app_selected: select an integrated App in a LayerLens window, then call get_context again."
    private static let captureOff = "network_capture_off: no requests recorded; ask the user to turn on capture in the LayerLens Network panel and reproduce."
    /// inBody 只读取最新这么多条请求的响应内容。
    private static let bodyScanMax = 300

    // MARK: - JSON-RPC

    private static func rpcResult(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// 只返回一份紧凑 JSON 文本。不声明 outputSchema，也就不必附带重复的 structuredContent。
    static func toolValue(_ value: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": jsonString(value)]], "isError": false]
    }

    static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func accepted(_ connection: HubConnection) {
        connection.respond(HTTPResponse(status: 202, contentType: "application/json", body: Data()))
    }

    private func respond(_ value: [String: Any], status: Int, connection: HubConnection) {
        respondJSON(value, status: status, connection: connection)
    }

    private func respondJSON(_ value: Any, status: Int, connection: HubConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else {
            connection.respond(.error(500, "JSON serialization failed"))
            return
        }
        connection.respond(HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data,
                                        headers: ["Cache-Control": "no-store"]))
    }

    private static func jsonString(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Definitions

    static let instructions = """
    For questions about the UI currently shown in LayerLens, call get_context first. \
    selected.element reads "ivar (Class) \"text\" · id=identifier"; search sourceRoot for those parts, selected.owner and selected.vc to locate code. \
    Use visible selected or annotated hints to search sourceRoot; if hints are insufficient, capture the pinned canvas. \
    For runtime behavior, get_context.activity counts this launch's logs and requests: use search_logs with a query, \
    list_requests (failedOnly first), then get_request for one request; pass back cursor to read only new entries. \
    Use get_canvas_screenshot with snapshotId only when the user asks to see the canvas or the answer depends on its visible appearance. Do not request the full hierarchy. On snapshot_stale or no_app_selected, ask the user to select the App or call get_context again.
    """

    private static let readOnly: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]

    private static let toolNames: Set<String> = ["get_context", "get_canvas_screenshot", "search_logs", "list_requests", "get_request"]

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "get_context",
            "title": "Get LayerLens context",
            "description": "Return the App, source root, selected node and log/request counts of the last-focused LayerLens window. "
                + "Pins a snapshotId for the other tools.",
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ],
            "annotations": readOnly,
        ],
        [
            "name": "get_canvas_screenshot",
            "title": "Get LayerLens canvas screenshot",
            "description": "Return one PNG of the canvas in the LayerLens page pinned by get_context, "
                + "including the selection as rendered. Use only for screenshot requests or questions about appearance.",
            "inputSchema": [
                "type": "object",
                "properties": ["snapshotId": snapshotIdProperty],
                "required": ["snapshotId"],
                "additionalProperties": false,
            ],
            "annotations": readOnly,
        ],
        [
            "name": "search_logs",
            "title": "Search LayerLens logs",
            "description": "Search the App's console logs of the current launch. One line per entry, newest last, repeats merged as ×N. "
                + "Pass the returned cursor to get only newer lines.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "snapshotId": snapshotIdProperty,
                    "query": queryProperty,
                    "cursor": ["type": "integer", "minimum": 0, "description": "cursor from a previous call; only newer entries are returned."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": MCPRecords.logLimitMax, "default": 50],
                ],
                "required": ["snapshotId"],
                "additionalProperties": false,
            ],
            "annotations": readOnly,
        ],
        [
            "name": "list_requests",
            "title": "List LayerLens requests",
            "description": "List network requests captured in the current launch, one line each: #id method status duration path size type. "
                + "Use get_request with an id for headers or body.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "snapshotId": snapshotIdProperty,
                    "query": ["type": "string", "description": "Matches method, status, URL and error. Keywords separated by |; a leading \\ makes it a regular expression."],
                    "failedOnly": ["type": "boolean", "default": false, "description": "Only status ≥ 400 or failed requests."],
                    "inBody": ["type": "boolean", "default": false, "description": "Also match response bodies of the newest \(bodyScanMax) requests."],
                    "cursor": ["type": "integer", "minimum": 0, "description": "cursor from a previous call; only newer requests are returned."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": MCPRecords.requestLimitMax, "default": 20],
                ],
                "required": ["snapshotId"],
                "additionalProperties": false,
            ],
            "annotations": readOnly,
        ],
        [
            "name": "get_request",
            "title": "Get LayerLens request",
            "description": "Read one captured request. summary gives URL, status, timing and redacted headers; request/response give the body. "
                + "JSON bodies are pruned (arrays keep 2 items); pass path such as data.items[0] to read a subtree.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "snapshotId": snapshotIdProperty,
                    "id": ["type": "integer", "minimum": 1, "description": "Request id from list_requests, without #."],
                    "part": ["type": "string", "enum": ["summary", "request", "response"], "default": "response"],
                    "path": ["type": "string", "description": "JSON path inside the body, e.g. data.items[0].title."],
                    "maxChars": ["type": "integer", "minimum": 200, "maximum": MCPRecords.bodyCharsMax, "default": MCPRecords.bodyCharsDefault],
                ],
                "required": ["snapshotId", "id"],
                "additionalProperties": false,
            ],
            "annotations": readOnly,
        ],
    ]

    private static let snapshotIdProperty: [String: Any] = ["type": "string", "description": "snapshotId returned by get_context."]
    private static let queryProperty: [String: Any] = [
        "type": "string",
        "description": "Keywords separated by |, case-insensitive; a leading \\ makes it a regular expression. Omit for the newest entries.",
    ]
}

struct MCPFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
