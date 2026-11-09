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
/// 三个队列互不阻塞: queue 管理观看者与发送, captureQueue 采集和编码(每帧约十几毫秒), touchQueue 注入输入
final class SimulatorStream {
    /// 底部 / 顶部边缘手势, 对应 Indigo 消息的边缘字段
    static let edges: [String: UInt8] = ["bottom": 0x01, "top": 0x08]
    /// 浏览器解码器可能滞留最后一帧, 画面静止后补编一帧把它顶出来
    static let trailingDelay: TimeInterval = 0.1
    /// 按住不动时在原位补发移动的间隔, 模拟触摸屏持续上报
    static let holdInterval: DispatchTimeInterval = .milliseconds(30)

    private let udid: String
    private let queue: DispatchQueue
    private let captureQueue: DispatchQueue
    private let touchQueue: DispatchQueue
    private var touch: SimTouch?
    private var homeButton: SimHomeButton?
    /// 尚未注入的最新一条移动, 任意线程写入, moveLock 保护
    private let moveLock = NSLock()
    private var pendingMove: (id: ObjectIdentifier, text: String)?
    // touchQueue 上访问: 正在按下的观看者和位置, 断开时据此补发抬起
    private var touchOwner: ObjectIdentifier?
    private var lastTouch = (x: 0.5, y: 0.5)
    private var lastEdge: UInt8 = 0
    private var holdTimer: DispatchSourceTimer?

    // queue 上访问
    private lazy var video = LiveVideoBroadcaster(queue: queue) { [weak self] in self?.encodeKeyFrame() }
    private var device: NSObject?
    private var running = false
    /// 最近一次设置的方向, 新观看者据此旋转画面; 默认竖屏
    private var orientation: UInt32 = 1

    // captureQueue 上访问
    private let encoder = LiveVideoEncoder()
    private var screen: SimScreen?
    private var frameSerial = 0
    /// 编码比采集慢时只保留最新一帧
    private var pendingSurface: IOSurface?
    private var encoding = false
    private var captureGeneration = 0

    init(udid: String) {
        self.udid = udid
        queue = DispatchQueue(label: "com.layerlens.live.\(udid)")
        captureQueue = DispatchQueue(label: "com.layerlens.live.capture.\(udid)", qos: .userInteractive)
        touchQueue = DispatchQueue(label: "com.layerlens.live.touch.\(udid)")
        encoder.onOutput = { [weak self] type, data in
            self?.queue.async {
                guard let self, self.running else { return }
                self.video.broadcast(type, data)
            }
        }
    }

    func add(_ socket: WebSocketConnection) {
        let id = ObjectIdentifier(socket)
        socket.onText = { [weak self] text in
            self?.receive(text, from: id)
        }
        socket.onClose = { [weak self] in
            self?.queue.async { self?.remove(id) }
        }
        queue.async { [self] in
            guard running || start() else {
                socket.close()
                return
            }
            let active = LiveViewerBudget.shared.join(id) { [weak self] active in
                self?.queue.async { self?.setViewerActive(id, active) }
            }
            socket.sendText(Self.budgetMessage(active))
            video.add(socket, active: active)
            socket.sendText(orientationMessage)
        }
    }

    // MARK: - Viewers

    private func start() -> Bool {
        guard let device = SimBridge.device(udid: udid), let screen = SimScreen(device: device, queue: captureQueue) else {
            LiveLog.write("simulator \(udid) not available")
            return false
        }
        self.device = device
        running = true
        captureQueue.async { [self] in
            captureGeneration += 1
            self.screen = screen
            screen.onFrame = { [weak self] surface in
                self?.capture(surface, trailing: false)
            }
            screen.start()
        }
        // 预先建立触摸通道, 首次触摸不必等待
        touchQueue.async { [self] in
            if touch == nil {
                touch = SimTouch(device: device)
                homeButton = SimHomeButton(device: device)
            }
        }
        return true
    }

    private func remove(_ id: ObjectIdentifier) {
        LiveViewerBudget.shared.leave(id)
        video.remove(id)
        touchQueue.async { [weak self] in self?.releaseTouch(of: id) }
        guard video.isEmpty, running else { return }
        running = false
        video.reset()
        captureQueue.async { [self] in
            captureGeneration += 1
            screen?.stop()
            screen = nil
            pendingSurface = nil
            encoding = false
            encoder.invalidate()
        }
        touchQueue.async { [self] in
            homeButton?.stop()
            homeButton = nil
            touch = nil
        }
    }

    private func requestKeyFrame() { video.requestKeyFrame() }

    private static func budgetMessage(_ active: Bool) -> String {
        "{\"type\":\"video-budget\",\"active\":\(active)}"
    }

    private func setViewerActive(_ id: ObjectIdentifier, _ active: Bool) {
        video.forEachSocket { socket in
            guard ObjectIdentifier(socket) == id else { return }
            socket.sendText(Self.budgetMessage(active))
        }
        video.setActive(active, of: id)
        if !active {
            touchQueue.async { [weak self] in self?.releaseTouch(of: id) }
        }
    }

