import Foundation

@main struct TargetHistoryTests {
    static func main() {
        for value in ["com.app", "com.valid-app_1", "single"] { precondition(TargetHistory.validBundleId(value)) }
        for value in ["", "com.bjyueyou.dramapro/", "../app", "app\\path", " app", "com..app", ".", "app?x=1", "app\n"] {
            precondition(!TargetHistory.validBundleId(value), value)
        }
        let raw: [String: [String: Any]] = ["phone": ["id": "phone", "name": "Keep", "apps": [
            "com.valid": ["bundleId": "mismatch", "appName": "Name", "capture": true],
            "com.app/": ["bundleId": "com.app/"], "bad-payload": "invalid"
        ]], "offline": ["id": "offline", "apps": ["bad/": [:]]]]
        let cleaned = TargetHistory.sanitized(raw)
        precondition(cleaned["phone"]?["name"] as? String == "Keep")
        let apps = cleaned["phone"]?["apps"] as! [String: Any]
        precondition(apps.count == 1)
        let app = apps["com.valid"] as! [String: Any]
        precondition(app["bundleId"] as? String == "com.valid")
        precondition(app["capture"] as? Bool == true && app["appName"] as? String == "Name")
        precondition((cleaned["offline"]?["apps"] as! [String: Any]).isEmpty)
        precondition(NSDictionary(dictionary: cleaned).isEqual(to: TargetHistory.sanitized(cleaned)), "Cleaning must be idempotent")
        print("PASS malformed target cleanup, canonical IDs, valid metadata/device preservation and idempotence")
    }
}
