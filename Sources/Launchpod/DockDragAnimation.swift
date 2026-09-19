import AppKit
import QuartzCore

/// Retarget from the current size, so crossing the Dock edge mid-animation
/// never jumps back to either endpoint. All dimensions are logical points.
struct DockDragSizeTransition {
    let original: CGFloat
    let dock: CGFloat
    private(set) var from: CGFloat
    private(set) var target: CGFloat
    private(set) var started: TimeInterval = 0
    var duration: TimeInterval = 0.22

    init(original: CGFloat, dock: CGFloat) {
        self.original = original; self.dock = dock; from = original; target = original
    }
    func size(at time: TimeInterval) -> CGFloat {
        let t = duration > 0 ? min(1,max(0,(time-started)/duration)) : 1
        let eased = t*t*(3-2*t)
        return from+(target-from)*CGFloat(eased)
    }
    mutating func setOverDock(_ over: Bool, at time: TimeInterval) {
        let next = over ? dock : original
        guard next != target else { return }
        from = size(at:time); target = next; started = time
    }
    func isAnimating(at time: TimeInterval) -> Bool { from != target && time < started+duration }
}

/// Resolve the visible Dock's actual bounds, not the whole bottom screen band.
/// Screen coordinates here use AppKit's bottom-left origin.
final class DockDragRegion {
    private var sampledAt: TimeInterval = -.infinity
    private var rectangles: [NSRect] = []

    func contains(_ point: NSPoint) -> Bool {
        let now = CACurrentMediaTime()
        if now-sampledAt > 0.05 {
            sampledAt = now
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let level = CGWindowLevelForKey(.dockWindow)
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
            rectangles = windows.compactMap { entry in
                guard entry[kCGWindowOwnerName as String] as? String == "Dock",
                      (entry[kCGWindowLayer as String] as? NSNumber)?.int32Value == level,
                      let bounds = entry[kCGWindowBounds as String] as? [String:Any],
                      let rect = CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return nil }
                let frame = NSRect(x:rect.minX,y:primaryTop-rect.maxY,width:rect.width,height:rect.height)
                // Ignore full-screen Dock-owned overlays such as Mission Control.
                guard NSScreen.screens.contains(where: { screen in
                    frame.intersects(screen.frame) && (frame.height < screen.frame.height*0.4 || frame.width < screen.frame.width*0.4)
                }) else { return nil }
                return frame
            }
        }
        if !rectangles.isEmpty { return rectangles.contains { $0.contains(point) } }
        // Hidden Dock: entering the physical edge starts the transition while
        // the Dock reveals itself. Visible bounds take over on the next sample.
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx:-1,dy:-1).contains(point) }) else { return false }
        let orientation = UserDefaults(suiteName:"com.apple.dock")?.string(forKey:"orientation") ?? "bottom"
        return Self.edgeContains(point,frame:screen.frame,visibleFrame:screen.visibleFrame,orientation:orientation)
    }
    static func edgeContains(_ point: NSPoint, frame: NSRect, visibleFrame: NSRect, orientation: String) -> Bool {
        switch orientation {
        case "left": return point.x <= max(frame.minX+3,visibleFrame.minX)
        case "right": return point.x >= min(frame.maxX-3,visibleFrame.maxX)
        default: return point.y <= max(frame.minY+3,visibleFrame.minY)
        }
    }
}

/// Keep AppKit's native drag frame/hotspot fixed. Resize only the icon component
/// inside it; component bounds do not clip artwork, including a label grab.
struct DockDragAnchor {
    let originalSize: NSSize
    let fraction: NSPoint

    init(sourceFrame: NSRect, pointer: NSPoint) {
        originalSize = sourceFrame.size
        fraction = NSPoint(x:(pointer.x-sourceFrame.minX)/max(1,sourceFrame.width),
                           y:(pointer.y-sourceFrame.minY)/max(1,sourceFrame.height))
    }
    func componentFrame(size: CGFloat) -> NSRect {
        NSRect(x:fraction.x*(originalSize.width-size),
               y:fraction.y*(originalSize.height-size),width:size,height:size)
    }
    func apply(size: CGFloat, artwork: NSImage?, to item: NSDraggingItem) {
        let frame = componentFrame(size:size)
        item.imageComponentsProvider = {
            let icon = NSDraggingImageComponent(key:.icon)
            icon.contents = artwork; icon.frame = frame
            return [icon]
        }
    }
}

/// AppKit owns pointer tracking. The common-mode timer only scales artwork
/// around its local grip, including while the pointer is stationary.
final class DockDragAnimation {
    private(set) var transition: DockDragSizeTransition
    private let anchor: DockDragAnchor
    private let artwork: NSImage?
    private let region = DockDragRegion()
    private weak var session: NSDraggingSession?
    private var timer: Timer?
    private var renderedSize: CGFloat?

    init(sourceFrame: NSRect, pointer: NSPoint, artwork: NSImage?, dockSize: CGFloat) {
        transition = DockDragSizeTransition(original:sourceFrame.width,dock:dockSize)
        if Motion.reduced { transition.duration = 0 }
        anchor = DockDragAnchor(sourceFrame:sourceFrame,pointer:pointer)
        self.artwork = artwork
    }
    func begin(_ session: NSDraggingSession, at point: NSPoint) {
        self.session = session
        // draggingLocation can still be uninitialized during willBeginAt.
        // Use the callback for Dock detection, never to reset draggingFrame.
        move(to:point)
    }
    func move(to point: NSPoint) {
        let now = CACurrentMediaTime()
        transition.setOverDock(region.contains(point),at:now)
        render(at:now)
        if transition.isAnimating(at:now), timer == nil {
            timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!,forMode:.common)
        }
    }
    private func tick() {
        guard let session = session else { stop(); return }
        let now = CACurrentMediaTime()
        transition.setOverDock(region.contains(session.draggingLocation),at:now)
        render(at:now)
        if !transition.isAnimating(at:now) { timer?.invalidate(); timer = nil }
    }
    private func render(at time: TimeInterval) {
        let size = transition.size(at:time)
        guard renderedSize != size, let session = session else { return }
        renderedSize = size
        let anchor = anchor, artwork = artwork
        // Reassigning a screen-space draggingFrame here races AppKit's initial
        // cursor offset and subsequent formation updates, making the icon jump.
        session.enumerateDraggingItems(options:[],for:nil,classes:[NSPasteboardItem.self],searchOptions:[:]) { item, _, _ in
            anchor.apply(size:size,artwork:artwork,to:item)
        }
    }
    func stop() { timer?.invalidate(); timer = nil; session = nil; renderedSize = nil }
    deinit { timer?.invalidate() }
}
