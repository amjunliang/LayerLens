//
//  NetworkRecorder.swift
//  LayerLens
//
//  Created by YueYou on 10/28/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// 抓包: 开关按设备 + Bundle ID 记在目标历史中, 默认关闭, Mac 是唯一的依据, 每次扫描与 App 上报的状态不一致时同步给 App.
/// 开启时每个运行中的 App 保持一条到 /api/network 的事件流, 请求结束后取回详情和内容,
/// 存到 ~/Library/Caches/LayerLens/Network/<Bundle ID>/<每次启动一个文件夹>/, 保存后通知 App 释放.
/// 网页的抓包接口都由这里回答, App 被挂起(如息屏)或退出后仍可查看, 也可查看以前的启动. 不设上限, 由用户在缓存管理中清理.
/// 所有状态只在 queue 上读写
final class NetworkRecorder {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LayerLens/Network")
    /// 同步开关后等待 App 生效的时间, 期间不重复发送
    static let captureSyncInterval: TimeInterval = 5
    /// 攒够这么多已保存的请求通知 App 释放一次, 取完当前的也会通知
    static let releaseBatch = 50
    /// App 每 15 秒发一次心跳, 超过这个时间没有数据视为连接已失效
    static let staleInterval: TimeInterval = 40
    static let summaryKeys = ["id", "type", "method", "url", "status", "mime", "reqSize", "resSize", "start", "duration", "state", "error"]
    static let sessionFile = "session.json"
    static let harBodyLimit = 1024 * 1024

    /// App 的一次启动
    final class Session {
        let instanceId: String
        let deviceId: String
        let bundleId: String
        var deviceName: String
        let start: Double
        let folder: URL
        var records: [UInt64: [String: Any]] = [:]
        var order: [UInt64] = []
        /// 本地序号, 网页据此补齐变化
        var seqs: [UInt64: UInt64] = [:]
        var seq: UInt64 = 0

        init(instanceId: String, deviceId: String, bundleId: String, deviceName: String, start: Double, folder: URL) {
            self.instanceId = instanceId
            self.deviceId = deviceId
            self.bundleId = bundleId
            self.deviceName = deviceName
            self.start = start
            self.folder = folder
        }

        func bodyURL(_ id: UInt64, side: String) -> URL {
            folder.appendingPathComponent("b/\(id)-\(side)")
        }

        func summary(_ id: UInt64) -> [String: Any] {
            var result: [String: Any] = [:]
            let record = records[id] ?? [:]
            for key in NetworkRecorder.summaryKeys {
                result[key] = record[key]
            }
            result["s"] = seqs[id] ?? 0
            return result
        }
    }

    /// 同一设备上同一 App
    final class Source {
        let deviceId: String
        let bundleId: String
        var deviceName = ""
        var session: Session?
        var loaded = false
        var endpoint: TargetEndpoint?
        var online = false
        var stream: AppEventStream?
        var streamInstance = ""
        /// App 端的序号, 重连时只补齐之后的变化
        var podSeq: UInt64 = 0
        var unsupported: Set<String> = []
        var pendingFetch: [UInt64] = []
        var fetching = false
        var subscribers: [ObjectIdentifier: NWConnection] = [:]
        /// App 支持开关和释放(新版 Pod 在 /api/app 中带 networkCapture)
        var canRelease = false
        var releasable: [UInt64] = []
        /// App 在 Mac 未连接期间丢弃的请求数
        var dropped = 0
        var captureSync = Date.distantPast

        init(deviceId: String, bundleId: String) {
            self.deviceId = deviceId
            self.bundleId = bundleId
        }
    }

    private let queue = DispatchQueue(label: "com.layerlens.network")
    /// 内容查找较慢, 不占用记录队列
    private let searchQueue = DispatchQueue(label: "com.layerlens.network.search", qos: .utility)
    private var sources: [String: Source] = [:]
    /// 查看过的以前的启动, 只读
    private var archives: [String: Session] = [:]
    private var searchGenerations: [String: Int] = [:]
    /// 设备 ID, Bundle ID -> 是否开启抓包
    private let isEnabled: (String, String) -> Bool
    private let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    init(isEnabled: @escaping (String, String) -> Bool) {
        self.isEnabled = isEnabled
    }

