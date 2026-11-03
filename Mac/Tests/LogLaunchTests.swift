import Foundation
import Network

/// Real viewer socket: verify the reset reaches an already-open panel, not just disk state.
final class LogLaunchViewer {
    private let queue = DispatchQueue(label: "test.log.launch.viewer")
    private let listener: NWListener
    private var client: NWConnection?
    private var peers: [NWConnection] = []
    private var buffer = Data()
    private var headers = false
    private var events: [(String, [String: Any])] = []
    var snapshot: [(String, [String: Any])] { queue.sync { events } }
    init(_ recorder: AppLogRecorder) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.peers.append(connection); connection.start(queue: self.queue)
            recorder.subscribe(deviceId: "phone", bundleId: "test-app", connection: connection)
        }
        listener.start(queue: queue)
        precondition(ready.wait(timeout: .now() + 3) == .success)
        client = NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp)
        client?.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.receive() } }
        client?.start(queue: queue)
    }
    private func receive() {
        client?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            self.buffer.append(data ?? Data())
            if !self.headers, let end = self.buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                self.buffer.removeSubrange(self.buffer.startIndex..<end); self.headers = true
            }
            if self.headers {
                while let range = self.buffer.range(of: Data("\n\n".utf8)) {
                    let block = String(decoding: self.buffer[..<range.lowerBound], as: UTF8.self)
                    self.buffer.removeSubrange(self.buffer.startIndex..<range.upperBound)
                    let lines = block.components(separatedBy: "\n")
                    if let name = lines.first(where: { $0.hasPrefix("event: ") }),
                       let payload = lines.first(where: { $0.hasPrefix("data: ") }),
                       let json = try? JSONSerialization.jsonObject(with: Data(payload.dropFirst(6).utf8)) as? [String: Any] {
                        self.events.append((String(name.dropFirst(7)), json))
                    }
                }
            }
            if !done && error == nil { self.receive() }
        }
    }
    func close() { queue.sync { client?.cancel(); peers.forEach { $0.cancel() }; listener.cancel() } }
}

@main struct LogLaunchTests {
    static func wait(_ check: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !check() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        precondition(check(), "Log launch test timed out")
    }
    static func app(_ server: AppServer) -> AppRecord {
        AppRecord(deviceId: "phone", bundleId: "test-app", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance])
    }
    static func current(_ recorder: AppLogRecorder) -> String? {
        let ready = DispatchSemaphore(value: 0); var file: String?
        recorder.current(deviceId: "phone", bundleId: "test-app") { value, _ in file = value; ready.signal() }
        precondition(ready.wait(timeout: .now() + 3) == .success); return file
    }
    static func displayed(_ viewer: LogLaunchViewer) -> [String] {
        var lines: [String] = []
        for (event, data) in viewer.snapshot {
            if event == "reset" { lines = [] }
            if event == "logs" { lines += (data["entries"] as? [[String: Any]] ?? []).compactMap { $0["m"] as? String } }
        }
        return lines
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/log-launch")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AppServer(), fresh = try AppServer()
        defer { first.stop(); fresh.stop() }
        let recorder = AppLogRecorder(folder: root); defer { recorder.stop() }
        let viewer = try LogLaunchViewer(recorder); defer { viewer.close() }
        recorder.update(apps: [app(first)])
        wait { displayed(viewer) == ["preserved-log-1"] }
        recorder.update(apps: []); _ = current(recorder)
        recorder.update(apps: [app(first)])
        wait { displayed(viewer) == ["preserved-log-1", "preserved-log-2"] }
        let oldFile = root.appendingPathComponent("test-app").appendingPathComponent(current(recorder)!)
        let oldBytes = try Data(contentsOf: oldFile)
        fresh.queue.sync { fresh.mode = "logs-empty" }
        recorder.update(apps: [app(fresh)])
        wait { viewer.snapshot.last(where: { $0.0 == "reset" })?.1["instanceId"] as? String == fresh.instance }
        precondition(displayed(viewer).isEmpty, "Empty new launch clears old display immediately")
        precondition(current(recorder) == nil, "New launch must not point to the old file")
        precondition(try! Data(contentsOf: oldFile) == oldBytes, "History remains unchanged")
        fresh.queue.sync { fresh.mode = "hold" }
        recorder.update(apps: []); _ = current(recorder)
        recorder.update(apps: [app(fresh)])
        wait { displayed(viewer) == ["preserved-log-1", "preserved-log-2"] }
        precondition(current(recorder) != oldFile.lastPathComponent)
        let late = try LogLaunchViewer(recorder); defer { late.close() }
        wait { displayed(late) == ["preserved-log-1", "preserved-log-2"] }
        precondition(try! Data(contentsOf: oldFile) == oldBytes)
        print("PASS current-launch-only real log stream, reconnect continuity, empty restart, late viewer and history preservation")
    }
}
