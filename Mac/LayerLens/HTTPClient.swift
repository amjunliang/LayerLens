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
        var callback: ((Response?) -> Void)? = completion
        let finish = { (response: Response?) in
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            received = Data()
            let done = callback
            callback = nil
            done?(response)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                guard !finished else { return }
                if let data {
                    received.append(data)
                }
                if received.count > 64 * 1024 * 1024 + 65536 { finish(nil); return }
                if let response = parse(received, eof: isComplete && error == nil) { finish(response) }
                else if isComplete || error != nil { finish(nil) }
                else { receive() }
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

    /// Only complete HTTP messages are accepted. EOF / reset cannot turn a partial body into success.
    static func parse(_ data: Data, eof: Bool = false) -> Response? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)), separator.lowerBound <= 65536,
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]), (200...599).contains(status) else { return nil }
        var lengths: [Int] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" && value.lowercased() != "identity" { return nil }
            if name == "content-length" {
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(value), length <= 64 * 1024 * 1024 else { return nil }
                lengths.append(length)
            }
        }
        let body = Data(data[separator.upperBound...])
        if let length = lengths.first {
            guard lengths.allSatisfy({ $0 == length }), body.count == length else { return nil }
        } else if status == 204 || status == 304 {
            guard body.isEmpty else { return nil }
        } else if !eof { return nil }
        return Response(status: status, body: body)
    }
}
