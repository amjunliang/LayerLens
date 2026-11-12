//
//  MCPClients.swift
//  LayerLens
//

import Foundation

/// 一键接入 Agent：检测本机的 Claude Code 和 Codex，安装或移除 LayerLens 的 MCP 与 Skill。
/// MCP 通过客户端自带的 `mcp get/add/remove` 命令修改，不直接编辑它们的配置文件；
/// Skill 是 LayerLens 自己写入的单个文件，只覆盖或删除带有标记的版本。
final class MCPClientInstaller {
    struct CommandResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }
    typealias Runner = (_ path: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) -> CommandResult?

    enum Client: String, CaseIterable {
        case claude, codex

        var name: String { self == .claude ? "Claude Code" : "Codex" }
        var skillFile: String { self == .claude ? ".claude/skills/layerlens/SKILL.md" : ".codex/skills/layerlens/SKILL.md" }
    }

    enum Part: String, CaseIterable { case mcp, skill }

    enum MCPState: String { case installed, missing, different, unknown }
    enum SkillState: String { case installed, missing, outdated, conflict }

    struct Status {
        let client: Client
        let path: String?
        let mcp: MCPState
        let mcpURL: String
        let skill: SkillState
        let error: String

        var json: [String: Any] {
            var value: [String: Any] = [
                "id": client.rawValue,
                "name": client.name,
                "found": path != nil,
                "mcp": mcp.rawValue,
                "skill": skill.rawValue,
            ]
            if let path { value["path"] = path }
            if !mcpURL.isEmpty { value["mcpURL"] = mcpURL }
            if !error.isEmpty { value["error"] = error }
            return value
        }
    }

    static let serverName = "layerlens"
    private static let commandTimeout: TimeInterval = 20

    let url: String
    private let home: URL
    private let runner: Runner
    private let shell: String
    private let lock = NSLock()
    private var cachedSearchPath: [String]?

    init(url: String,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
         runner: @escaping Runner = MCPClientInstaller.defaultRunner) {
        self.url = url
        self.home = home
        self.shell = shell
        self.runner = runner
    }

    static let defaultRunner: Runner = { path, arguments, environment, timeout in
        guard let result = BoundedProcess.capture(path, arguments, timeout: timeout, environment: environment,
                                                  directory: FileManager.default.homeDirectoryForCurrentUser) else { return nil }
        return CommandResult(status: result.status, output: String(decoding: result.data, as: UTF8.self), timedOut: result.timedOut)
    }

    // MARK: - Locate

    /// 从访达启动的 App 只有系统 PATH，Homebrew、npm 安装的命令找不到；
    /// 从登录 shell 读取用户的 PATH，再补上常见安装位置。
    func searchPath() -> [String] {
        lock.lock()
        if let cachedSearchPath { lock.unlock(); return cachedSearchPath }
        lock.unlock()
        var directories: [String] = []
        let allowedShell = ["/bin/zsh", "/bin/bash"].contains(shell) ? shell : "/bin/zsh"
        if let result = runner(allowedShell, ["-lc", "printf %s \"$PATH\""], ProcessInfo.processInfo.environment, 5),
           result.status == 0, !result.timedOut {
            directories = result.output.split(separator: ":").map(String.init)
        }
        let homePath = home.path
        directories += [
            "\(homePath)/.local/bin", "\(homePath)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(homePath)/.npm-global/bin", "\(homePath)/.bun/bin", "\(homePath)/.volta/bin",
            "/usr/bin", "/bin",
        ]
        var unique: [String] = []
        for directory in directories where !directory.isEmpty && !unique.contains(directory) { unique.append(directory) }
        lock.lock()
        cachedSearchPath = unique
        lock.unlock()
        return unique
    }

    /// Codex 桌面版自带 CLI，未单独安装时也能用它修改同一份 ~/.codex 配置。
    private static let bundledCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    func locate(_ client: Client, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        for directory in searchPath() {
            let candidate = (directory as NSString).appendingPathComponent(client.rawValue)
            if isExecutable(candidate) { return candidate }
        }
        if client == .codex, isExecutable(Self.bundledCodex) { return Self.bundledCodex }
        return nil
    }

    private var environment: [String: String] {
        var value = ProcessInfo.processInfo.environment
        value["PATH"] = searchPath().joined(separator: ":")
        return value
    }

    // MARK: - Status

    func status(_ client: Client) -> Status {
        let path = locate(client)
        let skill = skillState(client)
        guard let path else {
            return Status(client: client, path: nil, mcp: .unknown, mcpURL: "", skill: skill, error: "")
        }
        let (mcp, mcpURL, error) = mcpState(client, path: path)
        return Status(client: client, path: path, mcp: mcp, mcpURL: mcpURL, skill: skill, error: error)
    }

    func statuses() -> [Status] {
        var result = [Status?](repeating: nil, count: Client.allCases.count)
        let group = DispatchGroup()
        let resultLock = NSLock()
        for (index, client) in Client.allCases.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let value = status(client)
                resultLock.lock(); result[index] = value; resultLock.unlock()
                group.leave()
            }
        }
        group.wait()
        return result.compactMap { $0 }
    }

    private func mcpState(_ client: Client, path: String) -> (MCPState, String, String) {
        let arguments = client == .claude ? ["mcp", "get", Self.serverName] : ["mcp", "get", Self.serverName, "--json"]
        guard let result = runner(path, arguments, environment, Self.commandTimeout) else {
            return (.unknown, "", "Could not run \(client.rawValue)")
        }
        if result.timedOut { return (.unknown, "", "\(client.rawValue) mcp get timed out") }
        guard result.status == 0 else { return (.missing, "", "") }
        let configured = client == .claude ? Self.claudeURL(result.output) : Self.codexURL(result.output)
        guard let configured else { return (.different, "", "") }
        return (configured == url ? .installed : .different, configured, "")
    }

    /// `claude mcp get` 输出中的 "URL: http://…" 行。
    static func claudeURL(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("URL:") { return text.dropFirst(4).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// `codex mcp get --json` 输出中的 transport.url。
    static func codexURL(_ output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
              let json = (try? JSONSerialization.jsonObject(with: Data(output[start...].utf8))) as? [String: Any],
              let transport = json["transport"] as? [String: Any] else { return nil }
        return transport["url"] as? String
    }

    // MARK: - Install / remove

    struct Failure: Error {
        let message: String
    }

    func install(_ client: Client, parts: Set<Part>) -> [String] {
        var errors: [String] = []
        if parts.contains(.mcp) {
            if let error = installMCP(client) { errors.append("\(client.name) MCP: \(error)") }
        }
        if parts.contains(.skill) {
            if let error = installSkill(client) { errors.append("\(client.name) Skill: \(error)") }
        }
        return errors
    }

    func remove(_ client: Client, parts: Set<Part>) -> [String] {
        var errors: [String] = []
        if parts.contains(.mcp) {
            if let error = removeMCP(client) { errors.append("\(client.name) MCP: \(error)") }
        }
        if parts.contains(.skill) {
            if let error = removeSkill(client) { errors.append("\(client.name) Skill: \(error)") }
        }
        return errors
    }

    private func installMCP(_ client: Client) -> String? {
        guard let path = locate(client) else { return "\(client.rawValue) not found" }
        let (state, _, error) = mcpState(client, path: path)
        switch state {
        case .installed: return nil
        case .unknown: return error
        case .different:
            if let error = run(path, removeArguments(client)) { return error }
        case .missing: break
        }
        let arguments = client == .claude
            ? ["mcp", "add", "--transport", "http", "--scope", "user", Self.serverName, url]
            : ["mcp", "add", Self.serverName, "--url", url]
        return run(path, arguments)
    }

    private func removeMCP(_ client: Client) -> String? {
        guard let path = locate(client) else { return "\(client.rawValue) not found" }
        let (state, _, error) = mcpState(client, path: path)
        switch state {
        case .missing: return nil
        case .unknown: return error
        case .installed, .different: return run(path, removeArguments(client))
        }
    }

    private func removeArguments(_ client: Client) -> [String] {
        client == .claude ? ["mcp", "remove", "--scope", "user", Self.serverName] : ["mcp", "remove", Self.serverName]
    }

    private func run(_ path: String, _ arguments: [String]) -> String? {
        guard let result = runner(path, arguments, environment, Self.commandTimeout) else { return "Could not run \(path)" }
        if result.timedOut { return "Timed out" }
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Exit \(result.status)" : String(message.suffix(400))
        }
        return nil
    }

    // MARK: - Skill

    private func skillURL(_ client: Client) -> URL { home.appendingPathComponent(client.skillFile) }

    func skillState(_ client: Client) -> SkillState {
        guard let data = try? Data(contentsOf: skillURL(client)) else { return .missing }
        let text = String(decoding: data, as: UTF8.self)
        if text == Self.skill { return .installed }
        return text.contains(Self.skillMarker) ? .outdated : .conflict
    }

    private func installSkill(_ client: Client) -> String? {
        let url = skillURL(client)
        switch skillState(client) {
        case .installed: return nil
        case .conflict: return "\(url.path) exists and was not written by LayerLens"
        case .missing, .outdated: break
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Self.skill.utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func removeSkill(_ client: Client) -> String? {
        let url = skillURL(client)
        switch skillState(client) {
        case .missing: return nil
        case .conflict: return "\(url.path) was not written by LayerLens"
        case .installed, .outdated: break
        }
        do {
            try FileManager.default.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: directory)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static let skillMarker = "<!-- Installed by LayerLens. Remove it in LayerLens > MCP Setup. -->"

    /// Skill 平时只有 name 和 description 进入上下文，用到时才读取正文。
    static let skill = """
    ---
    name: layerlens
    description: Read the iOS UI the user is inspecting in LayerLens (selected view, its ivar, class, view controller and the App's source root) to find the code behind it, and read that App's console logs and captured network requests. Use when the user points at on-screen UI ("this button", "the selected view", "this screen"), asks where some visible UI is implemented, or asks why the running App misbehaves (errors, failed requests, wrong data), and LayerLens is running.
    ---

    \(skillMarker)

    # LayerLens

    1. Call the `layerlens` MCP tool `get_context`. If you can read this conversation's LayerLens browser page, use its `document.documentElement.dataset.layerlensWindowId` as `windowId`. Reuse that ID for the same page on later calls. If no page ID is known, omit it to use the last-focused LayerLens window.
    2. When `focus.type` is `element`, use `selected.element`, `selected.owner`, `selected.vc`, and `selected.hints` to search `sourceRoot`. System SwiftUI containers are weak clues; prefer visible text or business classes.
    3. When `focus.type` is `annotation`, use `focus.hints` only as candidates. If they are absent or ambiguous, call `get_canvas_screenshot` with the returned `snapshotId`; the user's marks identify the intended region.
    4. If no target is selected or marked and the user refers to visible UI without clear text, capture the canvas and search for distinctive visible text. Screenshots are also appropriate for visual questions. Do not infer that the canvas and hierarchy are the same frame.
    5. Keep output compact. Do not ask for the full view hierarchy.

    Runtime issues (`get_context.activity` counts this launch's logs and requests):
    - Logs: `search_logs` with a specific `query` (keywords joined by `|`, e.g. `error|fail`). Avoid reading all logs.
    - Network: `list_requests` with `failedOnly: true` or a URL `query` first; then `get_request` with one `id`, `part: "summary"` for status and headers, `"response"` for the body.
    - JSON bodies are pruned (arrays keep 2 items). Pass `path` (e.g. `data.items[0]`) to read a subtree instead of raising `maxChars`.
    - After the user reproduces the issue, pass the previous `cursor` to read only new entries.
    - `network_capture_off`: ask the user to turn on capture in the LayerLens Network panel and reproduce.

    Errors:
    - `no_app_selected`: ask the user to select the App in LayerLens.
    - `snapshot_stale` or `snapshot_not_found`: call `get_context` again with the same `windowId` if known.
    - `window_not_found`: retry after the page loads, or read the ID from the intended page again.
    - Connection refused: ask the user to open LayerLens.

    If the `layerlens` MCP tools are missing from this session (LayerLens was started later), call the same endpoint directly. Include `windowId` in `arguments` when known. No initialize step is needed:

    ```sh
    curl -s -X POST http://127.0.0.1:9523/mcp -H 'Content-Type: application/json' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_context","arguments":{}}}'
    ```

    """
}