    private func encodeKeyFrame() {
        guard running else { return }
        captureQueue.async { [self] in
            encoder.requestKeyFrame()
            if let surface = screen?.surface() { capture(surface, trailing: false) }
        }
    }

    /// 网页点击「重新连接画面」时重建采集与编码: 有页面一直连着时推流不会自然重建, 卡住(如锁屏、休眠后)只能这样恢复
    private func restartCapture() {
        guard running else { return }
        LiveLog.write("restart capture \(udid) by request")
        guard let device, let screen = SimScreen(device: device, queue: captureQueue) else {
            LiveLog.write("simulator \(udid) not available")
            return
        }
        captureQueue.async { [self] in
            captureGeneration += 1
            self.screen?.stop()
            pendingSurface = nil
            encoding = false
            encoder.invalidate()
            self.screen = screen
            screen.onFrame = { [weak self] surface in
                self?.capture(surface, trailing: false)
            }
            screen.start()
        }
        // 新的编码会话会重新输出解码配置和关键帧
        video.reset()
        requestKeyFrame()
    }

    // MARK: - Capture

    private func capture(_ surface: IOSurface, trailing: Bool) {
        guard screen != nil else { return }
        if !trailing {
            frameSerial += 1
            let serial = frameSerial
            captureQueue.asyncAfter(deadline: .now() + Self.trailingDelay) { [weak self] in
                guard let self, serial == self.frameSerial, let surface = self.screen?.surface() else { return }
                self.capture(surface, trailing: true)
            }
        }
        pendingSurface = surface
        guard !encoding else { return }
        encoding = true
        // 先让出队列, 期间到达的帧只保留最新一帧
        captureQueue.async { [weak self] in self?.encodePending() }
    }

    private func encodePending() {
        guard video.hasActiveViewers, screen != nil, let surface = pendingSurface else { encoding = false; return }
        pendingSurface = nil
        let generation = captureGeneration
        // 模拟器也始终保留原始分辨率, 避免小窗口下采样影响文字和细节清晰度。
        encoder.encode(surface) { [weak self] in
            self?.captureQueue.async { [weak self] in
                guard let self, generation == self.captureGeneration else { return }
                self.encoding = false
                if self.pendingSurface != nil {
                    self.encoding = true
                    self.encodePending()
                }
            }
        }
    }

    // MARK: - Size

    private func setSize(_ size: (width: Double, height: Double), of id: ObjectIdentifier) {
        video.setSize(size, of: id)
    }

    // MARK: - Orientation

    private var orientationMessage: String {
        "{\"type\":\"orientation\",\"value\":\(orientation)}"
    }

    private func setOrientation(_ value: UInt32) {
        guard (1...4).contains(value), let device, SimBridge.setOrientation(device, value) else { return }
        orientation = value
        let message = orientationMessage
        video.forEachSocket { $0.sendText(message) }
    }

    // MARK: - Input

    /// 移动只保留最新一条: 注入跟不上输入时丢弃中间位置, 不会越积越多导致拖动滞后; 其他消息照常排队, 顺序不变
    private func receive(_ text: String, from id: ObjectIdentifier) {
        guard text.contains("\"touch1-move\"") else {
            touchQueue.async { [weak self] in self?.handle(text, from: id) }
            return
        }
        moveLock.lock()
        let scheduled = pendingMove != nil
        pendingMove = (id, text)
        moveLock.unlock()
        guard !scheduled else { return }
        touchQueue.async { [weak self] in
            guard let self else { return }
            self.moveLock.lock()
            let move = self.pendingMove
            self.pendingMove = nil
            self.moveLock.unlock()
            if let move {
                self.handle(move.text, from: move.id)
            }
        }
    }

    /// 页面断开时手指可能还按着(拖动中关闭页面、网络中断), 补发抬起, 否则模拟器后续的点击会异常
    private func releaseTouch(of id: ObjectIdentifier) {
        guard touchOwner == id, let touch else { return }
        touchOwner = nil
        stopHold()
        touch.send(phase: .up, x: lastTouch.x, y: lastTouch.y)
        LiveLog.write("release touch of closed viewer")
    }

