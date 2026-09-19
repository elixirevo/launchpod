import AppKit

var checks = 0
func check(_ value: Bool, _ message: String) {
    guard value else { fputs("Wallpaper check failed: \(message)\n",stderr); exit(1) }
    checks += 1
}
func image(_ width: Int, _ height: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx); return ctx.makeImage()!
}
func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
    bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
}
let screen = CGRect(x:-1920,y:120,width:1920,height:1080)
func window(_ id: UInt32, _ level: Int32, _ frame: CGRect, visible: Bool = true, alpha: Double = 1) -> [String:Any] {
    [kCGWindowNumber as String:NSNumber(value:id),kCGWindowLayer as String:NSNumber(value:level),
     kCGWindowBounds as String:frame.dictionaryRepresentation,kCGWindowIsOnscreen as String:NSNumber(value:visible),
     kCGWindowAlpha as String:NSNumber(value:alpha)]
}
let level = CGWindowLevelForKey(.desktopWindow)-1
let candidates = [window(1,0,screen),window(2,CGWindowLevelForKey(.desktopIconWindow),screen),
    window(3,level,screen),window(4,level,CGRect(x:0,y:0,width:1920,height:1080)),
    window(5,level,screen,visible:false),window(6,level,screen,alpha:0.2),
    window(7,level,CGRect(x:-1920,y:120,width:100,height:100))]
check(WallpaperRenderer.desktopWindows(in:candidates,covering:screen) == [3],"selects only the current screen's desktop picture, excluding apps and Finder icons")
check(WallpaperRenderer.desktopWindows(in:candidates,covering:.zero).isEmpty,"rejects an empty screen")
check(WallpaperRenderer.desktopWindows(in:[[kCGWindowLayer as String:level]],covering:screen).isEmpty,"rejects incomplete window metadata")
var provider = window(8,level-1,screen)
provider[kCGWindowOwnerPID as String] = NSNumber(value:42)
var unrelated = window(9,level-1,screen)
unrelated[kCGWindowOwnerPID as String] = NSNumber(value:43)
check(WallpaperRenderer.desktopWindows(in:candidates+[unrelated,provider],covering:screen,providerPIDs:[42]) == [8,3],
      "macOS WallpaperAgent frame precedes the WindowManager placeholder")
check(WallpaperRenderer.desktopWindows(in:[provider,unrelated],covering:screen).isEmpty,"lower-level windows require a verified WallpaperAgent owner")
var otherDisplay = provider
otherDisplay[kCGWindowBounds as String] = CGRect(x:0,y:0,width:1920,height:1080).dictionaryRepresentation
check(WallpaperRenderer.desktopWindows(in:[otherDisplay],covering:screen,providerPIDs:[42]).isEmpty,"never borrows another display's provider frame")
var hiddenProvider = provider
hiddenProvider[kCGWindowIsOnscreen as String] = false
check(WallpaperRenderer.desktopWindows(in:[hiddenProvider],covering:screen,providerPIDs:[42]).isEmpty,"hidden Space provider frames are excluded")
let assetID = "9680B8EB-CE2A-4395-AF41-402801F4D6A6"
func aerialSelection(_ id: String, provider: String = "com.apple.wallpaper.choice.aerials") -> [String:Any] {
    let data = try! PropertyListSerialization.data(fromPropertyList:["assetID":id],format:.binary,options:0)
    return ["Type":"linked","Linked":["Content":["Choices":[["Provider":provider,"Configuration":data]],"Shuffle":"$null"]]]
}
let selection = aerialSelection(assetID)
var store: [String:Any] = ["Spaces":[String:Any](),"Displays":[String:Any](),"AllSpacesAndDisplays":selection]
check(WallpaperRenderer.aerialAsset(in:store,displayUUID:"display-a") == assetID,"resolves the configured aerial shared by all displays")
let secondID = "44166C39-8566-4ECA-BD16-43159429B52F"
store["Displays"] = ["display-a":aerialSelection(secondID)]
check(WallpaperRenderer.aerialAsset(in:store,displayUUID:"display-a") == secondID,"display override takes priority over shared selection")
check(WallpaperRenderer.aerialAsset(in:store,displayUUID:"display-b") == assetID,"other displays retain the shared selection")
store["Displays"] = ["display-a":aerialSelection(assetID,provider:"com.apple.wallpaper.choice.image")]
check(WallpaperRenderer.aerialAsset(in:store,displayUUID:"display-a") == nil,"non-aerial override cannot inherit the shared aerial")
store["Spaces"] = ["space-a":selection]
check(WallpaperRenderer.aerialAsset(in:store,displayUUID:"display-b") == nil,"ambiguous Space configuration is not guessed")
store["Spaces"] = [String:Any]()
store["AllSpacesAndDisplays"] = aerialSelection("../../other-file")
check(WallpaperRenderer.aerialAsset(in:store,displayUUID:"display-b") == nil,"asset identifiers cannot escape the aerial directory")
check(WallpaperRenderer.aerialAsset(in:[:],displayUUID:"display-a") == nil,"unknown wallpaper store schema falls back safely")
store["AllSpacesAndDisplays"] = ["Linked":["Content":["Choices":[["Provider":"com.apple.wallpaper.choice.aerials",
    "Configuration":try! PropertyListSerialization.data(fromPropertyList:["assetID":assetID],format:.binary,options:0)]],
    "Shuffle":["Enabled":true]]]]
