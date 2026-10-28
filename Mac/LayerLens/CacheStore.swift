//
//  CacheStore.swift
//  LayerLens
//
//  Created by YueYou on 10/28/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation

/// 缓存管理: 按 App 列出 LayerLens 保存的日志文件和抓包记录, 由用户自行删除. 各类缓存都不设上限
enum CacheStore {
    enum Kind: String, CaseIterable {
        case logs
        case network

        var folder: URL {
            switch self {
            case .logs:
                return AppLogRecorder.folder
            case .network:
                return NetworkRecorder.folder
            }
        }
    }

    /// 返回 { apps: [{ bundleId, size, items: [{ id, kind, name, device, deviceId, time, size, count }] }], size }
    static func list() -> [String: Any] {
        let manager = FileManager.default
        var apps: [String: [[String: Any]]] = [:]
        for kind in Kind.allCases {
            let bundles = (try? manager.contentsOfDirectory(at: kind.folder, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where !bundle.lastPathComponent.hasPrefix(".") {
                let entries = (try? manager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])) ?? []
                for url in entries where !url.lastPathComponent.hasPrefix(".") {
                    var item: [String: Any] = ["id": kind.rawValue + "/" + bundle.lastPathComponent + "/" + url.lastPathComponent, "kind": kind.rawValue, "name": url.lastPathComponent]
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    item["time"] = modified.timeIntervalSince1970 * 1000
                    switch kind {
                    case .logs:
                        guard url.pathExtension == "log" else { continue }
                        item["size"] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    case .network:
                        let info = NetworkRecorder.readJSON(url.appendingPathComponent(NetworkRecorder.sessionFile)) ?? [:]
                        item["device"] = info["deviceName"] as? String ?? ""
                        item["deviceId"] = info["deviceId"] as? String ?? ""
                        if let start = info["start"] as? Double {
                            item["start"] = start
                        }
                        item["count"] = ((try? manager.contentsOfDirectory(atPath: url.appendingPathComponent("r").path)) ?? []).filter { $0.hasSuffix(".json") }.count
                        item["size"] = size(of: url)
                    }
                    apps[bundle.lastPathComponent, default: []].append(item)
                }
            }
        }
        var total = 0
        let result: [[String: Any]] = apps.keys.sorted().map { bundleId in
            let items = apps[bundleId]!.sorted { ($0["time"] as? Double ?? 0) > ($1["time"] as? Double ?? 0) }
            let size = items.reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
            total += size
            return ["bundleId": bundleId, "size": size, "items": items]
        }
        return ["apps": result, "size": total]
    }

    /// ids 为 list 返回的 id; bundleId 删除该 App 的全部缓存; all 删除全部. 返回删除的位置
    static func delete(ids: [String], bundleId: String?, all: Bool) -> [URL] {
        var urls: [URL] = []
        if all {
            urls = Kind.allCases.flatMap { kind in
                ((try? FileManager.default.contentsOfDirectory(at: kind.folder, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
            }
        } else if let bundleId, valid(bundleId) {
            urls = Kind.allCases.map { $0.folder.appendingPathComponent(bundleId) }
        } else {
            for id in ids {
                let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                // 只接受 <类型>/<App>/<名称>, 防止删除其他位置
                guard parts.count == 3, let kind = Kind(rawValue: parts[0]), valid(parts[1]), valid(parts[2]) else { continue }
                urls.append(kind.folder.appendingPathComponent(parts[1]).appendingPathComponent(parts[2]))
            }
        }
        let removed = urls.filter { FileManager.default.fileExists(atPath: $0.path) && (try? FileManager.default.removeItem(at: $0)) != nil }
        return removed
    }

    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func size(of folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
