//
//  SimulatorLive.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit
import CoreImage
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

    private static let imageContext = CIContext()

    /// 当前屏幕原始分辨率的 PNG; 实时画面按显示尺寸缩小编码, 复制截图不能直接取网页画布
    func screenshot(udid: String) -> Data? {
        guard let device = SimBridge.device(udid: udid),
              let screen = SimScreen(device: device, queue: .global()), let surface = screen.surface() else { return nil }
        let image = CIImage(ioSurface: surface)
        guard let cgImage = Self.imageContext.createCGImage(image, from: image.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// 修复触摸注入: 模拟器重新启动后 backboardd 偶尔不再接收注入的事件, 重启它即可恢复.
    /// 会连带重启 SpringBoard, 前台 App 被结束; 约 10 秒后界面恢复. 同步执行, 不要在网络队列调用
    func healTouch(udid: String) -> Bool {
        guard SimBridge.device(udid: udid) != nil else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid, "launchctl", "stop", "com.apple.backboardd"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            LiveLog.write("heal failed: \(error.localizedDescription)")
            return false
        }
        process.waitUntilExit()
        LiveLog.write("heal touch \(udid): \(process.terminationStatus)")
        return process.terminationStatus == 0
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

/// 实时画面日志, 写入 ~/Library/Logs/LayerLens/live.log, 用于排查黑屏、触摸无效等问题.
/// 超过 maxSize 时改名为 live.1.log(覆盖上一份)后重新开始, 两份合计不超过 2 * maxSize
enum LiveLog {
    static let maxSize: UInt64 = 1_000_000
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayerLens/live.log")
    private static let queue = DispatchQueue(label: "com.layerlens.live.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// 在访达中选中日志文件, 还没有日志时打开所在文件夹
    static func reveal() -> Bool {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return TargetRegistry.run("/usr/bin/open", exists ? ["-R", url.path] : [folder.path]) != nil
    }

    static func write(_ message: String) {
        let time = Date()
        queue.async {
            guard let data = "\(formatter.string(from: time)) \(message)\n".data(using: .utf8) else { return }
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size >= maxSize {
                let previous = url.deletingLastPathComponent().appendingPathComponent("live.1.log")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}
