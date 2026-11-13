import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

/// 假的 claude / codex / gemini: 只在内存或临时目录中记录 layerlens 的配置, 不触碰真实客户端。
/// gemini 没有 mcp get, 由 LayerLens 读取 settings.json, 所以假 gemini 写临时 home 下的文件。
final class FakeCLI {
    var configured: [String: String] = [:]
    var calls: [[String]] = []
    let home: URL

    init(home: URL) { self.home = home }

    func geminiSettings(_ change: (inout [String: Any]) -> Void) {
        let file = home.appendingPathComponent(".gemini/settings.json")
        var settings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        settings["mcpServers"] = servers
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: settings).write(to: file)
    }

    func run(_ path: String, _ arguments: [String]) -> MCPClientInstaller.CommandResult {
        let name = (path as NSString).lastPathComponent
        calls.append([name] + arguments)
        if name == "zsh" || name == "bash" { return .init(status: 0, output: "/fake/bin:/usr/bin", timedOut: false) }
        if name == "gemini" {
            switch Array(arguments.prefix(2)) {
            case ["mcp", "add"]:
                geminiSettings { $0["layerlens"] = ["httpUrl": arguments.last!] }
                return .init(status: 0, output: "", timedOut: false)
            case ["mcp", "remove"]:
                geminiSettings { $0["layerlens"] = nil }
                return .init(status: 0, output: "", timedOut: false)
            default:
                return .init(status: 2, output: "unexpected", timedOut: false)
            }
        }
        switch Array(arguments.prefix(2)) {
        case ["mcp", "get"]:
            guard let url = configured[name] else { return .init(status: 1, output: "No MCP server", timedOut: false) }
            let output = name == "claude"
                ? "layerlens:\n  Scope: User config\n  Type: http\n  URL: \(url)\n"
                : "{\"name\":\"layerlens\",\"transport\":{\"type\":\"streamable_http\",\"url\":\"\(url)\"}}"
            return .init(status: 0, output: output, timedOut: false)
        case ["mcp", "add"]:
            if configured[name] != nil { return .init(status: 1, output: "already exists", timedOut: false) }
            configured[name] = arguments.last
            return .init(status: 0, output: "", timedOut: false)
        case ["mcp", "remove"]:
            configured[name] = nil
            return .init(status: 0, output: "", timedOut: false)
        default:
            return .init(status: 2, output: "unexpected", timedOut: false)
        }
    }
}

