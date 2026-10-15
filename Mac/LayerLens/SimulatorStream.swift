//
//  SimulatorStream.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import IOSurface

/// 一台模拟器的画面与输入: 采集和编码只做一份, 广播给所有观看的网页; 触摸通道共用.
/// 画面状态在 queue 上访问, 触摸在 touchQueue 上发送, 互不阻塞
final class SimulatorStream {
    /// 网络发送跟不上时该观看者跳过增量帧, 从下一个关键帧继续
    static let maxInFlight = 6
    /// 底部 / 顶部边缘手势, 对应 Indigo 消息的边缘字段
    static let edges: [String: UInt8] = ["bottom": 0x01, "top": 0x08]
    /// 浏览器解码器可能滞留最后一帧, 画面静止后补编一帧把它顶出来
    static let trailingDelay: TimeInterval = 0.1

    private let udid: String
    private let queue: DispatchQueue
    private let touchQueue: DispatchQueue
    private let encoder = SimulatorEncoder()
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var screen: SimScreen?
    private var touch: SimTouch?
    private var config: Data?
    private var device: NSObject?
    /// 最近一次设置的方向, 新观看者据此旋转画面; 默认竖屏
    private var orientation: UInt32 = 1
    private var frameSerial = 0
    private var running = false

    private final class Viewer {
        let socket: WebSocketConnection
        var inFlight = 0
        /// 新加入或丢帧后, 等到关键帧再开始发送
        var waitingKeyFrame = true

        init(socket: WebSocketConnection) {
            self.socket = socket
        }
    }

    init(udid: String) {
        self.udid = udid
        queue = DispatchQueue(label: "com.layerlens.live.\(udid)")
        touchQueue = DispatchQueue(label: "com.layerlens.live.touch.\(udid)")
        encoder.onOutput = { [weak self] type, data in
            self?.queue.async { self?.broadcast(type, data) }
        }
    }

    func add(_ socket: WebSocketConnection) {
        let id = ObjectIdentifier(socket)
        socket.onText = { [weak self] text in
            self?.touchQueue.async { self?.handle(text) }
        }
        socket.onClose = { [weak self] in
            self?.queue.async { self?.remove(id) }
        }
        queue.async { [self] in
            viewers[id] = Viewer(socket: socket)
            guard running || start() else {
                socket.close()
                return
            }
            // 新观看者需要解码配置和一个关键帧, 画面静止时也立即补一帧
            if let config {
                send(Data([0x01]) + config, to: viewers[id])
            }
            socket.sendText(orientationMessage)
            encoder.requestKeyFrame()
            if let surface = screen?.surface() {
                encode(surface, trailing: false)
            }
        }
    }

    // MARK: - Screen

    private func start() -> Bool {
        guard let device = SimBridge.device(udid: udid), let screen = SimScreen(device: device, queue: queue) else {
            NSLog("[live] simulator %@ not available", udid)
            return false
        }
        self.screen = screen
        self.device = device
        running = true
        screen.onFrame = { [weak self] surface in
            self?.encode(surface, trailing: false)
        }
        screen.start()
        // 预先建立触摸通道, 首次触摸不必等待
        touchQueue.async { [self] in
            if touch == nil {
                touch = SimTouch(device: device)
            }
        }
        return true
    }

    private func remove(_ id: ObjectIdentifier) {
        viewers[id] = nil
        guard viewers.isEmpty, running else { return }
        running = false
        screen?.stop()
        screen = nil
        encoder.invalidate()
        config = nil
        touchQueue.async { [self] in touch = nil }
    }

    private func encode(_ surface: IOSurface, trailing: Bool) {
        guard running else { return }
        encoder.encode(surface)
        guard !trailing else { return }
        frameSerial += 1
        let serial = frameSerial
        queue.asyncAfter(deadline: .now() + Self.trailingDelay) { [weak self] in
            guard let self, serial == self.frameSerial, let surface = self.screen?.surface() else { return }
            self.encode(surface, trailing: true)
        }
    }

    private func broadcast(_ type: UInt8, _ data: Data) {
        guard running else { return }
        if type == 0x01 {
            config = data
        }
        let frame = Data([type]) + data
        for viewer in viewers.values {
            switch type {
            case 0x01:
                send(frame, to: viewer)
            case 0x02:
                viewer.waitingKeyFrame = false
                send(frame, to: viewer)
            default:
                guard !viewer.waitingKeyFrame else { continue }
                if viewer.inFlight >= Self.maxInFlight {
                    viewer.waitingKeyFrame = true
                    encoder.requestKeyFrame()
                    continue
                }
                send(frame, to: viewer)
            }
        }
    }

    private func send(_ frame: Data, to viewer: Viewer?) {
        guard let viewer else { return }
        viewer.inFlight += 1
        viewer.socket.sendBinary(frame) { [weak self, weak viewer] _ in
            self?.queue.async { viewer?.inFlight -= 1 }
        }
    }

    // MARK: - Orientation

    private var orientationMessage: String {
        "{\"type\":\"orientation\",\"value\":\(orientation)}"
    }

    private func setOrientation(_ value: UInt32) {
        guard (1...4).contains(value), let device, SimBridge.setOrientation(device, value) else { return }
        orientation = value
        let message = orientationMessage
        for viewer in viewers.values {
            viewer.socket.sendText(message)
        }
    }

    // MARK: - Input

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        if type == "orientation" {
            let value = (message["value"] as? NSNumber)?.uint32Value ?? 0
            queue.async { [weak self] in self?.setOrientation(value) }
            return
        }
        guard let touch else { return }
        switch type {
        case "touch1-down", "touch1-move", "touch1-up":
            guard let x = message["x"] as? Double, let y = message["y"] as? Double,
                  let width = message["width"] as? Double, let height = message["height"] as? Double,
                  width > 0, height > 0 else { return }
            let phase: SimTouch.Phase = type == "touch1-down" ? .down : type == "touch1-move" ? .move : .up
            let edge = Self.edges[message["edge"] as? String ?? ""] ?? 0
            touch.send(phase: phase, x: x / width, y: y / height, edge: edge)
        case "button" where message["button"] as? String == "swipe-to-home":
            touch.send(phase: .down, x: 0.5, y: 0.995, edge: 0x01)
            for step in 1...10 {
                usleep(12_000)
                touch.send(phase: .move, x: 0.5, y: 0.995 - 0.05 * Double(step), edge: 0x01)
            }
            touch.send(phase: .up, x: 0.5, y: 0.5, edge: 0x01)
        case "key":
            guard let code = message["code"] as? String else { return }
            SimulatorKeyboard.press(code: code, modifiers: message["modifiers"] as? [String] ?? [], on: touch)
        case "paste":
            guard let text = message["text"] as? String, !text.isEmpty else { return }
            // 写剪贴板要起子进程, 不占用触摸队列
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                guard SimulatorKeyboard.setPasteboard(text, udid: self.udid) else {
                    NSLog("[live] set pasteboard failed")
                    return
                }
                self.touchQueue.async {
                    SimulatorKeyboard.press(code: "KeyV", modifiers: ["command"], on: touch)
                }
            }
        default:
            NSLog("[live] unsupported message: %@", type)
        }
    }
}
