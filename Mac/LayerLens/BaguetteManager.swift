//
//  BaguetteManager.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation

/// 管理三方工具 baguette (模拟器画面与输入): 随 LayerLens 启动和退出, 意外退出时自动重启.
/// 使用独立端口, 不影响用户自己启动的 baguette
final class BaguetteManager {
    static let port: UInt16 = 9524
    static let restartDelay: TimeInterval = 3

    private let queue = DispatchQueue(label: "com.layerlens.baguette")
    private var process: Process?
    private var stopping = false
    private(set) var executablePath: String?

    var isInstalled: Bool {
        queue.sync { executablePath != nil }
    }

    var isRunning: Bool {
        queue.sync { process?.isRunning == true }
    }

    func start() {
        queue.async { [self] in
            stopping = false
            executablePath = Self.locate()
            launch()
        }
    }

    /// 同步结束进程, 在 App 退出时调用
    func stop() {
        queue.sync {
            stopping = true
            process?.terminate()
            process?.waitUntilExit()
            process = nil
        }
    }

    /// 未安装时稍后重新查找, 用户安装后无需重启 LayerLens
    private func launch() {
        guard !stopping else { return }
        guard let path = executablePath ?? Self.locate() else {
            queue.asyncAfter(deadline: .now() + Self.restartDelay) { [self] in launch() }
            return
        }
        executablePath = path
        // 上次 LayerLens 异常退出时遗留的进程会占用端口
        _ = TargetRegistry.run("/usr/bin/pkill", ["-f", "baguette serve --port \(Self.port)"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["serve", "--port", "\(Self.port)", "--host", "127.0.0.1", "--allowed-hosts", "127.0.0.1", "--no-plugins"]
        let log = Self.logHandle()
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + Self.restartDelay) {
                guard !self.stopping, self.process === process else { return }
                self.process = nil
                self.launch()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            queue.asyncAfter(deadline: .now() + Self.restartDelay) { [self] in launch() }
        }
    }

    /// GUI App 不继承终端的 PATH, 依次查找 Homebrew 默认路径和登录 shell
    private static func locate() -> String? {
        for path in ["/opt/homebrew/bin/baguette", "/usr/local/bin/baguette"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let data = TargetRegistry.run("/bin/zsh", ["-lc", "command -v baguette"]),
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private static func logHandle() -> FileHandle? {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/LayerLens")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("baguette.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        return try? FileHandle(forWritingTo: file)
    }
}
