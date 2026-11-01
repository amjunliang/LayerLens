import Darwin
import Foundation
import Network

/// Real local SSE viewer. Each page() disconnects after the first complete network event.
final class NetworkViewerProbe {
    struct Page {
        let frames: [[String: Any]]
        var payload: [String: Any] { frames.last!["data"] as! [String: Any] }
        var records: [[String: Any]] { payload["records"] as! [[String: Any]] }
        var epoch: String { payload["epoch"] as? String ?? "" }
        var cursor: UInt64 { records.map { ($0["s"] as! NSNumber).uint64Value }.max() ?? 0 }
        var resets: Bool { frames.contains { $0["name"] as? String == "clear" } }
    }
    private let queue = DispatchQueue(label: "test.network.viewer")
    private let listener: NWListener
    private var clients: [NWConnection] = []
    init(recorder: NetworkRecorder) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.clients.append(connection); connection.start(queue: self.queue)
            self.receive(connection, Data(), recorder: recorder)
        }
        listener.start(queue: queue)
        assert(ready.wait(timeout: .now() + 5) == .success)
    }
    func close() { queue.sync { clients.forEach { $0.cancel() }; listener.cancel() } }
    private func receive(_ connection: NWConnection, _ previous: Data, recorder: NetworkRecorder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            var buffer = previous; buffer.append(data ?? Data())
            if let head = HTTPRequestHead.parse(buffer)?.head {
                assert(recorder.handle(head, path: head.path, deviceId: "phone", bundleId: "test-app", connection: HubConnection(connection: connection), fallback: { assertionFailure("Unexpected upstream fallback") }))
            } else if !done && error == nil { self?.receive(connection, buffer, recorder: recorder) }
        }
    }
    func page(since: UInt64 = 0, epoch: String = "") -> Page {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = listener.port!.rawValue.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        assert(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = Data("GET /api/network?since=\(since)&epoch=\(epoch) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        assert(request.withUnsafeBytes { write(fd, $0.baseAddress, request.count) } == request.count)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 65536), headers = false
        var frames: [[String: Any]] = []
        while true {
            let count = read(fd, &bytes, bytes.count); assert(count > 0, "SSE replay timed out")
            data.append(contentsOf: bytes.prefix(count))
            if !headers {
                guard let end = data.range(of: Data("\r\n\r\n".utf8))?.upperBound else { continue }
                data = Data(data[end...]); headers = true
            }
            while let range = data.range(of: Data("\n\n".utf8)) {
                let block = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                data = Data(data[range.upperBound...])
                guard block.hasPrefix("event: "), let payload = block.components(separatedBy: "\ndata: ").last else { continue }
                let name = String(block.components(separatedBy: "\n")[0].dropFirst(7))
                let json = try! JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
                frames.append(["name": name, "data": json])
                if name == "network" { return Page(frames: frames) }
            }
        }
    }
}