    // MARK: - Settings

    /// 开关变化后: 关闭时断开 App 的事件流, 已保存的内容保留; 打开着的面板收到 capture 后重新读取状态.
    /// App 端的开关在下次扫描时同步
    func captureChanged(deviceId: String, bundleId: String) {
        queue.async { [self] in
            guard let source = sources[deviceId + "|" + bundleId] else { return }
            source.captureSync = .distantPast
            if !isEnabled(deviceId, bundleId) {
                source.stream?.cancel()
                source.stream = nil
                source.streamInstance = ""
                source.pendingFetch = []
                source.releasable = []
            }
            broadcast(source, "capture", ["enabled": isEnabled(deviceId, bundleId)])
        }
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

    /// LayerLens 重启后先找回该设备上最近一次启动的记录, App 未运行时也能查看
    private func loadIfNeeded(_ source: Source) {
        guard !source.loaded else { return }
        source.loaded = true
        guard source.session == nil else { return }
        let folder = Self.folder.appendingPathComponent(Self.sanitize(source.bundleId))
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var latest: (url: URL, info: [String: Any])?
        for url in folders {
            guard let info = Self.readJSON(url.appendingPathComponent(Self.sessionFile)), info["deviceId"] as? String == source.deviceId else { continue }
            if latest == nil || (info["start"] as? Double ?? 0) > (latest?.info["start"] as? Double ?? 0) {
                latest = (url, info)
            }
        }
        if let latest {
            source.session = loadSession(latest.url, info: latest.info)
        }
    }

    private func loadSession(_ url: URL, info: [String: Any]) -> Session {
        let session = Session(instanceId: info["instanceId"] as? String ?? "", deviceId: info["deviceId"] as? String ?? "", bundleId: info["bundleId"] as? String ?? "", deviceName: info["deviceName"] as? String ?? "", start: info["start"] as? Double ?? 0, folder: url)
        let files = (try? FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("r"), includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let record = Self.readJSON(file), let id = (record["id"] as? NSNumber)?.uint64Value else { continue }
            session.records[id] = record
        }
        session.order = session.records.keys.sorted()
        for id in session.order {
            session.seq += 1
            session.seqs[id] = session.seq
        }
        return session
    }

    // MARK: - Upstream

    /// 每次扫描后调用: App 上报的开关与设置不一致时同步; 为开启了抓包的运行中 App 建立事件流, 失效的重新连接, 并继续拉取未取回的内容
    func update(apps: [AppRecord]) {
        queue.async { [self] in
            var seen: Set<String> = []
            for app in apps {
                let key = app.deviceId + "|" + app.bundleId
                let enabled = isEnabled(app.deviceId, app.bundleId)
                // 旧版 Pod 没有开关, 一直在记录
                let reported = app.info["networkCapture"] as? Bool
                guard enabled || sources[key] != nil || reported == true else { continue }
                let source = source(deviceId: app.deviceId, bundleId: app.bundleId)
                seen.insert(key)
                setOnline(source, !app.suspended)
                guard !app.suspended, let instanceId = app.info["instanceId"] as? String, !instanceId.isEmpty else { continue }
                source.endpoint = app.endpoint
                source.canRelease = reported != nil
                if let name = app.info["deviceName"] as? String, !name.isEmpty {
                    source.deviceName = name
                }
                if let reported, reported != enabled {
                    syncCapture(source, endpoint: app.endpoint, enabled: enabled)
                }
                guard enabled, !source.unsupported.contains(instanceId) else { continue }
                if !source.fetching, !source.pendingFetch.isEmpty, source.session?.instanceId == instanceId {
                    fetchNext(source)
                }
                if source.streamInstance == instanceId, let stream = source.stream, Date().timeIntervalSince(stream.lastReceive) < Self.staleInterval { continue }
                connect(source, endpoint: app.endpoint, instanceId: instanceId)
            }
            for (key, source) in sources where !seen.contains(key) {
                setOnline(source, false)
            }
        }
    }

    /// App 保存开关, 冷启动时据此决定是否记录; 关闭时 App 清空缓冲
    private func syncCapture(_ source: Source, endpoint: TargetEndpoint, enabled: Bool) {
        guard Date().timeIntervalSince(source.captureSync) > Self.captureSyncInterval else { return }
        source.captureSync = Date()
        let body = (try? JSONSerialization.data(withJSONObject: ["enabled": enabled])) ?? Data()
        AppRequest.send(endpoint, method: "POST", path: "/api/network/capture", body: body, timeout: 5, queue: queue) { _ in }
    }

    private func setOnline(_ source: Source, _ online: Bool) {
        guard source.online != online else { return }
        source.online = online
        broadcast(source, "source", ["online": online, "dropped": source.dropped])
    }

    private func connect(_ source: Source, endpoint: TargetEndpoint, instanceId: String) {
        source.stream?.cancel()
        loadIfNeeded(source)
        if source.session?.instanceId != instanceId {
            source.podSeq = 0
        }
        source.streamInstance = instanceId
        let stream = AppEventStream(queue: queue)
        stream.onEvent = { [weak self, weak stream] name, payload in
            guard let self, let stream, source.stream === stream, name == "network",
                  let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
            self.receive(json, source: source)
        }
        stream.onClose = { [weak stream] status in
            guard let stream, source.stream === stream else { return }
            source.stream = nil
            // 旧版 Pod 没有抓包接口, 该进程不再重试
            if status == 404 {
                source.unsupported.insert(instanceId)
            }
        }
        source.stream = stream
        stream.start(endpoint: endpoint, path: "/api/network?since=\(source.podSeq)")
    }

    private func receive(_ json: [String: Any], source: Source) {
        // 只有连接后的第一条带 instanceId, 之后的变化属于同一次启动
        let instanceId = (json["instanceId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? source.streamInstance
        guard !instanceId.isEmpty else { return }
        if let dropped = (json["dropped"] as? NSNumber)?.intValue, dropped != source.dropped {
            source.dropped = dropped
            broadcast(source, "source", ["online": source.online, "dropped": dropped])
        }
        let switched = source.session?.instanceId != instanceId
        if switched {
            // App 重新启动, 打开着的面板改为显示这一次的请求
            if source.session != nil {
                broadcast(source, "clear", [:])
            }
            source.session = newSession(source, instanceId: instanceId)
            source.pendingFetch = []
            source.releasable = []
        }
        guard let session = source.session else { return }
        var changed: [UInt64] = []
        for item in json["records"] as? [[String: Any]] ?? [] {
            guard let id = (item["id"] as? NSNumber)?.uint64Value else { continue }
            if let seq = (item["s"] as? NSNumber)?.uint64Value {
                source.podSeq = max(source.podSeq, seq)
            }
            var record = session.records[id] ?? [:]
            let old = record
            for key in Self.summaryKeys {
                record[key] = item[key]
            }
            // LayerLens 重启后 App 会重发全部请求, 没有变化的不再推送, 但未取回内容的仍需补取
            if record["state"] as? String != "pending", record["_f"] == nil, !source.pendingFetch.contains(id) {
                source.pendingFetch.append(id)
            }
            if session.records[id] == nil {
                session.order.append(id)
            } else if NSDictionary(dictionary: old).isEqual(to: record) {
                continue
            }
            session.records[id] = record
            session.seq += 1
            session.seqs[id] = session.seq
            changed.append(id)
            save(session, id: id)
        }
        // 换了一次启动时给出全部, 可能沿用了磁盘上同一次启动的记录
        let ids = switched ? session.order : changed
        if !ids.isEmpty {
            broadcast(source, "network", ["instanceId": session.instanceId, "records": ids.map { session.summary($0) }])
        }
        if !source.fetching {
            fetchNext(source)
        }
    }

    /// 同一次启动在 LayerLens 重启后继续使用原文件夹
    private func newSession(_ source: Source, instanceId: String) -> Session {
        let folder = Self.folder.appendingPathComponent(Self.sanitize(source.bundleId))
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in folders {
            if let info = Self.readJSON(url.appendingPathComponent(Self.sessionFile)), info["instanceId"] as? String == instanceId {
                return loadSession(url, info: info)
            }
        }
        let name = source.deviceName.isEmpty ? source.deviceId : source.deviceName
        let url = folder.appendingPathComponent(fileFormatter.string(from: Date()) + "_" + Self.sanitize(name) + "_" + String(instanceId.prefix(6)))
        return Session(instanceId: instanceId, deviceId: source.deviceId, bundleId: source.bundleId, deviceName: name, start: Date().timeIntervalSince1970 * 1000, folder: url)
    }

    // MARK: - Fetch

    /// 逐个取回已结束请求的详情和内容; App 不响应时停下, 下次扫描到 App 在线再继续
    private func fetchNext(_ source: Source) {
        guard let session = source.session, source.online, let endpoint = source.endpoint, !source.pendingFetch.isEmpty else {
            source.fetching = false
            releaseSaved(source)
            return
        }
        source.fetching = true
        let id = source.pendingFetch[0]
        let retryLater = {
            source.fetching = false
        }
        let done = { [weak self] (detail: [String: Any]?) in
            guard let self, source.session === session else {
                source.fetching = false
                return
            }
            if var record = session.records[id] {
                for (key, value) in detail ?? [:] where key != "s" && !Self.summaryKeys.contains(key) {
                    record[key] = value
                }
                record["_f"] = true
                session.records[id] = record
                self.save(session, id: id)
            }
            source.pendingFetch.removeAll { $0 == id }
            if source.canRelease {
                source.releasable.append(id)
                if source.releasable.count >= Self.releaseBatch {
                    self.releaseSaved(source)
                }
            }
            self.fetchNext(source)
        }
        AppRequest.send(endpoint, path: "/api/network/detail?id=\(id)", timeout: 10, queue: queue) { [weak self] response in
            guard let self else { return }
            guard let response else {
                retryLater()
                return
            }
            guard response.status == 200, let detail = response.json else {
                done(nil)
                return
            }
            let sides = ["req", "res"].filter { detail[$0 == "req" ? "reqBody" : "resBody"] as? String == "stored" && !FileManager.default.fileExists(atPath: session.bodyURL(id, side: $0).path) }
            self.fetchBodies(sides, id: id, session: session, endpoint: endpoint) { ok in
                ok ? done(detail) : retryLater()
            }
        }
    }

    /// 已保存的请求通知 App 释放内存和缓存文件; 失败时 App 达到上限后会自行丢弃最旧的
    private func releaseSaved(_ source: Source) {
        guard !source.releasable.isEmpty, source.online, let endpoint = source.endpoint else { return }
        let body = (try? JSONSerialization.data(withJSONObject: ["ids": source.releasable])) ?? Data()
        source.releasable = []
        AppRequest.send(endpoint, method: "POST", path: "/api/network/release", body: body, timeout: 5, queue: queue) { _ in }
    }

    private func fetchBodies(_ sides: [String], id: UInt64, session: Session, endpoint: TargetEndpoint, completion: @escaping (Bool) -> Void) {
        guard let side = sides.first else {
            completion(true)
            return
        }
        AppRequest.send(endpoint, path: "/api/network/body?id=\(id)&side=\(side)", timeout: 60, queue: queue) { [weak self] response in
            guard let self, let response else {
                completion(false)
                return
            }
            // App 端已清理的内容不再重试
            if response.status == 200 {
                let url = session.bodyURL(id, side: side)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? response.body.write(to: url)
            }
            self.fetchBodies(Array(sides.dropFirst()), id: id, session: session, endpoint: endpoint, completion: completion)
        }
    }

    // MARK: - File

    private func save(_ session: Session, id: UInt64) {
        let folder = session.folder.appendingPathComponent("r")
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let info: [String: Any] = ["instanceId": session.instanceId, "deviceId": session.deviceId, "bundleId": session.bundleId, "deviceName": session.deviceName, "start": session.start]
            try? JSONSerialization.data(withJSONObject: info).write(to: session.folder.appendingPathComponent(Self.sessionFile))
        }
        guard let record = session.records[id], let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: folder.appendingPathComponent("\(id).json"))
    }

    /// 本机保存的抓包所属的设备 ID -> Bundle ID
    static func savedApps() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let manager = FileManager.default
        for bundle in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where !bundle.lastPathComponent.hasPrefix(".") {
            for url in (try? manager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? [] {
                guard let deviceId = readJSON(url.appendingPathComponent(sessionFile))?["deviceId"] as? String, !deviceId.isEmpty else { continue }
                result[deviceId, default: []].insert(bundle.lastPathComponent)
            }
        }
        return result
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// 缓存管理删除了文件夹: 内存中对应的记录一起清空, 打开着的面板同步清空
    func didDelete(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        queue.async { [self] in
            archives = archives.filter { key, _ in !paths.contains { key == $0 || key.hasPrefix($0 + "/") } }
            for source in sources.values {
                guard let session = source.session else { continue }
                let path = session.folder.standardizedFileURL.path
                guard paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                reset(source, session)
            }
        }
    }

    private func reset(_ source: Source, _ session: Session) {
        session.records = [:]
        session.order = []
        session.seqs = [:]
        source.pendingFetch = []
        source.releasable = []
        broadcast(source, "clear", [:])
    }

    // MARK: - Serving

    /// 网页经 /t/ 访问抓包接口时调用; 不是抓包接口时返回 false, 由调用方照常转发给 App.
    /// query 带 session(以前某次启动的文件夹名)时只读查看那一次; 未开启抓包时只回答状态.
    /// fallback 用于本地还没有内容(如详情尚未取回)时转发给 App
    func handle(_ head: HTTPRequestHead, path: String, deviceId: String, bundleId: String, connection: HubConnection, fallback: @escaping () -> Void) -> Bool {
        guard path.hasPrefix("/api/network") else { return false }
        let enabled = isEnabled(deviceId, bundleId)
        queue.async { [self] in
            let source = source(deviceId: deviceId, bundleId: bundleId)
            loadIfNeeded(source)
            // 未开启抓包时最近一次启动也按以前的启动只读查看
            if let name = head.query["session"], !name.isEmpty, name != source.session?.folder.lastPathComponent || !enabled {
                guard let session = archive(name, source: source) else {
                    connection.respond(.error(404, "Session not found"))
                    return
                }
                serve(head, path: path, session: session, source: nil, enabled: enabled, connection: connection, fallback: fallback)
                return
            }
            guard enabled else {
                connection.respond(path == "/api/network/status" ? .json(status(source, enabled: false)) : .error(409, "Capture is off"))
                return
            }
            // 旧版 Pod 没有抓包接口, 交给 App 返回 Not Found, 网页据此提示升级
            if source.online, source.unsupported.contains(source.streamInstance) {
                fallback()
                return
            }
            serve(head, path: path, session: source.session, source: source, enabled: enabled, connection: connection, fallback: fallback)
        }
        return true
    }

    /// source 为空表示查看以前的启动: 只读, 没有实时更新, 也不转发给 App
    private func serve(_ head: HTTPRequestHead, path: String, session: Session?, source: Source?, enabled: Bool, connection: HubConnection, fallback: @escaping () -> Void) {
        let online = source?.online ?? false
        switch (head.method, path) {
        case ("GET", "/api/network/status"):
            var result = source.map { status($0, enabled: enabled) } ?? ["ok": true, "search": true, "cached": true, "capture": enabled]
            result["archived"] = source == nil
            connection.respond(.json(result))
        case ("GET", "/api/network"):
            subscribe(source, session: session, since: UInt64(head.query["since"] ?? "") ?? 0, connection: connection.detach())
        case ("GET", "/api/network/detail"):
            let id = UInt64(head.query["id"] ?? "") ?? 0
            guard let session, var record = session.records[id], record["_f"] != nil else {
                online ? fallback() : connection.respond(.error(404, "Request not found"))
                return
            }
            record = record.filter { !$0.key.hasPrefix("_") }
            record["s"] = session.seqs[id] ?? 0
            connection.respond(.json(record))
        case ("GET", "/api/network/body"):
            respondBody(session, online: online, id: UInt64(head.query["id"] ?? "") ?? 0, side: head.query["side"] == "req" ? "req" : "res", connection: connection, fallback: fallback)
        case ("GET", "/api/network/search"):
            search(session, head: head, connection: connection)
        case ("GET", "/api/network/har"):
            har(session, head: head, connection: connection)
        case ("POST", "/api/network/clear"):
            guard let source else {
                connection.respond(.error(409, "Delete saved sessions in Cache Manage"))
                return
            }
            if let session {
                try? FileManager.default.removeItem(at: session.folder)
                reset(source, session)
            }
            if source.online, let endpoint = source.endpoint {
                AppRequest.send(endpoint, method: "POST", path: "/api/network/clear", body: Data("{}".utf8), timeout: 5, queue: queue) { _ in }
            }
            connection.respond(.json(["ok": true]))
        default:
            connection.respond(.error(404, "Not Found"))
        }
    }

    private func status(_ source: Source, enabled: Bool) -> [String: Any] {
        ["ok": true, "search": true, "cached": true, "capture": enabled, "online": source.online, "dropped": source.dropped, "session": source.session?.folder.lastPathComponent ?? ""]
    }

    /// 以前的某次启动, 只接受该 App 文件夹下属于同一设备的
    private func archive(_ name: String, source: Source) -> Session? {
        guard !name.contains("/"), name != ".", name != ".." else { return nil }
        let url = Self.folder.appendingPathComponent(Self.sanitize(source.bundleId)).appendingPathComponent(name)
        if let session = archives[url.path] {
            return session
        }
        guard let info = Self.readJSON(url.appendingPathComponent(Self.sessionFile)), info["deviceId"] as? String == source.deviceId else { return nil }
        if archives.count >= 4 {
            archives.removeAll()
        }
        let session = loadSession(url, info: info)
        archives[url.path] = session
        return session
    }

    /// 该设备上这个 App 保存的每次启动, 最近的在前
    func sessions(deviceId: String, bundleId: String, completion: @escaping ([[String: Any]]) -> Void) {
        queue.async { [self] in
            let current = sources[deviceId + "|" + bundleId]?.session?.folder.lastPathComponent
            let folder = Self.folder.appendingPathComponent(Self.sanitize(bundleId))
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var result: [[String: Any]] = []
            for url in urls {
                guard let info = Self.readJSON(url.appendingPathComponent(Self.sessionFile)), info["deviceId"] as? String == deviceId else { continue }
                let count = ((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("r").path)) ?? []).filter { $0.hasSuffix(".json") }.count
                result.append(["id": url.lastPathComponent, "start": info["start"] as? Double ?? 0, "count": count, "current": url.lastPathComponent == current])
            }
            completion(result.sorted { ($0["start"] as? Double ?? 0) > ($1["start"] as? Double ?? 0) })
        }
    }

    private func subscribe(_ source: Source?, session: Session?, since: UInt64, connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        source?.subscribers[id] = connection
        var data = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 2000\n\n".utf8)
        data.append(Self.event("source", ["online": source?.online ?? false, "dropped": source?.dropped ?? 0, "archived": source == nil]))
        // 序号比当前还大说明对方记录的是另一份内容, 全部给出
        let start = since > (session?.seq ?? 0) ? 0 : since
        let ids = session?.order.filter { (session?.seqs[$0] ?? 0) > start } ?? []
        data.append(Self.event("network", ["instanceId": session?.instanceId ?? "", "records": ids.map { session!.summary($0) }]))
        connection.send(content: data, completion: .contentProcessed { _ in })
        watchClose(connection) { [weak self] in
            self?.queue.async {
                source?.subscribers[id] = nil
            }
        }
    }

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

    private func respondBody(_ session: Session?, online: Bool, id: UInt64, side: String, connection: HubConnection, fallback: @escaping () -> Void) {
        guard let session, let record = session.records[id] else {
            online ? fallback() : connection.respond(.error(404, "Request not found"))
            return
        }
        let headers = record[side == "req" ? "requestHeaders" : "responseHeaders"] as? [String: String] ?? [:]
        let contentType = Self.header("Content-Type", in: headers) ?? (side == "res" ? record["mime"] as? String : nil).flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
        if let data = try? Data(contentsOf: session.bodyURL(id, side: side)) {
            connection.respond(HTTPResponse(status: 200, contentType: contentType, body: data, headers: ["Cache-Control": "no-store"]))
            return
        }
        let state = record[side == "req" ? "reqBody" : "resBody"] as? String
        if record["_f"] == nil || state == "stored" {
            online ? fallback() : connection.respond(.error(404, "App is not running, content is not saved yet"))
            return
        }
        let messages = ["none": "No content", "tooLarge": "Content over 5 MB is not saved", "stream": "Sent as a stream, content is not available", "file": "File content is not saved", "evicted": "Removed by cache cleanup"]
        connection.respond(.error(404, messages[state ?? ""] ?? "No content"))
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - Search

    /// 规则同 App 端: 以 \ 开头为正则, 否则按 | 分隔的关键词, 不区分大小写
    private func search(_ session: Session?, head: HTTPRequestHead, connection: HubConnection) {
        guard let regex = Self.searchRegex(head.query["q"] ?? "") else {
            connection.respond(.error(400, "Invalid query"))
            return
        }
        let candidates = head.query["ids"].map { Set($0.split(separator: ",").compactMap { UInt64($0) }) }
        let client = head.query["client"] ?? ""
        // 只保留最近的 client, 避免页面反复刷新后无限增长
        if searchGenerations.count > 32, searchGenerations[client] == nil {
            searchGenerations.removeAll()
        }
        let generation = (searchGenerations[client] ?? 0) + 1
        searchGenerations[client] = generation
        guard let session else {
            connection.respond(.json(["ids": []]))
            return
        }
        let items = session.order.filter { candidates?.contains($0) ?? true }.map { ($0, session.bodyURL($0, side: "res"), session.bodyURL($0, side: "req")) }
        searchQueue.async { [weak self] in
            var ids: [UInt64] = []
            for (id, response, request) in items {
                let cancelled = self?.queue.sync { self?.searchGenerations[client] != generation } ?? true
                if cancelled {
                    connection.respond(.json(["ids": []]))
                    return
                }
                if Self.body(response, matches: regex) || Self.body(request, matches: regex) {
                    ids.append(id)
                }
            }
            connection.respond(.json(["ids": ids]))
        }
    }

    private static func searchRegex(_ query: String) -> NSRegularExpression? {
        let pattern: String
        if query.hasPrefix("\\") {
            pattern = String(query.dropFirst())
        } else {
            pattern = query.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        }
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    private static func body(_ url: URL, matches regex: NSRegularExpression) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return false }
        if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        // JSON 中的中文常转义为 \uXXXX, 还原后再匹配一次
        guard text.contains("\\u"), let decoded = text.applyingTransform(StringTransform("Any-Hex/Java"), reverse: true) else { return false }
        return regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)) != nil
    }

    // MARK: - HAR

    private func har(_ session: Session?, head: HTTPRequestHead, connection: HubConnection) {
        let requested = (head.query["ids"] ?? "").split(separator: ",").compactMap { UInt64($0) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entries: [[String: Any]] = []
        for id in requested.isEmpty ? session?.order ?? [] : requested {
            guard let session, let record = session.records[id] else { continue }
            entries.append(harEntry(record, id: id, session: session, formatter: formatter))
        }
        let har: [String: Any] = ["log": ["version": "1.2", "creator": ["name": "LayerLens", "version": HubServer.version], "entries": entries]]
        let name = (head.query["name"] ?? "").isEmpty ? "LayerLens.har" : head.query["name"]!
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "download"
        let ascii = name.unicodeScalars.allSatisfy { $0.isASCII && $0 != "\"" } ? name : "LayerLens.har"
        let data = (try? JSONSerialization.data(withJSONObject: har)) ?? Data()
        connection.respond(HTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data, headers: ["Content-Disposition": "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"]))
    }

    private func harEntry(_ record: [String: Any], id: UInt64, session: Session, formatter: ISO8601DateFormatter) -> [String: Any] {
        let requestHeaders = record["requestHeaders"] as? [String: String] ?? [:]
        let responseHeaders = record["responseHeaders"] as? [String: String] ?? [:]
        let url = record["url"] as? String ?? ""
        let status = (record["status"] as? NSNumber)?.intValue ?? 0
        let time = max((record["duration"] as? NSNumber)?.intValue ?? 0, 0)
        let start = (record["start"] as? NSNumber)?.doubleValue ?? 0
        var request: [String: Any] = [
            "method": record["method"] as? String ?? "GET",
            "url": url,
            "httpVersion": "HTTP/1.1",
            "headers": Self.harHeaders(requestHeaders),
            "queryString": (URLComponents(string: url)?.queryItems ?? []).map { ["name": $0.name, "value": $0.value ?? ""] },
            "cookies": [],
            "headersSize": -1,
            "bodySize": record["reqSize"] ?? 0,
        ]
        if let body = try? Data(contentsOf: session.bodyURL(id, side: "req")), !body.isEmpty, body.count <= Self.harBodyLimit {
            request["postData"] = ["mimeType": Self.header("Content-Type", in: requestHeaders) ?? "", "text": String(data: body, encoding: .utf8) ?? body.base64EncodedString()]
        }
        var content: [String: Any] = ["size": record["resSize"] ?? 0, "mimeType": record["mime"] as? String ?? ""]
        if let body = try? Data(contentsOf: session.bodyURL(id, side: "res")), !body.isEmpty, body.count <= Self.harBodyLimit {
            if let text = String(data: body, encoding: .utf8) {
                content["text"] = text
            } else {
                content["text"] = body.base64EncodedString()
                content["encoding"] = "base64"
            }
        }
        var entry: [String: Any] = [
            "startedDateTime": formatter.string(from: Date(timeIntervalSince1970: start / 1000)),
            "time": time,
            "request": request,
            "response": [
                "status": status,
                "statusText": status > 0 ? HTTPURLResponse.localizedString(forStatusCode: status) : "",
                "httpVersion": "HTTP/1.1",
                "headers": Self.harHeaders(responseHeaders),
                "cookies": [],
                "content": content,
                "redirectURL": Self.header("Location", in: responseHeaders) ?? "",
                "headersSize": -1,
                "bodySize": record["resSize"] ?? 0,
            ] as [String: Any],
            "cache": [:],
            "timings": ["send": 0, "wait": time, "receive": 0],
        ]
        if let error = record["error"] {
            entry["_error"] = error
        }
        return entry
    }

    private static func harHeaders(_ headers: [String: String]) -> [[String: String]] {
        headers.keys.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }.map { ["name": $0, "value": headers[$0] ?? ""] }
    }
}
