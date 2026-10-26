//
//  GitController.swift
//  LayerLens
//
//  Created by YueYou on 10/23/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import CoreServices
import AppKit
import Foundation
import Network

/// 工作区改动面板: 仓库由 App 上报的编译源文件路径推断, 网页只传 bundleId, 不接受任意路径.
/// 只在有网页观看时监听仓库文件变化(FSEvents), 变化后防抖执行 git status 推送; 无人观看时不执行任何 git 命令
final class GitController {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String

        var ok: Bool { status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
        /// 失败时给网页看的说明: 优先错误输出, git 有时把错误写在标准输出
        var message: String {
            let error = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return error.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : error
        }
    }

    /// 一个仓库的观看者与文件监听
    private final class Watch {
        let root: String
        var subscribers: [ObjectIdentifier: NWConnection] = [:]
        var stream: FSEventStreamRef?
        var refreshing = false
        var dirty = false
        /// 已开始和已推送的读取序号, 先开始的读取晚完成时不覆盖新状态
        var started = 0
        var published = 0
        var pending: DispatchWorkItem?
        /// 上次推送的内容, 新观看者加入时先发这份
        var last: Data?

        init(root: String) {
            self.root = root
        }
    }

    private static let git = "/usr/bin/git"
    private static let debounce: TimeInterval = 0.5
    private static let maxDiffBytes = 1024 * 1024
    private static let maxFilesPerGroup = 2000
    private static let noisyDirectories = ["/DerivedData/", "/build/", "/.build/", "/xcuserdata/", "/.DS_Store"]

    /// 管理观看者与监听
    private let queue = DispatchQueue(label: "com.layerlens.git")
    /// 执行 git status / diff 等读操作
    private let readQueue = DispatchQueue(label: "com.layerlens.git.read", attributes: .concurrent)
    /// 写操作串行执行, 拉取推送较慢时不影响读
    private let writeQueue = DispatchQueue(label: "com.layerlens.git.write")
    private var watches: [String: Watch] = [:]
    /// 源文件所在目录 -> 仓库根目录
    private var roots: [String: String] = [:]
    private let rootsLock = NSLock()

    // MARK: - Repository

    /// 源文件所在的仓库根目录, 不在仓库中时为 nil
    func repository(sourceFile: String) -> String? {
        guard !sourceFile.isEmpty else { return nil }
        let directory = (sourceFile as NSString).deletingLastPathComponent
        rootsLock.lock()
        let cached = roots[directory]
        rootsLock.unlock()
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let output = Self.run(directory, ["rev-parse", "--show-toplevel"], timeout: 10)
        guard output.ok else { return nil }
        let root = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        rootsLock.lock()
        roots[directory] = root
        rootsLock.unlock()
        return root
    }

    // MARK: - Commands

