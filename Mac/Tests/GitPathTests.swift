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
        print("PASS actual Git stage, unstage and discard treat brackets, wildcards and pathspec-like names literally")
    }
}
