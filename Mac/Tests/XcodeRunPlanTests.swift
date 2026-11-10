import Foundation

@main struct Tests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/run-plan-tests")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Apps.xcodeproj")
        let workspace = root.appendingPathComponent("Apps.xcworkspace")
        let schemeDir = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "<Workspace><FileRef location=\"group:Apps.xcodeproj\"/></Workspace>".write(to: workspace.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
        let build = root.appendingPathComponent("Custom/Build/Cache")
        let checkout = build.appendingPathComponent("SourcePackages/checkouts/LayerLens")
        let source = checkout.appendingPathComponent("Bridge.m").path
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace.path], format: .xml, options: 0)
        try info.write(to: build.appendingPathComponent("info.plist"))
        precondition(XcodeController.match(sourceFile: source, workspaces: [project.path, workspace.path]) == workspace.path)
        precondition(XcodeController.match(sourceFile: source, workspaces: [project.path]) == nil)
        func scheme(_ name: String, target: String, configuration: String = "Debug", extra: String = "") throws {
            let text = """
            <Scheme><BuildAction><BuildableReference BlueprintName="Dependency"/></BuildAction>
            <LaunchAction buildConfiguration="\(configuration)"><BuildableProductRunnable><BuildableReference BlueprintName="\(target)" ReferencedContainer="container:Apps.xcodeproj"/></BuildableProductRunnable>\(extra)</LaunchAction></Scheme>
            """
            try text.write(to: schemeDir.appendingPathComponent(name + ".xcscheme"), atomically: true, encoding: .utf8)
        }
        try scheme("Alpha", target: "Alpha")
        try scheme("Beta", target: "Beta", configuration: "BetaDebug")
        try scheme("Beta copy", target: "Beta", configuration: "BetaDebug")
        try "<Scheme><LaunchAction buildConfiguration=\"Debug\"><PathRunnable FilePath=\"/bin/true\"/></LaunchAction></Scheme>".write(to: schemeDir.appendingPathComponent("External.xcscheme"), atomically: true, encoding: .utf8)
        let objects: [String: Any] = [
            "auto": ["isa": "PBXNativeTarget", "productType": "com.apple.product-type.application", "name": "Auto", "buildConfigurationList": "configs"],
            "external": ["isa": "PBXNativeTarget", "productType": "com.apple.product-type.application", "name": "External", "buildConfigurationList": "configs"],
            "configs": ["buildConfigurations": ["debug"]], "debug": ["name": "Debug"],
        ]
        try PropertyListSerialization.data(fromPropertyList: ["objects": objects], format: .xml, options: 0).write(to: project.appendingPathComponent("project.pbxproj"))
        let names = ["Alpha", "Beta", "Beta copy", "Auto", "External"]
        let candidates = XcodeRunPlan.candidates(workspace: workspace.path, schemes: names)
        precondition(candidates.count == 4)
        precondition(!candidates.contains { $0.target == "Dependency" || $0.scheme == "External" })
        precondition(candidates.first { $0.scheme == "Beta" }?.configuration == "BetaDebug")
        func setting(_ target: String, _ bundle: String, projectPath: String? = nil, ext: String = "app") -> [String: Any] {
            ["target": target, "buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": bundle, "WRAPPER_EXTENSION": ext, "PROJECT_FILE_PATH": projectPath ?? project.path]]
        }
        var queries = 0
        let settings: (String, String) -> [[String: Any]]? = { _, config in
            queries += 1
            return config == "BetaDebug" ? [setting("Beta", "com.test.beta")] : [setting("Alpha", "com.test.alpha"), setting("Auto", "com.test.auto")]
        }
        // Xcode currently has Alpha selected, but user selected Beta in LayerLens.
        let unique = candidates.filter { $0.scheme != "Beta copy" }
        precondition(XcodeRunPlan.choose(unique, active: "Alpha", bundleId: "com.test.beta", settings: settings)?.scheme == "Beta")
        precondition(queries == 2, "Build settings shared by project/config must be queried once")
        precondition(XcodeRunPlan.choose(candidates, active: "Alpha", bundleId: "com.test.beta", settings: settings) == nil, "Ambiguous schemes must never launch arbitrarily")
        precondition(XcodeRunPlan.choose(candidates, active: "Beta copy", bundleId: "com.test.beta", settings: settings)?.scheme == "Beta copy")
        precondition(XcodeRunPlan.choose(candidates, active: "Alpha", bundleId: "com.test.missing", settings: settings) == nil)
        let alpha = candidates.first { $0.scheme == "Alpha" }!
        precondition(!XcodeRunPlan.matchesBundle([setting("Alpha", "com.test.alpha", projectPath: "/other/Apps.xcodeproj")], candidate: alpha, bundleId: "com.test.alpha"))
        precondition(!XcodeRunPlan.matchesBundle([setting("Alpha", "com.test.alpha", ext: "appex")], candidate: alpha, bundleId: "com.test.alpha"))
        precondition(XcodeRunPlan.choose(unique, active: "Alpha", bundleId: "com.test.alpha", settings: { _, _ in nil }) == nil)
        let data = try JSONSerialization.data(withJSONObject: [setting("Alpha", "com.test.alpha")])
        precondition(XcodeRunPlan.decodeSettings(Data("warning: diagnostic\n".utf8) + data)?.count == 1)
        precondition(XcodeRunPlan.decodeSettings(Data("not JSON".utf8)) == nil)
        if CommandLine.arguments.count == 4 {
            let workspacePath = CommandLine.arguments[1]
            let actualSettings = XcodeRunPlan.decodeSettings(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))!
            let bundle = CommandLine.arguments[3]
            let names = Array(Set(actualSettings.compactMap { $0["target"] as? String })).sorted()
            let plans = XcodeRunPlan.candidates(workspace: workspacePath, schemes: names)
            let plan = XcodeRunPlan.choose(plans, active: "PogNovel", bundleId: bundle, settings: { _, config in config == "Debug" ? actualSettings : nil })
            precondition(plan != nil && plan!.scheme != "PogNovel")
            print("PASS current multi-target workspace selected scheme: " + plan!.scheme)
        }
        print("PASS exact Run target, custom configuration, multi-target selection, ambiguity, foreign projects and executable isolation")
    }
}
