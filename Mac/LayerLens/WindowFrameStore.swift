//
//  WindowFrameStore.swift
//  LayerLens
//
//  Created by YueYou on 10/22/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit

/// 保存窗口位置和大小. 系统的 frame autosave 按保存时的屏幕可见区域匹配显示器,
/// 外接显示器的菜单栏显示与否变化后就匹配不上, 窗口会回到主显示器; 这里只要求位置仍在某个显示器上
enum WindowFrameStore {
    private static func key(_ name: String) -> String {
        "LayerLensWindowFrame.\(name)"
    }

    /// 恢复保存的位置, 没有保存或已不在任何显示器上(如外接显示器已断开)时返回 false
    @discardableResult
    static func restore(_ window: NSWindow, name: String) -> Bool {
        guard let text = UserDefaults.standard.string(forKey: key(name)) else { return false }
        let frame = NSRectFromString(text)
        guard frame.width >= window.minSize.width, frame.height >= window.minSize.height else { return false }
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.frame.intersection(frame)
            return overlap.width >= 100 && overlap.height >= 60
        }
        guard visible else { return false }
        window.setFrame(frame, display: false)
        return true
    }

    /// 移动或调整大小后保存; 全屏时不保存. 返回的观察者需要持有
    static func track(_ window: NSWindow, name: String) -> [NSObjectProtocol] {
        let save: @Sendable (Notification) -> Void = { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key(name))
            }
        }
        return [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main, using: save)
        }
    }
}
