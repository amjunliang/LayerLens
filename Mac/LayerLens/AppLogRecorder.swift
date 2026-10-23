//
//  AppLogRecorder.swift
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// App 日志: 每个运行中的 App 保持一条到 /api/logs 的事件流, 收到的日志写入
/// ~/Library/Logs/LayerLens/Apps/<Bundle ID>/(App 每次启动一个文件, LayerLens 重启后续写原文件), 并在内存保留最近的部分转发给打开了日志面板的网页.
/// 没有网页订阅时只记录不转发. 所有状态只在 queue 上读写
final class AppLogRecorder {
    static let memoryLimit = 50_000
    static let fileKeep = 20
    /// 网页连上时分批补齐, 网页可以边收边显示
    static let backlogBatch = 5_000
    /// App 每 15 秒发一次心跳, 超过这个时间没有数据视为连接已失效(如锁屏期间被系统回收)
    static let staleInterval: TimeInterval = 40
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayerLens/Apps")
    /// 记在日志文件扩展属性上: 所属的 App 进程和已写入的最大序号, LayerLens 重启后据此找回文件续写
    static let instanceAttribute = "com.layerlens.instance"
    static let seqAttribute = "com.layerlens.seq"

    struct Entry {
        let id: Int
        let time: Double
        let text: String
        /// 非日志的标记行, 如 restart 表示 App 重新启动
        var kind: String?

        var json: [String: Any] {
            kind.map { ["i": id, "t": time, "k": $0] } ?? ["i": id, "t": time, "m": text]
        }
    }

    /// 同一设备上同一 App 的日志, App 重启后继续使用, 中间插入一条标记
    final class Source {
        let deviceId: String
        let bundleId: String
        var deviceName = ""
        /// 当前日志所属的进程, 换了即为重启, 序号从头开始
        var instanceId = ""
        var lastSeq: UInt64 = 0
        var nextId = 1
        var entries: [Entry] = []
        var upstream: NWConnection?
        var upstreamInstance = ""
        var lastReceive = Date()
        /// 旧版 Pod 没有日志接口的进程, 不再重试
        var unsupported: Set<String> = []
        var file: FileHandle?
        var fileURL: URL?
        /// 已写入文件的最大序号, LayerLens 重启后 App 会重发内存中的日志, 已写过的不再写入
        var fileSeq: UInt64 = 0
        var subscribers: [ObjectIdentifier: NWConnection] = [:]

        init(deviceId: String, bundleId: String) {
            self.deviceId = deviceId
            self.bundleId = bundleId
        }

        var isUnsupported: Bool {
            !upstreamInstance.isEmpty && unsupported.contains(upstreamInstance)
        }
    }

    private let queue = DispatchQueue(label: "com.layerlens.applog")
    private var sources: [String: Source] = [:]
    private let timeFormatter = AppLogRecorder.formatter("yyyy-MM-dd HH:mm:ss.SSS")
    private let fileFormatter = AppLogRecorder.formatter("yyyy-MM-dd_HH-mm-ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private func source(deviceId: String, bundleId: String) -> Source {
        let key = deviceId + "|" + bundleId
        if let source = sources[key] {
            return source
        }
        let source = Source(deviceId: deviceId, bundleId: bundleId)
        sources[key] = source
        return source
    }

    // MARK: - Upstream

    /// 每次扫描后调用: 为运行中的 App 建立日志流, 失效的重新连接; 挂起的 App 保持原连接等它回到前台
    func update(apps: [AppRecord]) {
        queue.async { [self] in
            for app in apps where !app.suspended {
                guard let instanceId = app.info["instanceId"] as? String, !instanceId.isEmpty else { continue }
                let source = source(deviceId: app.deviceId, bundleId: app.bundleId)
                if let name = app.info["deviceName"] as? String, !name.isEmpty {
                    source.deviceName = name
                }
                if source.unsupported.contains(instanceId) { continue }
                if source.upstreamInstance == instanceId, source.upstream != nil, Date().timeIntervalSince(source.lastReceive) < Self.staleInterval { continue }
                source.upstream?.cancel()
                source.upstream = nil
                connect(source, endpoint: app.endpoint, instanceId: instanceId)
            }
        }
    }

    private func connect(_ source: Source, endpoint: TargetEndpoint, instanceId: String) {
        source.upstreamInstance = instanceId
        source.lastReceive = Date()
        let since = source.instanceId == instanceId ? source.lastSeq : 0
        let request = HTTPClient.request(method: "GET", path: "/api/logs?since=\(since)", host: "127.0.0.1:\(endpoint.port)")
        switch endpoint {
        case .local(let port):
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            source.upstream = connection
            start(connection, source: source, request: request)
            connection.start(queue: queue)
        case .usb(let deviceId, let port):
            // 连接建立前先占位, 避免下次扫描重复连接
            let placeholder = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            source.upstream = placeholder
            Usbmux.connect(deviceId: deviceId, port: port, queue: queue) { [weak self] connection, _ in
                guard let self, source.upstream === placeholder else {
                    connection?.cancel()
                    return
                }
                guard let connection else {
                    source.upstream = nil
                    return
                }
                source.upstream = connection
                self.start(connection, source: source, request: request)
            }
        }
    }

