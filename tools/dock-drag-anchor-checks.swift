import AppKit
import QuartzCore

// Compile with Sources/Launchpod/DockDragAnimation.swift; no catalog or layout.
enum Motion { static let reduced = false }

@main enum AnchorChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--native") { runNative(); return }
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        let artwork = NSImage(size:NSSize(width:112,height:112))
        for origin in [NSPoint(x:120,y:300),NSPoint(x:-1600,y:-500)] {
            let source = NSRect(origin:origin,size:NSSize(width:112,height:112))
            for grip in [NSPoint(x:0.5,y:0.5),NSPoint(x:0.1,y:0.9),NSPoint(x:0.8,y:0.2),NSPoint(x:0.4,y:-0.3)] {
                let pointer = NSPoint(x:source.minX+grip.x*112,y:source.minY+grip.y*112)
                let anchor = DockDragAnchor(sourceFrame:source,pointer:pointer)
                var transition = DockDragSizeTransition(original:112,dock:64)
                for (over,start) in [(true,0.0),(false,0.11),(true,0.18),(false,0.50)] {
                    transition.setOverDock(over,at:start)
                    for step in 0...30 {
                        let size = transition.size(at:start+Double(step)/120)
                        let item = NSDraggingItem(pasteboardWriter:"anchor" as NSString)
                        item.setDraggingFrame(source,contents:artwork)
                        anchor.apply(size:size,artwork:artwork,to:item)
                        let components = item.imageComponentsProvider!()
                        let frame = components[0].frame
                        check(item.draggingFrame == source)
                        check(abs(source.minX+frame.minX+grip.x*size-pointer.x) < 0.00001)
                        check(abs(source.minY+frame.minY+grip.y*size-pointer.y) < 0.00001)
                        check(components.count == 1 && components[0].key == .icon && components[0].contents as? NSImage === artwork)
                    }
                }
            }
        }
        print("PASS: \(checks) anchor checks (fixed native frame; center/off-center/label grips; shrink, expand, reversal; negative screen origins)")
    }
    static func runNative() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect:NSRect(x:200,y:300,width:800,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Launchpod Anchor Probe"
        window.contentView = NativeAnchorProbe(frame:NSRect(x:0,y:0,width:800,height:400))
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true); app.run()
    }
}

final class NativeAnchorProbe: NSView, NSDraggingSource {
    private var timer: Timer?
    private var started: Double = 0
    private var anchor = DockDragAnchor(sourceFrame:NSRect(x:0,y:0,width:112,height:112),pointer:NSPoint(x:30,y:80))
    private var transition = DockDragSizeTransition(original:112,dock:64)
    private var artwork: NSImage!
    private var lines: [String] = []
    private var maxError: CGFloat = 0
    private var samples = 0
    private var sawShrink = false, sawExpand = false
    override func draw(_ rect:NSRect) {
        NSColor.darkGray.setFill(); bounds.fill()
        NSColor.systemTeal.setFill(); NSRect(x:60,y:150,width:112,height:112).fill()
        ("Drag teal square across window" as NSString).draw(at:NSPoint(x:50,y:310),withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:24)])
    }
    override func mouseDown(with event:NSEvent) {}
    override func mouseDragged(with event:NSEvent) {
        artwork = NSImage(size:NSSize(width:112,height:112),flipped:false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
        let item = NSDraggingItem(pasteboardWriter:"anchor probe" as NSString)
        let p = convert(event.locationInWindow,from:nil)
        item.setDraggingFrame(NSRect(x:p.x-30,y:p.y-80,width:112,height:112),contents:artwork)
        beginDraggingSession(with:[item],event:event,source:self).animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .copy }
    private func update(_ session:NSDraggingSession) {
        let time = CACurrentMediaTime()-started
        if time >= 0.28 { transition.setOverDock(false,at:time) }
        let size = transition.size(at:time)
        sawShrink = sawShrink || (time < 0.28 && size < 100)
        sawExpand = sawExpand || (time > 0.4 && size > 90)
        session.enumerateDraggingItems(options:[],for:nil,classes:[NSPasteboardItem.self],searchOptions:[:]) { item,_,_ in
            let before = item.draggingFrame
            self.anchor.apply(size:size,artwork:self.artwork,to:item)
            precondition(before == item.draggingFrame)
        }
    }
    private func sample(_ session:NSDraggingSession) {
        let time = CACurrentMediaTime()-started
        session.enumerateDraggingItems(options:[],for:nil,classes:[NSPasteboardItem.self],searchOptions:[:]) { item,_,_ in
            guard let icon = item.imageComponents?.first else { preconditionFailure("missing icon") }
            let grip = self.anchor.fraction
            let point = NSPoint(x:item.draggingFrame.minX+icon.frame.minX+grip.x*icon.frame.width,
                                y:item.draggingFrame.minY+icon.frame.minY+grip.y*icon.frame.height)
            let cursor = session.draggingLocation
            let error = hypot(point.x-cursor.x,point.y-cursor.y)
            self.maxError = max(self.maxError,error); self.samples += 1
            self.lines.append("t=\(time) cursor=\(cursor) frame=\(item.draggingFrame) component=\(icon.frame) error=\(error)")
        }
    }
    func draggingSession(_ session:NSDraggingSession,willBeginAt point:NSPoint) {
        started = CACurrentMediaTime(); transition = DockDragSizeTransition(original:112,dock:64)
        transition.setOverDock(true,at:0); lines = []; maxError = 0; samples = 0; sawShrink = false; sawExpand = false
        lines.append("begin callback=\(point) uninitializedSessionCursor=\(session.draggingLocation)")
        update(session)
        timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self,weak session] _ in
            guard let self = self, let session = session else { return }
            self.sample(session); self.update(session)
        }
        RunLoop.main.add(timer!,forMode:.common)
    }
    func draggingSession(_ session:NSDraggingSession,movedTo point:NSPoint) { sample(session); update(session) }
    func draggingSession(_ session:NSDraggingSession,endedAt point:NSPoint,operation:NSDragOperation) {
        timer?.invalidate(); sample(session)
        let passed = samples > 15 && maxError < 1 && sawShrink && sawExpand
        lines.append("\(passed ? "PASS" : "FAIL"): \(samples) native samples; maximum grip error \(maxError) pt; shrink=\(sawShrink), expand=\(sawExpand)")
        try! lines.joined(separator:"\n").write(toFile:"/tmp/anchor-native-fixed.txt",atomically:true,encoding:.utf8)
        print(lines.last!)
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { NSApp.terminate(nil) }
    }
}
