//
//  XcodeController.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit

/// 按选中 App 的 Bundle ID 验证 Scheme, 再通过 AppleScript 在指定设备上运行.
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
            case busy = "xcode_busy"
            case schemeUnavailable = "xcode_scheme_unverified"
            case destinationUnavailable = "xcode_destination_unavailable"
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
    private let operationLock = NSLock()

    struct RunSession {
        let id: String
        let xcode: String
        let path: String
        let action: String
        let created: Date
    }
    private var sessions: [String: RunSession] = [:]

    /// 精确匹配 Run Action 的 App Bundle ID, 不沿用无关 Scheme / 设备。
    func run(sourceFile: String, deviceId: String, bundleId: String, simulator: Bool) -> Result<String, Failure> {
        guard operationLock.try() else { return .failure(Failure(code: .busy)) }
        defer { operationLock.unlock() }
        guard !bundleId.isEmpty, !deviceId.isEmpty else { return .failure(Failure(code: .schemeUnavailable)) }
        return checkPermission(ask: true).flatMap { workspace(for: sourceFile) }.flatMap { xcode, path in
            let metadata = """
            set doc to first workspace document whose path is \(quoted(path))
            return (name of active scheme of doc) & linefeed & ((name of schemes of doc) as text)
            """
            return execute(metadata, xcode: xcode).flatMap { output in
                let names = output.components(separatedBy: "\n")
                let schemes = Array(names.dropFirst()).filter { !$0.isEmpty }
                let sdk = simulator ? "iphonesimulator" : "iphoneos"
                let deadline = Date().addingTimeInterval(18)
                let builder = xcode + "/Contents/Developer/usr/bin/xcodebuild"
                func settings(_ arguments: [String]) -> [[String: Any]]? {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0, let result = BoundedProcess.capture(builder,
                        arguments + ["-showBuildSettings", "-json", "-sdk", sdk, "-disableAutomaticPackageResolution", "-skipPackageUpdates"], timeout: remaining),
                        !result.timedOut, result.status == 0 else { return nil }
                    return XcodeRunPlan.decodeSettings(result.data)
                }
                let candidates = XcodeRunPlan.candidates(workspace: path, schemes: schemes)
                guard let plan = XcodeRunPlan.choose(candidates, active: names.first ?? "", bundleId: bundleId, settings: { project, config in
                    settings(["-project", project, "-alltargets", "-configuration", config])
                }) else { return .failure(Failure(code: .schemeUnavailable)) }
                let containerFlag = path.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
                guard let actual = settings([containerFlag, path, "-scheme", plan.scheme, "-configuration", plan.configuration]),
                      XcodeRunPlan.matchesBundle(actual, candidate: plan, bundleId: bundleId) else { return .failure(Failure(code: .schemeUnavailable)) }
                // Scheme 和目标在同一个脚本中设置, 找不到设备时终止, 绝不运行到别的设备。
                let script = """
                set doc to first workspace document whose path is \(quoted(path))
                set active scheme of doc to first scheme of doc whose name is \(quoted(plan.scheme))
                set picked to missing value
                repeat with destination in (run destinations of doc)
                    try
                        if (device identifier of (device of destination)) is \(quoted(deviceId)) then
                            if picked is missing value or (architecture of destination) is not "x86_64" then set picked to contents of destination
                            if (architecture of destination) is not "x86_64" then exit repeat
                        end if
                    end try
                end repeat
                if picked is missing value then error "layerlens_destination_unavailable"
                set active run destination of doc to picked
                set actionResult to run doc
                return id of actionResult
                """
                return execute(script, xcode: xcode, timeout: 5).map { action in
                    let id = UUID().uuidString
                    sessions = sessions.filter { Date().timeIntervalSince($0.value.created) < 900 }
                    if sessions.count >= 16, let oldest = sessions.values.min(by: { $0.created < $1.created }) { sessions.removeValue(forKey: oldest.id) }
                    sessions[id] = RunSession(id: id, xcode: xcode, path: path, action: action, created: Date())
                    return id
                }
            }
        }
    }

    func status(runId: String) -> Result<RunStatus, Failure> {
        guard operationLock.try() else { return .failure(Failure(code: .busy)) }
        defer { operationLock.unlock() }
        guard let session = sessions[runId], Date().timeIntervalSince(session.created) < 900 else {
            return .success(RunStatus(status: "cancelled", detail: ""))
        }
        return checkPermission(ask: false).flatMap { _ in
            let script = """
            set doc to first workspace document whose path is \(quoted(session.path))
            set actionResult to last scheme action result of doc
            if actionResult is missing value then return "none"
            if (id of actionResult) is not \(quoted(session.action)) then return "cancelled"
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
            return execute(script, xcode: session.xcode).map { output in
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
    private func execute(_ body: String, xcode: String, timeout: TimeInterval = 3) -> Result<String, Failure> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.xcodeBundleId).isEmpty else {
            return .failure(.xcodeNotRunning)
        }
        let source = """
        set AppleScript's text item delimiters to linefeed
        tell application \(quoted(xcode))
        \(body)
        end tell
        """
        guard let result = BoundedProcess.capture("/usr/bin/osascript", ["-e", source], timeout: timeout) else {
            return .failure(.scriptFailed)
        }
        if result.timedOut {
            return .failure(Failure(code: .scriptFailed, message: "Xcode did not respond within \(Int(timeout)) seconds"))
        }
        let message = String(decoding: result.data, as: UTF8.self)
        guard result.status == 0 else {
            if message.contains("layerlens_destination_unavailable") { return .failure(Failure(code: .destinationUnavailable)) }
            // -1743: 未获得自动化权限; -1719 / -1728: 找不到对应的工作区
            if message.contains("-1743") {
                return .failure(.permissionDenied)
            }
            if message.contains("-1728") || message.contains("-1719") {
                return .failure(.projectNotOpen)
            }
            return .failure(Failure(code: .scriptFailed, message: message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let text = message
        return .success(text.hasSuffix("\n") ? String(text.dropLast()) : text)
    }

    private func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Scheme 的 Run Action 决定真正启动哪个 App; Build Action 中的依赖不能作为启动目标。
enum XcodeRunPlan {
    struct Candidate: Equatable {
        let scheme: String
        let project: String
        let target: String
        let configuration: String
    }

    static func choose(_ candidates: [Candidate], active: String, bundleId: String,
                       settings: (String, String) -> [[String: Any]]?) -> Candidate? {
        var cache: [String: [[String: Any]]] = [:]
        var matches: [Candidate] = []
        for candidate in candidates.sorted(by: { ($0.scheme == active ? 0 : 1) < ($1.scheme == active ? 0 : 1) }) {
            let key = candidate.project + "\n" + candidate.configuration
            if cache[key] == nil {
                guard let values = settings(candidate.project, candidate.configuration) else { return nil }
                cache[key] = values
            }
            if matchesBundle(cache[key]!, candidate: candidate, bundleId: bundleId) {
                if candidate.scheme == active { return candidate }
                matches.append(candidate)
            }
        }
        if let current = matches.first(where: { $0.scheme == active }) { return current }
        return matches.count == 1 ? matches[0] : nil
    }

    static func matchesBundle(_ values: [[String: Any]], candidate: Candidate, bundleId: String) -> Bool {
        values.contains { value in
            guard value["target"] as? String == candidate.target,
                  let settings = value["buildSettings"] as? [String: Any],
                  settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == bundleId,
                  settings["WRAPPER_EXTENSION"] as? String == "app",
                  let path = settings["PROJECT_FILE_PATH"] as? String else { return false }
            return normalized(path) == normalized(candidate.project)
        }
    }

    static func decodeSettings(_ data: Data) -> [[String: Any]]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: #"\[\s*\{"#, options: .regularExpression),
              let end = text.range(of: "]", options: .backwards), end.upperBound > start.lowerBound else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start.lowerBound..<end.upperBound].utf8)) as? [[String: Any]]
    }

    static func candidates(workspace: String, schemes: [String]) -> [Candidate] {
        let manager = FileManager.default
        var containers = [normalized(workspace)]
        var index = 0
        // 只读取工作区引用的项目, 不递归扫描 Pods 或整个源码目录。
        while index < containers.count && containers.count < 100 {
            let container = containers[index]
            index += 1
            guard container.hasSuffix(".xcworkspace"),
                  let xml = try? XMLDocument(contentsOf: URL(fileURLWithPath: container).appendingPathComponent("contents.xcworkspacedata"), options: []) else { continue }
            for node in (try? xml.nodes(forXPath: "//FileRef")) ?? [] {
                guard let element = node as? XMLElement, let location = element.attribute(forName: "location")?.stringValue else { continue }
                var base = (container as NSString).deletingLastPathComponent
                var groups: [XMLElement] = []
                var parent = element.parent
                while let value = parent {
                    if let group = value as? XMLElement, group.name == "Group" { groups.insert(group, at: 0) }
                    parent = value.parent
                }
                for group in groups {
                    if let value = group.attribute(forName: "location")?.stringValue { base = resolve(value, base: base, workspace: container) }
                }
                let path = resolve(location, base: base, workspace: container)
                if (path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace")) && !containers.contains(path) { containers.append(path) }
            }
        }
        var definitions: [String: [Candidate]] = [:]
        var explicit = Set<String>()
        for container in containers {
            let directories = [container + "/xcshareddata/xcschemes", container + "/xcuserdata/" + NSUserName() + ".xcuserdatad/xcschemes"]
            for directory in directories {
                for file in ((try? manager.contentsOfDirectory(atPath: directory)) ?? []).filter({ $0.hasSuffix(".xcscheme") }).sorted() {
                    let name = (file as NSString).deletingPathExtension
                    guard schemes.contains(name) else { continue }
                    explicit.insert(name)
                    guard let xml = try? XMLDocument(contentsOf: URL(fileURLWithPath: directory + "/" + file), options: []),
                          let action = (try? xml.nodes(forXPath: "/Scheme/LaunchAction"))?.first as? XMLElement,
                          let config = action.attribute(forName: "buildConfiguration")?.stringValue,
                          let reference = (try? action.nodes(forXPath: "BuildableProductRunnable/BuildableReference"))?.first as? XMLElement,
                          let target = reference.attribute(forName: "BlueprintName")?.stringValue,
                          let location = reference.attribute(forName: "ReferencedContainer")?.stringValue else { continue }
                    let project = resolve(location, base: (container as NSString).deletingLastPathComponent, workspace: workspace)
                    let value = Candidate(scheme: name, project: project, target: target, configuration: config)
                    if !(definitions[name] ?? []).contains(value) { definitions[name, default: []].append(value) }
                }
            }
        }
        // 未保存的自动 Scheme 与同名 Native App target 对应。编辑过的 Scheme 会有文件,
        // 不得用自动生成的定义覆盖自定义 executable / Run configuration。
        for project in containers where project.hasSuffix(".xcodeproj") {
            guard let data = manager.contents(atPath: project + "/project.pbxproj"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let objects = plist["objects"] as? [String: [String: Any]] else { continue }
            for target in objects.values where target["isa"] as? String == "PBXNativeTarget" && target["productType"] as? String == "com.apple.product-type.application" {
                guard let name = target["name"] as? String, schemes.contains(name), !explicit.contains(name),
                      let listId = target["buildConfigurationList"] as? String,
                      let list = objects[listId], let ids = list["buildConfigurations"] as? [String],
                      ids.contains(where: { objects[$0]?["name"] as? String == "Debug" }) else { continue }
                definitions[name, default: []].append(Candidate(scheme: name, project: project, target: name, configuration: "Debug"))
            }
        }
        // 同名定义冲突时不能猜 Xcode 会用哪一个。
        return schemes.compactMap { name in
            guard let values = definitions[name], values.count == 1 else { return nil }
            return values[0]
        }
    }

    private static func resolve(_ location: String, base: String, workspace: String) -> String {
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return normalized(base + "/" + location) }
        switch parts[0] {
        case "absolute": return normalized(parts[1])
        case "self": return normalized((workspace as NSString).deletingLastPathComponent + "/" + parts[1])
        case "container": return normalized(base + "/" + parts[1])
        default: return normalized(base + "/" + parts[1])
        }
    }
    private static func normalized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
}
