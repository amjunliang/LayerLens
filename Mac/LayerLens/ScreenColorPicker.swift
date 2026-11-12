import AppKit
import CoreGraphics
import ScreenCaptureKit
import QuartzCore

struct ScreenSampleRegion {
    let rect: CGRect
    let column: Int
    let row: Int

    static func at(_ point: NSPoint, in frame: NSRect, scale: CGFloat, cells: Int) -> ScreenSampleRegion {
        at(point, in: frame, pixelWidth: Int((frame.width * scale).rounded()),
           pixelHeight: Int((frame.height * scale).rounded()), cells: cells)
    }

    static func at(_ point: NSPoint, in frame: NSRect, pixelWidth: Int, pixelHeight: Int, cells: Int) -> ScreenSampleRegion {
        let scaleX = CGFloat(pixelWidth) / frame.width, scaleY = CGFloat(pixelHeight) / frame.height
        let px = max(0, min(pixelWidth - 1, Int(((point.x - frame.minX) * scaleX).rounded(.down))))
        let py = max(0, min(pixelHeight - 1, Int(((frame.maxY - point.y) * scaleY).rounded(.down))))
        let left = max(0, min(max(0, pixelWidth - cells), px - cells / 2))
        let top = max(0, min(max(0, pixelHeight - cells), py - cells / 2))
        return ScreenSampleRegion(rect: CGRect(x: left, y: top, width: min(cells, pixelWidth), height: min(cells, pixelHeight)),
                                  column: px - left, row: py - top)
    }

    static func nudge(_ point: NSPoint, in frame: NSRect, pixelWidth: Int, pixelHeight: Int, dx: Int, dy: Int) -> NSPoint {
        let current = at(point, in: frame, pixelWidth: pixelWidth, pixelHeight: pixelHeight, cells: 11)
        let x = max(0, min(pixelWidth - 1, Int(current.rect.minX) + current.column + dx))
        let y = max(0, min(pixelHeight - 1, Int(current.rect.minY) + current.row + dy))
        return NSPoint(x: frame.minX + (CGFloat(x) + 0.5) * frame.width / CGFloat(pixelWidth),
                       y: frame.maxY - (CGFloat(y) + 0.5) * frame.height / CGFloat(pixelHeight))
    }
}

enum ScreenColorKeyAction: Equatable {
    case cancel, confirm, nudge(UInt16), ignore

    static func from(keyCode: UInt16) -> ScreenColorKeyAction {
        switch keyCode {
        case 53: return .cancel
        case 36, 76: return .confirm
        case 123, 124, 125, 126: return .nudge(keyCode)
        default: return .ignore
        }
    }
}

/// Capture once, then freeze the screen while the user samples local pixels.
/// No repeated screen captures occur while the pointer moves.
@MainActor
final class ScreenColorPicker {
    private let completion: (String?) -> Void
    private var panels: [ColorPickerPanel] = []
    private var observer: NSObjectProtocol?
    private var keyMonitor: Any?
    private var active = false
    private var ready = false
    private var point: NSPoint?
    private var nudged = false
    private let cells = 11

    init(completion: @escaping (String?) -> Void) { self.completion = completion }

