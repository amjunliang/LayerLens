//
//  XcodeController.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit

/// 通过 AppleScript 让 Xcode 按当前 Scheme 和运行目标运行, 与点击 Xcode 的运行按钮一致.
/// 由 LayerLens 进程执行, 系统的"自动化"权限归属 LayerLens.
/// 多个 Xcode(如 Xcode.app 与 Xcode 26.6.app)的 Bundle ID 相同, 按应用路径分别发送脚本, 在打开了对应工作区的那个 Xcode 中运行
final class XcodeController {
    struct Failure: Error {
        enum Code: String {
            case xcodeNotRunning = "xcode_not_running"
            case projectNotOpen = "project_not_open"
            case permissionDenied = "permission_denied"
            /// 尚未询问过用户, 点击运行时会弹出系统授权窗口
            case permissionRequired = "permission_required"
            case scriptFailed = "script_failed"
        }

        let code: Code
        /// osascript 的错误输出, 用于展示未识别的错误
        var message = ""

        static let xcodeNotRunning = Failure(code: .xcodeNotRunning)
        static let projectNotOpen = Failure(code: .projectNotOpen)
        static let permissionDenied = Failure(code: .permissionDenied)
        static let permissionRequired = Failure(code: .permissionRequired)
        static let scriptFailed = Failure(code: .scriptFailed)
    }

    struct RunStatus {
        /// Xcode 的状态, 如 running / succeeded / failed / cancelled / error occurred
        let status: String
        let detail: String
    }

    private static let xcodeBundleId = "com.apple.dt.Xcode"

    /// - Parameter sourceFile: App 编译时的源文件路径, 用于找到对应的工作区
    func run(sourceFile: String) -> Result<Void, Failure> {
        // 由用户点击触发, 需要时弹出系统授权窗口并等待选择
        checkPermission(ask: true).flatMap { workspace(for: sourceFile) }.flatMap { xcode, path in
            execute("run (first workspace document whose path is \(quoted(path)))\nreturn \"\"", xcode: xcode).map { _ in () }
        }
    }

    func status(sourceFile: String) -> Result<RunStatus, Failure> {
        checkPermission(ask: false).flatMap { workspace(for: sourceFile) }.flatMap { xcode, path in
            let script = """
            set doc to first workspace document whose path is \(quoted(path))
            set actionResult to last scheme action result of doc
            if actionResult is missing value then return "none"
            set statusText to (status of actionResult) as text
            set detail to ""
            if statusText is "error occurred" then
                set detail to error message of actionResult
            else if statusText is "failed" and (count of build errors of actionResult) > 0 then
                set detail to message of build error 1 of actionResult
            end if
            if detail is missing value then set detail to ""
            return statusText & linefeed & detail
            """
            return execute(script, xcode: xcode).map { output in
                let lines = output.components(separatedBy: "\n")
                return RunStatus(status: lines.first ?? "", detail: lines.dropFirst().joined(separator: " "))
            }
        }
    }

    // MARK: - Workspace

    /// 优先选择所在目录包含源文件的工作区(取最深的); 没有时(如 Pod 以本地路径引入)选与源文件公共路径最长且唯一的;
    /// 不知道源文件(App 从未连接过)时, 只有一个打开的工作区才使用它. 知道源文件却匹配不到时不运行其他项目.
    /// 汇总所有运行中 Xcode 打开的工作区一起匹配, 返回匹配到的 Xcode 应用路径和工作区路径
    private func workspace(for sourceFile: String) -> Result<(xcode: String, path: String), Failure> {
        var owners: [(xcode: String, path: String)] = []
        var lastFailure: Failure?
        for xcode in runningXcodePaths() {
            switch execute("return (path of workspace documents) as text", xcode: xcode) {
            case .success(let output):
                output.components(separatedBy: "\n").filter { !$0.isEmpty }.forEach { owners.append((xcode, $0)) }
            case .failure(let failure):
                lastFailure = failure
            }
        }
        // 同一工作区在多个 Xcode 中打开时取第一个
        if let path = Self.match(sourceFile: sourceFile, workspaces: owners.map(\.path)), let owner = owners.first(where: { $0.path == path }) {
            return .success(owner)
        }
        // 所有 Xcode 都查询失败(如未授权)时报告失败原因, 否则视为未打开项目
        return .failure(owners.isEmpty ? lastFailure ?? .projectNotOpen : .projectNotOpen)
    }

    /// 运行中的 Xcode 应用路径, 当前激活的排在前面
    private func runningXcodePaths() -> [String] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.xcodeBundleId)
            .sorted { $0.isActive && !$1.isActive }
            .compactMap { $0.bundleURL?.path }
    }

    static func match(sourceFile: String, workspaces: [String]) -> String? {
        let directory = { (path: String) in (path as NSString).deletingLastPathComponent + "/" }
        if !sourceFile.isEmpty {
            let containing = workspaces.filter { sourceFile.hasPrefix(directory($0)) }
            if let best = containing.max(by: { directory($0).count < directory($1).count }) {
                return best
            }
            let source = sourceFile.split(separator: "/")
            let scored = workspaces.map { path -> (String, Int) in
                let parts = directory(path).split(separator: "/")
                return (path, zip(source, parts).prefix { $0 == $1 }.count)
            }.sorted { $0.1 > $1.1 }
            // 公共部分需超过用户目录一级, 且明显优于其他工作区
            let homeDepth = NSHomeDirectory().split(separator: "/").count
            if let first = scored.first, first.1 > homeDepth + 1, scored.count == 1 || scored[1].1 < first.1 {
                return first.0
            }
            return nil
        }
        return workspaces.count == 1 ? workspaces[0] : nil
    }

    // MARK: - AppleScript

    /// 查询"自动化"权限; ask 为 false 时不弹窗, 避免后台轮询触发系统窗口并阻塞
    private func checkPermission(ask: Bool) -> Result<Void, Failure> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.xcodeBundleId).isEmpty else {
            return .failure(.xcodeNotRunning)
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.xcodeBundleId)
        guard let descriptor = target.aeDesc else {
            return .failure(.scriptFailed)
        }
        switch AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask) {
        case noErr:
            return .success(())
        case OSStatus(errAEEventNotPermitted):
            return .failure(.permissionDenied)
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .failure(.permissionRequired)
        case OSStatus(procNotFound):
            return .failure(.xcodeNotRunning)
        default:
            return .failure(.scriptFailed)
        }
    }

    /// body 需以 return 返回文本, 列表转文本时以换行连接. 用 osascript 子进程执行, 不阻塞主线程(首次运行等待权限弹窗时也不卡窗口);
    /// 子进程的"自动化"权限仍归属 LayerLens. xcode 为应用路径, 指定发送给哪个 Xcode
    private func execute(_ body: String, xcode: String) -> Result<String, Failure> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.xcodeBundleId).isEmpty else {
            return .failure(.xcodeNotRunning)
        }
        let source = """
        set AppleScript's text item delimiters to linefeed
        tell application \(quoted(xcode))
        \(body)
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return .failure(.scriptFailed)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // -1743: 未获得自动化权限; -1719 / -1728: 找不到对应的工作区
            if message.contains("-1743") {
                return .failure(.permissionDenied)
            }
            if message.contains("-1728") || message.contains("-1719") {
                return .failure(.projectNotOpen)
            }
            return .failure(Failure(code: .scriptFailed, message: message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return .success(text.hasSuffix("\n") ? String(text.dropLast()) : text)
    }

    private func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
