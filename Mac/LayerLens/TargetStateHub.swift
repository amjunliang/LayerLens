import Foundation
import Network

protocol TargetStateStream: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var lastReceive: Date { get }
    var onEvent: ((String, Data) -> Void)? { get set }
    var onClose: ((Int) -> Void)? { get set }
    func start(endpoint: TargetEndpoint, path: String)
    func cancel()
}
extension AppEventStream: TargetStateStream {}

/// Registry 队列上运行。每个设备 / App 的进程只订阅一次, 与网页窗口数无关。
final class TargetStateMonitor {
    private final class Entry {
        var app: AppRecord
        var stream: TargetStateStream?
        var connected = false
        var foreground: Bool?
        var unsupported = false
        init(_ app: AppRecord) { self.app = app }
    }
    private var entries: [String: Entry] = [:]
    private let makeStream: () -> TargetStateStream
    private let epoch = UUID().uuidString
    private var revision = 0
    private var previous = Data()
    var onChange: (([[String: Any]], [String: Any]) -> Void)?

    init(makeStream: @escaping () -> TargetStateStream) { self.makeStream = makeStream }
    private func key(_ app: AppRecord) -> String { app.deviceId + "|" + app.bundleId }
    private func sameProcess(_ a: AppRecord, _ b: AppRecord) -> Bool {
        a.endpoint == b.endpoint && a.info["instanceId"] as? String == b.info["instanceId"] as? String
    }

    func update(_ apps: [AppRecord]) {
        let present = Set(apps.map(key))
        for (key, entry) in entries where !present.contains(key) {
            entry.stream?.cancel()
            entries.removeValue(forKey: key)
        }
        for app in apps {
            let id = key(app)
            if let old = entries[id], !sameProcess(old.app, app) {
                old.stream?.cancel()
                entries.removeValue(forKey: id)
            }
            let entry = entries[id] ?? Entry(app)
            entries[id] = entry
            entry.app = app
            // 扫描用于发现和兜底; 已连上的实时通知不能被在途的旧扫描覆盖。
            if entry.foreground == nil || entry.unsupported { entry.foreground = app.info["foreground"] as? Bool }
            // 活跃 App 的握手长时间未完成时重试。状态接口没有周期心跳, 已连接后允许无限静默。
            if let stream = entry.stream, !entry.connected && app.responding && Date().timeIntervalSince(stream.lastReceive) > 40 {
                stream.cancel()
                entry.stream = nil
                entry.connected = false
            }
            if entry.stream == nil && !entry.unsupported && app.responding { connect(entry, id: id) }
        }
        publish()
    }

    private func connect(_ entry: Entry, id: String) {
        let stream = makeStream()
        entry.stream = stream
        let active = { [weak self, weak entry, weak stream] in
            guard let self, let entry, let stream else { return false }
            return self.entries[id] === entry && entry.stream === stream
        }
        stream.onOpen = { [weak self, weak entry] in
            guard active(), let entry else { return }
            entry.connected = true
            self?.publish()
        }
        stream.onEvent = { [weak self, weak entry] name, payload in
            guard active(), let entry, name == "state",
                  let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let number = json["foreground"] as? NSNumber,
                  number == 0 || number == 1 else { return }
            entry.foreground = number.boolValue
            entry.app.suspended = false
            self?.publish()
        }
        stream.onClose = { [weak self, weak entry] status in
            guard active(), let entry else { return }
            entry.connected = false
            entry.stream = nil
            // 404 等接口错误不反复重试; 新进程或新端口会建立新 Entry。
            entry.unsupported = status != 0
            self?.publish()
        }
        stream.start(endpoint: entry.app.endpoint, path: "/api/events")
    }

    private func publish() {
        let apps: [[String: Any]] = entries.sorted { $0.key < $1.key }.map { _, entry in
            var info = entry.app.info
            info["deviceId"] = entry.app.deviceId
            info["port"] = entry.app.endpoint.port
            info["connection"] = entry.app.endpoint.connectionType
            if let foreground = entry.foreground { info["foreground"] = foreground }
            info["suspended"] = entry.app.suspended
            // 旧 Pod 无 events 接口时沿用扫描的可达性。新接口以长连接为准。
            info["stateConnected"] = entry.connected || (entry.unsupported && entry.app.responding)
            return info
        }
        let count = entries.values.filter { $0.stream != nil }.count
        let content: [String: Any] = ["apps": apps, "upstreamCount": count]
        guard let encoded = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), encoded != previous else { return }
        previous = encoded
        revision += 1
        onChange?(apps, ["epoch": epoch, "revision": revision, "apps": apps, "upstreamCount": count])
    }

    func stop() {
        entries.values.forEach { $0.stream?.cancel() }
        entries.removeAll()
        publish()
    }
}

/// Hub 队列上运行。每个窗口一条原生 WebSocket, 慢窗口最多保留一份最新快照。
final class TargetStateBroadcaster {
    private final class Viewer {
        let socket: WebSocketConnection
        var sending = false
        var pending: [String: Any]?
        init(_ socket: WebSocketConnection) { self.socket = socket }
    }
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var latest: [String: Any] = ["epoch": "", "revision": 0, "apps": [], "upstreamCount": 0]

    func accept(head: HTTPRequestHead, leftover: Data, connection: NWConnection) {
        let socket = WebSocketConnection(connection: connection, leftover: leftover)
        let viewer = Viewer(socket)
        let id = ObjectIdentifier(viewer)
        socket.onClose = { [weak self] in self?.viewers.removeValue(forKey: id) }
        guard socket.accept(head) else { socket.close(); return }
        viewers[id] = viewer
        send(snapshot(), to: viewer)
    }

    private func snapshot() -> [String: Any] {
        var result = latest
        result["replace"] = true
        result["type"] = "states"
        return result
    }

    func update(_ state: [String: Any]) {
        let old = latest["apps"] as? [[String: Any]] ?? []
        let apps = state["apps"] as? [[String: Any]] ?? []
        func key(_ app: [String: Any]) -> String { "\(app["deviceId"] ?? "")|\(app["bundleId"] ?? "")" }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { (key($0), $0 as NSDictionary) })
        let ids = Set(apps.map(key))
        let changedEpoch = latest["epoch"] as? String != state["epoch"] as? String
        latest = state
        var delta = state
        delta["apps"] = apps.filter { oldByID[key($0)] != ($0 as NSDictionary) }
        delta["removed"] = old.filter { !ids.contains(key($0)) }.map { ["deviceId": $0["deviceId"]!, "bundleId": $0["bundleId"]!] }
        delta["type"] = "states"
        delta["replace"] = false
        for viewer in viewers.values {
            if viewer.sending { viewer.pending = snapshot() }
            else { send(changedEpoch ? snapshot() : delta, to: viewer) }
        }
    }

    private func send(_ state: [String: Any], to viewer: Viewer) {
        guard let data = try? JSONSerialization.data(withJSONObject: state), let text = String(data: data, encoding: .utf8) else { return }
        viewer.sending = true
        viewer.socket.sendText(text) { [weak self, weak viewer] sent in
            guard let self, let viewer, self.viewers[ObjectIdentifier(viewer)] === viewer else { return }
            viewer.sending = false
            if !sent { viewer.socket.close(); return }
            if let pending = viewer.pending {
                viewer.pending = nil
                self.send(pending, to: viewer)
            }
        }
    }
}
