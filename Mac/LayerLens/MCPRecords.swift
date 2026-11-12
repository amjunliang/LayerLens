//
//  MCPRecords.swift
//  LayerLens
//

import Foundation

/// 日志和抓包给 Agent 的紧凑输出。原则: 先摘要后细节, 服务端过滤, 游标只取新增, 大内容裁剪, 敏感值打码。
/// 这里只做格式化, 不访问录制器, 便于单独测试。
enum MCPRecords {
    struct Failure: Error { let message: String }

    // MARK: - Arguments

    /// 工具参数校验: 拒绝未知参数, 类型和范围不对时给出可直接改正的提示。
    struct Arguments {
        private let values: [String: Any]

        init(_ values: [String: Any], known: Set<String>) throws {
            if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
                throw Failure(message: "unknown argument \(unknown).")
            }
            self.values = values
        }

        func snapshotId() throws -> String {
            guard let value = values["snapshotId"] as? String, !value.isEmpty else {
                throw Failure(message: "snapshotId is required; use the value returned by get_context.")
            }
            return value
        }

        func string(_ key: String, required: Bool = false) throws -> String {
            guard let raw = values[key] else {
                if required { throw Failure(message: "\(key) must be a non-empty string.") }
                return ""
            }
            guard let text = raw as? String else { throw Failure(message: "\(key) must be a string.") }
            if required, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Failure(message: "\(key) must be a non-empty string.")
            }
            return text
        }

        func bool(_ key: String, default fallback: Bool) throws -> Bool {
            guard let raw = values[key] else { return fallback }
            guard let number = raw as? NSNumber, Self.isBoolean(number) else { throw Failure(message: "\(key) must be a boolean.") }
            return number.boolValue
        }

        func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = values[key] else { return fallback }
            guard let number = raw as? NSNumber, !Self.isBoolean(number),
                  number.doubleValue == number.doubleValue.rounded(),
                  number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
                let upper = range.upperBound == Int.max ? "" : " and \(range.upperBound)"
                throw Failure(message: upper.isEmpty ? "\(key) must be an integer ≥ \(range.lowerBound)."
                              : "\(key) must be an integer between \(range.lowerBound)\(upper).")
            }
            return number.intValue
        }

        func choice(_ key: String, _ options: [String], default fallback: String) throws -> String {
            guard let raw = values[key] else { return fallback }
            guard let text = raw as? String, options.contains(text) else {
                throw Failure(message: "\(key) must be one of \(options.joined(separator: ", ")).")
            }
            return text
        }

        func query(_ key: String = "query") throws -> NSRegularExpression? {
            let text = try string(key)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard let regex = MCPRecords.regex(text) else { throw Failure(message: "\(key) is not a valid regular expression.") }
            return regex
        }

        private static func isBoolean(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }
    }

    // MARK: - Query

    /// 与网络面板搜索一致: 以 \ 开头为正则, 否则按 | 分隔的关键词, 不区分大小写。
    static func regex(_ query: String) -> NSRegularExpression? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let pattern: String
        if trimmed.hasPrefix("\\") {
            pattern = String(trimmed.dropFirst())
        } else {
            pattern = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        }
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return true }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.contains(where: \.isNewline) ? text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ") : text
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func time(_ milliseconds: Double) -> String {
        milliseconds > 0 ? clock.string(from: Date(timeIntervalSince1970: milliseconds / 1000)) : "--:--:--.---"
    }

    // MARK: - Logs

    struct LogEntry {
        let id: Int
        let time: Double
        let text: String
    }

    static let logLineMax = 200
    static let logLimitMax = 200

    /// 返回最新的 limit 条匹配日志, 每条一行; 连续相同的内容合并为 "×N"。
    /// cursor 为本次看到的最大 id, 下次传入只返回之后的新日志。
    static func logs(_ entries: [LogEntry], query: NSRegularExpression?, after cursor: Int, limit: Int) -> [String: Any] {
        let cap = max(1, min(logLimitMax, limit))
        var groups: [(entry: LogEntry, count: Int)] = []
        var matched = 0
        for entry in entries where entry.id > cursor && matches(query, entry.text) {
            matched += 1
            if let last = groups.last, last.entry.text == entry.text {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((entry, 1))
            }
        }
        let shown = groups.suffix(cap)
        let lines = shown.map { group -> String in
            return "\(time(group.entry.time)) \(clip(group.entry.text, logLineMax))" + (group.count > 1 ? " ×\(group.count)" : "")
        }
        var value: [String: Any] = [
            "lines": lines.joined(separator: "\n"),
            "cursor": max(cursor, entries.last?.id ?? cursor),
            "matched": matched,
        ]
        if groups.count > shown.count { value["omittedOlder"] = groups.count - shown.count }
        return value
    }

    // MARK: - Requests

    static let requestLimitMax = 100

    static func failed(_ record: [String: Any]) -> Bool {
        let status = (record["status"] as? NSNumber)?.intValue ?? 0
        let error = record["error"] as? String ?? ""
        return status >= 400 || !error.isEmpty || record["state"] as? String == "failed"
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024) }
        return String(format: "%.1fMB", Double(bytes) / 1024 / 1024)
    }

    /// 每个请求一行: `#42 POST 500 312ms /api/book?id=… 1.2KB json`。
    /// 所有请求同一个域名时只在 host 字段给出一次。
    /// include 做过滤; cursor 取全部记录的最大 id, 过滤掉的请求下次也不会再出现。
    static func requests(_ records: [(id: UInt64, record: [String: Any])], after cursor: UInt64, limit: Int,
                         where include: (UInt64, [String: Any]) -> Bool = { _, _ in true }) -> [String: Any] {
        let cap = max(1, min(requestLimitMax, limit))
        let fresh = records.filter { $0.id > cursor && include($0.id, $0.record) }
        let shown = Array(fresh.suffix(cap))
        let hosts = Set(shown.compactMap { URLComponents(string: $0.record["url"] as? String ?? "")?.host })
        let sharedHost = hosts.count == 1 ? hosts.first : nil
        let lines = shown.map { item -> String in
            let record = item.record
            let method = record["method"] as? String ?? "GET"
            let status = (record["status"] as? NSNumber)?.intValue ?? 0
            let state = record["state"] as? String ?? ""
            let statusText = status > 0 ? String(status) : (state == "pending" ? "…" : state == "failed" ? "ERR" : "UNKNOWN")
            let duration = (record["duration"] as? NSNumber).map { "\($0.intValue)ms" } ?? "-"
            var parts = ["#\(item.id)", method, statusText, duration, shortURL(record["url"] as? String ?? "", host: sharedHost)]
            let bytes = (record["resSize"] as? NSNumber)?.intValue ?? 0
            if bytes > 0 { parts.append(size(bytes)) }
            if let mime = record["mime"] as? String, !mime.isEmpty { parts.append(shortMime(mime)) }
            if let error = record["error"] as? String, !error.isEmpty { parts.append("error=\(clip(error, 120))") }
            if let note = record["captureNote"] as? String, !note.isEmpty { parts.append("capture=\(clip(note, 120))") }
            return parts.joined(separator: " ")
        }
        var value: [String: Any] = [
            "lines": lines.joined(separator: "\n"),
            "cursor": max(cursor, records.last?.id ?? cursor),
            "matched": fresh.count,
        ]
        if let sharedHost { value["host"] = sharedHost }
        if fresh.count > shown.count { value["omittedOlder"] = fresh.count - shown.count }
        return value
    }

    static func shortURL(_ url: String, host: String?) -> String {
        guard var components = URLComponents(string: url), components.host != nil else { return clip(url, 160) }
        let query = components.percentEncodedQuery.map { "?" + clip($0, 80) } ?? ""
        components.percentEncodedQuery = nil
        components.fragment = nil
        if components.host == host { return clip(components.percentEncodedPath, 120) + query }
        components.scheme = nil
        let text = components.string ?? url
        return clip(text.hasPrefix("//") ? String(text.dropFirst(2)) : text, 160) + query
    }

    static func shortMime(_ mime: String) -> String {
        let base = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? mime
        return base.split(separator: "/").last.map(String.init) ?? base
    }

    /// list_requests 的 query 匹配这一行: 方法、状态码、URL 和错误。
    static func searchText(_ record: [String: Any]) -> String {
        let status = (record["status"] as? NSNumber)?.intValue ?? 0
        return [record["method"] as? String ?? "", status > 0 ? String(status) : "", record["url"] as? String ?? "",
                record["error"] as? String ?? ""].joined(separator: " ")
    }

    /// get_request part=summary: 一次看清请求, 头部打码。尚未取回详情时注明。
    static func summary(id: UInt64, record: [String: Any]) -> [String: Any] {
        var value: [String: Any] = ["id": id]
        for key in ["method", "url", "status", "duration", "mime", "reqSize", "resSize", "error", "captureNote", "state"] {
            guard let item = record[key] else { continue }
            if let text = item as? String, text.isEmpty { continue }
            if key == "url", let text = item as? String { value[key] = clip(text, 2000); continue }
            value[key] = item
        }
        if let start = (record["start"] as? NSNumber)?.doubleValue { value["time"] = time(start) }
        for key in ["requestHeaders", "responseHeaders"] {
            if let headers = record[key] as? [String: String], !headers.isEmpty { value[key] = self.headers(headers) }
        }
        for key in ["reqBody", "resBody"] {
            if let state = record[key] as? String, !state.isEmpty { value[key] = state }
        }
        if record["_f"] == nil, record["state"] as? String != "pending" {
            value["details"] = record["_missing"] != nil ? "partially unavailable" : "not fetched yet; retry shortly"
        }
        return value
    }

    /// 内容不可读时的原因, 对应网络面板的提示。
    static func bodyUnavailable(_ record: [String: Any], side: String) -> String {
        let state = record[side == "req" ? "reqBody" : "resBody"] as? String ?? ""
        if record["state"] as? String == "pending" { return "body_unavailable: request is still pending." }
        if side == "res" && record["state"] as? String == "unavailable" { return "body_unavailable: request result was not captured." }
        if record["_f"] == nil && record["_missing"] == nil || state == "stored" {
            return "body_unavailable: content is not fetched from the App yet; retry shortly."
        }
        let reasons = ["none": "there is no content", "tooLarge": "content over 5 MB is not saved",
                       "stream": "it was sent as a stream", "unavailable": "response content was not captured", "file": "file content is not saved",
                       "evicted": "it was removed by cache cleanup"]
        return "body_unavailable: " + (reasons[state] ?? "there is no content") + "."
    }

    // MARK: - Redaction

    private static let secretHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key",
    ]

    static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretHeaders.contains(lower) || lower.contains("token") || lower.contains("secret")
            || lower.contains("password") || lower.contains("passwd") || lower == "pwd" || lower.contains("session")
    }

    static func masked(_ value: String) -> String { "*** (\(value.count) chars)" }

    static func headers(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = isSecret(name) ? masked(value) : clip(value, 160)
        }
        return result
    }

    // MARK: - Body

    static let bodyCharsDefault = 2000
    static let bodyCharsMax = 8000
    private static let arrayKeep = 2
    private static let stringMax = 200
    private static let depthMax = 6


    /// JSON 只保留结构: 数组留前 2 项并注明总数, 长字符串截断, 过深折叠, 敏感字段打码。
    /// path 形如 `data.items[0].title`, 先取子树再裁剪。
    static func body(_ data: Data, mime: String, path: String, maxChars: Int) -> Result<[String: Any], Failure> {
        let cap = max(200, min(bodyCharsMax, maxChars))
        if data.isEmpty { return .success(["body": "", "bytes": 0]) }
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            var node = json
            if !path.isEmpty {
                switch select(json, path: path) {
                case .success(let value): node = value
                case .failure(let error): return .failure(error)
                }
            }
            let pruned = prune(node, depth: 0)
            let text = serialized(pruned)
            var value: [String: Any] = ["bytes": data.count, "format": "json"]
            // 放得下时直接嵌入 JSON 值, 避免再转义一层字符串
            if text.count > cap {
                value["body"] = String(text.prefix(cap))
                value["truncated"] = "\(text.count) chars after pruning; pass path to select a subtree"
            } else {
                value["body"] = pruned
            }
            if path.isEmpty { value["pruned"] = "arrays keep \(arrayKeep) items, strings \(stringMax) chars, depth \(depthMax)" }
            return .success(value)
        }
        guard !path.isEmpty else {
            guard let text = String(data: data, encoding: .utf8) else {
                return .success(["body": "", "bytes": data.count, "format": "binary \(shortMime(mime))"])
            }
            var value: [String: Any] = ["bytes": data.count, "format": "text"]
            value["body"] = text.count > cap ? String(text.prefix(cap)) : text
            if text.count > cap { value["truncated"] = "\(text.count) chars" }
            return .success(value)
        }
        return .failure(Failure(message: "path only applies to JSON bodies."))
    }

    static func select(_ root: Any, path: String) -> Result<Any, Failure> {
        var node = root
        var walked = ""
        for token in tokens(path) {
            switch token {
            case .key(let key):
                guard let object = node as? [String: Any], let next = object[key] else {
                    return .failure(Failure(message: "path \(walked.isEmpty ? "" : walked + ".")\(key) not found."))
                }
                node = next
                walked += walked.isEmpty ? key : ".\(key)"
            case .index(let index):
                guard let array = node as? [Any], array.indices.contains(index) else {
                    return .failure(Failure(message: "path \(walked)[\(index)] out of range."))
                }
                node = array[index]
                walked += "[\(index)]"
            }
        }
        return .success(node)
    }

    private enum Token { case key(String), index(Int) }

    private static func tokens(_ path: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var index = ""
        var inBracket = false
        func flush() { if !current.isEmpty { result.append(.key(current)); current = "" } }
        for character in path {
            switch character {
            case "." where !inBracket: flush()
            case "[" where !inBracket: flush(); inBracket = true
            case "]" where inBracket:
                if let value = Int(index) { result.append(.index(value)) } else if !index.isEmpty { result.append(.key(index)) }
                index = ""; inBracket = false
            default:
                if inBracket { index.append(character) } else { current.append(character) }
            }
        }
        flush()
        return result
    }

    static func prune(_ value: Any, depth: Int, key: String = "") -> Any {
        if !key.isEmpty, isSecret(key), !(value is [String: Any]), !(value is [Any]) {
            return masked("\(value)")
        }
        if let object = value as? [String: Any] {
            if depth >= depthMax { return "{… \(object.count) keys}" }
            var result: [String: Any] = [:]
            for (name, item) in object { result[name] = prune(item, depth: depth + 1, key: name) }
            return result
        }
        if let array = value as? [Any] {
            if depth >= depthMax { return "[… \(array.count) items]" }
            // 只多一项时整体保留, 省略说明不比那一项短
            let keep = array.count > arrayKeep + 1 ? arrayKeep : array.count
            var result = array.prefix(keep).map { prune($0, depth: depth + 1) }
            if array.count > keep { result.append("… +\(array.count - arrayKeep) items (\(array.count) total)") }
            return result
        }
        if let text = value as? String, text.count > stringMax {
            return String(text.prefix(stringMax)) + "… (\(text.count) chars)"
        }
        return value
    }

    static func serialized(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || !(value is [Any] || value is [String: Any]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
