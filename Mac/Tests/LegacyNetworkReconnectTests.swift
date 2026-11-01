// Compile with RecorderTestSupport.swift and actual recorder / transport sources.
import Foundation
import Network

@main struct LegacyNetworkReconnectTests {
    static func wait(_ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !check() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        assert(check(), "Legacy replay reconciliation timed out")
    }
    static func summary(_ recorder: NetworkRecorder) -> [String: Int] {
        let done = DispatchSemaphore(value: 0); var result: [String: Int] = [:]
        recorder.connectionSummary { result = $0; done.signal() }
        assert(done.wait(timeout: .now() + 3) == .success); return result
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/legacy-network")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        for count in [65, 129, 1000] {
            let server = try AppServer(); defer { server.stop() }
            let pending = count == 1000
            server.queue.sync {
                server.mode = pending ? "pending" : "ok"
                server.networkIDs = (1...UInt64(count)).map { $0 }
                server.networkSequences[1] = 10_000 // Old request updated after all newer IDs.
                server.interruptFirstReplayAfter = 64
            }
            let folder = root.appendingPathComponent(String(count))
            let recorder = NetworkRecorder(folder: folder) { _, _ in true }; defer { recorder.stop() }
            let app = AppRecord(deviceId: "phone", bundleId: "test", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance, "networkCapture": true])
            func saved(_ id: Int) -> [String: Any]? {
                let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
                return files.first { $0.lastPathComponent == "\(id).json" }.flatMap(NetworkRecorder.readJSON)
            }
            recorder.update(apps: [app])
            wait { saved(64) != nil && summary(recorder)["connections"] == 0 && summary(recorder)["requests"] == 0 }
            assert(saved(65) == nil)
            if !pending { assert(saved(64)?["_f"] as? Bool == true && server.queue.sync { server.bodyRequests == 64 }) }

            // The old SDK's unchanged ID order is safe because every reconnect asks since=0.
            recorder.update(apps: [app])
            wait { saved(count) != nil && (pending || saved(count)?["_f"] as? Bool == true) && summary(recorder)["requests"] == 0 }
            assert(server.queue.sync { server.networkTargets == [0, 0] })
            let expectedDownloads = pending ? 0 : count
            assert(server.queue.sync { server.bodyRequests == expectedDownloads && server.detailRequests.count == expectedDownloads }, "Already saved bodies/details must not download again")

            // Repeat reconciliation, with a changed summary at the tail to confirm full delivery.
            server.queue.sync {
                server.networkURLs[UInt64(count)] = "https://example.test/reconnected"
                server.connections.forEach { $0.cancel() }
            }
            wait { summary(recorder)["connections"] == 0 }
            recorder.update(apps: [app])
            wait { server.queue.sync { server.networkTargets.count == 3 } && saved(count)?["url"] as? String == "https://example.test/reconnected" && summary(recorder)["requests"] == 0 }
            assert(server.queue.sync { server.networkTargets == [0, 0, 0] && server.bodyRequests == expectedDownloads && server.detailRequests.count == expectedDownloads })
            recorder.stop()
            let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            assert(files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "session.json" }.count == count)
        }
        print("PASS legacy SDK compatibility: unsorted 65/129/1000-record replays, interrupted page recovery, deduplication and no repeated body/detail downloads")
    }
}
