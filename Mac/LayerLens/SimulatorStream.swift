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
    /// 网络发送跟不上时该观看者跳过增量帧, 从下一个关键帧继续
    static let maxInFlight = 6
    /// 底部 / 顶部边缘手势, 对应 Indigo 消息的边缘字段
    static let edges: [String: UInt8] = ["bottom": 0x01, "top": 0x08]
    /// 浏览器解码器可能滞留最后一帧, 画面静止后补编一帧把它顶出来
    static let trailingDelay: TimeInterval = 0.1
    /// 强制关键帧的最小间隔, 关键帧较大, 频繁出现会拉低所有观看者的帧率
    static let keyFrameInterval: TimeInterval = 0.5

    private let udid: String
    private let queue: DispatchQueue
    private let captureQueue: DispatchQueue
    private let touchQueue: DispatchQueue
    private var touch: SimTouch?
    /// 尚未注入的最新一条移动, 任意线程写入, moveLock 保护
    private let moveLock = NSLock()
    private var pendingMove: (id: ObjectIdentifier, text: String)?
    // touchQueue 上访问: 正在按下的观看者和位置, 断开时据此补发抬起
    private var touchOwner: ObjectIdentifier?
    private var lastTouch = (x: 0.5, y: 0.5)

    // queue 上访问
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var device: NSObject?
    private var config: Data?
    private var running = false
    private var lastKeyFrameRequest: TimeInterval = 0
    private var keyFrameScheduled = false
    /// 最近一次设置的方向, 新观看者据此旋转画面; 默认竖屏
    private var orientation: UInt32 = 1

    // captureQueue 上访问
    private let encoder = SimulatorEncoder()
    private var screen: SimScreen?
    private var frameSerial = 0
    /// 编码比采集慢时只保留最新一帧
    private var pendingSurface: IOSurface?
    private var encoding = false
    /// 按观看者中最大的显示尺寸编码, nil 时为原始分辨率
    private var targetSize: (width: Double, height: Double)?

    private final class Viewer {
        let socket: WebSocketConnection
        var inFlight = 0
        /// 新加入或丢帧后, 等到关键帧再开始发送
        var waitingKeyFrame = true
        /// 丢帧后等积压发完再申请关键帧, 收不动的页面(如被节流的后台标签)不会反复触发
        var recovering = false
        /// 画面在页面上显示的像素尺寸, 未上报(旧版页面)时按原始分辨率编码
        var size: (width: Double, height: Double)?

        init(socket: WebSocketConnection) {
            self.socket = socket
        }
    }

    init(udid: String) {
        self.udid = udid
        queue = DispatchQueue(label: "com.layerlens.live.\(udid)")
        captureQueue = DispatchQueue(label: "com.layerlens.live.capture.\(udid)", qos: .userInteractive)
        touchQueue = DispatchQueue(label: "com.layerlens.live.touch.\(udid)")
        encoder.onOutput = { [weak self] type, data in
            self?.queue.async { self?.broadcast(type, data) }
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
            viewers[id] = Viewer(socket: socket)
            updateTargetSize()
            guard running || start() else {
                socket.close()
                return
            }
            // 新观看者需要解码配置和一个关键帧, 画面静止时也立即补一帧
            if let config {
                send(Data([0x01]) + config, to: viewers[id])
            }
            socket.sendText(orientationMessage)
            requestKeyFrame()
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
            }
        }
        return true
    }

    private func remove(_ id: ObjectIdentifier) {
        viewers[id] = nil
        updateTargetSize()
        touchQueue.async { [weak self] in self?.releaseTouch(of: id) }
        guard viewers.isEmpty, running else { return }
        running = false
        config = nil
        captureQueue.async { [self] in
            screen?.stop()
            screen = nil
            pendingSurface = nil
            encoder.invalidate()
        }
        touchQueue.async { [self] in touch = nil }
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
                    viewer.recovering = true
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
            self?.queue.async {
                guard let self, let viewer else { return }
                viewer.inFlight -= 1
                if viewer.recovering && viewer.inFlight == 0 {
                    viewer.recovering = false
                    self.requestKeyFrame()
                }
            }
        }
    }

    /// 下一帧编为关键帧并立即补编当前画面, 画面静止时也能恢复; 限制频率, 间隔内的请求合并
    private func requestKeyFrame() {
        guard running, !keyFrameScheduled else { return }
        let wait = lastKeyFrameRequest + Self.keyFrameInterval - CFAbsoluteTimeGetCurrent()
        guard wait <= 0 else {
            keyFrameScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.keyFrameScheduled = false
                self?.requestKeyFrame()
            }
            return
        }
        lastKeyFrameRequest = CFAbsoluteTimeGetCurrent()
        captureQueue.async { [self] in
            encoder.requestKeyFrame()
            if let surface = screen?.surface() {
                capture(surface, trailing: false)
            }
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
        config = nil
        for viewer in viewers.values {
            viewer.waitingKeyFrame = true
        }
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
        defer { encoding = false }
        guard screen != nil, let surface = pendingSurface else { return }
        pendingSurface = nil
        encoder.encode(surface, scale: encodeScale(of: surface))
    }

    /// 编码比例按 1/16 取整(向上), 缩放画面时不会每一点变化都重建编码器
    private func encodeScale(of surface: IOSurface) -> Double {
        guard let targetSize else { return 1 }
        let width = Double(IOSurfaceGetWidth(surface))
        let height = Double(IOSurfaceGetHeight(surface))
        guard width > 0, height > 0 else { return 1 }
        let ratio = max(targetSize.width / width, targetSize.height / height)
        return min((ratio * 16).rounded(.up) / 16, 1)
    }

    // MARK: - Size

    private func setSize(_ size: (width: Double, height: Double), of id: ObjectIdentifier) {
        guard let viewer = viewers[id] else { return }
        viewer.size = size
        updateTargetSize()
    }

    /// 取所有观看者中最大的显示尺寸; 有未上报的观看者时用原始分辨率. 变化后立即重编当前画面, 画面静止时也能更新
    private func updateTargetSize() {
        var target: (width: Double, height: Double)? = (0, 0)
        for viewer in viewers.values {
            guard let size = viewer.size, let current = target else {
                target = nil
                break
            }
            target = (max(current.width, size.width), max(current.height, size.height))
        }
        if let current = target, current.width <= 0 || current.height <= 0 {
            target = nil
        }
        captureQueue.async { [self] in
            let changed = targetSize?.width != target?.width || targetSize?.height != target?.height
            targetSize = target
            if changed, let surface = screen?.surface() {
                capture(surface, trailing: false)
            }
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
        touch.send(phase: .up, x: lastTouch.x, y: lastTouch.y)
        LiveLog.write("release touch of closed viewer")
    }

    private func handle(_ text: String, from id: ObjectIdentifier) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        if type == "orientation" {
            let value = (message["value"] as? NSNumber)?.uint32Value ?? 0
            queue.async { [weak self] in self?.setOrientation(value) }
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
        case "button" where message["button"] as? String == "swipe-to-home":
            touch.send(phase: .down, x: 0.5, y: 0.995, edge: 0x01)
            for step in 1...10 {
                usleep(12_000)
                touch.send(phase: .move, x: 0.5, y: 0.995 - 0.05 * Double(step), edge: 0x01)
            }
            touch.send(phase: .up, x: 0.5, y: 0.5, edge: 0x01)
        case "button" where message["button"] as? String == "app-switcher":
            // 上滑到屏幕中部时先快后慢(缓出), 末速度接近 0 即被识别为停顿而进入多任务, 不必久停
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
