import Foundation

/// Only target-menu metadata is cleaned; saved logs and network files are untouched.
enum TargetHistory {
    static func validBundleId(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..") && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func sanitizedApps(_ apps: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (bundleId, value) in apps where validBundleId(bundleId) {
            guard var app = value as? [String: Any] else { continue }
            app["bundleId"] = bundleId
            result[bundleId] = app
        }
        return result
    }

    static func sanitized(_ history: [String: [String: Any]]) -> [String: [String: Any]] {
        history.mapValues { entry in
            var entry = entry
            entry["apps"] = sanitizedApps(entry["apps"] as? [String: Any] ?? [:])
            return entry
        }
    }
}
