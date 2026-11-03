// Compile with RecorderTestSupport.swift, NetworkViewerTestSupport.swift and actual sources.
import Darwin
import Foundation
import Network

@main struct NetworkReplayTests {
    static func wait(_ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        assert(check(), "Replay setup timed out")
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/network-replay")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = try AppServer(); defer { upstream.stop() }
        upstream.queue.sync { upstream.mode = "pending"; upstream.networkIDs = Array(1...129) }
        let recorder = NetworkRecorder(folder: root) { _, _ in true }; defer { recorder.stop() }
        let app = AppRecord(deviceId: "phone", bundleId: "test-app", endpoint: .local(port: upstream.listener.port!.rawValue), info: ["instanceId": upstream.instance, "networkCapture": true])
        recorder.update(apps: [app])
        func saved(_ id: UInt64) -> [String: Any]? {
            let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            return files.first { $0.lastPathComponent == "\(id).json" }.flatMap(NetworkRecorder.readJSON)
        }
        wait { saved(129) != nil }
        func update(_ id: UInt64, sequence: UInt64) {
            upstream.queue.sync {
                let json = try! JSONSerialization.data(withJSONObject: ["records": [["id": id, "s": sequence, "url": "https://example.test/updated-\(id)", "state": "pending"]]])
                upstream.connections[0].send(content: Data("event: network\ndata: ".utf8) + json + Data("\n\n".utf8), completion: .contentProcessed { _ in })
            }
            wait { saved(id)?["url"] as? String == "https://example.test/updated-\(id)" }
        }
        update(1, sequence: 1000)
        let viewer = try NetworkViewerProbe(recorder: recorder); defer { viewer.close() }
        let firstPage = viewer.page()
        let first = firstPage.records
        assert(first.count == 128)
        let cursor = first.map { ($0["s"] as! NSNumber).uint64Value }.max()!
        assert(cursor == 129, "Updated old request must not advance the cursor ahead of an unsent page")
        // Another request changes while the viewer is disconnected.
        update(2, sequence: 1001)
        let second = viewer.page(since: cursor, epoch: firstPage.epoch).records
        assert(second.map { ($0["id"] as! NSNumber).uint64Value } == [1, 2])
        let received = Set((first + second).map { ($0["id"] as! NSNumber).uint64Value })
        assert(received == Set(1...129), "Reconnect must preserve every record and the new update")
        print("PASS actual Mac SSE replay: 129 records, first-page disconnect, resume and intervening update")
    }
}
