import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

@main enum MCPContextTests {
    static func main() {
        var now: TimeInterval = 100
        let store = MCPContextStore(now: { now })
        require(store.update([
            "windowId": "a",
            "deviceId": "sim",
            "bundleId": "app.a",
            "appName": "A",
            "instanceId": "launch-a",
            "revision": 1,
            "focusRequested": true,
            "focusEpoch": 10,
            "selected": ["element": "AView"],
        ]), "First window rejected")
        now += 1
        require(store.update([
            "windowId": "b",
            "deviceId": "sim",
            "bundleId": "app.b",
            "appName": "B",
            "instanceId": "launch-b",
            "revision": 1,
            "focusRequested": true,
            "focusEpoch": 11,
            "selected": ["element": "BView"],
        ]), "Second window rejected")
        require(store.latest()?.windowId == "b", "Latest focused window was not used")
        now += 1
        require(store.update([
            "windowId": "a",
            "deviceId": "sim",
            "bundleId": "app.a",
            "appName": "A",
            "instanceId": "launch-a",
            "revision": 2,
            "focusRequested": true,
            "focusEpoch": 9,
            "selected": ["element": "AView"],
        ]), "Late context update rejected")
        require(store.latest()?.windowId == "b", "Older focus event stole the active window")
        now += 1
        require(store.update([
            "windowId": "b",
            "deviceId": "sim",
            "bundleId": "app.b",
            "appName": "B",
            "instanceId": "launch-b",
            "revision": 2,
            "focusRequested": false,
            "focusEpoch": 12,
            "selected": ["element": "BView2"],
        ]), "Focused selection update rejected")
        require(store.latest()?.selected["element"] as? String == "BView2", "Current window content was not refreshed")
        require(store.update([
            "windowId": "a",
            "deviceId": "sim",
            "bundleId": "app.a",
            "appName": "A",
            "instanceId": "launch-a",
            "revision": 3,
            "focusRequested": false,
            "focusEpoch": 13,
            "selected": ["element": "AView3"],
        ]), "Background content update rejected")
        require(store.latest()?.windowId == "b", "Background content update stole focus")

        now += 1
        require(!store.update([
            "windowId": "b",
            "revision": 0,
        ]), "Out-of-order context update was accepted")
        let latest = store.latest()!
        require(latest.hasTarget, "A window with device and App must count as a target")
        let snapshot = store.snapshot(context: latest, sourceRoot: "/repo/b")!
        require(snapshot.json()["sourceRoot"] as? String == "/repo/b", "Source root missing")
        require(Set(snapshot.json().keys) == ["app", "bundleId", "selected", "snapshotId", "sourceRoot"],
                "get_context must only return fields that help locate source")
        require(store.update(["windowId": "b", "deviceId": "sim", "bundleId": "app.b", "instanceId": "launch-b",
                              "revision": 3, "selected": ["element": "BView3", "vc": "BController",
                                                          "rect": [0, 0, 1, 1], "classChain": ["BView"]]]),
                "Selection update rejected")
        let compactSelected = store.snapshot(context: store.latest()!, sourceRoot: nil)!.json()["selected"] as? [String: Any]
        require(compactSelected.map { Set($0.keys) } == ["element", "vc"], "Extra selected fields were not dropped")
        require(store.isCurrent(snapshot), "Fresh snapshot rejected")

        now += 1
        require(store.update([
            "windowId": "b",
            "deviceId": "sim",
            "bundleId": "app.c",
            "instanceId": "launch-c",
            "revision": 4,
            "focusRequested": false,
            "selected": [:],
        ]), "Target update rejected")
        require(!store.isCurrent(snapshot), "Snapshot survived an App change")
        require(store.snapshot(context: latest, sourceRoot: "/repo/b") == nil,
                "A source lookup that finished after an App change produced a stale snapshot")
        require(store.update(["windowId": "b", "deviceId": "sim", "bundleId": "app.b",
                              "instanceId": "launch-b", "revision": 5]), "Returning to a previous target was rejected")
        require(!store.isCurrent(snapshot), "Returning to a target revived its old snapshot")
        let current = store.snapshot(context: store.latest()!, sourceRoot: "/repo/b")!
        now += 3600
        require(store.snapshot(id: current.id) == nil && !store.isCurrent(current),
                "An idle snapshot must expire even when no new snapshot is created")

        let empty = MCPContextStore(now: { now })
        require(empty.update(["windowId": "w", "revision": 1, "focusRequested": true, "focusEpoch": 1,
                              "selected": ["vc": "AController"]]), "Window without App rejected")
        require(empty.latest()?.hasTarget == false, "A window without an App must not count as a target")
        require(empty.snapshot(context: empty.latest()!, sourceRoot: nil)!.json()["selected"] == nil,
                "A selection without element must be dropped")

        store.remove(windowId: "b")
        require(!store.update(["windowId": "b", "revision": 6, "focusRequested": true, "focusEpoch": 99]),
                "A delayed update resurrected a closed window")
        require(store.latest()?.windowId == "a", "Closing a window did not restore the previous focus")

        let roots: [[String: Any]] = [[
            "oid": 1,
            "classChain": ["UIWindow"],
            "vcClass": "DetailController",
            "rect": [0, 0, 400, 800],
            "hidden": false,
            "alpha": 1,
            "children": [
                [
                    "oid": 2,
                    "classChain": ["UIButton", "UIControl"],
                    "ivarTraces": ["DetailController.readButton"],
                    "vcClass": "DetailController",
                    "identifier": "book_detail_read_now",
                    "text": "立即阅读",
                    "rect": [20, 100, 120, 44],
                    "hidden": false,
                    "alpha": 1,
                    "children": [],
                ],
                [
                    "oid": 3,
                    "classChain": ["UILabel"],
                    "text": "立即阅读",
                    "rect": [500, 100, 120, 44],
                    "hidden": false,
                    "alpha": 1,
                    "children": [],
                ],
            ],
        ]]
        let visible = MCPNodeSearch.find(in: roots, query: "立即阅读", visibleOnly: true, limit: 5)
        require(visible.count == 1, "Visible-only search included an offscreen node")
        let element = visible[0]["element"] as? String ?? ""
        require(element.contains("DetailController.readButton"), "Ivar missing")
        require(visible[0]["vc"] as? String == "DetailController", "ViewController was not inherited")
        require(element.contains("id=book_detail_read_now"), "Identifier missing")
        require(Set(visible[0].keys) == ["element", "vc"], "find_nodes candidates must stay compact")
        let business: [[String: Any]] = [[
            "classChain": ["DetailView", "UIView"],
            "rect": [0, 0, 400, 800],
            "children": [[
                "classChain": ["UILabel"],
                "ivarTraces": ["DetailView : UIView._backgroundView", "DetailView.titleLabel"],
                "text": String(repeating: "长", count: 120),
                "rect": [0, 0, 100, 20],
            ]],
        ]]
        let label = MCPNodeSearch.find(in: business, query: "titleLabel", visibleOnly: true, limit: 5)
        require(label.first?["owner"] as? String == "DetailView", "Nearest business ancestor missing")
        let labelElement = label.first?["element"] as? String ?? ""
        require(labelElement.hasPrefix("DetailView.titleLabel (UILabel) \""), "System-declared ivar was kept beside a code ivar")
        require(labelElement.hasSuffix("…\""), "Long text was not clipped")
        require(labelElement.count < 80, "Clipped element is still too long")
        let system = MCPNodeSearch.find(in: [[
            "classChain": ["UILabel"],
            "ivarTraces": ["UIListContentView._textLabel"],
            "text": "Row 3",
            "rect": [0, 0, 10, 10],
        ]], query: "Row 3", visibleOnly: true, limit: 1)
        require(system.first?["element"] as? String == "UIListContentView._textLabel (UILabel) \"Row 3\"",
                "Element must fall back to system ivars like the web page")
        let all = MCPNodeSearch.find(in: roots, query: "立即阅读", visibleOnly: false, limit: 1)
        require(all.count == 1, "Result limit was not enforced")
        print("PASS MCP context: latest focus, revision ordering, snapshots and compact node search")
    }
}
