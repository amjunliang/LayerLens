import Darwin
import Foundation
import Network

@main struct ProxyTunnelTests {
    // Accessed only on the test's serial networking queue.
    private final class Peers { var connections: [NWConnection] = [] }
    private static func backendRead(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            var received = received; received.append(data ?? Data())
            if let parsed = HTTPRequestHead.parse(received), let head = parsed.head, received.count >= parsed.length + head.contentLength {
                let body = received.subdata(in: parsed.length..<(parsed.length + head.contentLength))
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if !done && error == nil { backendRead(connection, received) }
        }
    }
    private static func proxyRead(_ connection: NWConnection, _ received: Data, backend: NWListener, queue: DispatchQueue, peers: Peers) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            var received = received; received.append(data ?? Data())
            if HTTPRequestHead.parse(received) != nil {
                let upstream = NWConnection(host: "127.0.0.1", port: backend.port!, using: .tcp)
                peers.connections.append(upstream)
                ProxyTunnel(client: connection, upstream: upstream, initialData: received, queue: queue, onFailure: { assertionFailure("Proxy failed") }).start()
            } else if !done && error == nil { proxyRead(connection, received, backend: backend, queue: queue, peers: peers) }
        }
    }
    static func main() throws {
        let queue = DispatchQueue(label: "test.proxy")
        let backend = try NWListener(using: .tcp, on: .any)
        let proxy = try NWListener(using: .tcp, on: .any)
        let ready = DispatchGroup(); ready.enter(); ready.enter()
        backend.stateUpdateHandler = { if case .ready = $0 { ready.leave() } }
        proxy.stateUpdateHandler = { if case .ready = $0 { ready.leave() } }
        let peers = Peers()
        backend.newConnectionHandler = { connection in peers.connections.append(connection); connection.start(queue: queue); backendRead(connection, Data()) }
        proxy.newConnectionHandler = { connection in peers.connections.append(connection); connection.start(queue: queue); proxyRead(connection, Data(), backend: backend, queue: queue, peers: peers) }
        backend.start(queue: queue); proxy.start(queue: queue)
        assert(ready.wait(timeout: .now()+5) == .success)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = proxy.port!.rawValue.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        assert(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0); setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let payload = Data((0..<(2*1024*1024)).map { UInt8($0 % 251) })
        let request = Data("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload
        var offset = 0
        while offset < request.count {
            let count = request.withUnsafeBytes { write(client, $0.baseAddress!.advanced(by: offset), request.count-offset) }; assert(count > 0); offset += count
        }
        var response = Data(), bytes = [UInt8](repeating: 0, count: 32768)
        while true { let count = read(client, &bytes, bytes.count); if count == 0 { break }; assert(count > 0); response.append(contentsOf: bytes.prefix(count)) }
        close(client)
        let end = response.range(of: Data("\r\n\r\n".utf8))!.upperBound
        assert(Data(response[end...]) == payload, "Backpressure must preserve every request and response byte through final close")
        queue.sync { peers.connections.forEach { $0.cancel() }; backend.cancel(); proxy.cancel() }
        print("PASS backpressured proxy preserves a 2 MiB request/response through orderly close")
    }
}
