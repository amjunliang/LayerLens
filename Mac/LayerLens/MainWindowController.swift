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
final class MainWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    private let url: URL
    private var webView: WKWebView!
    private var focusObservers: [NSObjectProtocol] = []
    private var loaded = false
    /// 首次加载完成后才显示窗口, 避免看到空白页面
    private var waitingFirstLoad = false
    private static let themeKey = "LayerLensTheme"
    private var appearanceObservation: NSKeyValueObservation?
    private var zoomObserver: NSObjectProtocol?
    private var frameObservers: [NSObjectProtocol] = []
    /// 进行中的下载及其保存位置
    private var downloads: [ObjectIdentifier: URL] = [:]
    /// 与网页工具栏 --panel 一致: 标题栏后方与工具栏连成一体, 网页绘制前窗口也显示此颜色
    private static func backgroundColor(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x1B / 255.0, green: 0x1D / 255.0, blue: 0x21 / 255.0, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LayerLens"
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        if !WindowFrameStore.restore(window, name: "main") {
            window.center()
        }
        super.init(window: window)
        // 关闭层叠, 否则显示窗口时会挪动恢复的位置
        shouldCascadeWindows = false
        frameObservers = WindowFrameStore.track(window, name: "main")

        // 整页重新加载放在标题栏右侧; 用标题栏附件而不是工具栏, 不增加标题栏高度
        window.addTitlebarAccessoryViewController(makeReloadAccessory())

        let configuration = WKWebViewConfiguration()
        // 网页据此区分 App 窗口与浏览器, 只调整少量文案和入口
        let script = WKUserScript(source: "window.LAYERLENS_APP = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(WeakScriptHandler(self), name: "layerlens")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        zoomObserver = PageZoom.follow(webView)
        // 不绘制默认的白色背景, 网页绘制前透出窗口底色
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView
        focusObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.syncWindowFocus()
            }
        }
        applyTheme(UserDefaults.standard.string(forKey: Self.themeKey) ?? "auto")
        // 跟随系统外观时, 系统切换深浅色后同步更新底色
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateBackgroundColor()
            }
        }
    }

    deinit {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func syncWindowFocus() {
        let focused = window?.isKeyWindow == true
        webView.evaluateJavaScript("window.LAYERLENS_WINDOW_FOCUSED = \(focused ? "true" : "false"); window.dispatchEvent(new Event('layerlens-window-focus'));", completionHandler: nil)
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
        updateBackgroundColor()
    }

    /// WKWebView 在设置时即把颜色固定下来, 不会随外观变化, 需要按窗口当前外观重新设置
    private func updateBackgroundColor() {
        guard let window else { return }
        let color = Self.backgroundColor(dark: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        window.backgroundColor = color
        webView.underPageBackgroundColor = color
    }

    /// 整页重新加载
    @objc func reload() {
        webView.reload()
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
    /// 网页用 window.open 打开的窗口, 关闭时移除
    private var childWindows: [ChildWebWindow] = []

    private func makeReloadAccessory() -> NSTitlebarAccessoryViewController {
        let browser = makeTitlebarButton(symbol: "safari", title: L("在浏览器打开", "Open in Browser"), action: #selector(openInBrowser))
        browser.frame = NSRect(x: 0, y: 3, width: 28, height: 22)
        let reload = makeTitlebarButton(symbol: "arrow.clockwise", title: L("重新加载页面", "Reload Page"), action: #selector(reload))
        reload.toolTip = L("重新加载页面", "Reload Page") + " (⇧⌘R)"
        reload.frame = NSRect(x: 30, y: 3, width: 28, height: 22)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 66, height: 28))
        container.addSubview(browser)
        container.addSubview(reload)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
    }

    private func makeTitlebarButton(symbol: String, title: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.toolTip = title
        return button
    }

    /// 用系统浏览器打开当前页面, 网页地址中带着当前设备与 App
    @objc func openInBrowser() {
        let target = webView.url.flatMap { $0.host == url.host && $0.port == url.port ? $0 : nil } ?? url
        NSWorkspace.shared.open(target)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        finishFirstLoad()
        syncWindowFocus()
        if let panel = pendingPanel {
            pendingPanel = nil
            openPanel(panel)
        }
    }

    /// 外部链接用系统浏览器打开
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
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

    /// 附件(如沙盒文件下载)和无法显示的内容转为下载
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(disposition.lowercased().hasPrefix("attachment") || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    /// 保存到下载文件夹, 重名时加序号
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        downloads[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    // MARK: - WKUIDelegate

    /// 网页中的文件选择框(如日志面板打开本地文件), WKWebView 需要由宿主弹出选择面板
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard let window else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    /// 网页的 window.open(如独立的日志窗口)用新的 App 窗口打开, 同一地址已打开时直接切到前面; 外部地址用浏览器打开
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = navigationAction.request.url else { return nil }
        guard target.host == url.host, target.port == url.port else {
            NSWorkspace.shared.open(target)
            return nil
        }
        if let existing = childWindows.first(where: { $0.webView.url == target }) {
            existing.window.makeKeyAndOrderFront(nil)
            return nil
        }
        let child = ChildWebWindow(configuration: configuration, appearance: window?.appearance, backgroundColor: window?.backgroundColor)
        child.webView.uiDelegate = self
        child.webView.navigationDelegate = self
        child.onClose = { [weak self, weak child] in
            self?.childWindows.removeAll { $0 === child }
        }
        childWindows.append(child)
        child.window.makeKeyAndOrderFront(nil)
        return child.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        childWindows.first { $0.webView === webView }?.window.close()
    }

    // MARK: - WKScriptMessageHandler

    /// 网页发来的消息: {action: "theme", theme}
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "theme":
            applyTheme(body["theme"] as? String ?? "auto")
        default:
            break
        }
    }
}

/// 网页打开的子窗口, 可调整大小和全屏, 标题跟随网页
private final class ChildWebWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let webView: WKWebView
    var onClose: (() -> Void)?
    private var titleObservation: NSKeyValueObservation?
    private var zoomObserver: NSObjectProtocol?
    private var frameObservers: [NSObjectProtocol] = []

    init(configuration: WKWebViewConfiguration, appearance: NSAppearance?, backgroundColor: NSColor?) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        window.title = "LayerLens"
        window.minSize = NSSize(width: 400, height: 240)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.appearance = appearance
        if let backgroundColor {
            window.backgroundColor = backgroundColor
            webView.underPageBackgroundColor = backgroundColor
        }
        webView.isInspectable = true
        zoomObserver = PageZoom.follow(webView)
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView
        window.delegate = self
        if !WindowFrameStore.restore(window, name: "child") {
            window.center()
        }
        frameObservers = WindowFrameStore.track(window, name: "child")
        titleObservation = webView.observe(\.title) { [weak self] webView, _ in
            self?.window.title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "LayerLens"
        }
    }

    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        zoomObserver.map(NotificationCenter.default.removeObserver)
        zoomObserver = nil
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        onClose?()
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
