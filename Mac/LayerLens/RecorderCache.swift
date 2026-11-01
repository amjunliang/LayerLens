import Foundation

/// 磁盘数据不删除。只回收无人查看的离线缓存, 活跃采集和正在查看的数据不被强制截断。
enum RecorderCache {
    static let idleLifetime: TimeInterval = 300
    static let byteLimit = 32 * 1024 * 1024
    struct Item {
        let id: String
        let bytes: Int
        let lastUse: Date
        let pinned: Bool
    }
    static func evictions(_ items: [Item], now: Date = Date(), limit: Int = byteLimit) -> [String] {
        var total = items.reduce(0) { $0 + $1.bytes }
        var result: [String] = []
        for item in items.filter({ !$0.pinned }).sorted(by: { $0.lastUse < $1.lastUse }) {
            if total <= limit && now.timeIntervalSince(item.lastUse) < idleLifetime { continue }
            result.append(item.id)
            total -= item.bytes
        }
        return result
    }
}
