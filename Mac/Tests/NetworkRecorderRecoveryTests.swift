// Compile with RecorderTestSupport.swift and the actual recorder / transport sources.
import Foundation
import Network

@main struct NetworkRecorderRecoveryTests {
    static func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        assert(predicate(), "Timed out waiting for recorder recovery")
    }
    static func summary(_ recorder: NetworkRecorder) -> [String: Int] {
        let done = DispatchSemaphore(value: 0); var value: [String: Int] = [:]
        recorder.connectionSummary { value = $0; done.signal() }
        assert(done.wait(timeout: .now() + 3) == .success); return value
    }
    static func app(_ server: AppServer, capture: Bool = true) -> AppRecord {
        AppRecord(deviceId: "phone", bundleId: "test-app", endpoint: .local(port: server.listener.port!.rawValue),
                  info: ["instanceId": server.instance, "networkCapture": capture])
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/network-recovery")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        // A bad detail and a bad body each back off, while a third request saves and releases.
        let server = try AppServer(); defer { server.stop() }
        server.queue.sync {
            server.mode = "ok"; server.networkIDs = [1, 2, 3]
            server.failedDetailIDs = [1]; server.failedBodyIDs = [2]
        }
        var clock = Date()
        let recorder = NetworkRecorder(folder: root.appendingPathComponent("fairness"), now: { clock }) { _, _ in true }
        recorder.update(apps: [app(server)])
        wait { server.queue.sync { server.released == [3] } }
        assert(server.queue.sync { server.detailRequests == [1, 2, 3] })
        for _ in 0..<3 { recorder.update(apps: [app(server)]); _ = summary(recorder) }
        assert(server.queue.sync { server.detailRequests == [1, 2, 3] }, "Scans must honor per-request backoff")
        clock = clock.addingTimeInterval(1)
        recorder.update(apps: [app(server)])
        wait { server.queue.sync { server.detailRequests.count == 5 } && summary(recorder)["requests"] == 0 }
        clock = clock.addingTimeInterval(1)
        recorder.update(apps: [app(server)]); _ = summary(recorder)
        assert(server.queue.sync { server.detailRequests.count == 5 }, "Second failure must back off for two seconds")
        server.queue.sync { server.failedDetailIDs = []; server.failedBodyIDs = [] }
        clock = clock.addingTimeInterval(1)
        recorder.update(apps: [app(server)])
        wait { server.queue.sync { Set(server.released) == [1, 2, 3] } }
        recorder.stop()

        // A persisted _f record is released after a failed acknowledgement and Mac restart,
        // without downloading its details/body again. Repeating the test covers idempotence.
        let ack = try AppServer(); defer { ack.stop() }
        ack.queue.sync { ack.mode = "ok"; ack.releaseFailures = 1 }
        let saved = root.appendingPathComponent("ack")
        let before = NetworkRecorder(folder: saved) { _, _ in true }
        before.update(apps: [app(ack)])
        wait { ack.queue.sync { ack.releases == 1 } && summary(before)["requests"] == 0 }
        before.stop()
        for expected in 2...3 {
            let after = NetworkRecorder(folder: saved) { _, _ in true }
            after.update(apps: [app(ack)])
            wait { ack.queue.sync { ack.releases == expected } }
            assert(ack.queue.sync { ack.bodyRequests == 1 && ack.detailRequests == [1] })
            after.stop()
        }

        // No old-process ID can be released to a new process reusing the same request ID.
        let fresh = try AppServer(); defer { fresh.stop() }
        fresh.queue.sync { fresh.mode = "detail500" }
        let switched = NetworkRecorder(folder: saved) { _, _ in true }
        switched.update(apps: [app(ack)])
        wait { ack.queue.sync { ack.releases == 4 } }
        switched.update(apps: [app(fresh)])
        wait { fresh.queue.sync { fresh.detailRequests == [1] } && summary(switched)["requests"] == 0 }
        assert(fresh.queue.sync { fresh.releases == 0 })
        switched.stop()

        // Initial enable and process replacement both sync immediately, without canceling the POST.
        let capture = try AppServer(); defer { capture.stop() }
        capture.queue.sync { capture.mode = "ok" }
        let enabled = NetworkRecorder(folder: root.appendingPathComponent("capture")) { _, _ in true }
        enabled.update(apps: [app(capture, capture: false)])
        wait { capture.queue.sync { capture.captureRequests == [true] } }
        let replacement = try AppServer(); defer { replacement.stop() }
        replacement.queue.sync { replacement.mode = "ok" }
        enabled.update(apps: [app(replacement, capture: false)])
        wait { replacement.queue.sync { replacement.captureRequests == [true] } }
        enabled.stop()
        print("PASS per-request backoff and fairness, restart ACK recovery, idempotent release, process isolation and immediate capture enable")
    }
}
