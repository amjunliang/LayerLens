import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

@main enum MCPRecordsTests {
    static func main() throws {
        queryAndArguments()
        try logs()
        requests()
        try bodies()
        print("PASS MCP records: query, arguments, log cursor, request lines, redaction, body pruning")
    }

    static func queryAndArguments() {
        let keywords = MCPRecords.regex("timeout | 500")
        require(MCPRecords.matches(keywords, "Request TIMEOUT"), "Keywords must be case-insensitive")
        require(MCPRecords.matches(keywords, "status 500") && !MCPRecords.matches(keywords, "ok"), "Keywords must be alternatives")
        require(MCPRecords.matches(MCPRecords.regex("a.b"), "a.b") && !MCPRecords.matches(MCPRecords.regex("a.b"), "axb"),
                "Keywords must be literal")
        require(MCPRecords.matches(MCPRecords.regex("\\^GET /api"), "GET /api/x"), "Leading backslash means regex")
        require(MCPRecords.regex("\\(") == nil && MCPRecords.regex("  ") == nil, "Invalid or empty query")

        func failure(_ block: () throws -> Void) -> String {
            do { try block(); return "" } catch { return (error as? MCPRecords.Failure)?.message ?? "\(error)" }
        }
        require(failure { _ = try MCPRecords.Arguments(["x": 1], known: ["snapshotId"]) } == "unknown argument x.", "Unknown argument")
        let args = try! MCPRecords.Arguments(["snapshotId": "s", "limit": 3, "flag": true, "part": "summary", "q": "\\("],
                                             known: ["snapshotId", "limit", "flag", "part", "q"])
        require((try? args.snapshotId()) == "s", "snapshotId")
        require((try? args.int("limit", default: 5, range: 1...10)) == 3, "int")
        require((try? args.int("missing", default: 5, range: 1...10)) == 5, "int default")
        require(failure { _ = try args.int("flag", default: 1, range: 1...10) }.contains("integer"), "Bool is not an int")
        require(failure { _ = try args.int("limit", default: 1, range: 5...10) } == "limit must be an integer between 5 and 10.", "Range")
        require((try? args.bool("flag", default: false)) == true, "bool")
        require(failure { _ = try args.bool("limit", default: false) } == "limit must be a boolean.", "Number is not a bool")
        require(failure { _ = try args.choice("part", ["request"], default: "request") }.contains("one of request"), "choice")
        require(failure { _ = try args.query("q") }.contains("regular expression"), "Invalid regex is reported")
        require((try? args.query("missing")) == .some(nil), "Missing query matches everything")
    }

    static func logs() throws {
        let base = 1_700_000_000_000.0
        let entries = [
            MCPRecords.LogEntry(id: 1, time: base, text: "launch"),
            MCPRecords.LogEntry(id: 2, time: base + 1, text: "load failed: timeout"),
            MCPRecords.LogEntry(id: 3, time: base + 2, text: "load failed: timeout"),
            MCPRecords.LogEntry(id: 4, time: base + 3, text: "ready"),
            MCPRecords.LogEntry(id: 5, time: base + 4, text: String(repeating: "x", count: 300) + "\nnext"),
        ]
        var value = MCPRecords.logs(entries, query: nil, after: 0, limit: 50)
        let lines = (value["lines"] as! String).components(separatedBy: "\n")
        require(lines.count == 4, "Repeats must merge into one line")
        require(lines[1].hasSuffix("load failed: timeout ×2"), "Repeat count")
        require(lines[2].hasSuffix(" ready"), "Plain line")
        require(!lines[3].contains("\n") && lines[3].hasSuffix("…") && lines[3].count < 230, "Long line clipped to one line")
        require(value["cursor"] as? Int == 5 && value["matched"] as? Int == 5, "Cursor and matched")

        value = MCPRecords.logs(entries, query: MCPRecords.regex("timeout"), after: 0, limit: 1)
        require(value["lines"] as? String == MCPRecords.time(base + 1) + " load failed: timeout ×2", "Filtered line")
        require(value["omittedOlder"] == nil, "Merged group is one line")
        value = MCPRecords.logs(entries, query: MCPRecords.regex("launch|ready|x"), after: 0, limit: 1)
        require(value["omittedOlder"] as? Int == 2 && value["matched"] as? Int == 3, "Older groups beyond limit are counted")

        value = MCPRecords.logs(entries, query: nil, after: 5, limit: 50)
        require(value["lines"] as? String == "" && value["cursor"] as? Int == 5 && value["matched"] as? Int == 0, "Nothing new after cursor")
    }

