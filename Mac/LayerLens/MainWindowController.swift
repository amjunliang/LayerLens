//
//  MainWindowController.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit
import WebKit

/// 承载网页的窗口, 加载的地址与浏览器访问的相同
final class MainWindowController: NSWindowController, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private var webView: WKWebView!
    private var loaded = false
    /// 首次加载完成后才显示窗口, 避免看到空白页面
    private var waitingFirstLoad = false
    private static let themeKey = "LayerLensTheme"
    /// 与网页 --bg 一致, 网页绘制前窗口显示此颜色
    private static let backgroundColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x14 / 255.0, green: 0x15 / 255.0, blue: 0x18 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xF4 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
    }

    init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LayerLens"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LayerLensMainWindow")
        window.backgroundColor = Self.backgroundColor
        super.init(window: window)
        applyTheme(UserDefaults.standard.string(forKey: Self.themeKey) ?? "auto")

        let configuration = WKWebViewConfiguration()
        // 网页据此区分 App 窗口与浏览器, 只调整少量文案和入口
        let script = WKUserScript(source: "window.LAYERLENS_APP = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(WeakScriptHandler(self), name: "layerlens")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isInspectable = true
        // 不绘制默认的白色背景, 网页绘制前透出窗口底色
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = Self.backgroundColor
        window.contentView = webView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndLoad() {
        if !loaded {
            loaded = true
            waitingFirstLoad = true
            webView.load(URLRequest(url: url))
            // 加载过慢时不再等待
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.finishFirstLoad()
            }
            return
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finishFirstLoad() {
        guard waitingFirstLoad else { return }
        waitingFirstLoad = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// light / dark / auto, 与网页的主题选项一致; 保存后下次启动在网页加载前即可使用
    private func applyTheme(_ theme: String) {
        switch theme {
        case "dark":
            window?.appearance = NSAppearance(named: .darkAqua)
        case "light":
            window?.appearance = NSAppearance(named: .aqua)
        default:
            window?.appearance = nil
        }
        UserDefaults.standard.set(theme, forKey: Self.themeKey)
    }

    /// 打开网页中的面板, 如 about / integration
    func openPanel(_ name: String) {
        let script = "window.layerlensOpenPanel && window.layerlensOpenPanel('\(name)')"
        if webView.isLoading {
            pendingPanel = name
        } else {
            webView.evaluateJavaScript(script)
        }
    }

    private var pendingPanel: String?

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishFirstLoad()
        if let panel = pendingPanel {
            pendingPanel = nil
            openPanel(panel)
        }
    }

    /// 外部链接用系统浏览器打开
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if target.host == url.host && target.port == url.port {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(target)
            decisionHandler(.cancel)
        }
    }

    // MARK: - WKScriptMessageHandler

    /// 网页发来的消息: {action: "openBrowser", url} / {action: "theme", theme}
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "openBrowser":
            let target = (body["url"] as? String).flatMap(URL.init(string:)) ?? url
            // 只打开本服务的地址
            if target.host == url.host && target.port == url.port {
                NSWorkspace.shared.open(target)
            }
        case "theme":
            applyTheme(body["theme"] as? String ?? "auto")
        default:
            break
        }
    }
}

/// WKUserContentController 会强引用处理者, 通过弱引用中转避免循环引用
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