    func start() {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = L("屏幕取色需要屏幕录制权限", "Screen color picking needs Screen Recording access")
            alert.informativeText = L("请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许 LayerLens，然后重试。", "Allow LayerLens under Privacy & Security → Screen & System Audio Recording, then try again.")
            alert.addButton(withTitle: L("知道了", "OK"))
            alert.runModal()
            completion(nil)
            return
        }
        active = true
        let screens = NSScreen.screens
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active else { return event }
            switch ScreenColorKeyAction.from(keyCode: event.keyCode) {
            case .cancel: self.finish(nil); return nil
            case .confirm:
                if let point = self.point { self.pick(at: point) }
                return nil
            case .nudge(let key): self.nudge(key); return nil
            case .ignore: return nil
            }
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish(nil) }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard active else { return }
                guard !screens.isEmpty else { throw PickerError.displayUnavailable }
                var captured: [(NSScreen, CGImage)] = []
                for screen in screens {
                    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw PickerError.displayUnavailable }
                    // No picker windows exist yet; the screenshot cannot contain the loupe.
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
                    config.height = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
                    config.showsCursor = false
                    config.ignoreShadowsDisplay = false
                    config.ignoreShadowsSingleWindow = false
                    config.colorSpaceName = CGColorSpace.sRGB
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard active else { return }
                    captured.append((screen, image))
                }
                // Prepare every layer before ordering the windows on screen so
                // there is no transparent/full-screen transition during capture.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (screen, image) in captured {
                    let panel = ColorPickerPanel(screen: screen)
                    let view = ColorPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
                    view.onMove = { [weak self] point in self?.move(to: point) }
                    view.onClick = { [weak self] point in self?.pick(at: point) }
                    view.onCancel = { [weak self] in self?.finish(nil) }
                    panel.contentView = view
                    panel.snapshot = image
                    view.showSnapshot(image)
                    panels.append(panel)
                }
                CATransaction.commit()
                CATransaction.flush()
                ready = true
                for panel in panels {
                    panel.orderFrontRegardless()
                    if let view = panel.contentView { panel.makeFirstResponder(view) }
                }
                panels.first?.makeKey()
                move(to: NSEvent.mouseLocation)
            } catch {
                guard active else { return }
                NSLog("LayerLens screen color capture failed: %@", String(describing: error))
                finish(nil)
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private func move(to point: NSPoint) {
        guard active, ready else { return }
        self.point = point
        nudged = false
        updateLoupe()
    }

    private func nudge(_ key: UInt16) {
        guard ready, let point, let panel = panels.first(where: { $0.screenFrame.contains(point) }), let image = panel.snapshot else { return }
        let next = ScreenSampleRegion.nudge(point, in: panel.screenFrame, pixelWidth: image.width, pixelHeight: image.height,
                                            dx: key == 123 ? -1 : key == 124 ? 1 : 0,
                                            dy: key == 126 ? -1 : key == 125 ? 1 : 0)
        self.point = next
        nudged = true
        updateLoupe()
    }

    private func selected(at point: NSPoint) -> (CGImage, ScreenSampleRegion, String, [Int])? {
        guard let panel = panels.first(where: { $0.screenFrame.contains(point) }), let image = panel.snapshot,
              let bitmap = panel.bitmap else { return nil }
        let region = ScreenSampleRegion.at(point, in: panel.screenFrame, pixelWidth: image.width, pixelHeight: image.height, cells: cells)
        guard let crop = image.cropping(to: region.rect),
              let color = bitmap.colorAt(x: Int(region.rect.minX) + region.column, y: Int(region.rect.minY) + region.row)?.usingColorSpace(.sRGB) else { return nil }
        let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return (crop, region, String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2]), rgb)
    }

    private func updateLoupe() {
        guard let point, let (crop, region, hex, rgb) = selected(at: point) else { return }
        for panel in panels {
            guard let view = panel.contentView as? ColorPickerView else { continue }
            view.updateLoupe(panel.screenFrame.contains(point) ? (crop, point, region.column, region.row, hex, rgb) : nil, nudged: nudged)
        }
    }

    private func pick(at clicked: NSPoint) {
        guard active else { return }
        guard ready else { finish(nil); return }
        // Arrow keys move the selection by physical pixels; a stationary click
        // uses that position. Mouse movement resets it to the pointer.
        let chosen = nudged ? (point ?? clicked) : clicked
        guard let (_, _, hex, _) = selected(at: chosen) else { finish(nil); return }
        NSPasteboard.general.clearContents()
        finish(NSPasteboard.general.setString(hex, forType: .string) ? hex : nil)
    }

    private func finish(_ hex: String?) {
        guard active else { return }
        active = false; ready = false
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        completion(hex)
    }

    func cancel() { finish(nil) }

    private enum PickerError: LocalizedError {
        case displayUnavailable
        var errorDescription: String? { L("无法获取显示器信息，请重试。", "Could not obtain display information. Please try again.") }
    }
}

