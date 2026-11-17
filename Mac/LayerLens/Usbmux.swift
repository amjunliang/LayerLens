//
//  Usbmux.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Darwin
import Foundation
import Network

/// 通过 usbmuxd 访问 USB 连接的真机. 协议: 16 字节小端头(总长度, 版本 1, 类型 8 = plist, tag) + XML plist.
/// Connect 成功后这条 unix socket 连接即成为到设备端口的透传通道, 可连接设备的回环地址
enum Usbmux {
    struct Device: Equatable {
        /// usbmuxd 分配的编号, 设备重新插拔后会变化
        let id: Int
        /// 与 Xcode / devicectl 一致的 UDID
        let udid: String
    }

    static let socketPath = "/var/run/usbmuxd"
    private static let timeout: TimeInterval = 2
    private static let listQueue = DispatchQueue(label: "com.layerlens.usbmux.list", qos: .utility)

    /// 只返回 USB 连接的设备; 无线同步的设备经 usbmuxd 无法访问设备回环地址. 请求失败时回调 nil
    static func listDevices(queue: DispatchQueue, completion: @escaping ([Device]?) -> Void) {
        listDevicesDetailed(queue: queue) { devices, _ in
            completion(devices)
        }
    }

    /// 与 listDevices 相同, 失败时额外返回错误原因以便记录日志
    static func listDevicesDetailed(queue: DispatchQueue, completion: @escaping ([Device]?, String?) -> Void) {
        listQueue.async {
            let result = listDevicesSync()
            queue.async {
                completion(result.devices, result.error)
            }
        }
    }

    static func parseDevices(from reply: [String: Any]) -> [Device]? {
        guard let list = reply["DeviceList"] as? [[String: Any]] else {
            return nil
        }
        var byUDID: [String: Device] = [:]
        for item in list {
            guard let properties = item["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB",
                  let id = item["DeviceID"] as? Int ?? properties["DeviceID"] as? Int,
                  let serial = properties["SerialNumber"] as? String else {
                continue
            }
            let udid = normalizedUDID(serial)
            if let existing = byUDID[udid], existing.id >= id {
                continue
            }
            byUDID[udid] = Device(id: id, udid: udid)
        }
        return byUDID.values.sorted { $0.id < $1.id }
    }

    /// 连接设备上的 TCP 端口, 成功时回调已就绪的连接, 之后直接收发设备端的数据;
    /// 失败时 refused 表示设备明确拒绝(端口无人监听), 否则为超时等偶发错误
    static func connect(deviceId: Int, port: UInt16, queue: DispatchQueue, completion: @escaping (_ connection: NWConnection?, _ refused: Bool) -> Void) {
        // 端口按网络字节序传递
        let message: [String: Any] = ["MessageType": "Connect", "DeviceID": deviceId, "PortNumber": Int(port.bigEndian)]
        request(message, queue: queue) { connection, reply in
            guard let connection, reply?["MessageType"] as? String == "Result", reply?["Number"] as? Int == 0 else {
                connection?.cancel()
                completion(nil, reply?["Number"] as? Int == 3)
                return
            }
            connection.stateUpdateHandler = nil
            completion(connection, false)
        }
    }

    /// 新设备的 SerialNumber 不带连字符(24 位), 补成 00008110-001234567890123E 的形式
    private static func normalizedUDID(_ serial: String) -> String {
        guard serial.count == 24, !serial.contains("-") else { return serial }
        let index = serial.index(serial.startIndex, offsetBy: 8)
        return serial[..<index] + "-" + serial[index...]
    }

    // MARK: - Protocol

    private static func encodePacket(_ message: [String: Any]) -> Data? {
        var payload = message
        payload["ClientVersionString"] = "LayerLens"
        payload["ProgName"] = "LayerLens"
        payload["kLibUSBMuxVersion"] = 3
        guard let body = try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0) else {
            return nil
        }
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        return packet
    }

    /// 用原生 AF_UNIX socket 查询设备列表, 避免高频轮询反复创建 NWConnection TCP 状态机
    private static func listDevicesSync() -> (devices: [Device]?, error: String?) {
        guard let packet = encodePacket(["MessageType": "ListDevices"]) else {
            return (nil, "encode failed")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return (nil, "socket errno=\(errno)")
        }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return (nil, "socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult < 0 {
            guard errno == EINPROGRESS else { return (nil, "connect errno=\(errno)") }
            guard waitSocket(fd, events: Int16(POLLOUT), deadline: deadline) else {
                return (nil, "connect timeout")
            }
            var socketError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &len) != 0 || socketError != 0 {
                return (nil, "connect error=\(socketError != 0 ? socketError : errno)")
            }
        }

        if let sendError = sendAll(fd, data: packet, deadline: deadline) {
            return (nil, sendError)
        }
        guard let header = recvExact(fd, count: 16, deadline: deadline) else {
            return (nil, "read header failed")
        }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 16, length < 1024 * 1024 else {
            return (nil, "invalid length=\(length)")
        }
        guard let body = recvExact(fd, count: length - 16, deadline: deadline) else {
            return (nil, "read body failed")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let devices = parseDevices(from: plist) else {
            return (nil, "invalid plist")
        }
        return (devices, nil)
    }

    private static func waitSocket(_ fd: Int32, events: Int16, deadline: TimeInterval) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let timeoutMs = Int32(min(max(1, Int(ceil(remaining * 1000))), Int(Int32.max)))
            let rc = Darwin.poll(&pfd, 1, timeoutMs)
            if rc > 0 { return true }
            if rc == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    private static func sendAll(_ fd: Int32, data: Data, deadline: TimeInterval) -> String? {
        var offset = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return nil }
            while offset < data.count {
                let n = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard waitSocket(fd, events: Int16(POLLOUT), deadline: deadline) else {
                        return "send timeout"
                    }
                } else {
                    return "send errno=\(errno)"
                }
            }
            return nil
        }
    }

    private static func recvExact(_ fd: Int32, count: Int, deadline: TimeInterval) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return false }
            while offset < count {
                let n = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitSocket(fd, events: Int16(POLLIN), deadline: deadline) else {
                        return false
                    }
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? data : nil
    }

    /// 发送一条消息并读取一条回复; 回调时连接仍打开, 由调用方决定关闭或继续使用
    private static func request(_ message: [String: Any], queue: DispatchQueue, completion: @escaping (NWConnection?, [String: Any]?) -> Void) {
        guard let packet = encodePacket(message) else {
            queue.async { completion(nil, nil) }
            return
        }

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        var finished = false
        let finish = { (reply: [String: Any]?) in
            guard !finished else { return }
            finished = true
            if reply == nil {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            completion(reply == nil ? nil : connection, reply)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { error in
                    if error != nil {
                        finish(nil)
                    }
                })
                readReply(connection, completion: finish)
            case .failed, .waiting, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(nil)
        }
    }

    /// 按头部长度精确读取, 避免多读走 Connect 之后设备发来的数据
    private static func readReply(_ connection: NWConnection, completion: @escaping ([String: Any]?) -> Void) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { header, _, _, error in
            guard let header, header.count == 16, error == nil else {
                completion(nil)
                return
            }
            let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length > 16, length < 1024 * 1024 else {
                completion(nil)
                return
            }
            connection.receive(minimumIncompleteLength: length - 16, maximumLength: length - 16) { body, _, _, error in
                guard let body, error == nil,
                      let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
                    completion(nil)
                    return
                }
                completion(plist)
            }
        }
    }
}
