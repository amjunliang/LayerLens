import Foundation

@main struct CommandRunTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/command-run-tests")
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("App.xcodeproj")
        let source = root.appendingPathComponent("Sources/Bridge.m")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent("xcshareddata/xcschemes"), withIntermediateDirectories: true)
        try "".write(to: source, atomically: true, encoding: .utf8)
        let bundle = "com.layerlens.test.command.\(UUID().uuidString)"
        let scheme = """
        <Scheme><LaunchAction buildConfiguration="Debug"><BuildableProductRunnable><BuildableReference BlueprintName="App" ReferencedContainer="container:App.xcodeproj"/></BuildableProductRunnable><CommandLineArguments><CommandLineArgument argument="-test" isEnabled="YES"/></CommandLineArguments><EnvironmentVariables><EnvironmentVariable key="MODE" value="test" isEnabled="YES"/></EnvironmentVariables></LaunchAction></Scheme>
        """
        try scheme.write(to: project.appendingPathComponent("xcshareddata/xcschemes/App.xcscheme"), atomically: true, encoding: .utf8)
        let settings: [[String: Any]] = [["target": "App", "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": bundle, "WRAPPER_EXTENSION": "app", "PROJECT_FILE_PATH": project.path, "TARGET_BUILD_DIR": "MOCK_BUILD_DIR", "WRAPPER_NAME": "App.app"]]]
        try JSONSerialization.data(withJSONObject: settings).write(to: root.appendingPathComponent("settings.json"))
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle], format: .xml, options: 0)
        try info.write(to: root.appendingPathComponent("app-info.plist"))
        try "{\"project\":{\"schemes\":[\"App\"]}}".write(to: root.appendingPathComponent("schemes.json"), atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("xcrun")
        let script = """
        #!/bin/sh
        derived=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '-derivedDataPath' ]; then derived="$argument"; break; fi
          previous="$argument"
        done
        products="$derived/Build/Products/Debug-iphonesimulator"
        case " $* " in
          *" -list "*) echo list >> '\(root.path)/events'; if [ -f '\(root.path)/hang' ]; then sleep 5; fi; cat '\(root.path)/schemes.json';;
          *" -showBuildSettings "*)
            echo "$*" >> '\(root.path)/settings-events'
            settings='\(root.path)/settings.json'
            case " $* " in
              *" -scheme App "*) if [ -f '\(root.path)/retargeted-settings.json' ]; then settings='\(root.path)/retargeted-settings.json'; fi;;
            esac
            sed "s|MOCK_BUILD_DIR|$products|g" "$settings";;
          *" build "*)
            if [ -f '\(root.path)/fail-build' ]; then echo 'forced build error'; exit 1; fi
            mkdir -p "$products/App.app"
            cp '\(root.path)/app-info.plist' "$products/App.app/Info.plist"
            echo build >> '\(root.path)/events'; sleep 1;;
          *" install "*) echo install >> '\(root.path)/events'; if [ "$3" = device-slow ]; then sleep 4; fi;;
          *" launch "*) echo launch >> '\(root.path)/events';;
          *) exit 1;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let controller = CommandRunController(executable: executable.path, cacheRoot: root.appendingPathComponent("cache"))
        precondition(CommandRunController.findProjects(sourceDir: source.deletingLastPathComponent(), repository: nil)?.contains(project.path) == true)
        let derived = root.appendingPathComponent("DerivedData/App")
        let checkout = derived.appendingPathComponent("SourcePackages/checkouts/LayerLens/Pod/Classes")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": project.appendingPathComponent("project.xcworkspace").path],
            format: .xml, options: 0)
        try metadata.write(to: derived.appendingPathComponent("info.plist"))
        precondition(XcodeSourcePath.packageBuildDirectory(containing: checkout).flatMap(XcodeSourcePath.hostProject(in:)) == project.path,
                     "A SwiftPM checkout must resolve to its host Xcode project")
        precondition(XcodeSourcePath.packageBuildDirectory(containing: source.deletingLastPathComponent()) == nil)
        let relative = CommandRunController.relativePath(from: source.deletingLastPathComponent(), to: project)
        precondition(!relative.hasPrefix("/") && CommandRunController.resolveRelative(relative, from: source.deletingLastPathComponent()) == project.standardizedFileURL.path)
        precondition(CommandRunController.resolveRelative(project.path, from: source.deletingLastPathComponent()) == nil, "Absolute saved paths must be rejected")
        let homeMarker = root.appendingPathComponent("home")
        let first = controller.start(device: "device-a", bundle: bundle, source: source.path, simulator: true) {
            try! Data().write(to: homeMarker)
        }
        let deadline = Date().addingTimeInterval(10)
        while controller.status(id: first)?.0 != "building" && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(controller.status(id: first)?.0 == "building" && controller.status(id: first)?.2 == true)
        precondition(fm.fileExists(atPath: homeMarker.path), "Home must finish before the compiler starts")
        precondition(controller.currentRuns().contains { ($0["runId"] as? String) == first && ($0["app"] as? String) == bundle }, "A page reload must recover the active target's run")
        let second = controller.start(device: "device-a", bundle: bundle, source: source.path, simulator: true)
        let third = controller.start(device: "device-a", bundle: bundle, source: source.path, simulator: true)
        precondition(controller.currentRuns().contains { ($0["runId"] as? String) == third }, "A pending newer run must replace the old snapshot")
        while !["succeeded", "failed"].contains(controller.status(id: third)?.0 ?? "") && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        precondition(controller.status(id: third)?.0 == "succeeded", controller.status(id: third)?.1 ?? "missing")
        precondition(controller.status(id: first)?.0 == "superseded")
        precondition(controller.status(id: second)?.0 == "superseded")
        precondition(controller.currentRuns().isEmpty, "Completed runs must not appear as active")
        let events = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(events.components(separatedBy: "install").count == 2 && events.components(separatedBy: "launch").count == 2)
        precondition(events.components(separatedBy: "list").count == 2, "A cached relative project must not enumerate schemes again")
        let stored = (UserDefaults.standard.dictionary(forKey: "LayerLensCommandRunRelativeProjects") as? [String: [String: String]])?[bundle]
        precondition(stored?["path"] == relative && stored?["scheme"] == "App", "Only the source-relative path and scheme should be persisted")
        let settingsBeforeCache = try String(contentsOf: root.appendingPathComponent("settings-events"), encoding: .utf8)
        let restoredController = CommandRunController(executable: executable.path, cacheRoot: root.appendingPathComponent("cache"))
        let cachedRun = restoredController.start(device: "device-cache", bundle: bundle, source: source.path, simulator: true)
        let cacheDeadline = Date().addingTimeInterval(10)
        while restoredController.status(id: cachedRun)?.0 != "succeeded" && Date() < cacheDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(restoredController.status(id: cachedRun)?.0 == "succeeded", "Saved projects must survive a controller restart")
        let afterCache = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(afterCache.components(separatedBy: "list").count == 2, "Restored projects must validate without enumerating schemes")
        let settingsAfterCache = try String(contentsOf: root.appendingPathComponent("settings-events"), encoding: .utf8)
        precondition(settingsAfterCache.dropFirst(settingsBeforeCache.count).contains("-derivedDataPath"),
                     "A saved Scheme must still validate its current product")
        try "".write(to: root.appendingPathComponent("fail-build"), atomically: true, encoding: .utf8)
        let failingBuild = restoredController.start(device: "device-cache", bundle: bundle, source: source.path, simulator: true)
        let failBuildDeadline = Date().addingTimeInterval(5)
        while restoredController.status(id: failingBuild)?.0 != "failed" && Date() < failBuildDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(restoredController.status(id: failingBuild)?.1.contains("forced build error") == true, "Build failures must be reported")
        let afterFailBuild = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        let settingsAfterFailBuild = try String(contentsOf: root.appendingPathComponent("settings-events"), encoding: .utf8)
        precondition(afterFailBuild == afterCache && settingsAfterFailBuild.count == settingsAfterCache.count,
                     "An unchanged project must reuse the cached build settings, and a build error must stop the run")
        try fm.removeItem(at: root.appendingPathComponent("fail-build"))
        // 产物与缓存配置不符(如 xcconfig 改了 Bundle ID)时重新查询一次, 不再按旧配置安装。
        let otherInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle + ".changed"], format: .xml, options: 0)
        try otherInfo.write(to: root.appendingPathComponent("app-info.plist"))
        let staleCache = restoredController.start(device: "device-cache", bundle: bundle, source: source.path, simulator: true)
        let staleDeadline = Date().addingTimeInterval(10)
        while restoredController.status(id: staleCache)?.0 != "failed" && Date() < staleDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(restoredController.status(id: staleCache)?.1.contains("Bundle ID") == true, "A mismatched product must not be installed")
        let settingsAfterStale = try String(contentsOf: root.appendingPathComponent("settings-events"), encoding: .utf8)
        precondition(settingsAfterStale.dropFirst(settingsAfterFailBuild.count).split(separator: "\n").count == 1,
                     "A mismatched product must refresh the cached build settings once")
        let afterStale = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(!afterStale.dropFirst(afterFailBuild.count).contains("install"), "A mismatched product must not be installed")
        try info.write(to: root.appendingPathComponent("app-info.plist"))
        var invalidated = UserDefaults.standard.dictionary(forKey: "LayerLensCommandRunRelativeProjects") as? [String: [String: String]] ?? [:]
        invalidated[bundle]?["scheme"] = "Missing"
        UserDefaults.standard.set(invalidated, forKey: "LayerLensCommandRunRelativeProjects")
        let retry = restoredController.start(device: "device-cache", bundle: bundle, source: source.path, simulator: true)
        let retryDeadline = Date().addingTimeInterval(10)
        while restoredController.status(id: retry)?.0 != "failed" && Date() < retryDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(restoredController.status(id: retry)?.0 == "failed", "A stale saved scheme must report an error")
        let afterRetry = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(afterRetry == afterStale, "Invalid saved settings must not trigger discovery or build")
        invalidated[bundle]?["scheme"] = "App"
        invalidated[bundle]?["path"] = "../Missing.xcworkspace"
        UserDefaults.standard.set(invalidated, forKey: "LayerLensCommandRunRelativeProjects")
        let missingProject = restoredController.start(device: "device-cache", bundle: bundle, source: source.path, simulator: true)
        let missingDeadline = Date().addingTimeInterval(5)
        while restoredController.status(id: missingProject)?.0 != "failed" && Date() < missingDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(restoredController.status(id: missingProject)?.1.contains("保存的项目路径") == true, "Missing saved projects must report an error")
        let afterMissing = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(afterMissing == afterRetry, "Missing saved projects must not trigger discovery or build")
        invalidated[bundle]?["path"] = relative
        UserDefaults.standard.set(invalidated, forKey: "LayerLensCommandRunRelativeProjects")
        // A cached Scheme that now targets a different Bundle ID must never install the existing product.
        var retargeted = settings
        var retargetedBuild = retargeted[0]["buildSettings"] as! [String: Any]
        retargetedBuild["PRODUCT_BUNDLE_IDENTIFIER"] = bundle + ".other"
        retargeted[0]["buildSettings"] = retargetedBuild
        try JSONSerialization.data(withJSONObject: retargeted).write(to: root.appendingPathComponent("settings.json"))
        // 真实的改绑会修改项目文件, 让缓存的构建配置失效。
        func editProject() { try! UUID().uuidString.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8) }
        editProject()
        let wrongTarget = restoredController.start(device: "device-cache", bundle: bundle, source: source.path, simulator: true)
        let wrongTargetDeadline = Date().addingTimeInterval(5)
        while restoredController.status(id: wrongTarget)?.0 != "failed" && Date() < wrongTargetDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        precondition(restoredController.status(id: wrongTarget)?.0 == "failed" && restoredController.status(id: wrongTarget)?.2 == false)
        let afterWrongTarget = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(afterWrongTarget == afterMissing, "A stale product must not trigger build, install or launch")
        try JSONSerialization.data(withJSONObject: settings).write(to: root.appendingPathComponent("settings.json"))
        let schemeFile = project.appendingPathComponent("xcshareddata/xcschemes/App.xcscheme")
        let invalidHome = root.appendingPathComponent("invalid-launch-home")
        try scheme.replacingOccurrences(of: "-test", with: "$(MISSING_TEST_BUILD_SETTING)")
            .write(to: schemeFile, atomically: true, encoding: .utf8)
        let invalidLaunch = restoredController.start(device: "device-cache", bundle: bundle, source: source.path, simulator: true) {
            try! Data().write(to: invalidHome)
        }
        let invalidLaunchDeadline = Date().addingTimeInterval(5)
        while restoredController.status(id: invalidLaunch)?.0 != "failed" && Date() < invalidLaunchDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        precondition(restoredController.status(id: invalidLaunch)?.1.contains("启动参数") == true)
        precondition(!fm.fileExists(atPath: invalidHome.path), "An invalid launch configuration must fail before Home")
        let afterInvalidLaunch = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(afterInvalidLaunch == afterWrongTarget, "An invalid launch configuration must not build or install")
        try scheme.write(to: schemeFile, atomically: true, encoding: .utf8)
        let product = root.appendingPathComponent("TestProduct.app")
        precondition(!CommandRunController.appMatchesBundle(product, bundleId: bundle))
        try fm.createDirectory(at: product, withIntermediateDirectories: true)
        try info.write(to: product.appendingPathComponent("Info.plist"))
        precondition(CommandRunController.appMatchesBundle(product, bundleId: bundle))
        precondition(!CommandRunController.appMatchesBundle(product, bundleId: bundle + ".other"))
        let scanDirectory = root.appendingPathComponent("ScanLimit")
        try fm.createDirectory(at: scanDirectory, withIntermediateDirectories: true)
        for index in 0..<256 { try "".write(to: scanDirectory.appendingPathComponent("item-\(index)"), atomically: true, encoding: .utf8) }
        precondition(CommandRunController.findProjects(sourceDir: source.deletingLastPathComponent(), repository: root.path, shouldContinue: { false }) == nil, "Repository scans must stop on cancellation or timeout")
        let sibling = root.appendingPathComponent("Other/Example.xcworkspace")
        let ignored = root.appendingPathComponent("Pods/Ignore.xcodeproj")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        try fm.createDirectory(at: ignored, withIntermediateDirectories: true)
        let scanned = CommandRunController.findProjects(sourceDir: source.deletingLastPathComponent(), repository: root.path) ?? []
        precondition(scanned.contains(sibling.path) && !scanned.contains(ignored.path), "Repository discovery must include sibling projects and skip dependencies")
        let newest = controller.start(device: "device-b", bundle: bundle, source: source.path, simulator: true, owner: "window", order: 3)
        let stale = controller.start(device: "device-b", bundle: bundle, source: source.path, simulator: true, owner: "window", order: 2)
        precondition(controller.status(id: stale)?.0 == "superseded", "Late HTTP requests must not replace a newer run")
        controller.cancel(id: newest)
        let cancelDeadline = Date().addingTimeInterval(5)
        while !["cancelled", "failed"].contains(controller.status(id: newest)?.0 ?? "") && Date() < cancelDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: newest)?.0 == "cancelled")
        let slow = controller.start(device: "device-slow", bundle: bundle, source: source.path, simulator: true)
        let parallelDeadline = Date().addingTimeInterval(12)
        while controller.status(id: slow)?.0 != "installing" && Date() < parallelDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: slow)?.0 == "installing")
        let fast = controller.start(device: "device-fast", bundle: bundle, source: source.path, simulator: true)
        while controller.status(id: fast)?.0 != "succeeded" && Date() < parallelDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: fast)?.0 == "succeeded" && controller.status(id: slow)?.0 == "installing", "Different devices must run independently")
        while controller.status(id: slow)?.0 != "succeeded" && Date() < parallelDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: slow)?.0 == "succeeded")
        let before = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        let installing = controller.start(device: "device-slow", bundle: bundle, source: source.path, simulator: true)
        let serialDeadline = Date().addingTimeInterval(20)
        func eventsSince(_ prefix: String) -> String {
            let value = (try? String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)) ?? ""
            return String(value.dropFirst(prefix.count))
        }
        while !eventsSince(before).contains("install") && Date() < serialDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: installing)?.0 == "installing" && eventsSince(before).contains("install"))
        let replacement = controller.start(device: "device-slow", bundle: bundle, source: source.path, simulator: true)
        Thread.sleep(forTimeInterval: 0.2)
        precondition(controller.status(id: replacement)?.0 == "queued", "A new run must wait for an in-progress install")
        while controller.status(id: replacement)?.0 != "succeeded" && Date() < serialDeadline { Thread.sleep(forTimeInterval: 0.05) }
        precondition(controller.status(id: installing)?.0 == "superseded" && controller.status(id: replacement)?.0 == "succeeded")
        let after = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        let appended = String(after.dropFirst(before.count))
        precondition(appended.components(separatedBy: "install").count == 3 && appended.components(separatedBy: "launch").count == 2, "Superseded installation must not launch")
        // 切换目标只拦截启动：构建与安装照常完成，迟到的旧选择不能覆盖新选择。
        let beforeBuildSwitch = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        let owner = "selection-test"
        let buildSwitch = controller.start(device: "device-switch", bundle: bundle, source: source.path, simulator: true, owner: owner, order: 10)
        let switchDeadline = Date().addingTimeInterval(20)
        while controller.status(id: buildSwitch)?.0 != "building" && Date() < switchDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: buildSwitch)?.0 == "building")
        controller.selectTarget(owner: owner, device: "device-switch", bundle: "other.app", order: 12)
        controller.selectTarget(owner: owner, device: "device-switch", bundle: bundle, order: 11)
        while controller.status(id: buildSwitch)?.0 != "skipped" && Date() < switchDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: buildSwitch)?.0 == "skipped", "The latest selection must suppress launch")
        let afterBuildSwitch = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        let buildEvents = String(afterBuildSwitch.dropFirst(beforeBuildSwitch.count))
        precondition(buildEvents.contains("build") && buildEvents.contains("install") && !buildEvents.contains("launch"), "Switching during build must still build and install")
        let beforeInstallSwitch = afterBuildSwitch
        let installSwitch = controller.start(device: "device-slow", bundle: bundle, source: source.path, simulator: true, owner: owner, order: 13)
        while !eventsSince(beforeInstallSwitch).contains("install") && Date() < switchDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: installSwitch)?.0 == "installing" && eventsSince(beforeInstallSwitch).contains("install"))
        controller.selectTarget(owner: owner, device: "device-slow", bundle: "other.app", order: 14)
        while controller.status(id: installSwitch)?.0 != "skipped" && Date() < switchDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: installSwitch)?.0 == "skipped")
        let afterInstallSwitch = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        let installEvents = String(afterInstallSwitch.dropFirst(beforeInstallSwitch.count))
        precondition(installEvents.contains("build") && installEvents.contains("install") && !installEvents.contains("launch"), "Switching during installation must suppress only launch")
        let returnToA = controller.start(device: "device-return", bundle: bundle, source: source.path, simulator: true, owner: owner, order: 15)
        controller.selectTarget(owner: owner, device: "device-return", bundle: "other.app", order: 16)
        controller.selectTarget(owner: owner, device: "device-return", bundle: bundle, order: 17)
        while controller.status(id: returnToA)?.0 != "succeeded" && Date() < switchDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: returnToA)?.0 == "succeeded", "Returning to A before launch must allow it to start")
        let crossDevice = controller.start(device: "device-original", bundle: bundle, source: source.path, simulator: true, owner: owner, order: 18)
        controller.selectTarget(owner: owner, device: "device-other", bundle: "other.app", order: 19)
        while controller.status(id: crossDevice)?.0 != "skipped" && Date() < switchDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: crossDevice)?.0 == "skipped", "Changing the selected device must suppress the old launch")
        let plan = XcodeRunPlan.Candidate(scheme: "App", project: project.path, target: "App", configuration: "Debug")
        let options = CommandRunController.launchOptions(project: project.path, plan: plan)
        precondition(options.arguments == ["-test"] && options.environment["MODE"] == "test")
        let movedBase = root.appendingPathComponent("Moved/Sources")
        let movedProject = root.appendingPathComponent("Moved/App.xcodeproj")
        precondition(CommandRunController.resolveRelative(relative, from: movedBase) == movedProject.standardizedFileURL.path, "Saved relative paths must survive a repository move")
        try scheme.write(to: project.appendingPathComponent("xcshareddata/xcschemes/AppCopy.xcscheme"), atomically: true, encoding: .utf8)
        try "{\"project\":{\"schemes\":[\"App\",\"AppCopy\"]}}".write(to: root.appendingPathComponent("schemes.json"), atomically: true, encoding: .utf8)
        let ambiguousBundle = bundle + ".ambiguous"
        let ambiguousSettings: [[String: Any]] = [["target": "App", "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": ambiguousBundle, "WRAPPER_EXTENSION": "app", "PROJECT_FILE_PATH": project.path, "TARGET_BUILD_DIR": "MOCK_BUILD_DIR", "WRAPPER_NAME": "App.app"]]]
        try JSONSerialization.data(withJSONObject: ambiguousSettings).write(to: root.appendingPathComponent("settings.json"))
        let settingsBefore = (try? String(contentsOf: root.appendingPathComponent("settings-events"), encoding: .utf8)) ?? ""
        let ambiguous = controller.start(device: "device-ambiguous", bundle: ambiguousBundle, source: source.path, simulator: true)
        let failDeadline = Date().addingTimeInterval(10)
        while controller.status(id: ambiguous)?.0 != "failed" && Date() < failDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: ambiguous)?.1.contains("多个项目或 Scheme") == true, "Ambiguous matches must fail without choosing")
        let settingsAfter = try String(contentsOf: root.appendingPathComponent("settings-events"), encoding: .utf8)
        let ambiguousQueries = String(settingsAfter.dropFirst(settingsBefore.count)).components(separatedBy: "\n").filter { $0.contains("-alltargets") }
        precondition(ambiguousQueries.count == 1, "Schemes from the same project and configuration must share one target settings query")
        try "{\"project\":{\"schemes\":[]}}".write(to: root.appendingPathComponent("schemes.json"), atomically: true, encoding: .utf8)
        let missing = controller.start(device: "device-missing", bundle: bundle + ".missing", source: source.path, simulator: true)
        while controller.status(id: missing)?.0 != "failed" && Date() < failDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(controller.status(id: missing)?.1.contains("未找到") == true && controller.status(id: missing)?.2 == false, "Missing matches must fail before build without opening a window")
        try "".write(to: root.appendingPathComponent("hang"), atomically: true, encoding: .utf8)
        let timeoutController = CommandRunController(executable: executable.path, queryTimeout: 0.2, cacheRoot: root.appendingPathComponent("cache"))
        let timeoutStart = Date()
        let timeoutJob = timeoutController.start(device: "device-timeout", bundle: bundle + ".timeout", source: source.path, simulator: true)
        let timeoutDeadline = Date().addingTimeInterval(4)
        while timeoutController.status(id: timeoutJob)?.0 != "failed" && Date() < timeoutDeadline { Thread.sleep(forTimeInterval: 0.02) }
        precondition(timeoutController.status(id: timeoutJob)?.0 == "failed", "A stuck query must terminate and report failure")
        precondition(Date().timeIntervalSince(timeoutStart) < 4, "Inherited child output pipes must not keep a timed-out query stuck")
        try fm.removeItem(at: root.appendingPathComponent("hang"))
        try JSONSerialization.data(withJSONObject: settings).write(to: root.appendingPathComponent("settings.json"))
        try "{\"project\":{\"schemes\":[\"App\"]}}".write(to: root.appendingPathComponent("schemes.json"), atomically: true, encoding: .utf8)
        let customBuild = root.appendingPathComponent("Custom/Deeper/DerivedData/App")
        let customCheckout = customBuild.appendingPathComponent("SourcePackages/checkouts/LayerLens/Pod/Classes")
        try fm.createDirectory(at: customCheckout, withIntermediateDirectories: true)
        try metadata.write(to: customBuild.appendingPathComponent("info.plist"))
        func runPackage(_ directory: URL) {
            let id = controller.start(device: "device-package", bundle: bundle, source: directory.appendingPathComponent("Bridge.m").path, simulator: true)
            let deadline = Date().addingTimeInterval(10)
            while !["succeeded", "failed"].contains(controller.status(id: id)?.0 ?? "") && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            precondition(controller.status(id: id)?.0 == "succeeded", controller.status(id: id)?.1 ?? "Missing package run")
        }
        runPackage(checkout)
        let beforeRelocation = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        try fm.removeItem(at: customBuild.appendingPathComponent("SourcePackages"))
        runPackage(customCheckout)
        let afterRelocation = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(!afterRelocation.dropFirst(beforeRelocation.count).contains("list"), "Relocating DerivedData must reuse the host project’s saved Scheme")
        try JSONSerialization.data(withJSONObject: retargeted).write(to: root.appendingPathComponent("retargeted-settings.json"))
        editProject()
        try "{\"project\":{\"schemes\":[\"App\",\"AppCopy\"]}}".write(to: root.appendingPathComponent("schemes.json"), atomically: true, encoding: .utf8)
        runPackage(customCheckout)
        let afterRecovery = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(afterRecovery.dropFirst(afterRelocation.count).contains("list"), "A retargeted cached Scheme must trigger fresh discovery")
        runPackage(customCheckout)
        let afterRecoveredRun = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8)
        precondition(!afterRecoveredRun.dropFirst(afterRecovery.count).contains("list"), "The replacement Scheme must become the cached choice")
        print("PASS command run: latest per device, install/launch isolation and scheme options")
    }
}
