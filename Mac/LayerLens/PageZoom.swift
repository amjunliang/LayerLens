//
//  PageZoom.swift
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit
import WebKit

/// 页面缩放: 所有窗口共用一个比例, 下次启动时保留; WKWebView 本身不提供缩放快捷键
enum PageZoom {
    static let didChange = Notification.Name("LayerLensPageZoomDidChange")
    private static let key = "LayerLensPageZoom"
    /// 与 Safari 相同的缩放档位
    private static let steps: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static var level: CGFloat {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? CGFloat(value) : 1
    }

    static func zoomIn() {
        set(steps.first { $0 > level + 0.001 } ?? steps[steps.count - 1])
    }

    static func zoomOut() {
        set(steps.last { $0 < level - 0.001 } ?? steps[0])
    }

    static func reset() {
        set(1)
    }

    private static func set(_ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 应用当前比例并跟随之后的变化; 返回的观察者需要由调用方持有
    static func follow(_ webView: WKWebView) -> NSObjectProtocol {
        webView.pageZoom = level
        return NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { [weak webView] _ in
            webView?.pageZoom = level
        }
    }
}
