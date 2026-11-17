import Foundation

@main struct GitPathTests {
    static func main() throws {
        let root = "/private/tmp/LayerLens-release-build/git-path-tests"
        try? FileManager.default.removeItem(atPath: root)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        func run(_ args: [String], input: Data? = nil) -> GitController.Output {
            let result = GitController.run(root, args, timeout: 10, input: input)
            assert(result.ok, result.message); return result
        }
        _ = run(["-c", "init.templateDir=", "init", "-q"])
        _ = run(["config", "core.hooksPath", "/dev/null"])
        let names = ["page[id].txt", "pagei.txt", "paged.txt", ":(glob)*.txt", "literal*.txt", "literal1.txt"]
        for name in names { try Data("original".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(name)) }
        let controller = GitController()
        let build = URL(fileURLWithPath: root).appendingPathComponent("BuildCache")
        let checkout = build.appendingPathComponent("SourcePackages/checkouts/LayerLens")
        let sourceFile = checkout.appendingPathComponent("Bridge.m").path
        let hostProject = URL(fileURLWithPath: root).appendingPathComponent("Host.xcodeproj")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostProject, withIntermediateDirectories: true)
        assert(GitController.run(checkout.path, ["-c", "init.templateDir=", "init", "-q"], timeout: 10).ok)
        assert(controller.repository(sourceFile: sourceFile) == nil, "A dependency checkout without host metadata must not become the active repository")
        let info = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": hostProject.path], format: .xml, options: 0)
        try info.write(to: build.appendingPathComponent("info.plist"))
        assert(controller.repository(sourceFile: sourceFile) == root, "A SwiftPM checkout must resolve to the host Git repository")
        assert(controller.repository(deviceId: "device-git", bundleId: "com.layerlens.git.test", sourceFile: sourceFile) == root,
               "Device/bundle-aware Git lookup must resolve and persist host repository")
        try FileManager.default.removeItem(at: build)
        assert(controller.repository(deviceId: "device-git", bundleId: "com.layerlens.git.test", sourceFile: sourceFile) == root,
               "Git repository must still resolve from saved host after build directory is removed")
        XcodeSourcePath.removeSavedHostProject(deviceId: "device-git", bundleId: "com.layerlens.git.test", sourceFile: sourceFile)
        assert(controller.repository(sourceFile: root + "/pagei.txt") == root)
        try FileManager.default.removeItem(at: hostProject)
        func perform(_ action: String, _ paths: [String]) {
            let done = DispatchSemaphore(value: 0)
            controller.perform(action, repo: root, json: ["paths": paths]) { value, status in assert(status == 200, "\(value)"); done.signal() }
            assert(done.wait(timeout: .now()+15) == .success)
        }
        perform("stage", [names[0]])
        assert(run(["ls-files", "-z"]).text.split(separator: "\0").map(String.init) == [names[0]])
        perform("stage", [names[3], names[4]])
        assert(Set(run(["ls-files", "-z"]).text.split(separator: "\0").map(String.init)) == Set([names[0], names[3], names[4]]))
        _ = run(["add", "-A"])
        _ = run(["-c", "user.name=Regression", "-c", "user.email=regression@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"])
        for name in names { try Data("modified".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(name)) }
        perform("discard", [names[0]])
        for name in names { let expected = name == names[0] ? "original" : "modified"; let content = try String(contentsOfFile: root + "/" + name, encoding: .utf8); assert(content == expected) }
        perform("stage", [names[1], names[2], names[4], names[5]])
        perform("unstage", [names[4]])
        let staged = Set(run(["diff", "--cached", "--name-only", "-z"]).text.split(separator: "\0").map(String.init))
        assert(staged == Set([names[1], names[2], names[5]]))
        let oldBranch = run(["branch", "--show-current"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = run(["switch", "-c", "other-branch"])
        let beforeCommit = run(["rev-parse", "HEAD"]).text
        for action in ["commit", "push"] {
            let done = DispatchSemaphore(value: 0)
            controller.perform(action, repo: root, json: ["message": "wrong branch", "expectedBranch": oldBranch]) { value, status in
                assert(status == 409 && value["reason"] as? String == "branchChanged", "\(value)")
                done.signal()
            }
            assert(done.wait(timeout: .now() + 15) == .success)
        }
        assert(run(["rev-parse", "HEAD"]).text == beforeCommit, "The other branch must not be committed")

        // Multi-worktree enumeration, short collision-free naming, and common git dir recovery.
        assert(GitController.shortWorktreeNames(for: [
            "/Users/dev/.codex/worktrees/ea74/App",
            "/Users/dev/.codex/worktrees/ab12/App",
            "/Users/dev/Workspace/App-main",
        ]) == ["ea74", "ab12", "App-main"])
        let porcelain = """
        worktree /Users/dev/Workspace/App
        HEAD 1111111222222
        branch refs/heads/main

        worktree /Users/dev/.codex/worktrees/ea74/App
        HEAD 3333333444444
        detached

        worktree /Users/dev/.codex/worktrees/deleted/App
        HEAD 5555555666666
        prunable gitdir file points to non-existent location

        worktree /Users/dev/Workspace/App.bare
        bare

        """
        let parsed = GitController.parseWorktrees(porcelain, exists: { $0 != "/Users/dev/.codex/worktrees/deleted/App" })
        assert(parsed.count == 2)
        assert(parsed[0].name == "Workspace" && parsed[0].branch == "main" && parsed[0].isMain && !parsed[0].detached)
        assert(parsed[1].name == "ea74" && parsed[1].branch == "" && parsed[1].head == "3333333" && !parsed[1].isMain && parsed[1].detached)

        let wtB = root + "-wt-b"
        try? FileManager.default.removeItem(atPath: wtB)
        defer { try? FileManager.default.removeItem(atPath: wtB) }
        _ = run(["worktree", "add", "-b", "feat/worktree-b", wtB])
        let listed = controller.worktrees(for: root)
        let wtBResolved = URL(fileURLWithPath: wtB).resolvingSymlinksInPath().path
        let rootResolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        assert(listed.count == 2 && listed.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == wtBResolved && $0.branch == "feat/worktree-b" }), "listed=\(listed) wtB=\(wtB)")
        let commonDir = controller.commonGitDirectory(for: wtB)
        assert(commonDir != nil)
        _ = run(["worktree", "remove", wtB])
        if let commonDir {
            let afterRemove = controller.worktrees(for: commonDir)
            assert(afterRemove.count == 1 && URL(fileURLWithPath: afterRemove[0].path).resolvingSymlinksInPath().path == rootResolved)
        }
        print("PASS actual Git stage, unstage and discard treat brackets, wildcards and pathspec-like names literally")
    }
}
