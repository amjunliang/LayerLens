//
//  MCPContext.swift
//  LayerLens
//

import Foundation

/// 一个网页窗口上报的只读上下文。MCP 默认使用最后获得焦点的窗口。
struct MCPWindowContext {
    let windowId: String
    let deviceId: String
    let bundleId: String
    let deviceName: String
    let appName: String
    let instanceId: String
    let revision: Int
    let targetGeneration: Int
    let selected: [String: Any]
    let updatedAt: TimeInterval

    /// 窗口已选中一个 App；未选中时 get_context 返回错误而不是空快照。
    var hasTarget: Bool { !deviceId.isEmpty && !bundleId.isEmpty }

    /// 只输出 Agent 定位源码需要的字段；设备 ID、坐标等不帮助搜索源码，不返回。
    func json(sourceRoot: String?) -> [String: Any] {
        var value: [String: Any] = [
            "app": appName,
            "bundleId": bundleId,
        ]
        if let element = selected["element"] as? String, !element.isEmpty {
            value["selected"] = MCPNodeInfo.compact(selected)
        }
        if let sourceRoot, !sourceRoot.isEmpty {
            value["sourceRoot"] = sourceRoot
        }
        return value
    }
}

struct MCPContextSnapshot {
    let id: String
    let context: MCPWindowContext
    let sourceRoot: String?
    let createdAt: TimeInterval

    func json() -> [String: Any] {
        var value = context.json(sourceRoot: sourceRoot)
        value["snapshotId"] = id
        return value
    }
}

/// 窗口上下文和 Agent 快照都在主进程内。每个 Agent 的 get_context 会固定一个
/// window + App 快照，后续 find_nodes 不跟随其他窗口的焦点变化。
final class MCPContextStore {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var contexts: [String: MCPWindowContext] = [:]
    private var closedWindows: [String: TimeInterval] = [:]
    private var snapshots: [String: MCPContextSnapshot] = [:]
    private var currentWindowId: String?
    private var currentFocusEpoch: TimeInterval = 0
    private var focusOrder: [String] = []

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    @discardableResult
    func update(_ value: [String: Any]) -> Bool {
        guard let windowId = value["windowId"] as? String, !windowId.isEmpty else { return false }
        let timestamp = now()
        let focusRequested = value["focusRequested"] as? Bool == true
        let focusEpoch = (value["focusEpoch"] as? NSNumber)?.doubleValue ?? 0
        lock.lock()
        defer { lock.unlock() }
        if let closedAt = closedWindows[windowId], timestamp - closedAt < 3600 { return false }
        let previous = contexts[windowId]
        let revision = (value["revision"] as? NSNumber)?.intValue ?? 0
        guard previous == nil || revision >= previous!.revision else { return false }
        let deviceId = value["deviceId"] as? String ?? ""
        let bundleId = value["bundleId"] as? String ?? ""
        let instanceId = value["instanceId"] as? String ?? ""
        let sameTarget = previous?.deviceId == deviceId && previous?.bundleId == bundleId && previous?.instanceId == instanceId
        let targetGeneration = (previous?.targetGeneration ?? 0) + (sameTarget ? 0 : 1)
        let context = MCPWindowContext(
            windowId: windowId,
            deviceId: deviceId,
            bundleId: bundleId,
            deviceName: value["deviceName"] as? String ?? "",
            appName: value["appName"] as? String ?? "",
            instanceId: instanceId,
            revision: revision,
            targetGeneration: targetGeneration,
            selected: value["selected"] as? [String: Any] ?? [:],
            updatedAt: timestamp
        )
        contexts[windowId] = context
        if focusRequested && focusEpoch >= currentFocusEpoch {
            currentWindowId = windowId
            currentFocusEpoch = focusEpoch
            focusOrder.removeAll { $0 == windowId }
            focusOrder.insert(windowId, at: 0)
        } else if currentWindowId == nil {
            currentWindowId = windowId
        }
        return true
    }

    func remove(windowId: String) {
        guard !windowId.isEmpty else { return }
        lock.lock()
        let timestamp = now()
        closedWindows = closedWindows.filter { timestamp - $0.value < 3600 }
        closedWindows[windowId] = timestamp
        contexts.removeValue(forKey: windowId)
        focusOrder.removeAll { $0 == windowId }
        if currentWindowId == windowId {
            currentWindowId = focusOrder.first
        }
        lock.unlock()
    }

