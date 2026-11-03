// Shared local-only test app, isolated from user devices and user data.
import Foundation
import Network

enum TargetEndpoint: Equatable {
    case local(port: UInt16); case usb(deviceId: Int, port: UInt16)
    var port: UInt16 { switch self { case .local(let value), .usb(_, let value): return value } }
}
struct AppRecord {
    let deviceId: String; let bundleId: String; let endpoint: TargetEndpoint; let info: [String: Any]
    var suspended = false; var responding = true
}
enum HubServer { static let version = "test" }
enum TargetRegistry { static func run(_ path: String, _ args: [String]) -> Data? { nil } }
final class HubConnection {
    private var connection: NWConnection?
    private let onResponse: ((HTTPResponse) -> Void)?
    init(connection: NWConnection? = nil, onResponse: ((HTTPResponse) -> Void)? = nil) { self.connection = connection; self.onResponse = onResponse }
    func respond(_ response: HTTPResponse) { onResponse?(response) }
    func detach() -> NWConnection { connection ?? NWConnection(host: "127.0.0.1", port: 9, using: .tcp) }
}

final class AppServer {
    let queue = DispatchQueue(label: "test.app.server")
    let listener: NWListener
    let ready = DispatchSemaphore(value: 0)
    var connections: [NWConnection] = []
    var logSeq = 0
    let instance = UUID().uuidString
    var mode = "hold"
    var releases = 0
    var released: [UInt64] = []
    var releaseFailures = 0
    var networkIDs: [UInt64] = [1]
    var networkSequences: [UInt64: UInt64] = [:]
    var networkURLs: [UInt64: String] = [:]
    var networkTargets: [UInt64] = []
    var interruptFirstReplayAfter: Int?
    var detailRequests: [UInt64] = []
    var failedDetailIDs: Set<UInt64> = []
    var failedBodyIDs: Set<UInt64> = []
    var captureRequests: [Bool] = []
    var clearRequests = 0
    var logTargets: [String] = []
    var bodyRequests = 0
    var bodyCloses = 0
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
        assert(ready.wait(timeout: .now() + 5) == .success)
    }
    func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] bytes, _, end, error in
            var data = data; data.append(bytes ?? Data())
            guard let parsed = HTTPRequestHead.parse(data), let head = parsed.head,
                  data.count >= parsed.length + head.contentLength else {
                if !end && error == nil { receive(connection, data: data) }; return
            }
            let request = String(decoding: data, as: UTF8.self)
            let id = UInt64(head.query["id"] ?? "") ?? 0
            if request.hasPrefix("GET /api/logs") {
                logSeq += 1
                logTargets.append(request.components(separatedBy: "\r\n")[0])
                let target = request.components(separatedBy: " ")[1]
                let since = Int(URLComponents(string: "http://localhost" + target)?.queryItems?.first(where: { $0.name == "since" })?.value ?? "0") ?? 0
                let entries: [[String: Any]] = (1...logSeq).filter { $0 > since }.map { ["s": $0, "t": Date().timeIntervalSince1970 * 1000, "m": "preserved-log-\($0)"] }
                let value: [String: Any] = ["instanceId": instance, "entries": mode == "logs-empty" ? [] : entries]
                stream(connection, event: "logs", value: value)
            } else if request.hasPrefix("GET /api/network?") {
                let since = UInt64(head.query["since"] ?? "") ?? 0
                networkTargets.append(since)
                var ids = networkIDs.filter { (networkSequences[$0] ?? $0) > since }
                let interrupted = networkTargets.count == 1 && interruptFirstReplayAfter != nil
                if interrupted { ids = Array(ids.prefix(interruptFirstReplayAfter!)) }
                let value: [String: Any] = ["instanceId": instance, "records": ids.map { ["id": $0, "s": networkSequences[$0] ?? $0, "url": networkURLs[$0] ?? "https://example.test/", "method": "GET", "state": mode == "pending" ? "pending" : "complete", "start": 1] }]
                if interrupted {
                    let json = try! JSONSerialization.data(withJSONObject: value)
                    let data = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nevent: network\ndata: ".utf8) + json + Data("\n\n".utf8)
                    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
                } else { stream(connection, event: "network", value: value) }
            } else if request.hasPrefix("GET /api/network/detail") {
                detailRequests.append(id)
                let body = Data("{\"id\":\(id),\"reqBody\":\"stored\",\"resBody\":\"none\"}".utf8)
                let status = mode == "detail500" || failedDetailIDs.contains(id) ? "500 Internal Server Error" : mode == "detail404" ? "404 Not Found" : "200 OK"
                let header = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
            } else if request.hasPrefix("GET /api/network/body") {
                bodyRequests += 1
                if mode == "hold" {
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n".utf8) + Data(repeating: 65, count: 65536), completion: .contentProcessed { _ in })
                    watch(connection, body: true)
                } else {
                    let status = mode == "body500" || failedBodyIDs.contains(id) ? "500 Internal Server Error" : mode == "body404" ? "404 Not Found" : "200 OK"
                    let length = mode == "truncated" ? 99 : 7
                    connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: \(length)\r\n\r\npayload".utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if request.hasPrefix("POST /api/network/clear") {
                clearRequests += 1
                connection.send(content: Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 2\r\n\r\n{}".utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if request.hasPrefix("POST /api/network/capture") {
                let json = (try? JSONSerialization.jsonObject(with: Data(data.dropFirst(parsed.length)))) as? [String: Any]
                captureRequests.append(json?["enabled"] as? Bool ?? false)
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if request.hasPrefix("POST /api/network/release") {
                releases += 1
                let failed = releaseFailures > 0
                if failed { releaseFailures -= 1 }
                else {
                    let json = (try? JSONSerialization.jsonObject(with: Data(data.dropFirst(parsed.length)))) as? [String: Any]
                    released += (json?["ids"] as? [NSNumber] ?? []).map(\.uint64Value)
                }
                let status = failed ? "500 Internal Server Error" : "200 OK"
                let body = failed ? "{}" : "{\"ok\":true}"
                connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func stream(_ connection: NWConnection, event: String, value: [String: Any]) {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nevent: \(event)\ndata: \(json)\n\n".utf8), completion: .contentProcessed { _ in })
        watch(connection, body: false)
    }
    func watch(_ connection: NWConnection, body: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [self] _, _, end, error in
            if end || error != nil { if body { bodyCloses += 1 }; connection.cancel() }
            else { watch(connection, body: body) }
        }
    }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }
}

