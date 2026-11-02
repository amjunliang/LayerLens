import Foundation

@main struct LogClearTests {
    static func wait(_ check: () -> Bool) {
        let end = Date().addingTimeInterval(6)
        while !check() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        precondition(check(), "Log clear regression timed out")
    }
    static func summary(_ recorder: AppLogRecorder) -> [String: Int] {
        let ready = DispatchSemaphore(value: 0); var result: [String: Int] = [:]
        recorder.connectionSummary { result = $0; ready.signal() }
        precondition(ready.wait(timeout: .now() + 3) == .success); return result
    }
    static func app(_ server: AppServer, device: String = "phone") -> AppRecord {
        AppRecord(deviceId: device, bundleId: "test-app", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance, "deviceName": "Test"])
    }
    static func current(_ recorder: AppLogRecorder, device: String = "phone") -> (String?, String?) {
        let ready = DispatchSemaphore(value: 0); var result: (String?, String?) = (nil, nil)
        recorder.current(deviceId: device, bundleId: "test-app") { result = ($0, $1); ready.signal() }
        precondition(ready.wait(timeout: .now() + 3) == .success); return result
    }
    static func clear(_ recorder: AppLogRecorder, instance: String, device: String = "phone") -> Result<Void, Error> {
        let ready = DispatchSemaphore(value: 0); var result: Result<Void, Error>?
        recorder.clear(deviceId: device, bundleId: "test-app", expectedInstance: instance) { result = $0; ready.signal() }
        precondition(ready.wait(timeout: .now() + 3) == .success); return result!
    }
    static func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/log-clear")
        try? manager.removeItem(at: root); defer { try? manager.removeItem(at: root) }
        let first = try AppServer(), other = try AppServer()
        defer { first.stop(); other.stop() }
        let recorder = AppLogRecorder(folder: root)
        recorder.update(apps: [app(first), app(other, device: "other")])
        wait { summary(recorder)["files"] == 2 }
        let folder = root.appendingPathComponent("test-app")
        let file = folder.appendingPathComponent(current(recorder).0!)
        let otherFile = folder.appendingPathComponent(current(recorder, device: "other").0!)
        let otherBytes = try Data(contentsOf: otherFile)
        let checkpoint = AppLogRecorder.attribute(AppLogRecorder.seqAttribute, of: file)
        precondition(text(file).contains("preserved-log-1"))
        if case .failure(let error) = clear(recorder, instance: first.instance) { throw error }
        precondition(try! Data(contentsOf: file).isEmpty)
        precondition(AppLogRecorder.attribute(AppLogRecorder.seqAttribute, of: file) == checkpoint)
        precondition(try! Data(contentsOf: otherFile) == otherBytes, "Other devices must be untouched")

        // Reconnect and Mac restart retain the clear boundary; only newer sequences append.
        recorder.update(apps: []); _ = summary(recorder)
        recorder.update(apps: [app(first)])
        wait { text(file).contains("preserved-log-2") }
        precondition(!text(file).contains("preserved-log-1"))
        recorder.stop()
        let restored = AppLogRecorder(folder: root)
        restored.update(apps: [app(first)])
        wait { text(file).contains("preserved-log-3") }
        precondition(!text(file).contains("preserved-log-1"))
        precondition(first.queue.sync { first.logTargets.last!.contains("since=2") })

        // Failed clear preserves both visible records and saved data.
        let backup = root.appendingPathComponent("blocked-log-backup")
        let before = try Data(contentsOf: file)
        let cacheBefore = summary(restored)["cacheBytes"]
        try manager.moveItem(at: file, to: backup)
        try manager.createDirectory(at: file, withIntermediateDirectories: true)
        for (key, value) in [(AppLogRecorder.instanceAttribute, first.instance), (AppLogRecorder.deviceAttribute, "phone")] {
            precondition(value.withCString { setxattr(file.path, key, $0, strlen($0), 0, 0) } == 0)
        }
        if case .success = clear(restored, instance: first.instance) { fatalError("Failed rename must not report success") }
        precondition(try! Data(contentsOf: backup) == before)
        precondition(summary(restored)["cacheBytes"] == cacheBefore)
        try manager.removeItem(at: file); try manager.moveItem(at: backup, to: file)
        precondition(!(try! manager.contentsOfDirectory(atPath: folder.path)).contains { $0.hasPrefix(".clear-") })

        // A new App launch with no logs must never truncate the previous launch's file.
        let fresh = try AppServer(); defer { fresh.stop() }
        fresh.queue.sync { fresh.mode = "logs-empty" }
        restored.update(apps: [app(fresh)])
        wait { current(restored).1 == fresh.instance }
        if case .failure(let error) = clear(restored, instance: first.instance) {
            precondition((error as NSError).code == 409)
        } else { fatalError("Old confirmation must not clear a new launch") }
        precondition(try! Data(contentsOf: file) == before)
        if case .failure(let error) = clear(restored, instance: fresh.instance) { throw error }
        let freshFile = folder.appendingPathComponent(current(restored).0!)
        precondition(freshFile != file && (try! Data(contentsOf: freshFile)).isEmpty)
        precondition(try! Data(contentsOf: file) == before)
        restored.stop()

        // Offline current launch can also clear durably and later continue without backfill.
        let offline = AppLogRecorder(folder: root)
        offline.update(apps: [app(first)])
        wait { text(file).contains("preserved-log-4") }
        offline.update(apps: []); _ = summary(offline)
        if case .failure(let error) = clear(offline, instance: first.instance) { throw error }
        precondition(try! Data(contentsOf: file).isEmpty)
        offline.stop()
        let again = AppLogRecorder(folder: root)
        again.update(apps: [app(first)])
        wait { text(file).contains("preserved-log-5") }
        precondition(!text(file).contains("preserved-log-4"))
        precondition(AppLogRecorder.attribute(AppLogRecorder.seqAttribute, of: file) == "5")
        again.stop()
        print("PASS durable log clear, reconnect/Mac restart, new writes, device/launch isolation, empty launch and atomic failure")
    }
}
