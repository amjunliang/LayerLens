// Compile with RecorderTestSupport.swift and the recorder / transport sources.
import Foundation
import Network

@main struct Tests {
    static func summary(_ recorder: AppLogRecorder) -> [String: Int] {
        let ready = DispatchSemaphore(value: 0); var value: [String: Int] = [:]
        recorder.connectionSummary { value = $0; ready.signal() }
        assert(ready.wait(timeout: .now() + 3) == .success); return value
    }
    static func summary(_ recorder: NetworkRecorder) -> [String: Int] {
        let ready = DispatchSemaphore(value: 0); var value: [String: Int] = [:]
        recorder.connectionSummary { value = $0; ready.signal() }
        assert(ready.wait(timeout: .now() + 3) == .success); return value
    }
    static func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        assert(predicate(), "Timed out waiting for test state")
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/lifecycle-tests")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date()
        let server = try AppServer(); defer { server.stop() }
        let log = AppLogRecorder(folder: root.appendingPathComponent("logs"), now: { now })
        let network = NetworkRecorder(folder: root.appendingPathComponent("network"), now: { now }) { _, _ in true }
        let app = AppRecord(deviceId: "test-device", bundleId: "test-app", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance, "deviceName": "test", "networkCapture": true])
        log.update(apps: [app]); network.update(apps: [app])
        wait { summary(log)["files"] == 1 && server.queue.sync { server.bodyRequests == 1 } }
        assert(summary(network)["requests"] == 1)
        // A suspended process stays discoverable: keep its existing stream rather than reconnecting.
        var suspended = app; suspended.suspended = true; suspended.responding = false
        log.update(apps: [suspended]); network.update(apps: [suspended])
        assert(summary(log)["connections"] == 1 && summary(network)["connections"] == 1)
        log.update(apps: []); network.update(apps: [])
        assert(summary(log)["connections"] == 0 && summary(log)["files"] == 0)
        assert(summary(network)["connections"] == 0 && summary(network)["requests"] == 0)
        wait { server.queue.sync { server.bodyCloses == 1 } }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        assert(files.contains { $0.pathExtension == "log" })
        assert(files.contains { $0.lastPathComponent == "1.json" })
        // Same process returns: append to the original log file, no duplicate file creation.
        log.update(apps: [app]); wait { summary(log)["files"] == 1 }
        log.update(apps: []); _ = summary(log)
        let logFiles = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "log" }
        assert(logFiles.count == 1)
        let preserved = try Data(contentsOf: logFiles[0])
        assert(String(decoding: preserved, as: UTF8.self).contains("preserved-log-2"))
        now = now.addingTimeInterval(301)
        log.update(apps: []); network.update(apps: [])
        assert(summary(log)["cachedSources"] == 0 && summary(network)["cachedSources"] == 0)
        assert(FileManager.default.fileExists(atPath: logFiles[0].path), "Cache expiry must not delete disk history")
        log.stop(); network.stop()
        let items = [RecorderCache.Item(id: "old", bytes: 80, lastUse: now.addingTimeInterval(-10), pinned: false), .init(id: "recent", bytes: 80, lastUse: now, pinned: false), .init(id: "viewed", bytes: 10, lastUse: .distantPast, pinned: true)]
        assert(RecorderCache.evictions(items, now: now, limit: 100) == ["old"])
        assert(RecorderCache.evictions(items, now: now.addingTimeInterval(301), limit: 1000) == ["old", "recent"])
        assert(String(decoding: BoundedProcess.run("/usr/bin/printf", ["ok"], timeout: 1)!, as: UTF8.self) == "ok")
        let before = Date()
        assert(BoundedProcess.run("/usr/bin/python3", ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"], timeout: 0.2) == nil)
        assert(Date().timeIntervalSince(before) < 3, "TERM-resistant query must be killed within the deadline")
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            assert(BoundedProcess.run("/usr/bin/python3", ["-c", "import time;time.sleep(30)"], timeout: 30) == nil)
            stopped.signal()
        }
        wait { BoundedProcess.activeCount == 1 }
        BoundedProcess.stopAll()
        assert(stopped.wait(timeout: .now() + 2) == .success)
        assert(BoundedProcess.activeCount == 0)
        assert(BoundedProcess.run("/usr/bin/printf", ["late"], timeout: 1) == nil, "Shutdown cannot start late queries")
        print("PASS real socket cancellation, suspended retention, log descriptor closure and append recovery, disk preservation, cache TTL/LRU and bounded query termination")
    }
}