    func latest() -> MCPWindowContext? {
        lock.lock()
        defer { lock.unlock() }
        if let currentWindowId, let context = contexts[currentWindowId] { return context }
        if let next = focusOrder.first(where: { contexts[$0] != nil }) { return contexts[next] }
        return contexts.values.max { $0.updatedAt < $1.updatedAt }
    }

    func snapshot(context: MCPWindowContext, sourceRoot: String?) -> MCPContextSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = matchingContext(for: context) else { return nil }
        let timestamp = now()
        let snapshot = MCPContextSnapshot(
            id: UUID().uuidString,
            context: current,
            sourceRoot: sourceRoot,
            createdAt: timestamp
        )
        snapshots[snapshot.id] = snapshot
        snapshots = snapshots.filter { timestamp - $0.value.createdAt < 3600 }
        if snapshots.count > 128 {
            let keep = snapshots.values.sorted { $0.createdAt > $1.createdAt }.prefix(128)
            snapshots = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
        return snapshot
    }

    func snapshot(id: String) -> MCPContextSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshots[id], now() - snapshot.createdAt < 3600 else { return nil }
        return snapshot
    }

    /// 同一窗口切换 App、重启或关闭后，旧节点不能继续被其他 Agent 使用。
    func isCurrent(_ snapshot: MCPContextSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return now() - snapshot.createdAt < 3600 && matchingContext(for: snapshot.context) != nil
    }

    private func matchingContext(for context: MCPWindowContext) -> MCPWindowContext? {
        guard let current = contexts[context.windowId],
              current.targetGeneration == context.targetGeneration else { return nil }
        return current
    }
}

/// 节点输出为一行 element 加 owner、vc。element 已包含 ivar、类名、文字和 identifier，
/// 不再拆成独立字段。get_context 的 selected 由网页 elementLine 生成，find_nodes 在这里生成，格式一致。
enum MCPNodeInfo {
    /// 与 Web/app.js 的 ELEMENT_TEXT_MAX 一致；只限制长文章等极端文本，前缀仍可用于搜索源码。
    static let textMax = 40

    static func isSystemClass(_ name: String) -> Bool {
        name == "SwiftUI" || ["_", "UI", "NS", "CA", "WK", "AV", "MK", "PK", "SK", "SwiftUI."].contains { name.hasPrefix($0) }
    }

    /// 与网页 elementLine 一致："Host : Declaring.ivar" 输出 "Declaring.ivar"，优先声明在业务类中的，
    /// 没有时退回系统类的，如 UIListContentView._textLabel。
    static func ivarNames(_ traces: [String]) -> [String] {
        var code: [String] = []
        var all: [String] = []
        for trace in traces {
            guard let dot = trace.lastIndex(of: ".") else { continue }
            let prefix = String(trace[..<dot])
            let declaring = prefix.components(separatedBy: " : ").last ?? prefix
            let name = declaring + trace[dot...]
            if !all.contains(name) { all.append(name) }
            if !isSystemClass(declaring) && !code.contains(name) { code.append(name) }
        }
        return code.isEmpty ? all : code
    }

    static func clipped(_ value: String) -> String {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > textMax ? String(text.prefix(textMax)) + "…" : text
    }

    static func make(cls: String, ivarTraces: [String], identifier: String, text: String, title: String,
                     owner: String, vc: String) -> [String: Any] {
        var element = cls
        let ivars = ivarNames(ivarTraces)
        if !ivars.isEmpty { element = "\(ivars.joined(separator: " and ")) (\(cls))" }
        let shown = clipped(text.isEmpty ? (title == cls ? "" : title) : text)
        if !shown.isEmpty { element += " \"\(shown)\"" }
        if !identifier.isEmpty { element += " · id=\(identifier)" }
        var value: [String: Any] = ["element": element]
        if !owner.isEmpty && owner != cls { value["owner"] = owner }
        if !vc.isEmpty { value["vc"] = vc }
        return value
    }