    static func requests() {
        let records: [(id: UInt64, record: [String: Any])] = [
            (1, ["method": "GET", "url": "https://api.example.com/v1/books?page=2", "status": 200, "duration": 120, "resSize": 2048, "mime": "application/json; charset=utf-8"]),
            (2, ["method": "POST", "url": "https://api.example.com/v1/order", "status": 500, "duration": 312.7, "mime": "text/html"]),
            (3, ["method": "GET", "url": "https://api.example.com/v1/ping", "status": 0, "state": "failed", "error": "The request timed out."]),
            (4, ["method": "GET", "url": "https://api.example.com/v1/slow", "status": 0, "state": "pending"]),
        ]
        var value = MCPRecords.requests(records, after: 0, limit: 20)
        let lines = (value["lines"] as! String).components(separatedBy: "\n")
        require(value["host"] as? String == "api.example.com", "Shared host given once")
        require(lines[0] == "#1 GET 200 120ms /v1/books?page=2 2.0KB json", "Request line: \(lines[0])")
        require(lines[1] == "#2 POST 500 312ms /v1/order html", "Request line: \(lines[1])")
        require(lines[2] == "#3 GET ERR - /v1/ping error=The request timed out.", "Failed line: \(lines[2])")
        require(lines[3] == "#4 GET … - /v1/slow", "Pending line: \(lines[3])")

        value = MCPRecords.requests(records, after: 0, limit: 20) { _, record in MCPRecords.failed(record) }
        require(value["lines"] as? String == "#2 POST 500 312ms /v1/order html\n#3 GET ERR - /v1/ping error=The request timed out.",
                "failedOnly")
        require(value["cursor"] as? UInt64 == 4, "Cursor covers filtered-out records")

        value = MCPRecords.requests(records, after: 2, limit: 1)
        require((value["lines"] as? String)?.hasPrefix("#4 ") == true && value["omittedOlder"] as? Int == 1, "Cursor and limit")

        let uncaptured: [String: Any] = ["state": "unavailable", "status": 0, "captureNote": "Result not captured"]
        require(!MCPRecords.failed(uncaptured), "Uncaptured results are not network failures")
        let uncapturedLines = MCPRecords.requests([(5, uncaptured)], after: 0, limit: 10)["lines"] as? String ?? ""
        require(uncapturedLines.contains("UNKNOWN") && uncapturedLines.contains("capture=Result not captured"), "Unknown capture status explained")
        require(MCPRecords.bodyUnavailable(["_f": true, "resBody": "unavailable"], side: "res").contains("not captured"), "Uncaptured response body explained")

        let mixed: [(id: UInt64, record: [String: Any])] = [
            (1, ["url": "https://a.example.com/x"]), (2, ["url": "https://b.example.com/y?q=1"]),
        ]
        value = MCPRecords.requests(mixed, after: 0, limit: 20)
        require(value["host"] == nil && (value["lines"] as? String)?.contains("b.example.com/y?q=1") == true, "Hosts kept when mixed")
        require(MCPRecords.searchText(records[1].record) == "POST 500 https://api.example.com/v1/order ", "Search text")

        let summary = MCPRecords.summary(id: 2, record: [
            "method": "POST", "url": "https://x/y", "status": 500, "error": "",
            "requestHeaders": ["Authorization": "Bearer abc", "X-Trace": "t1", "x-session-id": "s"],
            "responseHeaders": ["Set-Cookie": "a=b"], "resBody": "stored", "_f": true,
        ])
        let request = summary["requestHeaders"] as? [String: String] ?? [:]
        require(request["Authorization"] == "*** (10 chars)" && request["X-Trace"] == "t1" && request["x-session-id"] == "*** (1 chars)",
                "Secret request headers masked")
        require((summary["responseHeaders"] as? [String: String])?["Set-Cookie"] == "*** (3 chars)", "Set-Cookie masked")
        require(summary["error"] == nil && summary["details"] == nil && summary["resBody"] as? String == "stored", "Summary fields")
        require(MCPRecords.summary(id: 1, record: ["state": "done"])["details"] as? String == "not fetched yet; retry shortly",
                "Unfetched details noted")

        require(MCPRecords.bodyUnavailable(["_f": true, "resBody": "tooLarge"], side: "res").contains("over 5 MB"), "tooLarge reason")
        require(MCPRecords.bodyUnavailable(["state": "done"], side: "res").contains("not fetched"), "Unfetched reason")
        require(MCPRecords.bodyUnavailable(["state": "pending"], side: "req").contains("pending"), "Pending reason")
    }

