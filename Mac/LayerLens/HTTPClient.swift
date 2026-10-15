//
//  HTTPClient.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// 在一条 NWConnection 上完成一次 HTTP 请求, 用于经 usbmuxd 访问真机上的 iOS App.
/// iOS 端每个请求处理完即关闭连接, 读到结束即为完整响应
enum HTTPClient {
    struct Response {
        let status: Int
        let body: Data

        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    static func request(method: String, path: String, host: String, headers: [String: String] = [:], body: Data? = nil) -> Data {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        if let body {
            text += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        var data = Data((text + "\r\n").utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    /// connection 尚未启动时先启动, 已就绪时(usbmuxd)直接发送; 结束后关闭连接
    static func exchange(_ request: Data, on connection: NWConnection, queue: DispatchQueue, timeout: TimeInterval, completion: @escaping (Response?) -> Void) {
        var finished = false
        var received = Data()
        let finish = { (response: Response?) in
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(response)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data {
                    received.append(data)
                }
                if isComplete || error != nil {
                    finish(parse(received))
                } else {
                    receive()
                }
            }
        }
        let send = {
            connection.send(content: request, completion: .contentProcessed { error in
                if error != nil {
                    finish(nil)
                }
            })
            receive()
        }
        let started = connection.state != .setup
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !started {
                    send()
                }
            case .failed, .waiting, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        if started {
            send()
        } else {
            connection.start(queue: queue)
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(nil)
        }
    }

    private static func parse(_ data: Data) -> Response? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let statusLine = String(data: data[..<separator.lowerBound], encoding: .utf8)?.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            return nil
        }
        return Response(status: status, body: Data(data[separator.upperBound...]))
    }
}