    /// 本机连接在 ready 后发送请求; usbmuxd 返回的连接已启动, 直接发送
    private func start(_ connection: NWConnection, source: Source, request: Data) {
        let send = { [weak self] in
            connection.send(content: request, completion: .contentProcessed { _ in })
            self?.receive(connection, source: source, buffer: Data(), headerDone: false)
        }
        let started = connection.state != .setup
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !started {
                    send()
                }
            case .failed, .waiting:
                self?.disconnect(connection, source: source)
            default:
                break
            }
        }
        if started {
            send()
        }
    }

    private func disconnect(_ connection: NWConnection, source: Source) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        if source.upstream === connection {
            source.upstream = nil
        }
    }

    private func receive(_ connection: NWConnection, source: Source, buffer: Data, headerDone: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard source.upstream === connection else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
                source.lastReceive = Date()
            }
            var headerDone = headerDone
            if !headerDone, let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let statusLine = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
                guard status == 200 else {
                    if status == 404 {
                        source.unsupported.insert(source.upstreamInstance)
                        self.broadcast(source, "status", ["unsupported": true])
                    }
                    self.disconnect(connection, source: source)
                    return
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                headerDone = true
            }
            if headerDone {
                // 事件之间以空行分隔
                while let range = buffer.range(of: Data("\n\n".utf8)) {
                    let block = Data(buffer[buffer.startIndex..<range.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    self.handleEvent(block, source: source)
                }
            }
            if isComplete || error != nil {
                self.disconnect(connection, source: source)
                return
            }
            self.receive(connection, source: source, buffer: buffer, headerDone: headerDone)
        }
    }

    private func handleEvent(_ block: Data, source: Source) {
        var name = ""
        var payload = Data()
        for line in block.split(separator: UInt8(ascii: "\n")) {
            if line.starts(with: Data("event: ".utf8)) {
                name = String(decoding: line.dropFirst(7), as: UTF8.self)
            } else if line.starts(with: Data("data: ".utf8)) {
                payload.append(line.dropFirst(6))
            }
        }
        guard name == "logs", let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
        if let instanceId = json["instanceId"] as? String, instanceId != source.instanceId {
            let restarted = !source.instanceId.isEmpty
            source.instanceId = instanceId
            source.lastSeq = 0
            source.fileSeq = 0
            source.file?.closeFile()
            source.file = nil
            if !restarted {
                resumeFile(source)
            }
            if restarted {
                append([Entry(id: source.nextId, time: Date().timeIntervalSince1970 * 1000, text: "", kind: "restart")], to: source)
                source.nextId += 1
            }
        }
        var added: [Entry] = []
        var unwritten: [Entry] = []
        for item in json["entries"] as? [[String: Any]] ?? [] {
            guard let seq = (item["s"] as? NSNumber)?.uint64Value, seq > source.lastSeq else { continue }
            source.lastSeq = seq
            let entry = Entry(id: source.nextId, time: (item["t"] as? NSNumber)?.doubleValue ?? 0, text: item["m"] as? String ?? "")
            added.append(entry)
            if seq > source.fileSeq {
                unwritten.append(entry)
            }
            source.nextId += 1
        }
        guard !added.isEmpty else { return }
        if !unwritten.isEmpty {
            write(unwritten, source: source)
            source.fileSeq = source.lastSeq
            if let url = source.fileURL {
                Self.setAttribute(Self.seqAttribute, String(source.fileSeq), of: url)
            }
        }
        append(added, to: source)
    }

    private func append(_ entries: [Entry], to source: Source) {
        source.entries.append(contentsOf: entries)
        // 超出一成再裁剪, 不必每批都移动数组
        if source.entries.count > Self.memoryLimit + Self.memoryLimit / 10 {
            source.entries.removeFirst(source.entries.count - Self.memoryLimit)
        }
        broadcast(source, "logs", ["entries": entries.map(\.json)])
    }

    // MARK: - File

    private func write(_ entries: [Entry], source: Source) {
        if source.file == nil {
            let folder = Self.folder.appendingPathComponent(Self.sanitize(source.bundleId))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = fileFormatter.string(from: Date()) + "_" + Self.sanitize(source.deviceName.isEmpty ? source.deviceId : source.deviceName) + ".log"
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            source.file = try? FileHandle(forWritingTo: url)
            source.fileURL = url
            Self.setAttribute(Self.instanceAttribute, source.instanceId, of: url)
            Self.removeOldFiles(in: folder)
        }
        let text = entries.map { "[\(timeFormatter.string(from: Date(timeIntervalSince1970: $0.time / 1000)))] \($0.text)\n" }.joined()
        try? source.file?.write(contentsOf: Data(text.utf8))
    }

    /// LayerLens 重启后找回同一次 App 运行的文件接着写
    private func resumeFile(_ source: Source) {
        let folder = Self.folder.appendingPathComponent(Self.sanitize(source.bundleId))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let url = files.first(where: { $0.pathExtension == "log" && Self.attribute(Self.instanceAttribute, of: $0) == source.instanceId }),
              let file = try? FileHandle(forWritingTo: url) else { return }
        _ = try? file.seekToEnd()
        source.file = file
        source.fileURL = url
        source.fileSeq = UInt64(Self.attribute(Self.seqAttribute, of: url) ?? "") ?? 0
    }

    private static func attribute(_ name: String, of url: URL) -> String? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        return read == length ? String(decoding: data, as: UTF8.self) : nil
    }

    private static func setAttribute(_ name: String, _ value: String, of url: URL) {
        let data = Data(value.utf8)
        _ = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private static func removeOldFiles(in folder: URL) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.filter { $0.pathExtension == "log" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        sorted.dropFirst(fileKeep).forEach { try? manager.removeItem(at: $0) }
    }

    // MARK: - Subscribers

    /// 网页打开日志面板: 先发 reset 和内存中的日志, 之后转发新日志, 直到网页断开
    func subscribe(deviceId: String, bundleId: String, connection: NWConnection) {
        queue.async { [self] in
            let source = source(deviceId: deviceId, bundleId: bundleId)
            let id = ObjectIdentifier(connection)
            source.subscribers[id] = connection
            var data = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 2000\n\n".utf8)
            data.append(Self.event("reset", ["unsupported": source.isUnsupported]))
            let entries = source.entries
            for start in stride(from: 0, to: entries.count, by: Self.backlogBatch) {
                data.append(Self.event("logs", ["entries": entries[start..<min(start + Self.backlogBatch, entries.count)].map(\.json)]))
            }
            connection.send(content: data, completion: .contentProcessed { _ in })
            watchClose(connection) { [weak self] in
                self?.queue.async {
                    source.subscribers[id] = nil
                }
            }
        }
    }

    /// 持续读取, 网页关闭时及时释放
    private func watchClose(_ connection: NWConnection, onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
                onClose()
                return
            }
            self?.watchClose(connection, onClose: onClose)
        }
    }

    private func broadcast(_ source: Source, _ name: String, _ object: [String: Any]) {
        guard !source.subscribers.isEmpty else { return }
        let data = Self.event(name, object)
        for connection in source.subscribers.values {
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    connection.cancel()
                }
            })
        }
    }

    private static func event(_ name: String, _ object: [String: Any]) -> Data {
        var data = Data("event: \(name)\ndata: ".utf8)
        data.append((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        data.append(Data("\n\n".utf8))
        return data
    }

    // MARK: - Actions

    /// 清空内存中的日志(文件保留), 所有打开的面板一起清空
    func clear(deviceId: String, bundleId: String) {
        queue.async { [self] in
            let source = source(deviceId: deviceId, bundleId: bundleId)
            source.entries = []
            broadcast(source, "reset", ["unsupported": source.isUnsupported])
        }
    }

    /// 导出到下载文件夹并在访达中选中; text 为空时导出内存中的全部日志
    func export(deviceId: String, bundleId: String, text: String?, completion: @escaping (URL?) -> Void) {
        queue.async { [self] in
            let source = source(deviceId: deviceId, bundleId: bundleId)
            let content = text ?? source.entries.filter { $0.kind == nil }.map { "[\(timeFormatter.string(from: Date(timeIntervalSince1970: $0.time / 1000)))] \($0.text)\n" }.joined()
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
            let url = downloads.appendingPathComponent(Self.sanitize(bundleId.isEmpty ? "LayerLens" : bundleId) + "_" + fileFormatter.string(from: Date()) + ".log")
            do {
                try Data(content.utf8).write(to: url)
            } catch {
                completion(nil)
                return
            }
            _ = TargetRegistry.run("/usr/bin/open", ["-R", url.path])
            completion(url)
        }
    }

    /// 在访达中选中当前的日志文件, 还没有时打开日志文件夹
    func reveal(deviceId: String, bundleId: String, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let source = sources[deviceId + "|" + bundleId]
            let ok: Bool
            if let url = source?.fileURL, FileManager.default.fileExists(atPath: url.path) {
                ok = TargetRegistry.run("/usr/bin/open", ["-R", url.path]) != nil
            } else {
                let folder = bundleId.isEmpty ? Self.folder : Self.folder.appendingPathComponent(Self.sanitize(bundleId))
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                ok = TargetRegistry.run("/usr/bin/open", [folder.path]) != nil
            }
            completion(ok)
        }
    }
}
