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

    init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LayerLens"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LayerLensMainWindow")
        super.init(window: window)

        let configuration = WKWebViewConfiguration()
        // 网页据此区分 App 窗口与浏览器, 只调整少量文案和入口
        let script = WKUserScript(source: "window.LAYERLENS_APP = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(WeakScriptHandler(self), name: "layerlens")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isInspectable = true
        window.contentView = webView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndLoad() {
        if !loaded {
            loaded = true
            webView.load(URLRequest(url: url))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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

    /// 网页发来的消息: {action: "openBrowser", url}
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "openBrowser":
            let target = (body["url"] as? String).flatMap(URL.init(string:)) ?? url
            // 只打开本服务的地址
            if target.host == url.host && target.port == url.port {
                NSWorkspace.shared.open(target)
            }
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
