//
//  SimulatorLive.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import IOSurface

/// 模拟器实时画面: 屏幕帧编码为 H.264 经 WebSocket 推给网页, 网页的触摸与按键消息注入模拟器
final class SimulatorLive {
    private let lock = NSLock()
    /// 每台模拟器一个, 无人观看时停止采集但保留对象, 避免并发加入时重复创建
    private var streams: [String: SimulatorStream] = [:]

    /// 私有框架可加载时才可用, 否则网页提示原因
    static var isAvailable: Bool {
        SimBridge.load()
    }

    /// 屏幕尺寸(point), 设备不存在时返回 nil
    func info(udid: String) -> [String: Any]? {
        guard let device = SimBridge.device(udid: udid) else { return nil }
        let scale = SimBridge.screenScale(device)
        guard let screen = SimScreen(device: device, queue: .global()), let surface = screen.surface() else { return nil }
        return ["screen": ["width": Double(IOSurfaceGetWidth(surface)) / scale, "height": Double(IOSurfaceGetHeight(surface)) / scale, "scale": scale]]
    }

    func accept(udid: String, head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        guard head.header("Upgrade")?.lowercased() == "websocket" else {
            connection.respond(.error(400, "WebSocket upgrade required"))
            return
        }
        // 先发出握手响应再加入广播, 否则首帧可能早于 101 到达; 两步在同一队列执行, 中间不会收到关闭
        let socket = WebSocketConnection(connection: connection.detach(), leftover: leftover)
        _ = socket.accept(head)
        stream(udid).add(socket)
    }

    private func stream(_ udid: String) -> SimulatorStream {
        lock.lock()
        defer { lock.unlock() }
        if let stream = streams[udid] {
            return stream
        }
        let stream = SimulatorStream(udid: udid)
        streams[udid] = stream
        return stream
    }
}
