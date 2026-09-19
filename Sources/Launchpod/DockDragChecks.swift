import AppKit

/// Focused checks: no catalog scan, layout writes, menu setup or other UI suites.
enum DockDragChecks {
    static func run(outputDirectory: URL) throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain:"DockDragChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            count += 1
        }
        for (value,expected): (Double?,CGFloat) in [(nil,64),(0,64),(-5,64),(.nan,64),(.infinity,64),(8,16),(32.5,32.5),(64,64),(128,128),(256,128)] {
            try check(DockDragPreview.iconSize(configured:value) == expected,"Dock size normalization: \(String(describing:value))")
        }
        let host = FlippedView(frame:NSRect(x:0,y:0,width:800,height:600))
        let artwork = NSWorkspace.shared.icon(forFile:Bundle.main.bundlePath)
        let artworkSize = artwork.size
        let fileURL = URL(fileURLWithPath:"/Applications/Example App.app")
        let tile = AppTile(content:TileContent(id:"dock-size-fixture",title:"제목이 긴 앱 이름",image:artwork,fileURL:fileURL))
        tile.frame = NSRect(x:120,y:90,width:180,height:190)
        tile.iconSize = 112; host.addSubview(tile); tile.layoutSubtreeIfNeeded()
        let original = tile.convert(tile.iconFrame,to:host)
        for size: CGFloat in [16,32.5,64,128] {
            for fraction in [NSPoint(x:0.5,y:0.5),NSPoint(x:0.1,y:0.9),NSPoint(x:0.8,y:0.2),NSPoint(x:0.4,y:1.2)] {
                let pointer = NSPoint(x:original.minX+original.width*fraction.x,y:original.minY+original.height*fraction.y)
                let item = tile.makeExternalDraggingItem(in:host,at:pointer,dockIconSize:size)
                let frame = item.draggingFrame
                try check(frame.size == NSSize(width:size,height:size),"native preview matches Dock size \(size)")
                try check(abs((pointer.x-frame.minX)/size-fraction.x) < 0.0001 && abs((pointer.y-frame.minY)/size-fraction.y) < 0.0001,
                          "resizing preserves the pointer's relative grip, including a label grab")
                let components = item.imageComponents ?? []
                try check(components.count == 1 && (components.first?.contents as? NSImage) === artwork && components.first?.frame.size == frame.size,
                          "native drag component contains only artwork at the requested size")
                try check((item.item as? NSPasteboardItem)?.string(forType:.fileURL) == fileURL.absoluteString,
                          "resizing preserves the application's file URL")
            }
        }
        let current = tile.makeExternalDraggingItem(in:host)
        try check(current.draggingFrame.width == DockDragPreview.iconSize && current.draggingFrame.height == DockDragPreview.iconSize,
                  "production default reads the current Dock size")
        try check(current.draggingFrame.midX == original.midX && current.draggingFrame.midY == original.midY,
                  "preview defaults to the original icon center")
        try check(tile.convert(tile.iconFrame,to:host) == original && tile.iconSize == 112 && artwork.size == artworkSize,
                  "Dock resizing leaves the page icon and shared image unchanged")
        // Sample the same transition used by the native session renderer.
        var transition = DockDragSizeTransition(original:112,dock:64)
        transition.setOverDock(true,at:10)
        try check(transition.size(at:10) == 112,"Dock entry starts at full page size")
        var sizes = (0...30).map { transition.size(at:10+Double($0)/120) }
        try check(zip(sizes,sizes.dropFirst()).allSatisfy { $1 <= $0 },"Dock entry shrinks monotonically")
        try check(sizes.contains { $0 > 64 && $0 < 112 } && transition.size(at:10.3) == 64,"entry has intermediate sizes and reaches Dock size")
        let item = tile.makeExternalDraggingItem(in:host,dockIconSize:112)
        for size in sizes {
            item.setDraggingFrame(DockDragPreview.frame(source:original,pointer:nil,iconSize:size),contents:artwork)
            // imageComponents caches its first inspection. The drag manager
            // calls the current provider when the session replaces its image.
            try check(abs((item.imageComponentsProvider?().first?.frame.width ?? -1)-size) < 0.001,
                      "animated native component provider follows each intermediate size")
        }
        transition.setOverDock(false,at:11)
        sizes = (0...30).map { transition.size(at:11+Double($0)/120) }
        try check(sizes.first == 64 && sizes.last == 112 && zip(sizes,sizes.dropFirst()).allSatisfy { $1 >= $0 },"leaving Dock expands back to the page size")
        transition.setOverDock(true,at:12)
        let reversingSize = transition.size(at:12.08)
        transition.setOverDock(false,at:12.08)
        try check(abs(transition.size(at:12.08)-reversingSize) < 0.0001,"early exit reverses from the current displayed size")
        transition.setOverDock(true,at:12.12)
        try check(transition.size(at:12.4) == 64,"re-entering during expansion settles at Dock size")
        var reduced = DockDragSizeTransition(original:112,dock:64); reduced.duration = 0
        reduced.setOverDock(true,at:0)
        try check(reduced.size(at:0) == 64 && !reduced.isAnimating(at:0),"Reduce Motion immediately uses the new size")
        let screen = NSRect(x:-800,y:100,width:800,height:600)
        try check(DockDragRegion.edgeContains(NSPoint(x:-400,y:101),frame:screen,visibleFrame:screen,orientation:"bottom"),"hidden bottom Dock recognizes the physical edge on another screen")
        try check(!DockDragRegion.edgeContains(NSPoint(x:-400,y:150),frame:screen,visibleFrame:screen,orientation:"bottom"),"moving away from hidden Dock restores page size")
        try check(DockDragRegion.edgeContains(NSPoint(x:-799,y:400),frame:screen,visibleFrame:screen,orientation:"left"),"left Dock edge is recognized")
        try check(DockDragRegion.edgeContains(NSPoint(x:-1,y:400),frame:screen,visibleFrame:screen,orientation:"right"),"right Dock edge is recognized")
        let report = "PASS: \(count) Dock drag preview checks\nConfigured Dock preview size: \(DockDragPreview.iconSize) pt\nOnly Dock drag sizing, animated entry/exit/reversal, pointer anchoring, artwork-only contents and file URL were tested.\n"
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        print(report)
    }
}
