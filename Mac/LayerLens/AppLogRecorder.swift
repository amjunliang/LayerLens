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
    /// 网页连上时分批补齐, 网页可以边收边显示
    static let backlogBatch = 5_000
    /// App 每 15 秒发一次心跳, 超过这个时间没有数据视为连接已失效(如锁屏期间被系统回收)
    static let staleInterval: TimeInterval = 40
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LayerLens/Apps")
    /// 记在日志文件扩展属性上: 所属的 App 进程和已写入的最大序号, LayerLens 重启后据此找回文件续写
    static let instanceAttribute = "com.layerlens.instance"
    static let seqAttribute = "com.layerlens.seq"
    private static let pendingAttribute = "com.layerlens.pending-write"
    /// 所属设备, LayerLens 重启后据此找回该设备最近的日志
    static let deviceAttribute = "com.layerlens.device"

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

    /// 同一设备上同一 App 当前启动的日志; 历史启动仅保存在各自文件中
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
        var lastUse = Date()
        var present = false
        var memoryBytes = 0
        var storageError = ""
        /// 旧版 Pod 没有日志接口的进程, 不再重试
        var unsupported: Set<String> = []
        var file: FileHandle?
        var fileURL: URL?
        /// 已写入文件的最大序号, LayerLens 重启后 App 会重发内存中的日志, 已写过的不再写入
        var fileSeq: UInt64 = 0
        var subscribers: [ObjectIdentifier: BoundedStreamWriter] = [:]

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
    private let storageFolder: URL
    private let now: () -> Date
    init(folder: URL = AppLogRecorder.folder, now: @escaping () -> Date = Date.init) { storageFolder = folder; self.now = now }

    func connectionSummary(completion: @escaping ([String: Int]) -> Void) {
        queue.async { [self] in
            completion(["connections": sources.values.filter { $0.upstream != nil }.count,
                        "files": sources.values.filter { $0.file != nil }.count,
                        "storageErrors": sources.values.filter { !$0.storageError.isEmpty }.count, "cachedSources": sources.count, "cacheBytes": sources.values.reduce(0) { $0 + $1.memoryBytes }])
        }
    }
    private let timeFormatter = AppLogRecorder.formatter("yyyy-MM-dd HH:mm:ss.SSS")
    private let fileFormatter = AppLogRecorder.formatter("yyyy-MM-dd_HH-mm-ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private func source(deviceId: String, bundleId: String, deviceName: String = "") -> Source {
        let key = deviceId + "|" + bundleId
        if let source = sources[key] {
            return source
        }
        let source = Source(deviceId: deviceId, bundleId: bundleId)
        source.deviceName = deviceName
        source.lastUse = now()
        sources[key] = source
        restore(source)
        return source
    }

    // MARK: - Upstream

    /// 每次扫描后调用: 为运行中的 App 建立日志流, 失效的重新连接; 挂起的 App 保持原连接等它回到前台
    func update(apps: [AppRecord]) {
        queue.async { [self] in
            let present = Set(apps.map { $0.deviceId + "|" + $0.bundleId })
            for (key, source) in sources {
                source.present = present.contains(key)
                if source.present { source.lastUse = now() }
                else {
                    if let upstream = source.upstream { disconnect(upstream, source: source) }
                    source.file?.closeFile(); source.file = nil
                }
            }
            for app in apps where app.responding {
                guard let instanceId = app.info["instanceId"] as? String, !instanceId.isEmpty else { continue }
                let source = source(deviceId: app.deviceId, bundleId: app.bundleId, deviceName: app.info["deviceName"] as? String ?? "")
                if let name = app.info["deviceName"] as? String, !name.isEmpty {
                    source.deviceName = name
                }
                if source.unsupported.contains(instanceId) { continue }
                if source.upstreamInstance == instanceId, source.upstream != nil, Date().timeIntervalSince(source.lastReceive) < Self.staleInterval { continue }
                source.upstream?.cancel()
                source.upstream = nil
                source.present = true
                connect(source, endpoint: app.endpoint, instanceId: instanceId)
            }
            pruneCaches()
        }
    }

    private func pruneCaches() {
        let items = sources.map { key, source in
            RecorderCache.Item(id: key, bytes: source.memoryBytes, lastUse: source.lastUse,
                               pinned: source.present || !source.subscribers.isEmpty)
        }
        for key in RecorderCache.evictions(items, now: now()) {
            guard let source = sources.removeValue(forKey: key) else { continue }
            source.upstream?.cancel()
            source.file?.closeFile()
        }
    }

    func stop() {
        queue.sync {
            for source in sources.values { source.upstream?.cancel(); source.file?.closeFile(); source.subscribers.values.forEach { $0.cancel() } }
            sources.removeAll()
        }
    }

    private func connect(_ source: Source, endpoint: TargetEndpoint, instanceId: String) {
        source.upstreamInstance = instanceId
        source.lastReceive = Date()
        let since = source.instanceId == instanceId ? source.fileSeq : 0
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
                    if source.upstream !== connection { return }
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
            source.instanceId = instanceId
            source.lastSeq = 0
            source.fileSeq = 0
            source.file?.closeFile()
            source.file = nil
            source.fileURL = nil
            source.entries = []
            source.memoryBytes = 0
            source.storageError = ""
            // 新启动替换实时列表; 断线重连的 instanceId 不变, 不会走这里。
            // 仍恢复该实例的持久断点, 防止重放已保存或已清空的日志。
            do { try resumeFile(source) }
            catch { source.storageError = error.localizedDescription }
            broadcast(source, "reset", ["unsupported": source.isUnsupported, "storageError": source.storageError])
            if !source.storageError.isEmpty {
                if let connection = source.upstream { disconnect(connection, source: source) }
                return
            }
        }
        var added: [Entry] = []
        var sequence = source.fileSeq
        for item in json["entries"] as? [[String: Any]] ?? [] {
            guard let seq = (item["s"] as? NSNumber)?.uint64Value, seq > sequence else { continue }
            sequence = seq
            added.append(Entry(id: source.nextId + added.count, time: (item["t"] as? NSNumber)?.doubleValue ?? 0, text: item["m"] as? String ?? ""))
        }
        guard !added.isEmpty else { return }
        do {
            try write(added, sequence: sequence, source: source)
            source.fileSeq = sequence
            source.lastSeq = sequence
            source.nextId += added.count
            if !source.storageError.isEmpty {
                source.storageError = ""
                broadcast(source, "status", ["unsupported": source.isUnsupported, "storageError": ""])
            }
            append(added, to: source)
        } catch {
            source.storageError = error.localizedDescription
            broadcast(source, "status", ["unsupported": source.isUnsupported, "storageError": source.storageError])
            // Stop consuming this stream. Reconnect from the last durable sequence, not received bytes.
            if let connection = source.upstream { disconnect(connection, source: source) }
        }
    }

    private func append(_ entries: [Entry], to source: Source) {
        source.entries.append(contentsOf: entries)
        source.memoryBytes += entries.reduce(0) { $0 + $1.text.utf8.count + 64 }
        if source.entries.count > Self.memoryLimit + Self.memoryLimit / 10 || source.memoryBytes > RecorderCache.byteLimit {
            var count = 0, bytes = source.memoryBytes
            while count < source.entries.count && (source.entries.count - count > Self.memoryLimit || bytes > RecorderCache.byteLimit) {
                bytes -= source.entries[count].text.utf8.count + 64; count += 1
            }
            source.entries.removeFirst(count); source.memoryBytes = bytes
        }
        broadcast(source, "logs", ["entries": entries.map(\.json)])
        pruneCaches()
    }

    // MARK: - File

    private func write(_ entries: [Entry], sequence: UInt64, source: Source) throws {
        if source.file == nil && !source.instanceId.isEmpty { try resumeFile(source) }
        if source.file == nil {
            let folder = storageFolder.appendingPathComponent(Self.sanitize(source.bundleId))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let suffix = "_" + Self.sanitize(source.deviceId) + "_" + Self.sanitize(source.instanceId)
            let base = fileFormatter.string(from: Date()) + "_" + Self.sanitize(source.deviceName.isEmpty ? source.deviceId : source.deviceName) + suffix
            var url = folder.appendingPathComponent(base + ".log")
            var fd: Int32 = -1
            // O_EXCL prevents an existing log from ever being truncated, even under a filename collision.
            for attempt in 0..<10 {
                if attempt > 0 { url = folder.appendingPathComponent(base + "_" + UUID().uuidString + ".log") }
                fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                if fd >= 0 || errno != EEXIST { break }
            }
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try Self.setRequiredAttribute(Self.instanceAttribute, source.instanceId, of: url)
                try Self.setRequiredAttribute(Self.deviceAttribute, source.deviceId, of: url)
            } catch {
                try? file.close(); try? FileManager.default.removeItem(at: url); throw error
            }
            source.file = file; source.fileURL = url
        }
        guard let file = source.file, let url = source.fileURL else { throw CocoaError(.fileWriteUnknown) }
        let offset = try file.seekToEnd()
        let text = entries.map { "[\(timeFormatter.string(from: Date(timeIntervalSince1970: $0.time / 1000)))] \($0.text)\n" }.joined()
        do {
            try Self.setRequiredAttribute(Self.pendingAttribute, "\(offset):\(sequence)", of: url)
            try file.write(contentsOf: Data(text.utf8))
            try file.synchronize()
            try Self.setRequiredAttribute(Self.seqAttribute, String(sequence), of: url)
            _ = removexattr(url.path, Self.pendingAttribute, 0)
        } catch {
            // A failed write may have appended a prefix: roll it back before requesting the batch again.
            do { try file.truncate(atOffset: offset); try file.synchronize() }
            catch {
                // Keep the open file for an explicit retry; never acknowledge or silently skip this batch.
                source.storageError = "Log write and rollback failed: " + error.localizedDescription
            }
            try? file.close(); source.file = nil
            throw error
        }
    }

    /// LayerLens 重启后读回该设备最近的日志文件, App 未运行时日志面板也有内容; 同时接着写这个文件,
    /// App 仍是同一次运行时只补齐之后的日志, 换了一次运行时按重启处理.
    /// 旧版本写的文件没有设备标记, 按文件名中的设备名匹配
    private func restore(_ source: Source) {
        let manager = FileManager.default
        let folder = storageFolder.appendingPathComponent(Self.sanitize(source.bundleId))
        let files = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "log" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        let suffix = "_" + Self.sanitize(source.deviceName)
        guard let url = files.first(where: { Self.attribute(Self.deviceAttribute, of: $0) == source.deviceId })
                ?? files.first(where: { !source.deviceName.isEmpty && Self.attribute(Self.deviceAttribute, of: $0) == nil && $0.deletingPathExtension().lastPathComponent.hasSuffix(suffix) }),
              let reader = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? reader.close() }
        if Self.attribute(Self.pendingAttribute, of: url) != nil {
            do {
                let writer = try FileHandle(forWritingTo: url)
                defer { try? writer.close() }
                try Self.recoverWrite(writer, at: url)
            } catch { source.storageError = error.localizedDescription; return }
        }
        let size = (try? reader.seekToEnd()) ?? 0
        try? reader.seek(toOffset: size > UInt64(RecorderCache.byteLimit) ? size - UInt64(RecorderCache.byteLimit) : 0)
        guard let data = try? reader.readToEnd() else { return }
        var entries: [Entry] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            // 每条以 [时间] 开头, 其余为上一条的续行
            if line.count > 26, line.hasPrefix("["), line.dropFirst(24).hasPrefix("] "), let date = timeFormatter.date(from: String(line.dropFirst().prefix(23))) {
                entries.append(Entry(id: 0, time: date.timeIntervalSince1970 * 1000, text: String(line.dropFirst(26))))
            } else if let last = entries.popLast() {
                entries.append(Entry(id: 0, time: last.time, text: last.text + "\n" + line))
            }
        }
        // 文件末尾的换行不算续行
        if let last = entries.popLast() {
            entries.append(Entry(id: 0, time: last.time, text: last.text.hasSuffix("\n") ? String(last.text.dropLast()) : last.text))
        }
        source.entries = entries.suffix(Self.memoryLimit).map {
            defer { source.nextId += 1 }
            return Entry(id: source.nextId, time: $0.time, text: $0.text)
        }
        source.memoryBytes = source.entries.reduce(0) { $0 + $1.text.utf8.count + 64 }
        if let instanceId = Self.attribute(Self.instanceAttribute, of: url), let file = try? FileHandle(forWritingTo: url) {
            _ = try? file.seekToEnd()
            source.instanceId = instanceId
            source.file = file
            source.fileURL = url
            source.fileSeq = UInt64(Self.attribute(Self.seqAttribute, of: url) ?? "") ?? 0
            source.lastSeq = source.fileSeq
        }
    }

    /// LayerLens 重启后找回同一次 App 运行的文件接着写
    private func resumeFile(_ source: Source) throws {
        let folder = storageFolder.appendingPathComponent(Self.sanitize(source.bundleId))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let url = files.first(where: { $0.pathExtension == "log" && Self.attribute(Self.instanceAttribute, of: $0) == source.instanceId && (Self.attribute(Self.deviceAttribute, of: $0) == nil || Self.attribute(Self.deviceAttribute, of: $0) == source.deviceId) }) else { return }
        let file = try FileHandle(forWritingTo: url)
        do { try Self.recoverWrite(file, at: url); _ = try file.seekToEnd() }
        catch { try? file.close(); throw error }
        source.file = file; source.fileURL = url
        source.fileSeq = UInt64(Self.attribute(Self.seqAttribute, of: url) ?? "") ?? 0
    }

    private static func recoverWrite(_ file: FileHandle, at url: URL) throws {
        guard let pending = attribute(pendingAttribute, of: url) else { return }
        let parts = pending.split(separator: ":")
        guard parts.count == 2, let offset = UInt64(parts[0]), let sequence = UInt64(parts[1]) else { throw CocoaError(.fileReadCorruptFile) }
        if (UInt64(attribute(seqAttribute, of: url) ?? "") ?? 0) < sequence {
            try file.truncate(atOffset: offset); try file.synchronize()
        }
        _ = removexattr(url.path, pendingAttribute, 0)
    }

    /// 本机保存的日志所属的设备 ID -> Bundle ID; 只含记了所属设备的文件
    static func savedApps() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let manager = FileManager.default
        for bundle in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where !bundle.lastPathComponent.hasPrefix(".") {
            for url in (try? manager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "log" {
                guard let deviceId = attribute(deviceAttribute, of: url), !deviceId.isEmpty else { continue }
                result[deviceId, default: []].insert(bundle.lastPathComponent)
            }
        }
        return result
    }

    static func attribute(_ name: String, of url: URL) -> String? {
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

    private static func setRequiredAttribute(_ name: String, _ value: String, of url: URL) throws {
        let data = Data(value.utf8)
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// 缓存管理删除了文件: 正在写的文件关闭, 之后的日志写入新文件
    func didDelete(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        queue.async { [self] in
            for source in sources.values {
                guard let path = source.fileURL?.standardizedFileURL.path, paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                source.file?.closeFile()
                source.file = nil
                source.fileURL = nil
            }
        }
    }

    // MARK: - Subscribers

    /// 网页打开日志面板: 先发 reset 和内存中的日志, 之后转发新日志, 直到网页断开
    func subscribe(deviceId: String, bundleId: String, connection: NWConnection) {
        queue.async { [self] in
            let source = source(deviceId: deviceId, bundleId: bundleId)
            source.lastUse = now()
            let id = ObjectIdentifier(connection)
            let writer = BoundedStreamWriter(queue: queue, send: { data, done in
                connection.send(content: data, completion: .contentProcessed { done($0 == nil) })
            }, close: { connection.cancel() })
            source.subscribers[id] = writer
            let entries = source.entries
            var index = 0, started = false
            let initial = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 2000\n\n".utf8) + Self.event("reset", ["unsupported": source.isUnsupported, "storageError": source.storageError, "instanceId": source.instanceId])
            writer.startReplay {
                if !started { started = true; return initial }
                guard index < entries.count else { return nil }
                let start = index
                var bytes = 0
                repeat { bytes += entries[index].text.utf8.count + 64; index += 1 }
                while index < entries.count && index - start < 128 && bytes < 256 * 1024
                return Self.event("logs", ["entries": entries[start..<index].map(\.json)])
            }
            watchClose(connection) { [weak self] in
                self?.queue.async {
                    source.subscribers[id]?.cancel(); source.subscribers[id] = nil
                    source.lastUse = self?.now() ?? Date()
                    self?.pruneCaches()
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
        var object = object
        object["instanceId"] = source.instanceId
        let data = Self.event(name, object)
        for writer in Array(source.subscribers.values) { writer.enqueue(data) }
    }

    private static func event(_ name: String, _ object: [String: Any]) -> Data {
        var data = Data("event: \(name)\ndata: ".utf8)
        data.append((try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        data.append(Data("\n\n".utf8))
        return data
    }

    // MARK: - Actions

    /// 原子清空本次启动的持久化内容, 保留续写序号, 不向 Pod 发送全局清空。
    /// expectedInstance 将确认框绑定到特定启动, App 重启后拒绝旧操作。
    func clear(deviceId: String, bundleId: String, expectedInstance: String,
               completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let source = source(deviceId: deviceId, bundleId: bundleId)
            guard !expectedInstance.isEmpty, source.instanceId == expectedInstance,
                  source.upstreamInstance.isEmpty || source.upstreamInstance == expectedInstance else {
                completion(.failure(NSError(domain: "LayerLens.LogClear", code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Log launch changed; please confirm again"])))
                return
            }
            do {
                // 在重启后的第一条日志到达前, fileURL 可能仍指向以前的启动。
                // 先建立/恢复当前实例文件, 绝不清空那个历史文件。
                if source.file == nil { try write([], sequence: source.fileSeq, source: source) }
                guard let url = source.fileURL,
                      Self.attribute(Self.instanceAttribute, of: url) == expectedInstance,
                      Self.attribute(Self.deviceAttribute, of: url) == deviceId else { throw CocoaError(.fileWriteUnknown) }
                try replaceWithEmptyLog(url, source: source)
                source.entries = []
                source.memoryBytes = 0
                source.storageError = ""
                // HTTP 响应不再次清前端列表, reset 后的新日志不会被迟到响应抹掉。
                broadcast(source, "reset", ["unsupported": source.isUnsupported, "storageError": ""])
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// 内容和断点在同一个 inode 中提交, 清空中断不会留下“内容已删但断点丢失”的状态。
    private func replaceWithEmptyLog(_ url: URL, source: Source) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".clear-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let replacement = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var committed = false
        defer {
            if !committed { try? replacement.close(); try? FileManager.default.removeItem(at: temporary) }
        }
        try Self.setRequiredAttribute(Self.instanceAttribute, source.instanceId, of: temporary)
        try Self.setRequiredAttribute(Self.deviceAttribute, source.deviceId, of: temporary)
        try Self.setRequiredAttribute(Self.seqAttribute, String(source.fileSeq), of: temporary)
        try replacement.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        committed = true
        source.file?.closeFile()
        source.file = replacement
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

    /// MCP 只读查询: 当前启动在内存中的日志(最近 memoryLimit 条)。
    /// 快照是否失效由 MCPContextStore 判断; 这里日志还属于别的启动时(新启动尚未连上), 视为还没有日志。
    func mcpEntries(deviceId: String, bundleId: String, instanceId: String, completion: @escaping ([MCPRecords.LogEntry]) -> Void) {
        queue.async { [self] in
            guard let source = sources[deviceId + "|" + bundleId], source.instanceId == instanceId else {
                completion([])
                return
            }
            // 只给本次启动: 最后一个重启标记之后的日志
            let start = source.entries.lastIndex { $0.kind != nil }.map { $0 + 1 } ?? 0
            completion(source.entries[start...].map { MCPRecords.LogEntry(id: $0.id, time: $0.time, text: $0.text) })
        }
    }

    /// 日志面板实时显示的文件名和 App 进程, 启动列表据此标出当前启动
    func current(deviceId: String, bundleId: String, completion: @escaping (_ file: String?, _ instanceId: String) -> Void) {
        queue.async { [self] in
            let source = sources[deviceId + "|" + bundleId]
            completion(source?.fileURL?.lastPathComponent, source?.instanceId ?? "")
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
