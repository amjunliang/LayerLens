// Compile with RecorderTestSupport.swift and the actual recorder / HTTP sources.
import Foundation
import Network

@main struct DataIntegrityTests {
    static func wait(_ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(6)
        while !check() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        assert(check(), "Timed out waiting for regression state")
    }
    static func summary(_ log: AppLogRecorder) -> [String: Int] {
        let done = DispatchSemaphore(value: 0); var value: [String: Int] = [:]
        log.connectionSummary { value = $0; done.signal() }
        assert(done.wait(timeout: .now()+3) == .success); return value
    }
    static func summary(_ net: NetworkRecorder) -> [String: Int] {
        let done = DispatchSemaphore(value: 0); var value: [String: Int] = [:]
        net.connectionSummary { value = $0; done.signal() }
        assert(done.wait(timeout: .now()+3) == .success); return value
    }
    static func app(_ server: AppServer, device: String = "phone") -> AppRecord {
        AppRecord(deviceId: device, bundleId: "test-app", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance, "deviceName": "iPhone", "networkCapture": true])
    }
    static func files(_ root: URL, suffix: String) -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent.hasSuffix(suffix) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/integrity-tests")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // HTTP framing: EOF or reset cannot turn a short body into a successful download.
        assert(HTTPClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\npayload".utf8), eof: true) == nil)
        assert(HTTPClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\npayload".utf8))?.body == Data("payload".utf8))
        assert(HTTPClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na".utf8), eof: true) == nil)
        assert(HTTPClient.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8), eof: true) == nil)
        let first = try AppServer(), second = try AppServer()
        defer { first.stop(); second.stop() }
        let logRoot = root.appendingPathComponent("collision")
        let logs = AppLogRecorder(folder: logRoot)
        logs.update(apps: [app(first, device: "one"), app(second, device: "two")])
        wait { summary(logs)["files"] == 2 }
        logs.update(apps: []); _ = summary(logs)
        let logFiles = files(logRoot, suffix: ".log")
        assert(logFiles.count == 2, "Same-name devices must have separate log files")
        assert(Set(logFiles.compactMap { AppLogRecorder.attribute(AppLogRecorder.deviceAttribute, of: $0) }) == ["one", "two"])
        logs.stop()
        // Same process restores its own file without truncating the other device's history.
        let resumed = AppLogRecorder(folder: logRoot)
        resumed.update(apps: [app(first, device: "one")])
        wait { summary(resumed)["files"] == 1 }
        resumed.update(apps: []); _ = summary(resumed)
        assert(files(logRoot, suffix: ".log").count == 2)
        resumed.stop()
        // Recover an interrupted append before replaying from its last committed checkpoint.
        let interrupted = logFiles.first { AppLogRecorder.attribute(AppLogRecorder.deviceAttribute, of: $0) == "one" }!
        let committed = try Data(contentsOf: interrupted)
        let checkpoint = UInt64(AppLogRecorder.attribute("com.layerlens.seq", of: interrupted) ?? "0") ?? 0
        let handle = try FileHandle(forWritingTo: interrupted)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("incomplete-tail".utf8)); try handle.close()
        let marker = "\(committed.count):\(checkpoint + 1)"
        assert(marker.withCString { setxattr(interrupted.path, "com.layerlens.pending-write", $0, strlen($0), 0, 0) } == 0)
        let recovered = AppLogRecorder(folder: logRoot)
        recovered.update(apps: [app(first, device: "one")])
        wait { summary(recovered)["files"] == 1 }
        recovered.update(apps: []); _ = summary(recovered)
        let recoveredText = try String(contentsOf: interrupted, encoding: .utf8)
        assert(!recoveredText.contains("incomplete-tail"))
        assert(AppLogRecorder.attribute("com.layerlens.pending-write", of: interrupted) == nil)
        recovered.stop()
        // Failed writes do not advance the receive checkpoint; repairing the path allows backfill.
        let blocked = root.appendingPathComponent("blocked-log")
        try Data("not a directory".utf8).write(to: blocked)
        let failing = AppLogRecorder(folder: blocked)
        failing.update(apps: [app(second)])
        wait { summary(failing)["storageErrors"] == 1 }
        failing.update(apps: []); _ = summary(failing)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        failing.update(apps: [app(second)])
        wait { summary(failing)["files"] == 1 && summary(failing)["storageErrors"] == 0 }
        assert(second.queue.sync { second.logTargets.last!.contains("since=0") })
        failing.update(apps: []); _ = summary(failing)
        let restored = try String(contentsOf: files(blocked, suffix: ".log")[0], encoding: .utf8)
        assert(restored.contains("preserved-log-1"), "Failed batch must be backfilled after storage recovers")
        failing.stop()
        for mode in ["detail500", "body500", "truncated", "disk-failure", "detail404", "body404", "release500"] {
            let server = try AppServer()
            server.queue.sync { server.mode = mode == "release500" || mode == "disk-failure" ? "ok" : mode; server.releaseFailures = mode == "release500" ? 1 : 0 }
            let folder = root.appendingPathComponent(mode)
            if mode == "disk-failure" { try Data("blocked".utf8).write(to: folder) }
            var clock = Date()
            let recorder = NetworkRecorder(folder: folder, now: { clock }) { _, _ in true }
            let target = app(server)
            recorder.update(apps: [target])
            if mode == "release500" {
                wait { server.queue.sync { server.releases == 1 } }
                assert(server.queue.sync { server.released.isEmpty })
            } else {
                wait { mode == "detail500" || mode == "detail404" ? summary(recorder)["requests"] == 0 && !files(folder, suffix: "1.json").isEmpty : mode == "disk-failure" ? summary(recorder)["storageErrors"] == 1 : server.queue.sync { server.bodyRequests > 0 } && summary(recorder)["requests"] == 0 }
                assert(server.queue.sync { server.releases == 0 }, "Incomplete / unavailable data must never be acknowledged: \(mode)")
            }
            if mode == "detail404" || mode == "body404" {
                for _ in 0..<3 { recorder.update(apps: [target]); _ = summary(recorder) }
                assert(server.queue.sync { server.releases == 0 })
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: files(folder, suffix: "1.json")[0])) as! [String: Any]
                assert(record["_missing"] as? Bool == true && record["_f"] == nil)
            } else {
                if mode == "disk-failure" { try FileManager.default.removeItem(at: folder); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
                server.queue.sync { server.mode = "ok" }
                clock = clock.addingTimeInterval(31)
                recorder.update(apps: [target])
                wait { server.queue.sync { server.released.count == 1 } }
                let bodies = files(folder, suffix: "1-req")
                assert(bodies.count == 1 && (try! Data(contentsOf: bodies[0])) == Data("payload".utf8))
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: files(folder, suffix: "1.json")[0])) as! [String: Any]
                assert(record["_f"] as? Bool == true)
            }
            recorder.stop(); server.stop()
        }
        print("PASS distinct device logs, durable checkpoint backfill, complete HTTP framing, transient errors, missing data, atomic disk recovery and release acknowledgement retries")
    }
}
