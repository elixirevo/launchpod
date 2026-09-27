import AppKit
import LaunchpodCore

extension LauncherController {
    /// Feed windowless events into the global callback path without posting input
    /// to Finder or other apps. The second-display coordinates may be synthetic.
    func runOutsideClickChecks(outputDirectory: URL, completion: @escaping (Result<Void,Error>) -> Void) {
        var checks = 0
        let otherWindow = NSWindow(contentRect:NSRect(x:40,y:40,width:240,height:100),
                                   styleMask:[.titled],backing:.buffered,defer:false)
        otherWindow.isReleasedWhenClosed = false
        otherWindow.title = "Outside click check"
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LayoutError.invalid("Outside click check failed: "+message) }
            checks += 1
        }
        func event(_ type: NSEvent.EventType = .leftMouseDown, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                              windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func outsidePoint() -> NSPoint {
            if let other = NSScreen.screens.first(where: { $0 != self.window.screen }) {
                return NSPoint(x:other.frame.midX,y:other.frame.midY)
            }
            return NSPoint(x:self.window.frame.minX-200,y:self.window.frame.midY)
        }
        let steps: [InteractionCheckStep] = [
            .init {
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                try check(!self.isMonitoringOutsideClicks,"hidden launcher has no outside-click listener")
                self.show()
            },
            .init(delay:0.8) {
                try check(self.isShown && self.window.isVisible && self.isMonitoringOutsideClicks,"visible launcher listens for external clicks")
                let inside = NSPoint(x:self.window.frame.midX,y:self.window.frame.midY)
                self.handleExternalMouseDown(event(at:inside))
                try check(self.isShown,"events on the launcher display retain its existing click handling")
                for type: NSEvent.EventType in [.mouseMoved,.leftMouseUp,.leftMouseDragged] {
                    self.handleExternalMouseDown(event(type,at:outsidePoint()))
                    try check(self.isShown,"moving, releasing or dragging outside does not dismiss")
                }
                // Reproduce a visible launcher that never receives a resign-key
                // transition when the outside click arrives.
                self.window.delegate = nil
                otherWindow.makeKeyAndOrderFront(nil)
            },
            .init(delay:0.15) {
                self.window.delegate = self
                try check(!self.window.isKeyWindow && self.isShown,"launcher stays visible without key focus before the click")
                let click = event(at:outsidePoint())
                try check(click.window == nil,"external event carries screen coordinates without a local window")
                self.handleExternalMouseDown(click)
                try check(!self.isShown,"one outside click dismisses without focusing the launcher first")
                try check(!self.isMonitoringOutsideClicks,"dismissal removes the listener immediately")
            },
            .init(delay:0.4) {
                try check(!self.window.isVisible && !self.menuTransition.panel.isVisible,"exit animation removes launcher and menu cover")
                try check(otherWindow.isKeyWindow,"dismissal preserves the newly selected window's focus")
                self.handleExternalMouseDown(event(at:outsidePoint()))
                try check(!self.isShown,"late clicks cannot reopen the launcher")
                otherWindow.orderOut(nil)
                self.show()
            },
            .init(delay:0.5) {
                try check(self.isShown && self.isMonitoringOutsideClicks,"reopening installs a fresh listener")
                self.handleExternalMouseDown(event(.rightMouseDown,at:outsidePoint()))
                try check(!self.isShown && !self.isMonitoringOutsideClicks,"right-click outside also dismisses")
                self.show()
            },
            .init(delay:0.5) {
                try check(self.isShown && self.window.isVisible && self.isMonitoringOutsideClicks,"rapid reopen survives the old closing animation")
                NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
                try check(!self.isShown && !self.isMonitoringOutsideClicks && !self.window.isVisible,"Space changes remove monitoring with the presentation")
                self.showSettings()
                self.show()
            },
            .init(delay:0.5) {
                let settings = NSApp.windows.first { $0.title == L10n.text("Launchpod Settings", "Launchpod 설정") }
                try check(settings?.isVisible == true && self.isShown,"hot corner can open the launcher while settings remain visible")
                self.handleExternalMouseDown(event(at:outsidePoint()))
                try check(!self.isShown && settings?.isVisible == true,"visible settings do not block an external click from dismissing the launcher")
                settings?.orderOut(nil)
                self.show()
            },
            .init(delay:0.5) {
                try check(self.isMonitoringOutsideClicks,"monitor is active before termination")
                self.prepareForTermination()
                try check(!self.isMonitoringOutsideClicks && !self.window.isVisible,"termination removes monitoring")
                let report = "PASS: \(checks) outside click checks\nIncludes a visible launcher without key focus, one-click dismissal, focus retention, reopen and teardown.\nNo mouse events posted to other applications.\n"
                try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
                print(report)
            }
        ]
        InteractionCheckSequence(steps) { result in
            self.window.delegate = self
            otherWindow.orderOut(nil)
            self.prepareForTermination()
            completion(result)
        }.run()
    }
}