@main enum MCPClientsTests {
    static func main() throws {
        let url = "http://127.0.0.1:9523/mcp"
        require(MCPClientInstaller.claudeURL("layerlens:\n  Scope: User config\n  URL: \(url)\n\nTo remove…") == url, "Claude URL parse")
        require(MCPClientInstaller.codexURL("{\"transport\":{\"url\":\"\(url)\"}}") == url, "Codex URL parse")
        require(MCPClientInstaller.codexURL("Error: none") == nil, "Codex parse must tolerate errors")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("layerlens-mcp-clients-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("fakebin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["claude", "codex", "gemini"] {
            let file = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let fake = FakeCLI(home: home)
        let installer = MCPClientInstaller(url: url, home: home, shell: "/bin/zsh") { path, arguments, _, _ in
            fake.run(path, arguments)
        }
        // 假 shell 返回的 PATH 里没有这两个命令, 放到 ~/.local/bin 模拟用户安装后靠补充目录找到
        let local = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bin, to: local)
        require(installer.searchPath().first == "/fake/bin", "Login shell PATH must come first")
        require(installer.locate(.claude) == local.appendingPathComponent("claude").path, "Claude not located from fallback directory")

        var status = installer.status(.claude)
        require(status.mcp == .missing && status.skill == .missing, "Fresh client must be missing")

        require(installer.install(.claude, parts: [.mcp, .skill]).isEmpty, "Claude install failed")
        require(fake.calls.contains(["claude", "mcp", "add", "--transport", "http", "--scope", "user", "layerlens", url]),
                "Claude must be installed at user scope")
        status = installer.status(.claude)
        require(status.mcp == .installed && status.skill == .installed, "Claude install not detected")
        let skill = try String(contentsOf: home.appendingPathComponent(".claude/skills/layerlens/SKILL.md"), encoding: .utf8)
        require(skill.hasPrefix("---\nname: layerlens\n"), "Skill frontmatter must start the file")
        require(skill.contains("get_context") && skill.contains("curl -s -X POST \(url)"), "Skill content missing")

        // 已安装时再次安装不重复执行 add
        let adds = fake.calls.filter { $0.prefix(3) == ["claude", "mcp", "add"] }.count
        require(installer.install(.claude, parts: [.mcp]).isEmpty, "Reinstall failed")
        require(fake.calls.filter { $0.prefix(3) == ["claude", "mcp", "add"] }.count == adds, "Installed MCP was added again")

        // 地址不同: 先移除再添加
        fake.configured["codex"] = "http://127.0.0.1:1/mcp"
        require(installer.status(.codex).mcp == .different, "Different URL not detected")
        require(installer.install(.codex, parts: [.mcp]).isEmpty, "Codex update failed")
        require(fake.configured["codex"] == url, "Codex URL not updated")
        require(fake.calls.contains(["codex", "mcp", "add", "layerlens", "--url", url]), "Codex add arguments")

        // 旧版本 Skill 可以更新; 用户自己的同名文件不能覆盖或删除
        let codexSkill = home.appendingPathComponent(".codex/skills/layerlens/SKILL.md")
        try FileManager.default.createDirectory(at: codexSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old\n\(MCPClientInstaller.skillMarker)\n".utf8).write(to: codexSkill)
        require(installer.skillState(.codex) == .outdated, "Outdated skill not detected")
        require(installer.install(.codex, parts: [.skill]).isEmpty, "Skill update failed")
        require(installer.skillState(.codex) == .installed, "Skill not updated")
        try Data("my own skill".utf8).write(to: codexSkill)
        require(installer.skillState(.codex) == .conflict, "Foreign skill not detected")
        require(!installer.install(.codex, parts: [.skill]).isEmpty, "Foreign skill was overwritten")
        require(!installer.remove(.codex, parts: [.skill]).isEmpty, "Foreign skill was removed")
        require((try? String(contentsOf: codexSkill, encoding: .utf8)) == "my own skill", "Foreign skill changed")

        // 移除: MCP 交给 CLI, Skill 删除文件和空目录
        require(installer.remove(.claude, parts: [.mcp, .skill]).isEmpty, "Claude remove failed")
        require(fake.calls.contains(["claude", "mcp", "remove", "--scope", "user", "layerlens"]), "Claude remove arguments")
        require(fake.configured["claude"] == nil, "Claude MCP still configured")
        require(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/layerlens").path),
                "Empty skill directory left behind")
        require(installer.remove(.claude, parts: [.mcp, .skill]).isEmpty, "Removing twice must succeed")

        // Gemini CLI: 通过命令以 user scope 增删, 状态读 settings.json(允许注释)
        require(installer.status(.gemini).mcp == .missing, "Gemini must start missing")
        require(installer.install(.gemini, parts: [.mcp, .skill]).isEmpty, "Gemini install failed")
        require(fake.calls.contains(["gemini", "mcp", "add", "--scope", "user", "--transport", "http", "layerlens", url]), "Gemini add arguments")
        require(installer.status(.gemini).mcp == .installed, "Gemini install not detected")
        require(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/skills/layerlens/SKILL.md").path), "Gemini skill missing")
        let geminiSettings = home.appendingPathComponent(".gemini/settings.json")
        try Data("{\n  // comment\n  \"mcpServers\": {\"layerlens\": {\"url\": \"http://127.0.0.1:1/mcp\"}}\n}".utf8).write(to: geminiSettings)
        require(installer.status(.gemini).mcp == .different, "Gemini settings with comments must be readable")
        require(installer.install(.gemini, parts: [.mcp]).isEmpty, "Gemini update failed")
        require(fake.calls.contains(["gemini", "mcp", "remove", "--scope", "user", "layerlens"]), "Gemini remove arguments")
        require(installer.status(.gemini).mcp == .installed, "Gemini URL not updated")

        // Antigravity: 检测到 App 即可, 只改 mcp_config.json 中的 layerlens, 保留其他服务
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications/Antigravity.app"), withIntermediateDirectories: true)
        require(installer.locate(.antigravity) != nil, "Antigravity not located")
        let agyConfig = home.appendingPathComponent(".gemini/config/mcp_config.json")
        try FileManager.default.createDirectory(at: agyConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"mcpServers\":{\"other\":{\"command\":\"x\"}},\"keep\":1}".utf8).write(to: agyConfig)
        require(installer.status(.antigravity).mcp == .missing, "Antigravity must start missing")
        require(installer.install(.antigravity, parts: [.mcp, .skill]).isEmpty, "Antigravity install failed")
        var agy = try JSONSerialization.jsonObject(with: Data(contentsOf: agyConfig)) as! [String: Any]
        var agyServers = agy["mcpServers"] as! [String: Any]
        require((agyServers["layerlens"] as? [String: Any])?["url"] as? String == url, "Antigravity URL not written")
        require(agyServers["other"] != nil && agy["keep"] as? Int == 1, "Antigravity config not preserved")
        require(installer.status(.antigravity).mcp == .installed && installer.skillState(.antigravity) == .installed, "Antigravity install not detected")
        require(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/config/skills/layerlens/SKILL.md").path), "Antigravity skill missing")
        require(installer.remove(.antigravity, parts: [.mcp, .skill]).isEmpty, "Antigravity remove failed")
        agy = try JSONSerialization.jsonObject(with: Data(contentsOf: agyConfig)) as! [String: Any]
        agyServers = agy["mcpServers"] as! [String: Any]
        require(agyServers["layerlens"] == nil && agyServers["other"] != nil, "Antigravity remove must keep other servers")
        try Data("{ // not plain JSON\n}".utf8).write(to: agyConfig)
        require(installer.status(.antigravity).mcp == .unknown, "Invalid Antigravity config must be unknown")
        require(!installer.install(.antigravity, parts: [.mcp]).isEmpty, "Invalid Antigravity config was overwritten")
        require((try? String(contentsOf: agyConfig, encoding: .utf8)) == "{ // not plain JSON\n}", "Invalid Antigravity config changed")

        let statuses = installer.statuses()
        require(statuses.map(\.client) == [.claude, .codex, .gemini, .antigravity], "Statuses must keep client order")
        require(statuses[1].json["mcp"] as? String == "installed" && statuses[1].json["found"] as? Bool == true, "Status JSON")
        print("PASS MCP clients: locate, status, user-scope install, URL update, skill ownership and removal, Gemini CLI, Antigravity config")
    }
}
