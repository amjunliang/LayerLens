//
//  TerminalController.swift
//  LayerLens
//
//  Created by YueYou on 10/23/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Darwin
import Foundation
import Network

/// 集成终端: 在 App 源码所在仓库的根目录启动用户的登录 shell(伪终端), 网页用 xterm.js 显示.
/// 会话不随网页断开结束, 用户关闭或 LayerLens 退出时结束; 每个会话保留最近的输出, 网页重新连接时回放
final class TerminalController {
    static let maxReplayBytes = 512 * 1024

    private final class Session {
        let id: String
        let root: String
        let name: String
        let app: String
        let pid: pid_t
        let master: Int32
        let created = Date()
        var replay = Data()
        var sockets: [ObjectIdentifier: WebSocketConnection] = [:]
        var readSource: DispatchSourceRead?
        var exitSource: DispatchSourceProcess?
        var command = ""
        var exited = false
        var exitStatus: Int32 = 0

        init(id: String, root: String, name: String, app: String, pid: pid_t, master: Int32) {
            self.id = id
            self.root = root
            self.name = name
            self.app = app
            self.pid = pid
            self.master = master
        }

        var busy: Bool { !exited && !command.isEmpty }
    }

    private let queue = DispatchQueue(label: "com.layerlens.terminal")
    private var sessions: [Session] = []
    /// 已从列表移除、等待进程退出的会话, 退出后释放监听
    private var closing: [Session] = []
    private var subscribers: [ObjectIdentifier: NWConnection] = [:]
    private var poll: DispatchSourceTimer?
    private var lastList = Data()
    private var counter = 0

    // MARK: - Sessions