check(WallpaperRenderer.aerialAsset(in:store,displayUUID:"display-b") == nil,"shuffle state does not imply the currently displayed aerial")
let display = NSSize(width:800,height:600), portrait = NSSize(width:200,height:400)
check(WallpaperRenderer.pictureRect(image:portrait,screen:display,options:[:]) == CGRect(x:250,y:0,width:300,height:600),"fit preserves image proportions")
check(WallpaperRenderer.pictureRect(image:portrait,screen:display,options:[.allowClipping:true]) == CGRect(x:0,y:-500,width:800,height:1600),"fill crops around the center")
check(WallpaperRenderer.pictureRect(image:portrait,screen:display,options:[.imageScaling:NSImageScaling.scaleAxesIndependently.rawValue]) == CGRect(origin:.zero,size:display),"stretch follows desktop preference")
check(WallpaperRenderer.pictureRect(image:portrait,screen:display,options:[.imageScaling:NSImageScaling.scaleNone.rawValue]) == CGRect(x:300,y:100,width:200,height:400),"center preserves natural size")
check(WallpaperRenderer.pictureRect(image:.zero,screen:display,options:[:]) == .zero,"invalid image sizes are rejected")
let renderer = WallpaperRenderer()
var hardwareIDs: [CGWindowID] = []
let hardwareImage = image(200,100) { ctx in
    ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x:0,y:0,width:100,height:100))
    ctx.setFillColor(NSColor.blue.cgColor); ctx.fill(CGRect(x:100,y:0,width:100,height:100))
}
let hardware = WallpaperRenderer(captureHardware:{ id in hardwareIDs.append(id); return hardwareImage })
var systemWindow = window(20,level,screen)
systemWindow[kCGWindowOwnerPID as String] = 55
check(hardware.hardwareSnapshot(windows:[systemWindow],bounds:screen,screenSize:screen.size,managerPIDs:[]) == nil && hardwareIDs.isEmpty,
      "hardware capture never receives an unverified owner's window")
check(hardware.hardwareSnapshot(windows:[systemWindow],bounds:screen,screenSize:screen.size,managerPIDs:[55])?.source == "desktop hardware window 20",
      "verified desktop window uses the hardware path")
let absentHardware = WallpaperRenderer(captureHardware:{ _ in nil })
check(absentHardware.hardwareSnapshot(windows:[systemWindow],bounds:screen,screenSize:screen.size,managerPIDs:[55]) == nil,
      "missing hardware symbol or failed capture leaves fallback available")
let crop = WallpaperRenderer.crop(hardwareImage,window:CGRect(x:-200,y:-100,width:200,height:100),screen:CGRect(x:-100,y:-100,width:100,height:100))!
let croppedColor = color(NSBitmapImageRep(cgImage:crop),50,50)
check(crop.width == 100 && crop.height == 100 && croppedColor.blueComponent > croppedColor.redComponent,
      "hardware frame is cropped to the selected display using global window coordinates")