private final class ColorPickerPanel: NSPanel {
    let screenFrame: NSRect
    let displayID: CGDirectDisplayID
    let scale: CGFloat
    var bitmap: NSBitmapImageRep?
    var snapshot: CGImage? { didSet { bitmap = snapshot.map(NSBitmapImageRep.init(cgImage:)) } }
    override var canBecomeKey: Bool { true }
    init(screen: NSScreen) {
        screenFrame = screen.frame
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        scale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = true; backgroundColor = .black; hasShadow = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .readOnly
        isReleasedWhenClosed = false
    }
}

private final class ColorPickerView: NSView {
    typealias Sample = (CGImage, NSPoint, Int, Int, String, [Int])
    var onMove: ((NSPoint) -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var onCancel: (() -> Void)?
    private let loupe = ColorPickerLoupe(frame: .zero)
    private let target = ColorPickerTarget(frame: .zero)
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { if let window { onMove?(window.convertPoint(toScreen: event.locationInWindow)) } }
    override func mouseDown(with event: NSEvent) { if let window { onClick?(window.convertPoint(toScreen: event.locationInWindow)) } }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }
    func showSnapshot(_ image: CGImage?) {
        wantsLayer = true
        let backdrop = CALayer()
        backdrop.frame = bounds
        backdrop.contents = image
        backdrop.contentsGravity = .resize
        layer?.insertSublayer(backdrop, at: 0)
        if loupe.superview == nil { addSubview(loupe) }
        if target.superview == nil { addSubview(target) }
    }
    func updateLoupe(_ sample: Sample?, nudged: Bool) {
        guard let sample, let window else { loupe.isHidden = true; target.isHidden = true; return }
        let local = window.convertPoint(fromScreen: sample.1)
        target.frame = NSRect(x: local.x - 9, y: local.y - 9, width: 18, height: 18)
        target.isHidden = !nudged
        let width: CGFloat = 165, height: CGFloat = 190, gap: CGFloat = 18
        var x = local.x + gap, y = local.y - gap - height
        if x + width > bounds.maxX { x = local.x - gap - width }
        if y < bounds.minY { y = local.y + gap }
        loupe.frame = NSRect(x: max(0, x), y: min(max(0, y), bounds.height - height), width: width, height: height)
        loupe.sample = sample; loupe.isHidden = false; loupe.needsDisplay = true
    }
}

private final class ColorPickerTarget: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 9, y: 1)); path.line(to: NSPoint(x: 9, y: 17))
        path.move(to: NSPoint(x: 1, y: 9)); path.line(to: NSPoint(x: 17, y: 9))
        path.lineWidth = 3; NSColor.black.setStroke(); path.stroke()
        path.lineWidth = 1; NSColor.systemYellow.setStroke(); path.stroke()
    }
}

private final class ColorPickerLoupe: NSView {
    var sample: ColorPickerView.Sample?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let (image, _, column, row, hex, rgb) = sample else { return }
        NSColor(calibratedWhite: 0.12, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let grid = NSRect(x: 0, y: 25, width: 165, height: 165)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: image, size: NSSize(width: 11, height: 11)).draw(in: grid, from: .zero, operation: .sourceOver, fraction: 1)
        let cell: CGFloat = 15
        let marker = NSRect(x: CGFloat(column) * cell, y: grid.maxY - CGFloat(row + 1) * cell, width: cell, height: cell)
        NSColor.black.setStroke(); NSBezierPath(rect: marker.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSColor.white.setStroke(); NSBezierPath(rect: marker.insetBy(dx: 1.5, dy: 1.5)).stroke()
        "\(hex)  \(rgb.map { String(format: "%03d", $0) }.joined(separator: " "))".draw(at: NSPoint(x: 7, y: 5), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
    }
}