    /// 在仓库中执行 git; 交互提示全部关闭, 需要凭据时直接失败而不是卡住
    static func run(_ repo: String, _ arguments: [String], timeout: TimeInterval, readOnly: Bool = false, input: Data? = nil) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repo] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        // 图形界面启动时 PATH 很短, 补上 Homebrew 目录, git-lfs 等钩子依赖的工具才能找到
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // 读操作不刷新索引, 不和 Xcode 或命令行的 git 抢锁
        if readOnly { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: Data(), stderr: error.localizedDescription)
        }
        if let input, let inputPipe {
            DispatchQueue.global().async {
                inputPipe.fileHandleForWriting.write(input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        let timedOut = Flag()
        let timer = DispatchWorkItem { [weak process] in
            timedOut.value = true
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // 错误输出在后台读取, 两个管道任一写满都不会互相阻塞
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        timer.cancel()
        let stderr = String(decoding: errorData, as: UTF8.self)
        return Output(status: process.terminationStatus, stdout: outputData, stderr: timedOut.value ? "Timed out\n" + stderr : stderr)
    }

    /// 分支与文件状态
    func status(repo: String) -> [String: Any] {
        let output = Self.run(repo, ["status", "--porcelain=v2", "--branch", "-z", "-uall"], timeout: 30, readOnly: true)
        guard output.ok else { return ["error": output.message] }
        var result = Self.parseStatus(output.stdout, root: repo)
        // 纯本地仓库没有远程, 网页隐藏拉取 / 推送
        let remotes = Self.run(repo, ["remote"], timeout: 10, readOnly: true)
        result["hasRemote"] = !remotes.text.isEmpty
        return result
    }

    static func parseStatus(_ data: Data, root: String) -> [String: Any] {
        var branch: [String: Any] = [:]
        var staged: [[String: Any]] = []
        var unstaged: [[String: Any]] = []
        var untracked: [[String: Any]] = []
        var conflicted: [[String: Any]] = []
        var truncated = false
        func add(_ entry: [String: Any], to list: inout [[String: Any]]) {
            if list.count < maxFilesPerGroup { list.append(entry) } else { truncated = true }
        }
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": branch["oid"] = parts[1]
                case "branch.head": branch["head"] = parts[1]
                case "branch.upstream": branch["upstream"] = parts[1]
                case "branch.ab":
                    let ab = parts[1].split(separator: " ")
                    if ab.count == 2 {
                        branch["ahead"] = Int(ab[0].dropFirst()) ?? 0
                        branch["behind"] = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") {
                // 1 XY sub mH mI mW hH hI path; 2 在 hI 后多一个相似度字段, 原路径在下一条记录
                let fieldCount = record.hasPrefix("1 ") ? 9 : 10
                let fields = record.split(separator: " ", maxSplits: fieldCount - 1, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == fieldCount else { continue }
                let xy = Array(fields[1])
                let path = fields[fieldCount - 1]
                var origin: String?
                if record.hasPrefix("2 "), index < records.count {
                    origin = records[index]
                    index += 1
                }
                if xy[0] != "." {
                    var entry: [String: Any] = ["path": path, "status": String(xy[0])]
                    entry["origin"] = origin
                    add(entry, to: &staged)
                }
                if xy[1] != "." {
                    add(["path": path, "status": String(xy[1])], to: &unstaged)
                }
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 11 else { continue }
                add(["path": fields[10], "status": fields[1]], to: &conflicted)
            } else if record.hasPrefix("? ") {
                add(["path": String(record.dropFirst(2)), "status": "?"], to: &untracked)
            }
        }
        return [
            "root": root,
            "name": (root as NSString).lastPathComponent,
            "branch": branch,
            "staged": staged,
            "unstaged": unstaged,
            "untracked": untracked,
            "conflicted": conflicted,
            "truncated": truncated,
        ]
    }

    /// 单个文件的统一 diff; group 为 staged / unstaged / untracked / conflicted
    func diff(repo: String, path: String, origin: String?, group: String, completion: @escaping ([String: Any]) -> Void) {
        readQueue.async {
            var arguments = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff"]
            switch group {
            case "staged":
                arguments += ["--cached", "-M", "--"] + [origin, path].compactMap { $0 }
            case "untracked":
                arguments += ["--no-index", "--", "/dev/null", path]
            default:
                arguments += ["--", path]
            }
            let output = Self.run(repo, arguments, timeout: 30, readOnly: true)
            // --no-index 有差异时退出码为 1
            guard output.ok || (group == "untracked" && output.status == 1) else {
                completion(["error": output.message])
                return
            }
            let truncated = output.stdout.count > Self.maxDiffBytes
            let text = String(decoding: truncated ? output.stdout.prefix(Self.maxDiffBytes) : output.stdout, as: UTF8.self)
            completion(["text": text, "truncated": truncated])
        }
    }

    /// 一个或多个提交的全部改动; 每个提交前有一行 "\0短哈希 标题"
    func show(repo: String, commits: [String], completion: @escaping ([String: Any]) -> Void) {
        guard !commits.isEmpty, commits.count <= 50, commits.allSatisfy({ $0.range(of: "^[0-9a-f]{4,40}$", options: .regularExpression) != nil }) else {
            completion(["error": "Invalid commit"])
            return
        }
        readQueue.async {
            let output = Self.run(repo, ["-c", "core.quotePath=false", "show", "--format=%x00%h %s", "-M", "--no-color", "--no-ext-diff"] + commits, timeout: 30, readOnly: true)
            guard output.ok else {
                completion(["error": output.message])
                return
            }
            let truncated = output.stdout.count > Self.maxDiffBytes
            let text = String(decoding: truncated ? output.stdout.prefix(Self.maxDiffBytes) : output.stdout, as: UTF8.self)
            completion(["text": text, "truncated": truncated])
        }
    }

    /// 用默认 App 打开仓库内的文件; 只接受仓库内已存在的路径
    func open(repo: String, path: String) -> Bool {
        let root = URL(fileURLWithPath: repo).standardizedFileURL.path
        let url = URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, url.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: url.path) else { return false }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        return true
    }

    /// 在 Finder 中选中仓库内的文件; 已删除的文件退到最近的存在的上级目录
    func reveal(repo: String, path: String) -> Bool {
        let root = URL(fileURLWithPath: repo).standardizedFileURL.path
        var url = URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, url.path.hasPrefix(root + "/") else { return false }
        while !FileManager.default.fileExists(atPath: url.path), url.path.count > root.count {
            url = url.deletingLastPathComponent()
        }
        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return true
    }

    /// 单个提交的补丁文本(git format-patch)
    func patch(repo: String, commit: String, completion: @escaping ([String: Any]) -> Void) {
        guard commit.range(of: "^[0-9a-f]{4,40}$", options: .regularExpression) != nil else {
            completion(["error": "Invalid commit"])
            return
        }
        readQueue.async {
            let output = Self.run(repo, ["format-patch", "-1", "--stdout", "--no-color", commit], timeout: 30, readOnly: true)
            guard output.ok else {
                completion(["error": output.message])
                return
            }
            let truncated = output.stdout.count > Self.maxDiffBytes
            let text = String(decoding: truncated ? output.stdout.prefix(Self.maxDiffBytes) : output.stdout, as: UTF8.self)
            completion(["text": text, "truncated": truncated])
        }
    }

    /// 提交记录, 每页 50 条, skip 用于滑动加载更多
    func log(repo: String, skip: Int, completion: @escaping ([String: Any]) -> Void) {
        readQueue.async {
            // 网页按完整哈希和父提交画分支图; 引用用完整名区分本地分支、远端分支和标签
            let format = "--format=%h%x1f%s%x1f%an%x1f%ar%x1f%ct%x1f%H%x1f%P%x1f%D"
            let output = Self.run(repo, ["log", "-n", "50", "--skip", String(max(skip, 0)), "--date-order", "--decorate=full", format], timeout: 15, readOnly: true)
            // 还没有提交的新仓库没有日志
            guard output.ok else {
                completion(["commits": []])
                return
            }
            let commits = output.text.split(separator: "\n").map { line -> [String: String] in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                return ["hash": parts[safe: 0] ?? "", "subject": parts[safe: 1] ?? "", "author": parts[safe: 2] ?? "", "date": parts[safe: 3] ?? "", "time": parts[safe: 4] ?? "", "oid": parts[safe: 5] ?? "", "parents": parts[safe: 6] ?? "", "refs": parts[safe: 7] ?? ""]
            }
            completion(["commits": commits])
        }
    }

    /// 写操作, 完成后立即刷新所有观看者
    func perform(_ action: String, repo: String, json: [String: Any], completion: @escaping ([String: Any], Int) -> Void) {
        let paths = (json["paths"] as? [String] ?? []).filter { !$0.isEmpty }
        let untracked = (json["untracked"] as? [String] ?? []).filter { !$0.isEmpty }
        var commands: [(arguments: [String], timeout: TimeInterval)] = []
        var input: Data?
        switch action {
        // 路径经标准输入传给 git, 文件很多时不受命令行长度限制; 文件多时较慢, 超时放宽
        case "stage" where !paths.isEmpty:
            input = Data(paths.joined(separator: "\0").utf8)
            commands = [(["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], 120)]
        case "unstage" where !paths.isEmpty:
            input = Data(paths.joined(separator: "\0").utf8)
            commands = [(["restore", "--staged", "--pathspec-from-file=-", "--pathspec-file-nul"], 120)]
        case "discard" where !paths.isEmpty || !untracked.isEmpty:
            if !paths.isEmpty { commands.append((["restore", "--worktree", "--"] + paths, 30)) }
            if !untracked.isEmpty { commands.append((["clean", "-f", "--"] + untracked, 30)) }
        case "commit":
            let message = (json["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let amend = json["amend"] as? Bool == true
            guard !message.isEmpty || amend else {
                completion(["error": "Empty commit message"], 400)
                return
            }
            var arguments = ["commit"]
            if amend { arguments.append("--amend") }
            arguments += message.isEmpty ? ["--no-edit"] : ["-m", message]
            // 提交钩子可能较慢
            commands = [(arguments, 120)]
        case "hunk":
            // 按块暂存 / 取消暂存 / 放弃: 网页提交单个块的补丁, 通过标准输入交给 git apply
            let patch = json["patch"] as? String ?? ""
            let modes = ["stage": ["--cached"], "unstage": ["--cached", "-R"], "discard": ["-R"]]
            guard patch.hasPrefix("diff --git "), let mode = modes[json["mode"] as? String ?? ""] else {
                completion(["error": "Invalid request"], 400)
                return
            }
            input = Data(patch.utf8)
            commands = [(["apply", "--whitespace=nowarn"] + mode + ["-"], 30)]
        case "reset":
            // 只移动当前分支, 工作区和暂存区保持不变; 原提交仍可从 reflog 找回
            let commit = json["commit"] as? String ?? ""
            guard commit.range(of: "^[0-9a-f]{4,40}$", options: .regularExpression) != nil else {
                completion(["error": "Invalid commit"], 400)
                return
            }
            commands = [(["reset", "--soft", commit], 30)]
        case "revert":
            let commit = json["commit"] as? String ?? ""
            guard commit.range(of: "^[0-9a-f]{4,40}$", options: .regularExpression) != nil else {
                completion(["error": "Invalid commit"], 400)
                return
            }
            commands = [(["revert", "--no-edit", commit], 120)]
        case "pull":
            commands = [(["pull", "--ff-only"], 120)]
        case "push":
            commands = [([], 120)]
        default:
            completion(["error": "Invalid request"], 400)
            return
        }
        writeQueue.async { [self] in
            // 已有进行中的回滚时不再回滚, 也不能替用户撤销它
            if action == "revert", Self.run(repo, ["rev-parse", "-q", "--verify", "REVERT_HEAD"], timeout: 10, readOnly: true).ok {
                completion(["error": "A revert is already in progress"], 409)
                return
            }
            var last: Output?
            for command in commands {
                var arguments = command.arguments
                if action == "push" {
                    // 没有上游分支时推到 origin 的同名分支并设为上游
                    let upstream = Self.run(repo, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: 10, readOnly: true)
                    arguments = upstream.ok ? ["push"] : ["push", "-u", "origin", "HEAD"]
                }
                let output = Self.run(repo, arguments, timeout: command.timeout, input: input)
                last = output
                if !output.ok { break }
            }
            // 回滚冲突或失败时撤销, 不让仓库停在回滚中途
            if action == "revert", let last, !last.ok {
                _ = Self.run(repo, ["revert", "--abort"], timeout: 30)
            }
            refreshNow(root: repo)
            if let last, !last.ok {
                completion(["error": last.message], 500)
            } else {
                completion(["ok": true, "output": last?.message ?? ""], 200)
            }
        }
    }

    // MARK: - Watching

    /// 网页打开改动面板时订阅; 立即推送一次状态, 之后仓库文件变化时推送
    func subscribe(root: String, connection: NWConnection) {
        queue.async { [self] in
            let watch = watches[root] ?? Watch(root: root)
            watches[root] = watch
            let id = ObjectIdentifier(connection)
            watch.subscribers[id] = connection
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 2000\n\n".utf8), completion: .contentProcessed { _ in })
            if let last = watch.last {
                connection.send(content: last, completion: .contentProcessed { _ in })
            }
            if watch.stream == nil { startStream(watch) }
            schedule(watch, delay: 0)
            watchClose(connection) { [weak self] in
                self?.queue.async {
                    watch.subscribers[id] = nil
                    guard watch.subscribers.isEmpty else { return }
                    self?.stopStream(watch)
                    watch.pending?.cancel()
                    watch.last = nil
                    self?.watches[root] = nil
                }
            }
        }
    }

    /// 写操作后在当前线程读取状态并推送, 推送后再响应网页, 网页的加载结束时列表已是新状态
    func refreshNow(root: String) {
        let seq: Int? = queue.sync {
            guard let watch = watches[root], !watch.subscribers.isEmpty else { return nil }
            watch.pending?.cancel()
            watch.pending = nil
            watch.started += 1
            return watch.started
        }
        guard let seq else { return }
        let data = statusEvent(repo: root)
        queue.sync {
            guard let watch = watches[root] else { return }
            publish(data, seq: seq, to: watch)
        }
    }

    /// 立即刷新时取消等待中的一次; 文件变化时已有等待中的就不再推迟, 持续变化(如编译中)也能按间隔刷新
    private func schedule(_ watch: Watch, delay: TimeInterval) {
        if delay > 0, let pending = watch.pending, !pending.isCancelled { return }
        watch.pending?.cancel()
        let item = DispatchWorkItem { [weak self, weak watch] in
            guard let watch else { return }
            watch.pending = nil
            self?.runStatus(watch)
        }
        watch.pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 同一时间只执行一次 status, 执行期间又有变化时结束后再执行一次
    private func runStatus(_ watch: Watch) {
        guard !watch.subscribers.isEmpty else { return }
        if watch.refreshing {
            watch.dirty = true
            return
        }
        watch.refreshing = true
        watch.started += 1
        let seq = watch.started
        readQueue.async { [self] in
            let data = statusEvent(repo: watch.root)
            queue.async { [self] in
                watch.refreshing = false
                publish(data, seq: seq, to: watch)
                if watch.dirty {
                    watch.dirty = false
                    schedule(watch, delay: Self.debounce)
                }
            }
        }
    }

    private func statusEvent(repo: String) -> Data {
        var data = Data("event: status\ndata: ".utf8)
        data.append((try? JSONSerialization.data(withJSONObject: status(repo: repo))) ?? Data("{}".utf8))
        data.append(Data("\n\n".utf8))
        return data
    }

    /// 在 queue 上调用. 写操作后的读取可能先于更早开始的一次完成, 旧状态不再推送
    private func publish(_ data: Data, seq: Int, to watch: Watch) {
        guard seq > watch.published else { return }
        watch.published = seq
        watch.last = data
        // 内容相同也推送: 文件内容变了而状态不变时, 网页据此刷新选中文件的 diff
        for connection in watch.subscribers.values {
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
        }
    }

    private func startStream(_ watch: Watch) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let controller = Unmanaged<GitController>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            controller.filesChanged(list.prefix(count).map { $0 })
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [watch.root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        watch.stream = stream
    }

    private func stopStream(_ watch: Watch) {
        guard let stream = watch.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        watch.stream = nil
    }

    /// 在 queue 上回调. 对象库、引用日志等 git 内部的写入不影响状态, 忽略; 索引、HEAD、分支引用的变化需要刷新
    private func filesChanged(_ paths: [String]) {
        for watch in watches.values {
            let gitDir = watch.root + "/.git/"
            let relevant = paths.contains { path in
                let path = path.hasSuffix("/") ? path : path + "/"
                guard path.hasPrefix(watch.root + "/") else { return false }
                // 编译产物与 Xcode 用户数据变化频繁且通常被忽略, 不触发刷新
                if Self.noisyDirectories.contains(where: { path.contains($0) }) { return false }
                guard path.hasPrefix(gitDir) else { return true }
                return !(path.hasPrefix(gitDir + "objects/") || path.hasPrefix(gitDir + "logs/") || path.hasPrefix(gitDir + "lfs/"))
            }
            if relevant { schedule(watch, delay: Self.debounce) }
        }
    }

    /// 持续读取, 网页关闭时及时释放
    private func watchClose(_ connection: NWConnection, onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
                onClose()
                return
            }
            self?.watchClose(connection, onClose: onClose)
        }
    }
}

private final class Flag {
    var value = false
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
