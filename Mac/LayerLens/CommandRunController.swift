import CryptoKit
import Foundation

/// 命令行运行与 Xcode 自动化分离。同一设备只保留最新请求，设备之间互不阻塞。
final class CommandRunController {
    private final class Job {
        let id = UUID().uuidString
        let device: String
        let bundle: String
        let source: String
        let simulator: Bool
        let owner: String
        let xcodePath: String
        let beforeBuild: () -> Void
        let created = Date()
        var status = "queued"
        var buildStarted = false
        var detail = ""
        var cancelled = false
        var process: Process?
        var canTerminate = false
        var superseded = false
        init(device: String, bundle: String, source: String, simulator: Bool, owner: String, xcodePath: String, beforeBuild: @escaping () -> Void) {
            self.device = device; self.bundle = bundle; self.source = source; self.simulator = simulator; self.owner = owner
            self.xcodePath = xcodePath
            self.beforeBuild = beforeBuild
        }
    }
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var active: [String: Job] = [:]
    private var pending: [String: Job] = [:]
    private var latestOrders: [String: Int] = [:]
    private struct Selection { let device: String; let bundle: String; let order: Int }
    private var selections: [String: Selection] = [:]
    private let worker = DispatchQueue(label: "com.layerlens.command-run", attributes: .concurrent)
    private let defaultsKey = "LayerLensCommandRunRelativeProjects"
    private let executable: String
    private let queryTimeout: TimeInterval
    private let cacheRoot: URL
    init(executable: String = "/usr/bin/xcrun", queryTimeout: TimeInterval = 30, cacheRoot: URL? = nil) {
        self.executable = executable; self.queryTimeout = queryTimeout
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("LayerLens/CommandBuilds", isDirectory: true)
    }

    func start(device: String, bundle: String, source: String, simulator: Bool, owner: String = "", order: Int = 0, xcodePath: String = "", beforeBuild: @escaping () -> Void = {}) -> String {
        let job = Job(device: device, bundle: bundle, source: source, simulator: simulator, owner: owner, xcodePath: xcodePath, beforeBuild: beforeBuild)
        lock.lock()
        jobs = jobs.filter { _, old in
            !["succeeded", "failed", "cancelled", "superseded", "skipped"].contains(old.status) || Date().timeIntervalSince(old.created) < 3600
        }
        let orderKey = owner + "|" + device
        if !owner.isEmpty && order <= (latestOrders[orderKey] ?? 0) {
            job.cancelled = true; job.superseded = true; job.status = "superseded"
            jobs[job.id] = job
            lock.unlock(); return job.id
        }
        if !owner.isEmpty {
            latestOrders[orderKey] = order
            setSelectionLocked(owner: owner, device: device, bundle: bundle, order: order)
        }
        jobs[job.id] = job
        if let previous = pending.updateValue(job, forKey: device) {
            previous.cancelled = true; previous.status = "superseded"
        }
        if let current = active[device] {
            current.cancelled = true; current.superseded = true
            if current.canTerminate, let process = current.process, process.isRunning { Self.interrupt(process) }
        }
        let next = takeNext(device)
        lock.unlock()
        if let next { launch(next) }
        return job.id
    }

    private func setSelectionLocked(owner: String, device: String, bundle: String, order: Int) {
        guard !owner.isEmpty, order > (selections[owner]?.order ?? 0) else { return }
        selections[owner] = Selection(device: device, bundle: bundle, order: order)
    }
    func selectTarget(owner: String, device: String, bundle: String, order: Int) {
        lock.lock(); defer { lock.unlock() }
        setSelectionLocked(owner: owner, device: device, bundle: bundle, order: order)
    }

    func cancel(id: String) {
        lock.lock()
        guard let job = jobs[id] else { lock.unlock(); return }
        job.cancelled = true
        if pending[job.device] === job { pending[job.device] = nil; job.status = "cancelled" }
        if job.canTerminate, let process = job.process, process.isRunning { Self.interrupt(process) }
        lock.unlock()
    }

    func shutdown() {
        lock.lock()
        let running = Array(active.values)
        for job in pending.values { job.cancelled = true; job.status = "cancelled" }
        pending.removeAll()
        for job in running {
            job.cancelled = true
            if job.canTerminate, let process = job.process, process.isRunning { Self.interrupt(process) }
        }
        lock.unlock()
    }