check(WallpaperRenderer.crop(hardwareImage,window:.zero,screen:screen) == nil,"invalid hardware geometry falls back safely")
let stripes = image(400,300) { ctx in
    for x in stride(from:0,to:400,by:4) {
        ctx.setFillColor((x%8 == 0 ? NSColor.white : NSColor.black).cgColor)
        ctx.fill(CGRect(x:x,y:0,width:4,height:300))
    }
}
let placeholder = image(100,100) { ctx in ctx.setFillColor(NSColor.darkGray.cgColor); ctx.fill(CGRect(x:0,y:0,width:100,height:100)) }
check(WallpaperRenderer.isUniform(placeholder),"detects a solid WindowManager placeholder")
let gradient = image(100,100) { ctx in
    for x in 0..<100 { ctx.setFillColor(NSColor(white:CGFloat(x)/100,alpha:1).cgColor); ctx.fill(CGRect(x:x,y:0,width:1,height:100)) }
}
check(!WallpaperRenderer.isUniform(gradient),"preserves real gradient wallpaper content")
let result = renderer.render(stripes,screenSize:NSSize(width:400,height:300),options:[:],source:"fixture")!
var rect = CGRect(origin:.zero,size:result.image.size)
let bitmap = NSBitmapImageRep(cgImage:result.image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!)
check(result.screenSize == NSSize(width:400,height:300) && bitmap.pixelsWide == 400 && bitmap.pixelsHigh == 300,"render has the desktop's aspect and size")
check(abs(color(bitmap,160,150).redComponent-color(bitmap,164,150).redComponent) < 0.03,"blur removes high-frequency stripe contrast")
check(color(bitmap,0,0).alphaComponent > 0.99 && color(bitmap,399,299).alphaComponent > 0.99,"clamped edges remain opaque without dark transparent seams")
check(color(bitmap,200,150).redComponent > 0.1 && color(bitmap,200,150).redComponent < 0.85,"original color matrix keeps the blurred background visible and subdued")
let large = renderer.render(stripes,screenSize:NSSize(width:3840,height:2160),options:[:],source:"large")!
rect = CGRect(origin:.zero,size:large.image.size)
let largeCG = large.image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!
check(largeCG.width == 2048 && largeCG.height == 1152,"large desktop rendering stays bounded")
check(large.image.size == NSSize(width:3840,height:2160),"bounded bitmap retains logical screen dimensions")
check(renderer.render(stripes,screenSize:.zero,options:[:],source:"invalid") == nil,"zero screen cannot allocate a render")
check(renderer.fileSnapshot(URL(fileURLWithPath:"/nonexistent/launchpod-wallpaper.heic"),screenSize:display,options:[:]) == nil,"missing wallpaper has a recoverable fallback")
let red = image(20,40) { ctx in ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x:0,y:0,width:20,height:40)) }
let fit = renderer.render(red,screenSize:display,options:[.fillColor:NSColor.blue],source:"fit")!
rect = CGRect(origin:.zero,size:fit.image.size)
let fitBitmap = NSBitmapImageRep(cgImage:fit.image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!)
check(color(fitBitmap,30,300).blueComponent > color(fitBitmap,30,300).redComponent,"fit uses desktop fill color in side margins")
check(color(fitBitmap,400,300).redComponent > color(fitBitmap,400,300).blueComponent,"fit keeps the image centered")
for (input,expected) in [(CGFloat(0),WallpaperRenderer.colorBias),(CGFloat(1),WallpaperRenderer.colorGain+WallpaperRenderer.colorBias)] {
    let solid = image(100,100) { ctx in ctx.setFillColor(NSColor(white:input,alpha:1).cgColor); ctx.fill(CGRect(x:0,y:0,width:100,height:100)) }
    let result = renderer.render(solid,screenSize:NSSize(width:100,height:100),options:[:],source:"color-space")!
    rect = CGRect(origin:.zero,size:result.image.size)
    let pixels = NSBitmapImageRep(cgImage:result.image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!)
    // colorAt returns NSCalibratedRGBColorSpace; converting that NSColor again
    // would apply another profile transform to already encoded sRGB samples.
    var components = [Int](repeating:0,count:pixels.samplesPerPixel)
    pixels.getPixel(&components,atX:50,y:50)
    let value = CGFloat(components[0])/255
    check(abs(value-expected) < 0.015,"matrix applies display-space coefficients (input=\(input), actual=\(value), expected=\(expected))")
}
if CommandLine.arguments.contains("--desktop") {
    let app = NSApplication.shared
    check(!NSScreen.screens.isEmpty,"desktop check has a GUI screen")
    for screen in NSScreen.screens {
        let start = ProcessInfo.processInfo.systemUptime
        guard let snapshot = renderer.snapshot(for:screen,refresh:true) else { check(false,"current wallpaper is available"); exit(1) }
        check(snapshot.image.size == screen.frame.size,"live wallpaper matches the selected screen")
        if CommandLine.arguments.contains("--expect-picture") {
            check(!WallpaperRenderer.isUniform(snapshot.original),"configured photographic wallpaper must not resolve to a flat placeholder")
        }
        if CommandLine.arguments.contains("--expect-hardware") {
            check(snapshot.source.hasPrefix("desktop hardware window"),"current desktop comes from hardware capture, not a static file fallback")
        }
        check(renderer.snapshot(for:screen)?.image === snapshot.image,"menu and launcher reuse exactly one processed snapshot")
        let renewed = renderer.snapshot(for:screen,refresh:true)
        check(renewed?.image !== snapshot.image,"reopening refreshes the desktop instead of reusing a stale dynamic frame")
        print("Desktop: \(snapshot.source), \(screen.frame.size), two renders \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms")
        if let url = NSWorkspace.shared.desktopImageURL(for:screen) {
            let file = renderer.fileSnapshot(url,screenSize:screen.frame.size,options:NSWorkspace.shared.desktopImageOptions(for:screen) ?? [:])
            check(file != nil,"configured HEIC or image file decodes through the fallback path")
            check(file.map { max($0.original.width,$0.original.height) <= Int(WallpaperRenderer.maximumDimension) } == true,
                  "file fallback decodes one bounded image")
        }
    }
    _ = app
}
print("PASS: \(checks) wallpaper checks")