    /// 网页上报的 selected 只保留同样的三个字段。
    static func compact(_ node: [String: Any]) -> [String: Any] {
        var value: [String: Any] = [:]
        for key in ["element", "owner", "vc", "swiftUIPath"] {
            if let text = node[key] as? String, !text.isEmpty { value[key] = text }
        }
        return value
    }
}

/// 在 `/api/hierarchy` 的原始节点中做小范围搜索。只返回 Agent 定位源码所需的字段。
enum MCPNodeSearch {
    static let maxLimit = 10

    static func find(in roots: [[String: Any]], query: String, visibleOnly: Bool, limit: Int) -> [[String: Any]] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let cap = max(1, min(maxLimit, limit))
        var matches: [(score: Int, depth: Int, value: [String: Any])] = []

        func text(_ node: [String: Any], _ key: String) -> String {
            node[key] as? String ?? ""
        }
        func strings(_ node: [String: Any], _ key: String) -> [String] {
            node[key] as? [String] ?? []
        }
        func rect(_ value: Any?) -> [Double] {
            (value as? [NSNumber] ?? []).map(\.doubleValue)
        }
        func intersects(_ a: [Double], _ b: [Double]) -> Bool {
            guard a.count == 4, b.count == 4 else { return true }
            return a[0] < b[0] + b[2] && a[0] + a[2] > b[0] &&
                a[1] < b[1] + b[3] && a[1] + a[3] > b[1]
        }
        func walk(
            _ node: [String: Any],
            depth: Int,
            inheritedHidden: Bool,
            rootRect: [Double],
            nearestVC: String,
            nearestBusiness: String
        ) {
            let hidden = inheritedHidden || (node["hidden"] as? Bool == true) ||
                ((node["alpha"] as? NSNumber)?.doubleValue ?? 1) < 0.01
            let nodeRect = rect(node["rect"])
            let chain = strings(node, "classChain")
            let cls = chain.first ?? text(node, "cls")
            let currentVC = text(node, "vcClass").isEmpty ? nearestVC : text(node, "vcClass")
            let visible = !hidden && nodeRect.count == 4 && nodeRect[2] > 0 && nodeRect[3] > 0 &&
                (rootRect.isEmpty || intersects(nodeRect, rootRect))
            if !visibleOnly || visible {
                let ivars = strings(node, "ivarTraces")
                let identifier = text(node, "identifier")
                let title = text(node, "title")
                let valueText = text(node, "text")
                let special = text(node, "specialTrace")
                let address = text(node, "address")
                var score = 0
                func add(_ candidate: String, exact: Int, contains: Int) {
                    let lower = candidate.lowercased()
                    guard !lower.isEmpty else { return }
                    if lower == needle { score += exact }
                    else if lower.contains(needle) { score += contains }
                }
                add(identifier, exact: 110, contains: 70)
                add(valueText, exact: 100, contains: 60)
                add(title, exact: 90, contains: 55)
                chain.forEach { add($0, exact: 85, contains: 45) }
                ivars.forEach { add($0, exact: 80, contains: 50) }
                add(currentVC, exact: 70, contains: 35)
                add(special, exact: 60, contains: 30)
                add(address, exact: 50, contains: 20)
                if score > 0 {
                    if !MCPNodeInfo.isSystemClass(cls) { score += 10 }
                    let value = MCPNodeInfo.make(
                        cls: cls,
                        ivarTraces: ivars,
                        identifier: identifier,
                        text: valueText,
                        title: title,
                        owner: nearestBusiness,
                        vc: currentVC
                    )
                    matches.append((score, depth, value))
                }
            }
            let currentBusiness = !cls.isEmpty && !MCPNodeInfo.isSystemClass(cls) ? cls : nearestBusiness
            for child in node["children"] as? [[String: Any]] ?? [] {
                walk(
                    child,
                    depth: depth + 1,
                    inheritedHidden: hidden,
                    rootRect: rootRect,
                    nearestVC: currentVC,
                    nearestBusiness: currentBusiness
                )
            }
        }

        for root in roots {
            let rootRect = rect(root["rect"])
            walk(root, depth: 0, inheritedHidden: false, rootRect: rootRect, nearestVC: "", nearestBusiness: "")
        }
        return matches.sorted {
            if $0.score == $1.score { return $0.depth < $1.depth }
            return $0.score > $1.score
        }.prefix(cap).map(\.value)
    }
}
