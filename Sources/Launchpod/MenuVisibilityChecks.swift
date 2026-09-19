import AppKit
import QuartzCore
import LaunchpodCore

extension LauncherController {
    /// Integration checks against the real menu-cover window in an isolated store.
    func runMenuVisibilityChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        var checks = 0, samples = 0
        var requireCover = false
        var invalidSample: String?
        var timer: Timer?
        let originalOptions = NSApp.presentationOptions
        let savedLayout = try? Data(contentsOf:store.fileURL)
        let wait = max(Motion.enterDuration,Motion.exitDuration)+0.2+0.35
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LayoutError.invalid("Menu visibility check failed: "+message) }
            checks += 1
        }
        func coverIsAtTop() -> Bool {
            let panel = menuTransition.panel
            guard let screen = window.screen,
                  let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(panel.windowNumber)) as? [[String:Any]],
                  let entry = entries.first, entry[kCGWindowIsOnscreen as String] as? Bool == true,
                  let dictionary = entry[kCGWindowBounds as String] as? [String:Any],
                  let frame = CGRect(dictionaryRepresentation:dictionary as CFDictionary) else { return false }
            let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)-screen.frame.maxY
            return abs(frame.minY-top) < 1 && abs(frame.minX-screen.frame.minX) < 1
                && abs(frame.width-screen.frame.width) < 1 && abs(frame.height-panel.frame.height) < 1
                && (entry[kCGWindowLayer as String] as? Int ?? 0) > NSWindow.Level.mainMenu.rawValue
        }
        func checkCovered(_ phase: String) throws {
            let panel = menuTransition.panel
            try check(isShown && window.isVisible,"launcher visible: "+phase)
            try check(panel.isVisible && panel.alphaValue == 1 && menuTransition.opacity == 1,"menu stays fully covered: "+phase)
            try check(!panel.ignoresMouseEvents && !panel.canBecomeKey,"menu cover intercepts background clicks without stealing search focus: "+phase)
            try check(coverIsAtTop(),"WindowServer keeps cover above the menu at the screen top: "+phase)
            try check(NSRunningApplication.current.activationPolicy == .accessory,"Dock running tile stays disabled: "+phase)
            try check(NSApp.presentationOptions == originalOptions,"Dock/menu system presentation is unchanged: "+phase)
            try check(!window.collectionBehavior.contains(.canJoinAllSpaces)
                && !panel.collectionBehavior.contains(.canJoinAllSpaces),"launcher and cover do not follow Space transitions: "+phase)
            try check(window.collectionBehavior.contains(.moveToActiveSpace)
                && panel.collectionBehavior.contains(.moveToActiveSpace),"explicit reopen can move to the current Space: "+phase)
        }
        let steps: [InteractionCheckStep] = [
            .init {
                try check(!CommandLine.arguments.contains("--windowed"),"fullscreen check invocation")
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                timer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { _ in
                    guard requireCover else { return }
                    samples += 1
                    if !self.menuTransition.panel.isVisible || self.menuTransition.opacity < 0.999 || !coverIsAtTop() {
                        invalidSample = "sample \(samples): visible=\(self.menuTransition.panel.isVisible), opacity=\(self.menuTransition.opacity)"
                    }
                }
                RunLoop.main.add(timer!,forMode:.common)
                self.show()
            },
            .init(delay:wait) { try checkCovered("entry"); requireCover = true },
            .init(delay:1.0) {
                try checkCovered("after entry completion")
                try check(samples >= 10 && invalidSample == nil,"cover stays at the top across display samples: \(invalidSample ?? "none")")
                requireCover = false; self.dismiss(restoreFocus:false)
            },
            .init(delay:wait) {
                try check(!self.window.isVisible && !self.menuTransition.panel.isVisible,"dismiss restores the desktop menu")
                try check(NSRunningApplication.current.activationPolicy == .accessory,"Dock running tile remains disabled while dismissed")
                self.show()
            },
            .init(delay:0.05) { self.dismiss(restoreFocus:false); self.show() },
            .init(delay:wait) {
                try checkCovered("rapid reopen")
                self.showSettings()
            },
            .init(delay:wait) {
                try check(!self.menuTransition.panel.isVisible && !self.isShown,"settings restores access to the menu bar")
                guard let settings = NSApp.windows.first(where: { $0.title == L10n.text("Launchpod Settings", "Launchpod 설정") && $0.isVisible }) else {
                    throw LayoutError.invalid("Menu visibility check failed: settings window missing")
                }
                guard let reopen = settings.contentView?.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.text("Open Launchpod", "Launchpod 열기") }) else {
                    throw LayoutError.invalid("Menu visibility check failed: settings reopen button missing")
                }
                reopen.performClick(nil)
            },
            .init(delay:wait) {
                try checkCovered("return from settings")
                let panel = self.menuTransition.panel
                let point = NSPoint(x:panel.contentView!.bounds.midX,y:panel.contentView!.bounds.midY)
                for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                    let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                        windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                    if type == .leftMouseDown { panel.contentView!.mouseDown(with:event) }
                    else { panel.contentView!.mouseUp(with:event) }
                }
                try check(!self.isShown,"clicking the menu-bar background dismisses the launcher")
            },
            .init(delay:wait) {
                try check(!self.window.isVisible && !self.menuTransition.panel.isVisible,"top click finishes hiding both surfaces")
                self.show()
            },
            .init(delay:wait) {
                NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
                try check(!self.isShown && !self.window.isVisible && !self.menuTransition.panel.isVisible,"Space change hides both surfaces synchronously")
                self.show()
                NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
            },
            .init(delay:wait) {
                try check(!self.isShown && !self.window.isVisible && !self.menuTransition.panel.isVisible,"Space change cancels pending presentation")
                self.show()
            },
            .init(delay:wait) {
                self.dismiss(restoreFocus:false)
                NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
                try check(!self.window.isVisible && !self.menuTransition.panel.isVisible,"Space change cancels an outgoing fade immediately")
                self.show()
            },
            .init(delay:wait) {
                try checkCovered("reopen after Space change")
                self.prepareForTermination()
                try check(!self.menuTransition.panel.isVisible && !self.window.isVisible,"termination removes all menu covers")
                try check(NSApp.presentationOptions == originalOptions,"termination preserves original system presentation")
                try check(try Data(contentsOf:self.store.fileURL) == savedLayout,"visibility changes preserve the layout file")
            }
        ]
        InteractionCheckSequence(steps) { result in
            timer?.invalidate(); self.prepareForTermination()
            if case .success = result {
                let report = "PASS: \(checks) menu visibility checks\nCovered samples: \(samples); invalid: \(invalidSample ?? "none")\n"
                print(report)
                try? report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
            }
            completion(result)
        }.run()
    }
}
