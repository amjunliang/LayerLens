//
//  LaunchStore.swift
//  LayerLens
//
//  Created by YueYou on 10/28/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation

/// App 的每次启动: 日志文件和抓包记录按 App 进程(instanceId)合并为一次启动.
/// 旧版本写的日志文件没有进程标记, 单独作为一次启动
enum LaunchStore {
    /// 返回该 App 保存的每次启动, 新的在前; deviceId 为空时不按设备过滤.
    /// 旧版本写的日志没有设备标记, 按文件名中的设备名 deviceName 匹配
    /// [{ id, instanceId, deviceId, device, start, time, size, log: { id, name, size }, network: { id, session, count, size } }]
    static func launches(bundleId: String, deviceId: String = "", deviceName: String = "") -> [[String: Any]] {
        guard valid(bundleId) else { return [] }
        let manager = FileManager.default
        var launches: [String: [String: Any]] = [:]
        let logFolder = AppLogRecorder.folder.appendingPathComponent(bundleId)
        for url in (try? manager.contentsOfDirectory(at: logFolder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [] where url.pathExtension == "log" {
            let name = url.lastPathComponent
            let device = AppLogRecorder.attribute(AppLogRecorder.deviceAttribute, of: url) ?? ""
            // 文件名为 <开始时间>_<设备名>.log
            let stem = url.deletingPathExtension().lastPathComponent
            let fileDevice = stem.count > 20 ? String(stem.dropFirst(20)) : ""
            guard deviceId.isEmpty || device == deviceId || (device.isEmpty && !deviceName.isEmpty && fileDevice == deviceName) else { continue }
            let instance = AppLogRecorder.attribute(AppLogRecorder.instanceAttribute, of: url) ?? ""
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            let start = fileFormatter.date(from: String(stem.prefix(19))).map { $0.timeIntervalSince1970 * 1000 }
            var launch = launches[instance.isEmpty ? "log:" + name : instance] ?? [:]
            launch["log"] = ["id": "logs/\(bundleId)/\(name)", "name": name, "size": size]
            merge(&launch, instance: instance, deviceId: device, device: fileDevice, start: start, time: values?.contentModificationDate, size: size)
            launches[instance.isEmpty ? "log:" + name : instance] = launch
        }
        let networkFolder = NetworkRecorder.folder.appendingPathComponent(bundleId)
        for url in (try? manager.contentsOfDirectory(at: networkFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where !url.lastPathComponent.hasPrefix(".") {
            let info = NetworkRecorder.readJSON(url.appendingPathComponent(NetworkRecorder.sessionFile)) ?? [:]
            let device = info["deviceId"] as? String ?? ""
            guard deviceId.isEmpty || device == deviceId || (device.isEmpty && !deviceName.isEmpty && info["deviceName"] as? String == deviceName) else { continue }
            let instance = info["instanceId"] as? String ?? ""
            let name = url.lastPathComponent
            let count = ((try? manager.contentsOfDirectory(atPath: url.appendingPathComponent("r").path)) ?? []).filter { $0.hasSuffix(".json") }.count
            let size = folderSize(url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            var launch = launches[instance.isEmpty ? "net:" + name : instance] ?? [:]
            launch["network"] = ["id": "network/\(bundleId)/\(name)", "session": name, "count": count, "size": size]
            merge(&launch, instance: instance, deviceId: device, device: info["deviceName"] as? String ?? "", start: info["start"] as? Double, time: modified, size: size)
            launches[instance.isEmpty ? "net:" + name : instance] = launch
        }
        return launches.map { key, value in
            var launch = value
            launch["id"] = key
            return launch
        }.sorted { ($0["start"] as? Double ?? 0) > ($1["start"] as? Double ?? 0) }
    }

    private static func merge(_ launch: inout [String: Any], instance: String, deviceId: String, device: String, start: Double?, time: Date?, size: Int) {
        launch["instanceId"] = instance
        if !deviceId.isEmpty { launch["deviceId"] = deviceId }
        if (launch["device"] as? String ?? "").isEmpty { launch["device"] = device }
        if let start, start < (launch["start"] as? Double ?? .infinity) { launch["start"] = start }
        let modified = (time ?? .distantPast).timeIntervalSince1970 * 1000
        if modified > (launch["time"] as? Double ?? 0) { launch["time"] = modified }
        launch["size"] = (launch["size"] as? Int ?? 0) + size
        if launch["start"] == nil { launch["start"] = modified }
    }

    /// 缓存管理中展开某次启动时的预览: 日志最后若干行, 抓包前若干个请求
    static func preview(bundleId: String, launchId: String, logLines: Int = 20, requests: Int = 10) -> [String: Any]? {
        guard let launch = launches(bundleId: bundleId).first(where: { $0["id"] as? String == launchId }) else { return nil }
        var result: [String: Any] = [:]
        if let log = launch["log"] as? [String: Any], let name = log["name"] as? String {
            result["log"] = tail(AppLogRecorder.folder.appendingPathComponent(bundleId).appendingPathComponent(name), lines: logLines)
        }
        if let network = launch["network"] as? [String: Any], let session = network["session"] as? String {
            let folder = NetworkRecorder.folder.appendingPathComponent(bundleId).appendingPathComponent(session).appendingPathComponent("r")
            let ids = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { $0.hasSuffix(".json") ? UInt64($0.dropLast(5)) : nil }.sorted()
            result["requests"] = ids.prefix(requests).compactMap { id -> [String: Any]? in
                guard let record = NetworkRecorder.readJSON(folder.appendingPathComponent("\(id).json")) else { return nil }
                return ["method": record["method"] ?? "", "status": record["status"] ?? 0, "url": record["url"] ?? "", "start": record["start"] ?? 0]
            }
        }
        return result
    }

    /// 读取保存的日志文件的一段, id 为 logs/<App>/<文件名>; 返回数据和文件总长度
    static func readLog(id: String, offset: UInt64, length: Int) -> (Data, UInt64)? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "logs", valid(parts[1]), valid(parts[2]), parts[2].hasSuffix(".log") else { return nil }
        let url = AppLogRecorder.folder.appendingPathComponent(parts[1]).appendingPathComponent(parts[2])
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()) ?? 0
        guard offset < total else { return (Data(), total) }
        try? handle.seek(toOffset: offset)
        return ((try? handle.read(upToCount: length)) ?? Data(), total)
    }

    private static func tail(_ url: URL, lines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 16 * 1024
        try? handle.seek(toOffset: total > chunk ? total - chunk : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var result = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // 从中间截断的第一行不完整
        if total > chunk, !result.isEmpty { result.removeFirst() }
        return Array(result.suffix(lines))
    }

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func folderSize(_ folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
