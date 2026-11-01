// Compile with RecorderTestSupport.swift, NetworkViewerTestSupport.swift and actual sources.
import Foundation
import Network

@main struct NetworkViewerEpochTests {
    static func wait(_ check: () -> Bool) {
        let end = Date().addingTimeInterval(6)
        while !check() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        assert(check(), "Viewer generation test timed out")
    }
    static func summary(_ recorder: NetworkRecorder) -> [String: Int] {
        let done = DispatchSemaphore(value: 0); var value: [String: Int] = [:]
        recorder.connectionSummary { value = $0; done.signal() }
        assert(done.wait(timeout: .now() + 3) == .success); return value
    }
    static func app(_ server: AppServer) -> AppRecord {
        AppRecord(deviceId: "phone", bundleId: "test-app", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance, "networkCapture": true])
    }
    static func clear(_ recorder: NetworkRecorder) {
        let head = HTTPRequestHead.parse(Data("POST /api/network/clear HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n".utf8))!.head!
        let done = DispatchSemaphore(value: 0)
        assert(recorder.handle(head, path: head.path, deviceId: "phone", bundleId: "test-app", connection: HubConnection(onResponse: { assert($0.status == 200); done.signal() }), fallback: { assertionFailure("Unexpected fallback") }))
        assert(done.wait(timeout: .now() + 3) == .success)
    }
    static func main() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/viewer-generations")
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        var fixtures: [String: [[String: Any]]] = [:]
        let server = try AppServer(); defer { server.stop() }
        server.queue.sync { server.mode = "pending"; server.networkIDs = [1, 2, 3] }
        let recorder = NetworkRecorder(folder: folder) { _, _ in true }
        recorder.update(apps: [app(server)]); wait { summary(recorder)["records"] == 3 }
        let viewer = try NetworkViewerProbe(recorder: recorder)
        let first = viewer.page(); assert(first.resets && first.records.count == 3 && !first.epoch.isEmpty)
        fixtures["initial"] = first.frames

        // A disconnected viewer misses another window's clear. Its old cursor must not survive.
        clear(recorder)
        let empty = viewer.page(since: first.cursor, epoch: first.epoch)
        assert(empty.resets && empty.records.isEmpty && empty.epoch != first.epoch)
        fixtures["afterClear"] = empty.frames
        server.queue.sync { server.networkIDs = Array(1...132) }
        recorder.update(apps: [app(server)]); wait { summary(recorder)["records"] == 129 }
        let page = viewer.page(epoch: empty.epoch)
        assert(!page.resets && page.records.count == 128)
        let tail = viewer.page(since: page.cursor, epoch: page.epoch)
        assert(!tail.resets && tail.records.count == 1)
        assert(Set((page.records + tail.records).map { ($0["id"] as! NSNumber).intValue }) == Set(4...132))
        fixtures["page"] = page.frames; fixtures["tail"] = tail.frames
        // Clearing between pages forces a replacement, including when the view is paused.
        clear(recorder)
        let clearedPage = viewer.page(since: page.cursor, epoch: page.epoch)
        assert(clearedPage.resets && clearedPage.records.isEmpty)
        fixtures["clearDuringReplay"] = clearedPage.frames
        server.queue.sync { server.networkIDs = [1, 2, 3, 133, 134] }
        recorder.update(apps: [app(server)]); wait { summary(recorder)["records"] == 2 }
        let latest = viewer.page(epoch: clearedPage.epoch)
        assert(!latest.resets && latest.records.count == 2)
        fixtures["newRecords"] = latest.frames
        let unchanged = viewer.page(since: latest.cursor, epoch: latest.epoch)
        assert(!unchanged.resets && unchanged.records.isEmpty)
        fixtures["unchanged"] = unchanged.frames
        viewer.close(); recorder.stop()

        // Even an old cursor that happens to be within range is invalid after a Mac restart.
        var clock = Date()
        let restarted = NetworkRecorder(folder: folder, now: { clock }) { _, _ in true }
        restarted.update(apps: [app(server)]); wait { summary(restarted)["records"] == 2 }
        let nextViewer = try NetworkViewerProbe(recorder: restarted)
        let afterRestart = nextViewer.page(since: 1, epoch: latest.epoch)
        assert(afterRestart.resets && afterRestart.records.count == 2 && afterRestart.epoch != latest.epoch)
        fixtures["afterRestart"] = afterRestart.frames
        // Cold cache eviction also regenerates local sequence numbers and requires replacement.
        wait { summary(restarted)["viewers"] == 0 }
        restarted.update(apps: []); _ = summary(restarted)
        clock = clock.addingTimeInterval(301)
        restarted.update(apps: []); wait { summary(restarted)["cachedSources"] == 0 }
        restarted.update(apps: [app(server)]); wait { summary(restarted)["records"] == 2 }
        let reloaded = nextViewer.page(since: 1, epoch: afterRestart.epoch)
        assert(reloaded.resets && reloaded.records.count == 2 && reloaded.epoch != afterRestart.epoch)
        fixtures["cacheReload"] = reloaded.frames
        let fresh = try AppServer(); defer { fresh.stop() }
        fresh.queue.sync { fresh.mode = "pending"; fresh.networkIDs = [1, 2] }
        restarted.update(apps: [app(fresh)]); wait { summary(restarted)["records"] == 2 && fresh.queue.sync { !fresh.networkTargets.isEmpty } }
        let process = nextViewer.page(since: 1, epoch: reloaded.epoch)
        assert(process.resets && process.records.count == 2 && process.payload["instanceId"] as? String == fresh.instance)
        fixtures["processChanged"] = process.frames
        nextViewer.close(); restarted.stop()
        try JSONSerialization.data(withJSONObject: fixtures).write(to: URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/network-viewer-events.json"))
        print("PASS real viewer protocol: missed clear, paged resume, mid-replay clear, new records, unchanged resume, Mac restart, cache eviction and App restart")
    }
}
