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

    /// 返回 { apps: [{ bundleId, size, launches: LaunchStore.launches }], size }; 日志和抓包按每次启动合并
    static func list() -> [String: Any] {
        var bundles = Set<String>()
        for kind in Kind.allCases {
            let urls = (try? FileManager.default.contentsOfDirectory(at: kind.folder, includingPropertiesForKeys: nil)) ?? []
            urls.filter { !$0.lastPathComponent.hasPrefix(".") }.forEach { bundles.insert($0.lastPathComponent) }
        }
        var total = 0
        let result: [[String: Any]] = bundles.sorted().compactMap { bundleId in
            let launches = LaunchStore.launches(bundleId: bundleId)
            guard !launches.isEmpty else { return nil }
            let size = launches.reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
            total += size
            return ["bundleId": bundleId, "size": size, "launches": launches]
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
}
