import AppKit
import QuartzCore
class FlippedView: NSView { override var isFlipped: Bool { true } }
class ProbeWindow: NSWindow { override var canBecomeKey: Bool { true } }
// Diagnostic only: compare the old ordering with the corrected ordering.
// Both and fixed run the same animation/presentation options; only the handoff order differs.
guard CommandLine.arguments.count == 3,
      ["both", "fixed", "system", "overlay"].contains(CommandLine.arguments[1]) else {
    fputs("Usage: menu-handoff-probe both|fixed|system|overlay OUTPUT_DIRECTORY\n", stderr)
    exit(2)
}
let mode = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!
let window = ProbeWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
window.backgroundColor = NSColor(white:0.5,alpha:1)
window.level = .floating; window.animationBehavior = .none
window.isReleasedWhenClosed = false
let transition = MenuBarTransition()
let previous = app.presentationOptions
app.activate(ignoringOtherApps:true)
window.makeKeyAndOrderFront(nil)
var samples = [[String:Any]]()
var timer: Timer?
var index = 0
var phase = "entry"
DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
    app.activate(ignoringOtherApps:true)
    if mode == "overlay" || mode == "both" || mode == "fixed" { transition.prepare(screen:screen,image:nil,opacity:0); transition.animate(covering:true,duration:0.32) }
    timer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { _ in
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],0) as? [[String:Any]] ?? []
        samples.append(["frame":index,"phase":phase,"panelFrame":NSStringFromRect(transition.panel.frame),"options":app.presentationOptions.rawValue,"systemOptions":app.currentSystemPresentationOptions.rawValue,"windows":windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier || ["Dock","Window Server"].contains($0[kCGWindowOwnerName as String] as? String ?? "") }])
        if [21,23,25,65,67,69].contains(index), let image = CGWindowListCreateImage(CGRect(x:0,y:screen.frame.height-360,width:screen.frame.width,height:300),[.optionOnScreenOnly],0,[]) {
            let bitmap = NSBitmapImageRep(cgImage:image)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("\(mode)-\(index).png"))
        }
        index += 1
        if index == 110 {
            timer?.invalidate(); transition.hide(); app.presentationOptions = previous
            let data = try! JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys])
            try! data.write(to:output.appendingPathComponent(mode+".json"))
            print("\(mode): \(samples.count) samples, screen \(screen.frame)")
            window.orderOut(nil); exit(0)
        }
    }
    DispatchQueue.main.asyncAfter(deadline:.now()+0.32) {
        if mode == "system" || mode == "both" || mode == "fixed" {
            NSAnimationContext.beginGrouping(); NSAnimationContext.current.duration = 0; NSAnimationContext.current.allowsImplicitAnimation = false
            if mode == "fixed" { transition.hide() }
            app.presentationOptions = [.autoHideMenuBar]
            NSAnimationContext.endGrouping()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { transition.hide() }
    }
    DispatchQueue.main.asyncAfter(deadline:.now()+1.0) {
        phase = "exit"
        NSAnimationContext.beginGrouping(); NSAnimationContext.current.duration = 0; NSAnimationContext.current.allowsImplicitAnimation = false
        if mode == "fixed" { app.presentationOptions = previous }
        if mode == "both" || mode == "fixed" { transition.prepare(screen:screen,image:nil,opacity:1) }
        if mode == "both" || mode == "system" { app.presentationOptions = previous }
        transition.animate(covering:false,duration:0.28)
        NSAnimationContext.endGrouping()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.28) { transition.hide() }
    }
}
app.run()