    static func bodies() throws {
        let object: [String: Any] = [
            "token": "abcdef",
            "data": ["items": (0..<5).map { ["title": "Book \($0)", "id": $0] }, "note": String(repeating: "n", count: 250)],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .success(let pruned) = MCPRecords.body(data, mime: "application/json", path: "", maxChars: 2000),
              let back = pruned["body"] as? [String: Any],
              let inner = back["data"] as? [String: Any], let items = inner["items"] as? [Any] else {
            fatalError("JSON body")
        }
        require(back["token"] as? String == "*** (6 chars)", "Secret JSON field masked")
        require(items.count == 3 && items.last as? String == "… +3 items (5 total)", "Array kept 2 items")
        require((inner["note"] as? String)?.hasSuffix("… (250 chars)") == true, "Long string clipped")
        require((MCPRecords.prune([1, 2, 3], depth: 0) as? [Int]) == [1, 2, 3], "One extra item is kept")
        require(pruned["format"] as? String == "json" && pruned["pruned"] != nil && pruned["truncated"] == nil, "JSON metadata")

        guard case .success(let item) = MCPRecords.body(data, mime: "application/json", path: "data.items[3].title", maxChars: 2000) else {
            fatalError("JSON path")
        }
        require(item["body"] as? String == "Book 3" && item["pruned"] == nil, "Path selects subtree")
        guard case .success(let cut) = MCPRecords.body(data, mime: "application/json", path: "", maxChars: 200),
              let cutText = cut["body"] as? String else { fatalError("Truncated JSON") }
        require(cutText.count == 200 && (cut["truncated"] as? String)?.contains("pass path") == true, "Long JSON truncated as text")
        if case .success = MCPRecords.body(data, mime: "", path: "data.items[9]", maxChars: 2000) { fatalError("Out of range path") }
        if case .failure(let error) = MCPRecords.body(data, mime: "", path: "data.missing", maxChars: 2000) {
            require(error.message == "path data.missing not found.", "Missing path message: \(error.message)")
        }

        let long = Data(String(repeating: "a", count: 5000).utf8)
        guard case .success(let plain) = MCPRecords.body(long, mime: "text/plain", path: "", maxChars: 300) else { fatalError("Text") }
        require((plain["body"] as? String)?.count == 300 && plain["truncated"] as? String == "5000 chars", "Text truncated")
        guard case .success(let binary) = MCPRecords.body(Data([0xff, 0xfe, 0x00, 0x80]), mime: "image/png", path: "", maxChars: 300) else {
            fatalError("Binary")
        }
        require(binary["format"] as? String == "binary png" && binary["bytes"] as? Int == 4, "Binary only reports size")
        if case .success = MCPRecords.body(long, mime: "text/plain", path: "a", maxChars: 300) { fatalError("Path on text") }
    }
}
