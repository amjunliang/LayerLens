//
//  WebSocketConnection.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import CryptoKit
import Foundation
import Network

/// 服务端 WebSocket: 在已读完请求头的 HTTP 连接上完成握手, 收发帧(不支持扩展和压缩)
final class WebSocketConnection {
    static let maxMessageLength = 1024 * 1024
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let connection: NWConnection
    private var buffer: Data
    private var message = Data()
    private var messageIsText = false
    private var closed = false

    init(connection: NWConnection, leftover: Data) {
        self.connection = connection
        buffer = leftover
    }

    /// 返回 false 表示不是合法的升级请求, 调用方负责响应错误
    func accept(_ head: HTTPRequestHead) -> Bool {
        guard head.header("Upgrade")?.lowercased() == "websocket", let key = head.header("Sec-WebSocket-Key") else { return false }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + Self.guid).utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        parse()
        receive()
        return true
    }

    /// completion 在连接的队列回调, 参数表示是否发送成功
    func sendBinary(_ payload: Data, completion: @escaping (Bool) -> Void) {
        send(opcode: 0x2, payload: payload, completion: completion)
    }

    func sendText(_ text: String) {
        send(opcode: 0x1, payload: Data(text.utf8)) { _ in }
    }

    func close() {
        guard !closed else { return }
        send(opcode: 0x8, payload: Data()) { _ in }
        finish()
    }

    private func send(opcode: UInt8, payload: Data, completion: @escaping (Bool) -> Void) {
        guard !closed else {
            completion(false)
            return
        }
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xFF) })
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
                parse()
            }
            if error != nil || isComplete {
                finish()
            } else if !closed {
                receive()
            }
        }
    }

    private func parse() {
        while !closed, buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(14))
            let fin = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            guard length <= Self.maxMessageLength else {
                close()
                return
            }
            var mask: [UInt8] = []
            if masked {
                guard bytes.count >= offset + 4 else { return }
                mask = Array(bytes[offset..<(offset + 4)])
                offset += 4
            }
            guard buffer.count >= offset + length else { return }
            var payload = [UInt8](buffer.dropFirst(offset).prefix(length))
            if masked {
                for i in payload.indices {
                    payload[i] ^= mask[i % 4]
                }
            }
            buffer = Data(buffer.dropFirst(offset + length))
            handle(opcode: opcode, fin: fin, payload: Data(payload))
        }
    }

    private func handle(opcode: UInt8, fin: Bool, payload: Data) {
        switch opcode {
        case 0x0, 0x1, 0x2:
            message.append(payload)
            guard message.count <= Self.maxMessageLength else {
                close()
                return
            }
            if opcode != 0x0 {
                messageIsText = opcode == 0x1
            }
            guard fin else { return }
            if messageIsText, let text = String(data: message, encoding: .utf8) {
                onText?(text)
            }
            message = Data()
        case 0x8:
            close()
        case 0x9:
            send(opcode: 0xA, payload: payload) { _ in }
        default:
            break
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let onClose = onClose
        self.onClose = nil
        onText = nil
        onClose?()
    }
}
