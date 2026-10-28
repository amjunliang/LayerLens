//
//  AppDelegate.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import AppKit

/// 界面全部由网页提供, 原生部分只有承载网页的窗口、系统菜单和菜单栏图标
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let registry = TargetRegistry()
    private lazy var server = HubServer(registry: registry)
    private lazy var windowController = MainWindowController(url: server.baseURL)
    private var statusItem: NSStatusItem?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }
        handleTerminationSignal()
        NSApp.mainMenu = MainMenu.build(target: self)
        setupStatusItem()
        registry.start()
        server.start { [weak self] error in
            guard let self else { return }
            if let error {
                self.showStartError(error)
                return
            }
            self.windowController.showAndLoad()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindow()
        }
        return true
    }

    /// 有终端会话时提醒: 退出会结束所有终端
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let summary = server.terminal.summary()
        guard summary.total > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("退出 LayerLens 会结束所有终端", "Quitting LayerLens ends all terminals")
        alert.informativeText = summary.busy > 0
            ? L("有 \(summary.total) 个终端会话, 其中 \(summary.busy) 个正在运行命令.", "\(summary.total) terminal sessions, \(summary.busy) running a command.")
            : L("有 \(summary.total) 个终端会话.", "\(summary.total) terminal sessions.")
        alert.addButton(withTitle: L("退出", "Quit"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        server.terminal.terminateAll()
        return .terminateNow
    }

    /// 关闭窗口后继续在菜单栏运行, 浏览器仍可访问
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Actions

    @objc func openWindow() {
        windowController.showAndLoad()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openInBrowser() {
        NSWorkspace.shared.open(server.baseURL)
    }

    @objc func reloadPage() {
        openWindow()
        windowController.reload()
    }

    @objc func zoomIn() {
        PageZoom.zoomIn()
    }

    @objc func zoomOut() {
        PageZoom.zoomOut()
    }

    @objc func actualSize() {
        PageZoom.reset()
    }

    @objc func showAbout() {
        openWindow()
        windowController.openPanel("about")
    }

    @objc func showIntegration() {
        openWindow()
        windowController.openPanel("integration")
    }

    @objc func showCache() {
        openWindow()
        windowController.openPanel("cache")
    }

    // MARK: - Private

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: "LayerLens")
        let menu = NSMenu()
        menu.addItem(withTitle: L("打开窗口", "Open Window"), action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("在浏览器打开", "Open in Browser"), action: #selector(openInBrowser), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出 LayerLens", "Quit LayerLens"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// 被 kill 等方式结束时也走正常退出流程
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSource = source
    }

    /// 已有实例在运行时激活它, 避免两个实例争用端口
    private func activateExistingInstance() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { $0 != NSRunningApplication.current }
        guard let other = others.first else { return false }
        other.activate()
        return true
    }

    private func showStartError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("LayerLens 无法启动", "LayerLens failed to start")
        alert.informativeText = L("端口 \(HubServer.port) 可能被其他程序占用.\n\(error.localizedDescription)", "Port \(HubServer.port) may be in use by another process.\n\(error.localizedDescription)")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

/// 原生文案很少, 跟随系统语言
func L(_ zh: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? zh : en
}
