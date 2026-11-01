// Standalone: swiftc Mac/LayerLens/TargetStateHub.swift Mac/Tests/TargetStateHubTests.swift -o <test>
import Foundation
import Network

enum TargetEndpoint: Equatable { case local(port: UInt16); case usb(deviceId: Int, port: UInt16)
    var port: UInt16 { switch self { case .local(let p), .usb(_, let p): return p } }
    var connectionType: String { switch self { case .local: return "simulator"; case .usb: return "usb" } }
}
struct AppRecord {
    let deviceId: String; let bundleId: String; let endpoint: TargetEndpoint; let info: [String: Any]
    var suspended = false; var responding = true
}
final class AppEventStream {
    var onOpen: (() -> Void)?; var onEvent: ((String, Data) -> Void)?; var onClose: ((Int) -> Void)?
    var cancelled = false
    var lastReceive = Date()
    func start(endpoint: TargetEndpoint, path: String) { assert(path == "/api/events") }
    func cancel() { cancelled = true }
    func foreground(_ value: Bool) { onEvent?("state", try! JSONSerialization.data(withJSONObject: ["foreground": value])) }
}
struct HTTPRequestHead {}
final class WebSocketConnection {
    static var sockets: [WebSocketConnection] = []
    var onClose: (() -> Void)?
    var messages: [[String: Any]] = []
    var completion: ((Bool) -> Void)?
    init(connection: NWConnection, leftover: Data) { Self.sockets.append(self) }
    func accept(_ head: HTTPRequestHead) -> Bool { true }
    func sendText(_ text: String, completion: @escaping (Bool) -> Void) {
        assert(self.completion == nil, "Only one send may be in flight")
        messages.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
        self.completion = completion
    }
    func drain() { let done = completion; completion = nil; done?(true) }
    func close() { onClose?(); onClose = nil }
}

@main struct Tests {
    static func main() {
        var streams: [AppEventStream] = [], snapshots: [[String: Any]] = []
        let monitor = TargetStateMonitor { let stream = AppEventStream(); streams.append(stream); return stream }
        monitor.onChange = { _, snapshot in snapshots.append(snapshot) }
        func app(_ device: String = "phone", instance: String = "one", port: UInt16 = 9527, foreground: Bool = true, responding: Bool = true) -> AppRecord {
            var app = AppRecord(deviceId: device, bundleId: "test", endpoint: .local(port: port), info: ["bundleId": "test", "instanceId": instance, "foreground": foreground])
            app.responding = responding
            return app
        }
        func latestApp() -> [String: Any] { (snapshots.last!["apps"] as! [[String: Any]])[0] }
        monitor.update([app()]); assert(streams.count == 1)
        streams[0].onOpen?(); streams[0].foreground(false)
        assert(latestApp()["foreground"] as? Bool == false)
        monitor.update([app()]) // old HTTP response cannot overwrite pushed background
        assert(latestApp()["foreground"] as? Bool == false && streams.count == 1)
        let count = snapshots.count
        monitor.update([app()]); assert(snapshots.count == count, "Unchanged scans must not broadcast")
        let broadcaster = TargetStateBroadcaster()
        broadcaster.update(snapshots.last!)
        func join() -> WebSocketConnection {
            broadcaster.accept(head: HTTPRequestHead(), leftover: Data(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
            return WebSocketConnection.sockets.last!
        }
        let first = join(), second = join()
        assert(streams.count == 1, "Additional windows must not open additional App streams")
        assert(first.messages[0]["replace"] as? Bool == true)
        assert(second.messages[0]["revision"] as? Int == snapshots.last!["revision"] as? Int)
        first.drain(); second.drain()
        streams[0].foreground(true); broadcaster.update(snapshots.last!)
        assert(first.messages.last!["replace"] as? Bool == false)
        assert((first.messages.last!["apps"] as! [[String: Any]])[0]["foreground"] as? Bool == true)
        let sent = first.messages.count
        // A stalled viewer gets no accumulating delta queue, only the latest snapshot.
        for index in 0..<100 { streams[0].foreground(index % 2 == 0); broadcaster.update(snapshots.last!) }
        assert(first.messages.count == sent)
        first.drain()
        assert(first.messages.count == sent + 1 && first.messages.last!["replace"] as? Bool == true)
        assert(first.messages.last!["revision"] as? Int == snapshots.last!["revision"] as? Int)
        first.drain()
        let late = join()
        assert(late.messages[0]["replace"] as? Bool == true)
        assert(streams.count == 1)
        let oldCallback = streams[0].onEvent
        monitor.update([app(instance: "two", port: 9528)])
        assert(streams.count == 2 && streams[0].cancelled)
        oldCallback?("state", Data("{\"foreground\":false}".utf8))
        assert(latestApp()["instanceId"] as? String == "two" && latestApp()["foreground"] as? Bool == true)
        streams[1].onClose?(404)
        monitor.update([app(instance: "two", port: 9528)])
        assert(streams.count == 2, "404 must not retry repeatedly for the same process")
        assert(latestApp()["stateConnected"] as? Bool == true, "Old Pod can use successful scan")
        monitor.update([app(instance: "three", port: 9529)])
        assert(streams.count == 3)
        streams[2].onClose?(0)
        monitor.update([app(instance: "three", port: 9529, responding: false)])
        assert(streams.count == 3, "Unresponsive background app should not reconnect on every scan")
        monitor.update([app(instance: "three", port: 9529)])
        assert(streams.count == 4, "Reachable app reconnects after transport failure")
        streams[3].lastReceive = Date().addingTimeInterval(-41)
        monitor.update([app(instance: "three", port: 9529)])
        assert(streams[3].cancelled && streams.count == 5, "A stalled handshake on a reachable App must reconnect")
        streams[4].onOpen?()
        streams[4].lastReceive = Date().addingTimeInterval(-100)
        monitor.update([app(instance: "three", port: 9529)])
        assert(!streams[4].cancelled && streams.count == 5, "State stream has no periodic heartbeat; healthy idle connection stays open")
        monitor.update([app("other", instance: "other")])
        assert(streams[4].cancelled && streams.count == 6)
        monitor.stop()
        assert(streams[5].cancelled && (snapshots.last!["apps"] as! [[String: Any]]).isEmpty)
        print("PASS native shared subscriptions, realtime state, scan races, restart, 404, reconnect, latest-only delivery and cleanup")
    }
}
