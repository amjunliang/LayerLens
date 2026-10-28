//
//  AppEventStream.swift
//  LayerLens
//
//  Created by YueYou on 10/28/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// 到 App 内事件流接口的一条长连接, 按空行切分事件交给 onEvent; 状态码不是 200 或连接断开时调用 onClose.
/// 所有回调都在创建时传入的 queue 上执行
final class AppEventStream {
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var closed = false
    var onEvent: ((_ name: String, _ payload: Data) -> Void)?
    /// status 为 0 表示连接失败或中途断开
    var onClose: ((_ status: Int) -> Void)?
    private(set) var lastReceive = Date()

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(endpoint: TargetEndpoint, path: String) {
        let request = HTTPClient.request(method: "GET", path: path, host: "127.0.0.1:\(endpoint.port)")
        lastReceive = Date()
        AppRequest.open(endpoint, queue: queue) { [weak self] connection in
            guard let self else {
                connection?.cancel()
                return
            }
            guard !self.closed else {
                connection?.cancel()
                return
            }
            guard let connection else {
                self.finish(0)
                return
            }
            self.connection = connection
            self.send(request, on: connection)
        }
    }

    func cancel() {
        closed = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func send(_ request: Data, on connection: NWConnection) {
        let send = { [weak self] in
            connection.send(content: request, completion: .contentProcessed { _ in })
            self?.receive(connection, buffer: Data(), headerDone: false)
        }
        // 本机连接在 ready 后发送请求; usbmuxd 返回的连接已启动, 直接发送
        let started = connection.state != .setup
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !started {
                    send()
                }
            case .failed, .waiting:
                self?.finish(0)
            default:
                break
            }
        }
        if started {
            send()
        } else {
            connection.start(queue: queue)
        }
    }

    private func finish(_ status: Int) {
        guard !closed else { return }
        cancel()
        onClose?(status)
    }

    private func receive(_ connection: NWConnection, buffer: Data, headerDone: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, self.connection === connection else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
                self.lastReceive = Date()
            }
            var headerDone = headerDone
            if !headerDone, let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let statusLine = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
                guard status == 200 else {
                    self.finish(status)
                    return
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                headerDone = true
            }
            if headerDone {
                while let range = buffer.range(of: Data("\n\n".utf8)) {
                    let block = Data(buffer[buffer.startIndex..<range.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    self.handle(block)
                    if self.closed { return }
                }
            }
            if isComplete || error != nil {
                self.finish(0)
                return
            }
            self.receive(connection, buffer: buffer, headerDone: headerDone)
        }
    }

    private func handle(_ block: Data) {
        var name = ""
        var payload = Data()
        for line in block.split(separator: UInt8(ascii: "\n")) {
            if line.starts(with: Data("event: ".utf8)) {
                name = String(decoding: line.dropFirst(7), as: UTF8.self)
            } else if line.starts(with: Data("data: ".utf8)) {
                payload.append(line.dropFirst(6))
            }
        }
        if !name.isEmpty {
            onEvent?(name, payload)
        }
    }
}

/// 对 App 内接口的单次请求
enum AppRequest {
    /// 本机返回未启动的连接, 真机返回 usbmuxd 已建立的连接
    static func open(_ endpoint: TargetEndpoint, queue: DispatchQueue, completion: @escaping (NWConnection?) -> Void) {
        switch endpoint {
        case .local(let port):
            completion(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
        case .usb(let deviceId, let port):
            Usbmux.connect(deviceId: deviceId, port: port, queue: queue) { connection, _ in
                completion(connection)
            }
        }
    }

    static func send(_ endpoint: TargetEndpoint, method: String = "GET", path: String, body: Data? = nil, timeout: TimeInterval, queue: DispatchQueue, completion: @escaping (HTTPClient.Response?) -> Void) {
        let request = HTTPClient.request(method: method, path: path, host: "127.0.0.1:\(endpoint.port)", body: body)
        open(endpoint, queue: queue) { connection in
            guard let connection else {
                completion(nil)
                return
            }
            HTTPClient.exchange(request, on: connection, queue: queue, timeout: timeout, completion: completion)
        }
    }
}
