// Compile with RecorderTestSupport.swift and actual recorder / transport sources.
import Foundation
import Network

@main struct NetworkClearTests {
    static func wait(_ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(6)
        while !check() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        assert(check(), "Clear-state regression timed out")
    }
    static func summary(_ recorder: NetworkRecorder) -> [String: Int] {
        let ready = DispatchSemaphore(value: 0); var result: [String: Int] = [:]
        recorder.connectionSummary { result = $0; ready.signal() }
        assert(ready.wait(timeout: .now() + 3) == .success); return result
    }
    static func app(_ server: AppServer, device: String = "phone") -> AppRecord {
        AppRecord(deviceId: device, bundleId: "test", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance, "networkCapture": true])
    }
    static func call(_ recorder: NetworkRecorder, method: String = "POST", path: String = "/api/network/clear") -> HTTPResponse {
        let head = HTTPRequestHead.parse(Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n".utf8))!.head!
        let ready = DispatchSemaphore(value: 0); var result: HTTPResponse?
        let connection = HubConnection(onResponse: { result = $0; ready.signal() })
        assert(recorder.handle(head, path: head.path, deviceId: "phone", bundleId: "test", connection: connection, fallback: {
            result = .error(418, "Unexpected upstream fallback"); ready.signal()
        }))
        assert(ready.wait(timeout: .now() + 3) == .success); return result!
    }
    static func recordFiles(_ root: URL) -> [URL] {
        ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []).filter { $0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent == "r" }
    }
    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/LayerLens-release-build/network-clear")
        try? manager.removeItem(at: root); defer { try? manager.removeItem(at: root) }
        let server = try AppServer(); defer { server.stop() }
        server.queue.sync { server.mode = "pending"; server.networkIDs = [1, 2, 3] }
        let folder = root.appendingPathComponent("offline")
        let first = NetworkRecorder(folder: folder) { _, _ in true }
        first.update(apps: [app(server)]); wait { summary(first)["records"] == 3 }
        let sessionFolder = recordFiles(folder)[0].deletingLastPathComponent().deletingLastPathComponent()
        let backup = root.appendingPathComponent("interrupted-delete-backup")
        try manager.copyItem(at: sessionFolder, to: backup)
        first.update(apps: []); assert(summary(first)["connections"] == 0)
        assert(call(first).status == 200 && summary(first)["records"] == 0)
        assert(recordFiles(folder).isEmpty)
        first.stop()

        // Simulate an interrupted unlink: the durable boundary must also hide leftover disk data.
        try manager.copyItem(at: backup, to: sessionFolder)
        server.queue.sync { server.mode = "ok"; server.networkIDs = [1, 2, 3, 4] }
        let restored = NetworkRecorder(folder: folder) { _, _ in true }
        restored.update(apps: [app(server)])
        wait { summary(restored)["records"] == 1 && server.queue.sync { server.released.contains(4) } }
        assert(server.queue.sync { server.detailRequests == [4] && server.bodyRequests == 1 && server.clearRequests == 0 })
        assert(call(restored, method: "GET", path: "/api/network/detail?id=1").status == 404)
        assert(call(restored, method: "GET", path: "/api/network/body?id=1&side=req").status == 404)
        restored.stop()

        // A second Mac restart still excludes old IDs and reuses the saved new body.
        let again = NetworkRecorder(folder: folder) { _, _ in true }
        again.update(apps: [app(server)])
        wait { summary(again)["connections"] == 1 && summary(again)["records"] == 1 }
        assert(server.queue.sync { server.bodyRequests == 1 }); again.stop()

        // A Pod without selective release support still respects the local clear boundary.
        let legacy = NetworkRecorder(folder: folder) { _, _ in true }
        let releases = server.queue.sync { server.releases }
        let legacyApp = AppRecord(deviceId: "phone", bundleId: "test", endpoint: .local(port: server.listener.port!.rawValue), info: ["instanceId": server.instance])
        legacy.update(apps: [legacyApp])
        wait { summary(legacy)["connections"] == 1 && summary(legacy)["records"] == 1 }
        assert(server.queue.sync { server.releases == releases && server.bodyRequests == 1 })
        legacy.stop()

        // Pending cleanup cannot reach a new App process whose IDs start again at 1.
        let fresh = try AppServer(); defer { fresh.stop() }
        fresh.queue.sync { fresh.mode = "ok"; fresh.networkIDs = [1, 2] }
        let changed = NetworkRecorder(folder: folder) { _, _ in true }
        changed.update(apps: [app(fresh)])
        wait { fresh.queue.sync { Set(fresh.released) == [1, 2] } }
        assert(summary(changed)["records"] == 2 && fresh.queue.sync { fresh.bodyRequests == 2 && fresh.clearRequests == 0 })
        changed.stop()

        // Device isolation: a boundary from phone must not hide IDs on another device.
        let other = NetworkRecorder(folder: folder) { _, _ in true }
        other.update(apps: [app(server, device: "other")])
        wait { summary(other)["records"] == 4 && server.queue.sync { server.bodyRequests == 5 } }
        other.stop()

        // Online cleanup uses targeted, retryable release. A failed release cannot resurrect rows.
        let online = try AppServer(); defer { online.stop() }
        online.queue.sync { online.mode = "ok"; online.networkIDs = [1, 2, 3] }
        let onlineRecorder = NetworkRecorder(folder: root.appendingPathComponent("online")) { _, _ in true }
        onlineRecorder.update(apps: [app(online)])
        wait { online.queue.sync { online.released.count == 3 } && summary(onlineRecorder)["requests"] == 0 }
        online.queue.sync { online.releaseFailures = 1 }
        assert(call(onlineRecorder).status == 200)
        wait { online.queue.sync { online.releases == 2 } && summary(onlineRecorder)["requests"] == 0 }
        assert(summary(onlineRecorder)["records"] == 0)
        online.queue.sync { online.networkIDs = [1, 2, 3, 4] }
        onlineRecorder.update(apps: [app(online)])
        wait { online.queue.sync { online.released.contains(4) } }
        assert(summary(onlineRecorder)["records"] == 1 && online.queue.sync { online.bodyRequests == 4 && online.clearRequests == 0 })
        onlineRecorder.stop()

        // Failure to persist the boundary is an API error and must leave existing records intact.
        let failure = try AppServer(); defer { failure.stop() }
        failure.queue.sync { failure.mode = "pending"; failure.networkIDs = [1, 2, 3] }
        let blockedFolder = root.appendingPathComponent("blocked")
        let blocked = NetworkRecorder(folder: blockedFolder) { _, _ in true }
        blocked.update(apps: [app(failure)]); wait { summary(blocked)["records"] == 3 }
        let markerFolder = blockedFolder.appendingPathComponent(".cleared")
        try Data("not a directory".utf8).write(to: markerFolder)
        assert(call(blocked).status == 500 && summary(blocked)["records"] == 3 && recordFiles(blockedFolder).count == 3)
        try manager.removeItem(at: markerFolder)
        assert(call(blocked).status == 200 && summary(blocked)["records"] == 0)
        blocked.stop()

        // A corrupt/unreadable boundary blocks replay instead of exposing cleared history;
        // repairing it allows the same recorder to recover without a stale error indicator.
        let marker = try manager.contentsOfDirectory(at: folder.appendingPathComponent(".cleared"), includingPropertiesForKeys: nil).first!
        let markerData = try Data(contentsOf: marker)
        try Data("invalid JSON".utf8).write(to: marker)
        let corrupt = NetworkRecorder(folder: folder) { _, _ in true }
        corrupt.update(apps: [app(server)])
        wait { summary(corrupt)["storageErrors"] == 1 }
        assert(summary(corrupt)["records"] == 0 && summary(corrupt)["connections"] == 0)
        assert(call(corrupt, method: "GET", path: "/api/network/status").status == 503)
        try markerData.write(to: marker)
        corrupt.update(apps: [app(server)])
        wait { summary(corrupt)["records"] == 1 && summary(corrupt)["storageErrors"] == 0 }
        corrupt.stop()

        // Cache Manage uses the same boundary when deleting a currently loaded session.
        let cacheServer = try AppServer(); defer { cacheServer.stop() }
        cacheServer.queue.sync { cacheServer.mode = "pending"; cacheServer.networkIDs = [1, 2, 3] }
        let cacheFolder = root.appendingPathComponent("cache-delete")
        let cache = NetworkRecorder(folder: cacheFolder) { _, _ in true }
        cache.update(apps: [app(cacheServer)]); wait { summary(cache)["records"] == 3 }
        let deletedFolder = recordFiles(cacheFolder)[0].deletingLastPathComponent().deletingLastPathComponent()
        try manager.removeItem(at: deletedFolder)
        cache.didDelete([deletedFolder]); assert(summary(cache)["records"] == 0)
        cacheServer.queue.sync { cacheServer.networkIDs.append(4) }
        cache.update(apps: [app(cacheServer)])
        wait { summary(cache)["records"] == 1 && recordFiles(cacheFolder).contains { $0.lastPathComponent == "4.json" } }
        cache.stop()
        print("PASS durable offline clear, interrupted unlink recovery, no stale detail fallback, later requests, process/device isolation, release retry and persistence failure")
    }
}
