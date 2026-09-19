import AppKit
import LaunchpodCore

extension LauncherController {
    func runStartupRenderingChecks(outputDirectory: URL, completion: @escaping (Result<Void,Error>) -> Void) {
        var checks = 0
        var firstVisibleReady: Bool?
        var preparationWasVisible = false
        var timer: Timer?
        let start = ProcessInfo.processInfo.systemUptime
        var firstVisibleMilliseconds = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LayoutError.invalid("Startup rendering check failed: "+message) }
            checks += 1
        }
        let steps: [InteractionCheckStep] = [
            .init {
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                self.icons.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval:1.0/120,repeats:true) { _ in
                    if self.isPreparingToShow && self.window.isVisible { preparationWasVisible = true }
                    if self.window.isVisible && firstVisibleReady == nil {
                        firstVisibleReady = self.launcherView.initialIconRecords.allSatisfy { self.icons.cachedImage(for:$0) != nil }
                        firstVisibleMilliseconds = Int((ProcessInfo.processInfo.systemUptime-start)*1000)
                    }
                }
                RunLoop.main.add(timer!,forMode:.common)
                self.show()
                try check(self.isShown,"show request is toggleable during preparation")
            },
            .init(delay:0.9) {
                timer?.invalidate()
                try check(!preparationWasVisible,"hidden preparation never exposes an unfinished window")
                try check(firstVisibleReady == true,"all first-page and folder preview icons are ready on the first visible sample")
                try check(self.window.isVisible && !self.isPreparingToShow,"prepared window is presented")
                guard let screen = self.window.screen, let snapshot = self.wallpapers.snapshot(for:screen) else {
                    throw LayoutError.invalid("Startup check has no wallpaper")
                }
                try check(!WallpaperRenderer.isUniform(snapshot.original),"photographic desktop has actual image content")
                if let bitmap = self.launcherView.bitmapImageRepForCachingDisplay(in:self.launcherView.bounds) {
                    self.launcherView.cacheDisplay(in:self.launcherView.bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])?.write(to:outputDirectory.appendingPathComponent("launcher.png"))
                }
                self.dismiss(restoreFocus:false)
            },
            .init(delay:0.4) {
                self.icons.invalidate()
                self.show()
                try check(self.isPreparingToShow,"cold reopen enters icon preparation")
                self.dismiss(restoreFocus:false)
                try check(!self.isShown && !self.isPreparingToShow && !self.window.isVisible,"toggle cancels a hidden pending presentation")
            },
            .init(delay:0.5) {
                try check(!self.window.isVisible && !self.menuTransition.panel.isVisible,"late icon completion cannot reopen a dismissed launcher")
                self.show()
            },
            .init(delay:0.7) {
                try check(self.window.isVisible && self.isShown,"reopen works after cancelling preparation")
                let report = "PASS: \(checks) startup rendering checks\nFirst visible sample: \(firstVisibleMilliseconds) ms; icons ready: \(firstVisibleReady == true)\n"
                print(report)
                try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
            }
        ]
        InteractionCheckSequence(steps) { result in
            timer?.invalidate(); self.prepareForTermination(); completion(result)
        }.run()
    }
}