    private static func interrupt(_ process: Process) {
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// 当前每台设备最新的命令行任务，供页面刷新或新窗口恢复状态。
    func currentRuns() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let devices = Set(active.keys).union(pending.keys)
        return devices.compactMap { device in
            guard let job = pending[device] ?? active[device], !job.cancelled else { return nil }
            return ["runId": job.id, "device": job.device, "app": job.bundle, "status": job.status, "buildStarted": job.buildStarted]
        }
    }

    func status(id: String) -> (String, String, Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[id] else { return nil }
        return (job.status, job.detail, job.buildStarted)
    }

    private func takeNext(_ device: String) -> Job? {
        guard active[device] == nil, let job = pending.removeValue(forKey: device) else { return nil }
        active[device] = job
        return job
    }
    private func launch(_ job: Job) {
        worker.async { [self] in
            run(job)
            lock.lock()
            if job.cancelled { job.status = job.superseded ? "superseded" : "cancelled" }
            if active[job.device] === job { active[job.device] = nil }
            let next = takeNext(job.device)
            lock.unlock()
            if let next { launch(next) }
        }
    }
    private func update(_ job: Job, _ status: String, _ detail: String = "") -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !job.cancelled else { return false }
        job.status = status; job.detail = detail
        return true
    }
    private func shouldPressHome(_ job: Job) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !job.cancelled && (job.owner.isEmpty ||
            (selections[job.owner]?.device == job.device && selections[job.owner]?.bundle == job.bundle))
    }
    private func mayLaunch(_ job: Job) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !job.cancelled else { return false }
        if !job.owner.isEmpty {
            guard let selection = selections[job.owner], selection.device == job.device, selection.bundle == job.bundle else {
                job.status = "skipped"; return false
            }
        }
        return true
    }
    private static func buildProgress(_ line: String) -> String? {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let kind = fields.first else { return nil }
        switch kind {
        case "SwiftCompile", "CompileSwift", "CompileC", "CompileCXX":
            let extensions = [".swift", ".m", ".mm", ".c", ".cc", ".cpp"]
            guard let path = fields.dropFirst().first(where: { field in extensions.contains { field.hasSuffix($0) } }) else { return nil }
            return "编译 " + URL(fileURLWithPath: path).lastPathComponent
        case "Ld": return "链接"
        case "CodeSign": return "签名"
        case "CompileAssetCatalog", "CompileAssetCatalogVariant": return "编译资源"
        case "LinkStoryboards": return "处理界面资源"
        case "PhaseScriptExecution": return "执行构建脚本"
        default: return nil
        }
    }
    private func runProcess(_ job: Job, _ arguments: [String], cancellable: Bool, environment: [String: String] = [:], executablePath: String? = nil, marksBuild: Bool = false, requireSelection: Bool = false, timeout: TimeInterval? = nil) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath ?? executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        if executablePath == nil {
            env["DEVELOPER_DIR"] = job.xcodePath.isEmpty ? nil : job.xcodePath + "/Contents/Developer"
        }
        for (key, value) in environment { env[key] = value }
        process.environment = env
        lock.lock()
        guard !job.cancelled else { lock.unlock(); return nil }
        if requireSelection && !job.owner.isEmpty {
            guard let selection = selections[job.owner], selection.device == job.device, selection.bundle == job.bundle else {
                job.status = "skipped"; lock.unlock(); return nil
            }
        }
        do { try process.run() } catch { lock.unlock(); return (-1, error.localizedDescription) }
        job.process = process; job.canTerminate = cancellable
        if marksBuild { job.buildStarted = true; job.status = "building" }
        lock.unlock()
        var timedOut = false
        let timer: DispatchWorkItem? = timeout.map { seconds in
            let item = DispatchWorkItem { [self] in
                lock.lock(); defer { lock.unlock() }
                if job.process === process && process.isRunning { timedOut = true; Self.interrupt(process) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        // 子进程可能继承输出管道；父进程退出后不要无限等待后代关闭管道。
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var output = Data()
        var progressLine = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
                if output.count > 8 * 1024 * 1024 { output.removeFirst(output.count - 8 * 1024 * 1024) }
                if marksBuild {
                    progressLine.append(buffer, count: count)
                    while let end = progressLine.firstIndex(of: 10) {
                        let line = String(decoding: progressLine[..<end], as: UTF8.self)
                        progressLine.removeSubrange(...end)
                        if let detail = Self.buildProgress(line) {
                            lock.lock()
                            if job.status == "building" && !job.cancelled { job.detail = detail }
                            lock.unlock()
                        }
                    }
                    if progressLine.count > 65536 { progressLine.removeAll() }
                }
            } else if count == 0 { break }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.02)
            } else { break }
        }
        process.waitUntilExit()
        timer?.cancel()
        lock.lock(); job.process = nil; job.canTerminate = false; let cancelled = job.cancelled; let expired = timedOut; lock.unlock()
        if cancelled { return nil }
        if expired { return (-1, "项目配置查询超时") }
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
    private func fail(_ job: Job, _ message: String) { _ = update(job, "failed", String(message.suffix(4000))) }

    private func run(_ job: Job, useSavedScheme: Bool = true) {
        guard update(job, "resolving") else { return }
        if !job.xcodePath.isEmpty && !XcodeController.installedXcodes().contains(where: { $0.path == URL(fileURLWithPath: job.xcodePath).resolvingSymlinksInPath().path }) {
            fail(job, "所选 Xcode 不可用，请重新选择"); return
        }
        guard !job.source.isEmpty else { fail(job, "未找到 App 上报的源码路径，无法查找项目"); return }
        let sourceDir = URL(fileURLWithPath: job.source).deletingLastPathComponent().standardizedFileURL
        let packageBuild = XcodeSourcePath.packageBuildDirectory(containing: sourceDir)
        let hostProject = packageBuild.flatMap(XcodeSourcePath.hostProject(in:))
        if packageBuild != nil && hostProject == nil {
            fail(job, "无法从 Xcode 构建目录确定宿主项目"); return
        }
        if hostProject == nil && !FileManager.default.fileExists(atPath: sourceDir.path) {
            fail(job, "App 上报的源码目录不存在，无法查找项目"); return
        }
        let savedKey = hostProject.map { job.bundle + "|" + $0 } ?? job.bundle
        let saved = useSavedScheme ? (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: String]])?[savedKey] : nil
        let savedProject = hostProject ?? saved.flatMap { Self.resolveRelative($0["path"] ?? "", from: sourceDir) }
        let sdk = job.simulator ? "iphonesimulator" : "iphoneos"
        var resolutionFailed = false
        var targetSettings: [String: [[String: Any]]] = [:]
        var failedTargetSettings = Set<String>()
        func plans(_ project: String) -> [(String, XcodeRunPlan.Candidate)]? {
            let flag = project.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
            guard let list = runProcess(job, ["xcodebuild", flag, project, "-list", "-json", "-disableAutomaticPackageResolution", "-skipPackageUpdates"], cancellable: true, timeout: queryTimeout) else { return nil }
            let jsonText = list.1.firstIndex(of: "{").map { String(list.1[$0...]) } ?? list.1
            guard list.0 == 0, let data = jsonText.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = (json["workspace"] ?? json["project"]) as? [String: Any], let names = info["schemes"] as? [String] else { resolutionFailed = true; return [] }
            var matched: [(String, XcodeRunPlan.Candidate)] = []
            for candidate in XcodeRunPlan.candidates(workspace: project, schemes: names) {
                let key = candidate.project + "\n" + candidate.configuration
                if failedTargetSettings.contains(key) { continue }
                if targetSettings[key] == nil {
                    guard let result = runProcess(job, ["xcodebuild", "-project", candidate.project, "-alltargets", "-configuration", candidate.configuration, "-sdk", sdk, "-showBuildSettings", "-json", "-disableAutomaticPackageResolution", "-skipPackageUpdates"], cancellable: true, timeout: queryTimeout) else { return nil }
                    guard result.0 == 0, let values = XcodeRunPlan.decodeSettings(Data(result.1.utf8)) else { resolutionFailed = true; failedTargetSettings.insert(key); continue }
                    targetSettings[key] = values
                }
                guard let values = targetSettings[key], XcodeRunPlan.matchesBundle(values, candidate: candidate, bundleId: job.bundle) else { continue }
                // 项目级结果仅用于筛选，最终仍验证工作区和 Scheme 的实际 Bundle ID。
                guard let exact = runProcess(job, ["xcodebuild", flag, project, "-scheme", candidate.scheme, "-configuration", candidate.configuration, "-sdk", sdk, "-showBuildSettings", "-json", "-disableAutomaticPackageResolution", "-skipPackageUpdates"], cancellable: true, timeout: queryTimeout) else { return nil }
                guard exact.0 == 0, let verified = XcodeRunPlan.decodeSettings(Data(exact.1.utf8)) else { resolutionFailed = true; continue }
                if XcodeRunPlan.matchesBundle(verified, candidate: candidate, bundleId: job.bundle) { matched.append((project, candidate)) }
            }
            return matched
        }
        var chosen: (String, XcodeRunPlan.Candidate)?
        if let saved, let savedProject, FileManager.default.fileExists(atPath: savedProject),
           let scheme = saved["scheme"], !scheme.isEmpty {
            let candidates = XcodeRunPlan.candidates(workspace: savedProject, schemes: [scheme])
            if candidates.count == 1, let candidate = candidates.first {
                chosen = (savedProject, candidate)
            } else if hostProject == nil {
                fail(job, "保存的 Scheme 不存在或运行目标不明确，请检查项目配置"); return
            }
        } else if saved != nil && hostProject == nil {
            fail(job, "保存的项目路径或 Scheme 不可用，请检查项目位置和运行配置"); return
        }
        let hasSavedProject = chosen != nil
        if chosen == nil {
            guard update(job, "resolving") else { return }
            resolutionFailed = false
            let projects: [String]
            if let hostProject {
                projects = [hostProject]
            } else {
                let git = runProcess(job, ["-C", sourceDir.path, "rev-parse", "--show-toplevel"], cancellable: true, executablePath: "/usr/bin/git", timeout: min(queryTimeout, 5))
                guard let git else { return }
                if git.0 != 0 && git.1 == "项目配置查询超时" { fail(job, "Git 仓库查询超时，请检查仓库后重试"); return }
                let root = git.0 == 0 ? git.1.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                let deadline = ProcessInfo.processInfo.systemUptime + 20
                guard let found = Self.findProjects(sourceDir: sourceDir, repository: root, shouldContinue: {
                    self.lock.lock(); let current = !job.cancelled; self.lock.unlock()
                    return current && ProcessInfo.processInfo.systemUptime < deadline
                }) else { fail(job, "项目扫描超时或无法读取，请检查源码所在仓库"); return }
                projects = found
            }
            var matches: [(String, XcodeRunPlan.Candidate)] = []
            for (index, project) in projects.enumerated() {
                guard update(job, "resolving", "\(index + 1)/\(projects.count)") else { return }
                guard let found = plans(project) else { return }
                matches.append(contentsOf: found)
            }
            guard !resolutionFailed else { fail(job, "项目配置查询超时或无法读取，请检查项目后重试"); return }
            // 仅去掉工作区已包含的同一项目入口，不合并不同工作区。
            func identity(_ candidate: XcodeRunPlan.Candidate) -> String {
                [candidate.project, candidate.target, candidate.scheme, candidate.configuration].joined(separator: "\n")
            }
            let workspaceIDs = Set(matches.filter { $0.0.hasSuffix(".xcworkspace") }.map { identity($0.1) })
            let unique = matches.filter { $0.0.hasSuffix(".xcworkspace") || !workspaceIDs.contains(identity($0.1)) }
            guard unique.count == 1, let match = unique.first else {
                fail(job, unique.isEmpty ? "未找到与此 App Bundle ID 匹配的项目和 Scheme" : "多个项目或 Scheme 匹配此 App，请保留唯一的运行配置")
                return
            }
            chosen = match
        }
        guard let (project, plan) = chosen else { return }
        let flag = project.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let cacheKey = [project, plan.project, plan.scheme, plan.target, job.device, job.xcodePath].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let derived = cacheRoot.appendingPathComponent(digest, isDirectory: true).path
        let base = ["xcodebuild", flag, project, "-scheme", plan.scheme, "-configuration", plan.configuration, "-destination", "id=\(job.device)", "-derivedDataPath", derived]
        guard let settings = runProcess(job, base + ["-showBuildSettings", "-json"], cancellable: true, timeout: queryTimeout) else { return }
        guard settings.0 == 0, let values = XcodeRunPlan.decodeSettings(Data(settings.1.utf8)) else {
            fail(job, settings.1.isEmpty ? "无法读取当前 Scheme 的构建配置" : settings.1); return
        }
        guard let value = values.first(where: { XcodeRunPlan.matchesBundle([$0], candidate: plan, bundleId: job.bundle) }) else {
            if hostProject != nil && hasSavedProject {
                // Scheme 仍存在但已改绑目标。只重新发现一次，不重复发送 Home。
                run(job, useSavedScheme: false)
            } else {
                fail(job, "当前 Scheme 不再构建所选 App")
            }
            return
        }
        guard let build = value["buildSettings"] as? [String: Any],
              let directory = build["TARGET_BUILD_DIR"] as? String, !directory.isEmpty,
              let name = build["WRAPPER_NAME"] as? String, name.hasSuffix(".app"), name == (name as NSString).lastPathComponent else {
            fail(job, "当前 Scheme 不再构建所选 App，或无法确定构建产物"); return
        }
        let app = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let launch = Self.launchOptions(project: project, plan: plan)
        guard !launch.unsupported else { fail(job, "此 Scheme 的运行脚本或自定义工作目录需要通过 Xcode 运行"); return }
        func expand(_ text: String) -> String? {
            var result = text
            let regex = try! NSRegularExpression(pattern: #"\$\(([^)]+)\)"#)
            for _ in 0..<8 {
                let ns = result as NSString
                let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
                if matches.isEmpty { return result }
                for match in matches.reversed() {
                    let key = ns.substring(with: match.range(at: 1))
                    guard let value = build[key] as? String, let range = Range(match.range, in: result) else { return nil }
                    result.replaceSubrange(range, with: value)
                }
            }
            return nil
        }
        var arguments: [String] = []
        for value in launch.arguments {
            guard let expanded = expand(value) else { fail(job, "无法解析 Scheme 启动参数中的构建变量"); return }
            arguments.append(expanded)
        }
        var expandedEnvironment: [String: String] = [:]
        for (key, value) in launch.environment {
            guard let expanded = expand(value) else { fail(job, "无法解析 Scheme 环境变量中的构建变量"); return }
            expandedEnvironment[key] = expanded
        }
        var environment: [String: String] = [:]
        let command: [String]
        if job.simulator {
            for (key, value) in expandedEnvironment { environment["SIMCTL_CHILD_" + key] = value }
            command = ["simctl", "launch", "--terminate-running-process", job.device, job.bundle] + arguments
        } else {
            for (key, value) in expandedEnvironment { environment["DEVICECTL_CHILD_" + key] = value }
            command = ["devicectl", "device", "process", "launch", "--terminate-existing", "--device", job.device, job.bundle, "--"] + arguments
        }
        if !hasSavedProject {
            // SwiftPM 每次从宿主元数据获取项目，只保存该项目对应的 Scheme。
            var configuration = ["scheme": plan.scheme]
            if hostProject == nil {
                configuration["path"] = Self.relativePath(from: sourceDir, to: URL(fileURLWithPath: project))
            }
            lock.lock()
            var savedProjects = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]
            savedProjects[savedKey] = configuration
            UserDefaults.standard.set(savedProjects, forKey: defaultsKey)
            // 清理本 App 的旧格式绝对路径；其他 App 的记录留待各自迁移。
            var legacy = UserDefaults.standard.dictionary(forKey: "LayerLensCommandRunProjects") as? [String: String] ?? [:]
            if let old = legacy.removeValue(forKey: job.bundle) {
                UserDefaults.standard.set(legacy, forKey: "LayerLensCommandRunProjects")
                UserDefaults.standard.removeObject(forKey: "LayerLensCommandRunScheme." + job.bundle + "." + old)
            }
            lock.unlock()
        }
        if shouldPressHome(job) { job.beforeBuild() }
        guard let built = runProcess(job, base + ["build"], cancellable: true, marksBuild: true) else { return }
        guard built.0 == 0 else { fail(job, built.1); return }
        guard Self.appMatchesBundle(app, bundleId: job.bundle) else {
            fail(job, "构建成功，但指定产物的 Bundle ID 与当前 App 不匹配"); return
        }
        guard update(job, "installing") else { return }
        let install = job.simulator ? ["simctl", "install", job.device, app.path] : ["devicectl", "device", "install", "app", "--device", job.device, app.path]
        guard let installed = runProcess(job, install, cancellable: false) else { return }
        guard installed.0 == 0 else { fail(job, installed.1); return }
        guard mayLaunch(job), update(job, "launching") else { return }
        guard let launched = runProcess(job, command, cancellable: false, environment: environment, requireSelection: true) else { return }
        guard launched.0 == 0 else { fail(job, launched.1); return }
        _ = update(job, "succeeded")
    }
    static func appMatchesBundle(_ app: URL, bundleId: String) -> Bool {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return false }
        return plist["CFBundleIdentifier"] as? String == bundleId
    }
    static func launchOptions(project: String, plan: XcodeRunPlan.Candidate) -> (arguments: [String], environment: [String: String], unsupported: Bool) {
        var locations: [String] = []
        for root in [project, plan.project] {
            locations.append(root + "/xcshareddata/xcschemes/" + plan.scheme + ".xcscheme")
            let userDir = root + "/xcuserdata/" + NSUserName() + ".xcuserdatad/xcschemes/"
            locations.append(userDir + plan.scheme + ".xcscheme")
        }
        guard let path = locations.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let document = try? XMLDocument(contentsOf: URL(fileURLWithPath: path), options: []) else { return ([], [:], false) }
        let arguments = ((try? document.nodes(forXPath: "/Scheme/LaunchAction/CommandLineArguments/CommandLineArgument")) ?? []).compactMap { node -> String? in
            guard let element = node as? XMLElement, element.attribute(forName: "isEnabled")?.stringValue != "NO" else { return nil }
            return element.attribute(forName: "argument")?.stringValue
        }
        var environment: [String: String] = [:]
        for node in (try? document.nodes(forXPath: "/Scheme/LaunchAction/EnvironmentVariables/EnvironmentVariable")) ?? [] {
            guard let element = node as? XMLElement, element.attribute(forName: "isEnabled")?.stringValue != "NO", let key = element.attribute(forName: "key")?.stringValue, let value = element.attribute(forName: "value")?.stringValue else { continue }
            environment[key] = value
        }
        let scripts = (try? document.nodes(forXPath: "/Scheme/LaunchAction/PreActions/ExecutionAction | /Scheme/LaunchAction/PostActions/ExecutionAction")) ?? []
        let action = (try? document.nodes(forXPath: "/Scheme/LaunchAction"))?.first as? XMLElement
        let customDirectory = action?.attribute(forName: "useCustomWorkingDirectory")?.stringValue == "YES"
        return (arguments, environment, !scripts.isEmpty || customDirectory)
    }
    static func relativePath(from base: URL, to target: URL) -> String {
        let a = base.standardizedFileURL.pathComponents
        let b = target.standardizedFileURL.pathComponents
        let common = zip(a, b).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: a.count - common) + Array(b.dropFirst(common))).joined(separator: "/")
    }
    static func resolveRelative(_ path: String, from base: URL) -> String? {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else { return nil }
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasSuffix(".xcodeproj") || url.path.hasSuffix(".xcworkspace") else { return nil }
        return url.path
    }
    // 仓库内遍历，排除依赖与构建目录；没有仓库时仅搜索祖先目录。
    static func findProjects(sourceDir: URL, repository: String?, shouldContinue: () -> Bool = { true }) -> [String]? {
        let fm = FileManager.default
        let excluded: Set<String> = ["Pods", "DerivedData", ".build", "build", "node_modules", "Carthage", ".git", "xcuserdata", "SourcePackages"]
        var found: [String] = []
        if let repository, !repository.isEmpty {
            let root = URL(fileURLWithPath: repository, isDirectory: true)
            var failed = false
            guard let iter = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return false }) else { return nil }
            var count = 0
            for case let url as URL in iter {
                count += 1
                if count > 100_000 || (count % 128 == 0 && !shouldContinue()) { return nil }
                let name = url.lastPathComponent
                if excluded.contains(name) || name.hasSuffix(".xcassets") || name.hasSuffix(".xcframework") || name.hasSuffix(".framework") || name.hasSuffix(".app") { iter.skipDescendants(); continue }
                if name.hasSuffix(".xcworkspace") || name.hasSuffix(".xcodeproj") {
                    if name != "project.xcworkspace" && name != "Pods.xcodeproj" { found.append(url.path) }
                    iter.skipDescendants()
                }
            }
            if failed { return nil }
        } else {
            var dir = sourceDir
            for _ in 0..<16 {
                guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
                found += entries.filter { ($0.pathExtension == "xcworkspace" && $0.lastPathComponent != "project.xcworkspace") || ($0.pathExtension == "xcodeproj" && $0.lastPathComponent != "Pods.xcodeproj") }.map(\.path)
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return Array(Set(found)).sorted()
    }
}