    /// 新建会话, 返回会话 id; 失败返回 nil
    func create(root: String, app: String) -> String? {
        queue.sync {
            counter += 1
            let id = "t\(counter)"
            guard let (pid, master) = Self.spawnShell(root: root) else { return nil }
            let session = Session(id: id, root: root, name: (root as NSString).lastPathComponent, app: app, pid: pid, master: master)
            let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            read.setEventHandler { [weak self, weak session] in
                guard let self, let session else { return }
                self.readOutput(session)
            }
            read.setCancelHandler { Darwin.close(master) }
            read.resume()
            session.readSource = read
            let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [weak self, weak session] in
                guard let self, let session else { return }
                self.finish(session)
            }
            exit.resume()
            session.exitSource = exit
            sessions.append(session)
            publish()
            return id
        }
    }

    /// 结束会话: 先挂断整个进程组, 仍未退出时强制结束
    func close(id: String) -> Bool {
        queue.sync {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
            let session = sessions.remove(at: index)
            terminate(session)
            publish()
            return true
        }
    }

    /// LayerLens 退出时调用: 挂断全部会话, 稍等后强制结束仍在运行的
    func terminateAll() {
        queue.sync {
            let running = (sessions + closing).filter { !$0.exited }
            running.forEach {
                kill(-$0.pid, SIGHUP)
                kill($0.pid, SIGHUP)
            }
            if !running.isEmpty { usleep(300_000) }
            running.forEach {
                kill(-$0.pid, SIGKILL)
                kill($0.pid, SIGKILL)
            }
            sessions.removeAll()
            closing.removeAll()
        }
    }

    /// 退出前提醒用: 会话总数和正在运行命令的会话数
    func summary() -> (total: Int, busy: Int) {
        queue.sync {
            refreshCommands()
            return (sessions.count, sessions.filter(\.busy).count)
        }
    }

    private func terminate(_ session: Session) {
        session.sockets.values.forEach { $0.close() }
        session.sockets.removeAll()
        guard !session.exited else {
            session.readSource?.cancel()
            session.readSource = nil
            return
        }
        closing.append(session)
        kill(-session.pid, SIGHUP)
        kill(session.pid, SIGHUP)
        let pid = session.pid
        queue.asyncAfter(deadline: .now() + 1) {
            guard !session.exited else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private func readOutput(_ session: Session) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(session.master, &buffer, buffer.count)
        guard count > 0 else {
            // shell 退出后主端读到 EOF 或 EIO, 停止读取, 退出状态由进程监听处理
            session.readSource?.cancel()
            session.readSource = nil
            return
        }
        let data = Data(buffer.prefix(count))
        session.replay.append(data)
        if session.replay.count > Self.maxReplayBytes {
            session.replay = Data(session.replay.suffix(Self.maxReplayBytes))
        }
        session.sockets.values.forEach { $0.sendBinary(data) { _ in } }
    }

    private func finish(_ session: Session) {
        var status: Int32 = 0
        waitpid(session.pid, &status, WNOHANG)
        session.exited = true
        session.exitStatus = (status >> 8) & 0xff
        session.command = ""
        session.exitSource?.cancel()
        session.exitSource = nil
        if let index = closing.firstIndex(where: { $0 === session }) {
            closing.remove(at: index)
            session.readSource?.cancel()
            session.readSource = nil
        }
        publish()
    }

    // MARK: - Spawn

    /// forkpty 启动登录 shell; 子进程中只调用 chdir / execve / _exit 等异步信号安全函数, 参数在 fork 前准备好
    private static func spawnShell(root: String) -> (pid_t, Int32)? {
        let shell = userShell()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "LayerLens"
        environment["PWD"] = root
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // 以 - 开头的 argv[0] 表示登录 shell, 会读取用户的 profile
        let argv = ["-" + (shell as NSString).lastPathComponent].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(shell)
        let directory = strdup(root)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(path)
            free(directory)
        }
        var master: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { return nil }
        if pid == 0 {
            _ = chdir(directory)
            argv.withUnsafeBufferPointer { argv in
                envp.withUnsafeBufferPointer { envp in
                    _ = execve(path, argv.baseAddress, envp.baseAddress)
                }
            }
            _exit(127)
        }
        let flags = fcntl(master, F_GETFD)
        _ = fcntl(master, F_SETFD, flags | FD_CLOEXEC)
        return (pid, master)
    }

    private static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    // MARK: - WebSocket

    /// 连接后先回放最近的输出, 再实时转发; 网页发来 {"t":"i","d":输入} 或 {"t":"r","c":列,"r":行}
    func accept(id: String, head: HTTPRequestHead, leftover: Data, connection: HubConnection) {
        guard head.header("Upgrade")?.lowercased() == "websocket" else {
            connection.respond(.error(400, "WebSocket upgrade required"))
            return
        }
        let socket = WebSocketConnection(connection: connection.detach(), leftover: leftover)
        guard socket.accept(head) else { return }
        queue.async { [self] in
            guard let session = sessions.first(where: { $0.id == id }) else {
                socket.close()
                return
            }
            let key = ObjectIdentifier(socket)
            session.sockets[key] = socket
            if !session.replay.isEmpty { socket.sendBinary(session.replay) { _ in } }
            socket.onText = { [weak self, weak session] text in
                self?.queue.async {
                    guard let session else { return }
                    self?.receive(text, session: session)
                }
            }
            socket.onClose = { [weak self, weak session] in
                self?.queue.async { session?.sockets[key] = nil }
            }
        }
    }

    private func receive(_ text: String, session: Session) {
        guard !session.exited, let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        switch json["t"] as? String {
        case "i":
            guard let input = json["d"] as? String else { return }
            // 输入带着该窗口的尺寸: 多个窗口连着同一会话时, 以正在输入的窗口为准
            resize(session, cols: json["c"] as? Int, rows: json["r"] as? Int)
            var bytes = Array(input.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeMutableBufferPointer { write(session.master, $0.baseAddress! + offset, $0.count - offset) }
                if written <= 0 { break }
                offset += written
            }
        case "r":
            resize(session, cols: json["c"] as? Int, rows: json["r"] as? Int)
        default:
            break
        }
    }

    /// 尺寸不变时内核不会发 SIGWINCH, 重复设置没有影响
    private func resize(_ session: Session, cols: Int?, rows: Int?) {
        guard let cols, let rows, cols > 0, rows > 0 else { return }
        var size = winsize(ws_row: UInt16(min(rows, 1000)), ws_col: UInt16(min(cols, 1000)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(session.master, TIOCSWINSZ, &size)
    }

    // MARK: - Session list

    /// 会话列表事件流: 立即推送一次, 之后列表或前台命令变化时推送
    func subscribe(connection: NWConnection) {
        queue.async { [self] in
            let id = ObjectIdentifier(connection)
            subscribers[id] = connection
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 2000\n\n".utf8), completion: .contentProcessed { _ in })
            connection.send(content: listEvent(), completion: .contentProcessed { _ in })
            startPolling()
            watchClose(connection) { [weak self] in
                self?.queue.async {
                    self?.subscribers[id] = nil
                    if self?.subscribers.isEmpty == true {
                        self?.poll?.cancel()
                        self?.poll = nil
                    }
                }
            }
        }
    }

    /// 有网页订阅时每秒检查各会话的前台命令, 用于显示忙碌状态
    private func startPolling() {
        guard poll == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.publish() }
        timer.resume()
        poll = timer
    }

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "login"]

    /// shell 的后代中, 处于所在终端前台且不是 shell 的进程即正在运行的命令. 不能只看 shell 的终端:
    /// 有的 shell 配置(如 kiro-cli-term)会再开一层伪终端运行真正的 shell; tcgetpgrp 也只能查自己的控制终端
    private func refreshCommands() {
        let running = sessions.filter { !$0.exited }
        guard !running.isEmpty else { return }
        let processes = Self.allProcesses()
        var children: [pid_t: [kinfo_proc]] = [:]
        processes.forEach { children[$0.kp_eproc.e_ppid, default: []].append($0) }
        for session in running {
            var command = ""
            var queue = children[session.pid] ?? []
            while !queue.isEmpty {
                let process = queue.removeFirst()
                let name = Self.name(of: process)
                let foreground = process.kp_eproc.e_pgid == process.kp_eproc.e_tpgid
                if foreground, !Self.shells.contains(String(name.split(separator: " ").first ?? "")) { command = name }
                queue += children[process.kp_proc.p_pid] ?? []
            }
            session.command = command
        }
    }

    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // 两次调用之间可能有新进程, 多留一些空间
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func name(of process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            let name = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            return (name as NSString).lastPathComponent
        }
    }

    private func publish() {
        refreshCommands()
        let data = listEvent()
        guard data != lastList else { return }
        lastList = data
        for connection in subscribers.values {
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
        }
    }

    private func listEvent() -> Data {
        let list = sessions.map { session -> [String: Any] in
            ["id": session.id, "name": session.name, "root": session.root, "app": session.app, "command": session.command, "busy": session.busy, "exited": session.exited, "status": session.exitStatus, "created": session.created.timeIntervalSince1970]
        }
        var data = Data("event: sessions\ndata: ".utf8)
        data.append((try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8))
        data.append(Data("\n\n".utf8))
        return data
    }

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
