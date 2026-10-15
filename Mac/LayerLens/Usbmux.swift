//
//  Usbmux.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// 通过 usbmuxd 访问 USB 连接的真机. 协议: 16 字节小端头(总长度, 版本 1, 类型 8 = plist, tag) + XML plist.
/// Connect 成功后这条 unix socket 连接即成为到设备端口的透传通道, 可连接设备的回环地址
enum Usbmux {
    struct Device {
        /// usbmuxd 分配的编号, 设备重新插拔后会变化
        let id: Int
        /// 与 Xcode / devicectl 一致的 UDID
        let udid: String
    }

    static let socketPath = "/var/run/usbmuxd"
    private static let timeout: TimeInterval = 2

    /// 只返回 USB 连接的设备; 无线同步的设备经 usbmuxd 无法访问设备回环地址. 请求失败时回调 nil
    static func listDevices(queue: DispatchQueue, completion: @escaping ([Device]?) -> Void) {
        request(["MessageType": "ListDevices"], queue: queue) { connection, reply in
            connection?.cancel()
            guard let list = reply?["DeviceList"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            let devices: [Device] = list.compactMap { item in
                guard let properties = item["Properties"] as? [String: Any],
                      properties["ConnectionType"] as? String == "USB",
                      let id = item["DeviceID"] as? Int ?? properties["DeviceID"] as? Int,
                      let serial = properties["SerialNumber"] as? String else {
                    return nil
                }
                return Device(id: id, udid: normalizedUDID(serial))
            }
            completion(devices)
        }
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

    /// 发送一条消息并读取一条回复; 回调时连接仍打开, 由调用方决定关闭或继续使用
    private static func request(_ message: [String: Any], queue: DispatchQueue, completion: @escaping (NWConnection?, [String: Any]?) -> Void) {
        var payload = message
        payload["ClientVersionString"] = "LayerLens"
        payload["ProgName"] = "LayerLens"
        payload["kLibUSBMuxVersion"] = 3
        guard let body = try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0) else {
            queue.async { completion(nil, nil) }
            return
        }
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        var finished = false
        let finish = { (reply: [String: Any]?) in
            guard !finished else { return }
            finished = true
            if reply == nil {
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
