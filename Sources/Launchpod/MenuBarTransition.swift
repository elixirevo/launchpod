import AppKit
import QuartzCore

/// Covers the menu bar while the launcher is open, with an entry/exit fade.
/// Order out BEFORE changing presentation options;
/// AppKit can relocate a visible menu-level panel when the menu reservation changes.
/// Draws the same processed desktop picture as the launcher.
final class MenuBarTransition {
    private final class StripPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    private final class Backdrop: FlippedView {
        var image: NSImage?
        var desktopSize = NSSize.zero
        var onClick: (() -> Void)?
        private var clickOrigin: NSPoint?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { clickOrigin = event.locationInWindow }
        override func mouseUp(with event: NSEvent) {
            defer { clickOrigin = nil }
            guard let origin = clickOrigin, window?.ignoresMouseEvents == false else { return }
            let point = event.locationInWindow
            guard hypot(point.x-origin.x,point.y-origin.y) < 3,
                  bounds.contains(convert(point,from:nil)) else { return }
            onClick?()
        }
        override func rightMouseDown(with event: NSEvent) {}
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: bounds).addClip()
            NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.32, alpha: 1).setFill()
            bounds.fill()
            if let image = image, desktopSize.height > 0 {
                // Paint only the menu strip's top crop, never a desktop-height
                // drawing rectangle into a thin backing surface.
                let height = image.size.height*bounds.height/desktopSize.height
                let source = NSRect(x: 0,y: image.size.height-height,width: image.size.width,height: height)
                image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
    var onBackgroundClick: (() -> Void)? {
        didSet { backdrop.onClick = onBackgroundClick }
    }
    private let backdrop = Backdrop()
    private var stripSizes: [UInt32:(screenSize:NSSize,height:CGFloat)] = [:]
    let panel: NSPanel
    var opacity: Float { backdrop.layer?.presentation()?.opacity ?? backdrop.layer?.opacity ?? 0 }
    init() {
        panel = StripPanel(contentRect: NSRect(x: 0,y: 0,width: 1,height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.animationBehavior = .none; panel.alphaValue = 0
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue+1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        backdrop.wantsLayer = true; backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width,.height]; panel.contentView = backdrop
    }
    func prepare(screen: NSScreen, image: NSImage?, opacity: Float, blocksMenuInteraction: Bool = false) {
        let measured = max(NSStatusBar.system.thickness, max(screen.safeAreaInsets.top, screen.frame.maxY-screen.visibleFrame.maxY))
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let previous = stripSizes[display]
        // visibleFrame loses the menu reservation while auto-hidden. Keep the
        // measured height so opening and closing use the same backing surface.
        let height = previous?.screenSize == screen.frame.size ? max(measured,previous!.height) : measured
        stripSizes[display] = (screen.frame.size,height)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY-height, width: screen.frame.width, height: height)
        // Keep an unordered surface invisible to WindowServer until its final
        // position, content size and initial opacity have all been installed.
        if !panel.isVisible { panel.alphaValue = 0 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false, animate: false)
        backdrop.frame = NSRect(origin: .zero,size: frame.size)
        backdrop.image = image; backdrop.desktopSize = screen.frame.size; backdrop.needsDisplay = true
        backdrop.layer?.removeAllAnimations(); backdrop.layer?.opacity = opacity
        panel.ignoresMouseEvents = !blocksMenuInteraction
        CATransaction.commit()
        panel.orderFrontRegardless(); panel.displayIfNeeded()
        CATransaction.flush()
        panel.alphaValue = 1
    }
    func animate(covering: Bool, duration: TimeInterval) {
        guard let layer = backdrop.layer else { return }
        let start = opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = covering ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start; fade.toValue = layer.opacity; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: covering ? .easeIn : .easeOut)
        layer.add(fade, forKey: "menuTransition")
        CATransaction.commit()
    }
    func hide() {
        panel.alphaValue = 0; panel.orderOut(nil); backdrop.layer?.removeAllAnimations()
        panel.ignoresMouseEvents = true
    }
}