    /// 真实触摸屏在手指按住不动时仍持续上报位置; 只发一次按下的话, 依赖持续触摸事件的长按菜单、长按倍速等手势不会触发,
    /// 因此按下后在原位补发移动, 每次按下或移动都重新计时, 抬起时停止
    private func startHold() {
        let timer = holdTimer ?? {
            let timer = DispatchSource.makeTimerSource(queue: touchQueue)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard self.touchOwner != nil, let touch = self.touch else {
                    self.stopHold()
                    return
                }
                touch.send(phase: .move, x: self.lastTouch.x, y: self.lastTouch.y, edge: self.lastEdge)
            }
            timer.resume()
            holdTimer = timer
            return timer
        }()
        timer.schedule(deadline: .now() + Self.holdInterval, repeating: Self.holdInterval)
    }

    private func stopHold() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func handle(_ text: String, from id: ObjectIdentifier) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        if type == "release" {
            releaseTouch(of: id)
            return
        }
        if type == "orientation" {
            let value = (message["value"] as? NSNumber)?.uint32Value ?? 0
            queue.async { [weak self] in self?.setOrientation(value) }
            return
        }
        if type == "keyframe" {
            queue.async { [weak self] in self?.requestKeyFrame() }
            return
        }
        if type == "viewer-focus" {
            queue.async { LiveViewerBudget.shared.focus(id) }
            return
        }
        if type == "restart" {
            queue.async { [weak self] in self?.restartCapture() }
            return
        }
        if type == "size" {
            guard let width = message["width"] as? Double, let height = message["height"] as? Double, width > 0, height > 0 else { return }
            queue.async { [weak self] in self?.setSize((width, height), of: id) }
            return
        }
        guard video.isActive(id) || ["release", "size"].contains(type) else { return }
        guard let touch else { return }
        switch type {
        case "touch1-down", "touch1-move", "touch1-up":
            guard let x = message["x"] as? Double, let y = message["y"] as? Double,
                  let width = message["width"] as? Double, let height = message["height"] as? Double,
                  width > 0, height > 0 else { return }
            let phase: SimTouch.Phase = type == "touch1-down" ? .down : type == "touch1-move" ? .move : .up
            let edge = Self.edges[message["edge"] as? String ?? ""] ?? 0
            // 拖出画面时停在屏幕边缘, 与手指滑出屏幕一致
            let point = (x: min(max(x / width, 0), 1), y: min(max(y / height, 0), 1))
            touch.send(phase: phase, x: point.x, y: point.y, edge: edge)
            touchOwner = phase == .up ? nil : id
            lastTouch = point
            lastEdge = edge
            if phase == .up {
                stopHold()
            } else {
                startHold()
            }
        case "button" where message["button"] as? String == "swipe-to-home":
            homeButton?.press(legacyPress: { [weak self, weak touch] in
                self?.touchQueue.async { [weak self, weak touch] in
                    guard let self, let touch, self.touch === touch else { return }
                    touch.sendHome(down: true)
                    usleep(30_000)
                    touch.sendHome(down: false)
                }
            }, unavailable: { [weak self] in
                self?.queue.async { [weak self] in
                    self?.video.forEachSocket { socket in
                        guard ObjectIdentifier(socket) == id else { return }
                        socket.sendText("{\"type\":\"input-error\",\"detail\":\"home-unavailable\"}")
                    }
                }
            })
        case "button" where message["button"] as? String == "sleep-wake":
            homeButton?.press(usage: 0x30, legacyPress: { [weak self, weak touch] in
                self?.touchQueue.async { [weak self, weak touch] in
                    guard let self, let touch, self.touch === touch else { return }
                    touch.sendSleepWake(down: true)
                    usleep(30_000)
                    touch.sendSleepWake(down: false)
                }
            }, unavailable: { [weak self] in
                self?.queue.async { [weak self] in
                    self?.video.forEachSocket { socket in
                        guard ObjectIdentifier(socket) == id else { return }
                        socket.sendText("{\"type\":\"input-error\",\"detail\":\"sleep-wake-unavailable\"}")
                    }
                }
            })
        case "button" where message["button"] as? String == "app-switcher":
            // dtuhidd 直接按系统多任务键; 旧版不支持该服务的模拟器改用上滑停顿。
            let gesture: () -> Void = { [weak self, weak touch] in
                self?.touchQueue.async { [weak self, weak touch] in
                    guard let self, let touch, self.touch === touch else { return }
                    touch.send(phase: .down, x: 0.5, y: 0.995, edge: 0x01)
                    let steps = 6
                    for step in 1...steps {
                        usleep(16_000)
                        let progress = Double(step) / Double(steps)
                        let eased = 1 - pow(1 - progress, 3)
                        touch.send(phase: .move, x: 0.5, y: 0.995 - 0.4 * eased, edge: 0x01)
                    }
                    usleep(80_000)
                    touch.send(phase: .up, x: 0.5, y: 0.595, edge: 0x01)
                }
            }
            if let homeButton {
                homeButton.press(
                    usagePage: 0xff01,
                    usage: 0x10,
                    holdMicroseconds: 80_000,
                    legacyPress: gesture,
                    unavailable: gesture
                )
            } else {
                gesture()
            }
        case "key":
            guard let code = message["code"] as? String else { return }
            SimulatorKeyboard.press(code: code, modifiers: message["modifiers"] as? [String] ?? [], on: touch)
        case "paste":
            guard let text = message["text"] as? String, !text.isEmpty else { return }
            // 写剪贴板要起子进程, 不占用触摸队列
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                guard SimulatorKeyboard.setPasteboard(text, udid: self.udid) else {
                    LiveLog.write("set pasteboard failed")
                    return
                }
                self.touchQueue.async {
                    SimulatorKeyboard.press(code: "KeyV", modifiers: ["command"], on: touch)
                }
            }
        default:
            LiveLog.write("unsupported message: \(type)")
        }
    }
}
