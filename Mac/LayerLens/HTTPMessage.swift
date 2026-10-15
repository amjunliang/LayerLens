//
//  HTTPMessage.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation

/// 请求头部, 解析自 "\r\n\r\n" 之前的内容
struct HTTPRequestHead {
    let method: String
    /// 原始请求路径, 含查询参数
    let target: String
    let path: String
    let query: [String: String]
    /// 保留原始顺序和大小写, 转发时原样写回
    let headers: [(name: String, value: String)]

    static let terminator = Data("\r\n\r\n".utf8)

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentLength: Int {
        Int(header("Content-Length") ?? "") ?? 0
    }

    /// 返回解析结果和头部(含结束符)长度; 数据不完整时返回 nil
    static func parse(_ data: Data) -> (head: HTTPRequestHead?, length: Int)? {
        guard let range = data.range(of: terminator) else { return nil }
        let length = range.upperBound - data.startIndex
        guard let text = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else { return (nil, length) }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return (nil, length) }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let target = String(parts[1])
        let components = URLComponents(string: "http://localhost" + target)
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        let head = HTTPRequestHead(method: parts[0].uppercased(), target: target, path: components?.path ?? target, query: query, headers: headers)
        return (head, length)
    }

    /// 生成转发给上游的头部: 替换路径与 Host, 去掉浏览器专属信息
    func forwarded(target newTarget: String, host: String, keepConnection: Bool) -> Data {
        let dropped: Set<String> = keepConnection ? ["host", "origin", "referer", "cookie"] : ["host", "origin", "referer", "cookie", "connection", "keep-alive"]
        var text = "\(method) \(newTarget) HTTP/1.1\r\nHost: \(host)\r\n"
        for (name, value) in headers where !dropped.contains(name.lowercased()) {
            text += "\(name): \(value)\r\n"
        }
        if !keepConnection {
            text += "Connection: close\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return error(500, "JSON serialization failed")
        }
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data, headers: ["Cache-Control": "no-store"])
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    func serialized() -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable"]
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Unknown")\r\n"
        text += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
