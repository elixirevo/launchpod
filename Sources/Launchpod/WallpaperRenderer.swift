import AppKit
import CoreImage
import ImageIO
import AVFoundation
import Darwin

/// A snapshot of the current desktop picture, never the windows above it.
/// Keep the processed screen-sized image shared by the launcher and menu cover.
final class WallpaperRenderer {
    struct Snapshot {
        let image: NSImage
        let original: CGImage
        let source: String
        let screenSize: NSSize
    }
    // Springboard.init: Gaussian radius 30, saturation 1.8, then a color matrix.
    // Radius is in desktop points, independent of thumbnail size / Retina scale.
    static let blurRadius: CGFloat = 30
    static let saturation: CGFloat = 1.8
    static let colorGain: CGFloat = 0.55
    static let colorBias: CGFloat = 0.05292
    static let maximumDimension: CGFloat = 2048
    // Apply the original display-color coefficients in sRGB, not Core Image's
    // default linear-light space (which would turn the 0.05292 bias into gray).
    private lazy var context = CIContext(options: [.cacheIntermediates:false,
        .workingColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,
        .outputColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!])
    private var snapshots: [UInt32:Snapshot] = [:]
    private let captureHardware: (CGWindowID) -> CGImage?
    init(captureHardware: @escaping (CGWindowID) -> CGImage? = WallpaperRenderer.hardwareImage) {
        self.captureHardware = captureHardware
    }

    // Optional compatibility adapter observed in LaunchOS 2.3.0. Resolve at
    // runtime so removal of a private symbol cannot prevent app startup.
    // The caller only supplies a verified system wallpaper window ID.
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Capture = @convention(c) (UInt32,UnsafePointer<UInt32>,UInt32,UInt32) -> Unmanaged<CFArray>?
    private static let connection: Connection? = dlsym(UnsafeMutableRawPointer(bitPattern:-2),"CGSMainConnectionID").map { unsafeBitCast($0,to:Connection.self) }
    private static let capture: Capture? = dlsym(UnsafeMutableRawPointer(bitPattern:-2),"CGSHWCaptureWindowList").map { unsafeBitCast($0,to:Capture.self) }
    static func hardwareImage(_ window: CGWindowID) -> CGImage? {
        guard #available(macOS 26.0,*), let connection = connection, let capture = capture else { return nil }
        var id = window
        let images = capture(connection(),&id,1,0x80a00)?.takeRetainedValue() as? [CGImage]
        return images?.first
    }

    func snapshot(for screen: NSScreen, refresh: Bool = false) -> Snapshot? {
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        if !refresh, let saved = snapshots[display], saved.screenSize == screen.frame.size { return saved }
        let bounds = CGDisplayBounds(display)
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        // The legacy capture API can return gray for a WindowManager wallpaper
        // whose hardware capture still contains the actual current frame.
        let providerPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.wallpaper.agent").map(\.processIdentifier))
        let managerPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.WindowManager").map(\.processIdentifier))
        var next = hardwareSnapshot(windows:windows,bounds:bounds,screenSize:screen.frame.size,managerPIDs:managerPIDs)
        var placeholder: Snapshot?
        for id in Self.desktopWindows(in:windows,covering:bounds,providerPIDs:providerPIDs) {
            if next != nil { break }
            // Apple's WWDC19 session 701 identifies the desktop-picture level
            // explicitly. Including just this ID excludes Finder icons, Dock,
            // menu bar, other apps, and our already visible launcher window.
            if let image = CGWindowListCreateImage(bounds,.optionIncludingWindow,id,[.boundsIgnoreFraming,.nominalResolution]) {
                let rendered = render(image,screenSize:screen.frame.size,options:[.imageScaling:NSImageScaling.scaleAxesIndependently.rawValue],
                              source:"desktop window \(id)")
                let owner = windows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }?[kCGWindowOwnerName as String] as? String
                if owner == "WindowManager", Self.isUniform(image) {
                    // A solid-color wallpaper remains valid if there is no
                    // positively identified replacement for this display.
                    placeholder = rendered
                    continue
                }
                next = rendered
                if next != nil { break }
            }
        }
        if next == nil { next = aerialSnapshot(display:display,screenSize:screen.frame.size) }
        if next == nil { next = placeholder }
        if next == nil, let url = NSWorkspace.shared.desktopImageURL(for:screen) {
            next = fileSnapshot(url,screenSize:screen.frame.size,options:NSWorkspace.shared.desktopImageOptions(for:screen) ?? [:])
        }
        if let next = next {
            if snapshots.count > 8 { snapshots.removeAll() }
            snapshots[display] = next
        }
        // A temporary unavailable desktop during Space switching must not flash
        // a flat fill. Reuse only this display's previously rendered picture.
        return next ?? snapshots[display]
    }

    func hardwareSnapshot(windows: [[String:Any]], bounds: CGRect, screenSize: NSSize, managerPIDs: Set<pid_t>) -> Snapshot? {
        let candidates = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber).map { managerPIDs.contains($0.int32Value) } == true
        }
        for id in Self.desktopWindows(in:candidates,covering:bounds) {
            guard let entry = candidates.first(where:{ ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
                  let raw = entry[kCGWindowBounds as String] as? [String:Any],
                  let frame = CGRect(dictionaryRepresentation:raw as CFDictionary),
                  let image = captureHardware(id),
                  let cropped = Self.crop(image,window:frame,screen:bounds),
                  let rendered = render(cropped,screenSize:screenSize,options:[.imageScaling:NSImageScaling.scaleAxesIndependently.rawValue],
                                        source:"desktop hardware window \(id)") else { continue }
            // Solid colors are valid here: do not mistake an intentional
            // single-color desktop for the legacy API's gray response.
            return rendered
        }
        return nil
    }
    static func crop(_ image: CGImage, window: CGRect, screen: CGRect) -> CGImage? {
        guard window.width > 0, window.height > 0, screen.width > 0, screen.height > 0,
              window.contains(screen) else { return nil }
        let x = CGFloat(image.width)/window.width, y = CGFloat(image.height)/window.height
        return image.cropping(to:CGRect(x:(screen.minX-window.minX)*x,y:(screen.minY-window.minY)*y,
                                       width:screen.width*x,height:screen.height*y).integral)
    }

    static func desktopWindows(in windows: [[String:Any]], covering screen: CGRect, providerPIDs: Set<pid_t> = []) -> [CGWindowID] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        let pictureLevel = CGWindowLevelForKey(.desktopWindow)-1
        let candidates: [(CGWindowID,Bool)] = windows.compactMap { item in
            let level = (item[kCGWindowLayer as String] as? NSNumber)?.int32Value
            let provider = level == pictureLevel-1 && (item[kCGWindowOwnerPID as String] as? NSNumber).map { providerPIDs.contains($0.int32Value) } == true
            guard level == pictureLevel || provider,
                  (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0.99,
                  let raw = item[kCGWindowBounds as String] as? [String:Any],
                  let bounds = CGRect(dictionaryRepresentation:raw as CFDictionary),
                  bounds.insetBy(dx:-1,dy:-1).contains(screen),
                  let id = item[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (id.uint32Value,provider)
        }
        return candidates.filter { $0.1 }.map { $0.0 } + candidates.filter { !$0.1 }.map { $0.0 }
    }

    static func isUniform(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating:0,count:16*16*4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data:bytes.baseAddress,width:16,height:16,bitsPerComponent:8,bytesPerRow:64,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image,in:CGRect(x:0,y:0,width:16,height:16))
            let samples = bytes.bindMemory(to:UInt8.self)
            return (0..<4).allSatisfy { channel in
                let values = stride(from:channel,to:samples.count,by:4).map { Int(samples[$0]) }
                return values.max()! - values.min()! <= 1
            }
        }
    }

    // Optional compatibility fallback, not an authoritative macOS API. Read
    // only a recognized, unambiguous aerial selection; never guess a Space or
    // take another display's wallpaper when the store schema changes.
    static func aerialAsset(in store: [String:Any], displayUUID: String) -> String? {
        guard let spaces = store["Spaces"] as? [String:Any], spaces.isEmpty,
              let displays = store["Displays"] as? [String:Any] else { return nil }
        let selection: [String:Any]?
        if let override = displays[displayUUID] { selection = override as? [String:Any] }
        else { selection = store["AllSpacesAndDisplays"] as? [String:Any] }
        guard let selection = selection,
              let desktop = (selection["Desktop"] ?? selection["Linked"]) as? [String:Any],
              let content = desktop["Content"] as? [String:Any],
              content["Shuffle"] == nil || content["Shuffle"] as? String == "$null",
              let choices = content["Choices"] as? [[String:Any]], choices.count == 1,
              choices[0]["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configuration = choices[0]["Configuration"] as? Data,
              let value = (try? PropertyListSerialization.propertyList(from:configuration,format:nil)) as? [String:Any],
              let rawID = value["assetID"] as? String, let id = UUID(uuidString:rawID) else { return nil }
        return id.uuidString
    }

    private func aerialSnapshot(display: CGDirectDisplayID, screenSize: NSSize) -> Snapshot? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let data = try? Data(contentsOf:root.appendingPathComponent("Store/Index.plist")),
              let store = (try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any],
              let asset = Self.aerialAsset(in:store,displayUUID:CFUUIDCreateString(nil,uuid) as String) else { return nil }
        let options: [NSWorkspace.DesktopImageOptionKey:Any] = [.allowClipping:true]
        let video = root.appendingPathComponent("aerials/videos/\(asset).mov")
        if FileManager.default.fileExists(atPath:video.path) {
            let generator = AVAssetImageGenerator(asset:AVURLAsset(url:video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = NSSize(width:Self.maximumDimension,height:Self.maximumDimension)
            if let image = try? generator.copyCGImage(at:.zero,actualTime:nil) {
                return render(image,screenSize:screenSize,options:options,source:"selected aerial (still frame)")
            }
        }
        return fileSnapshot(root.appendingPathComponent("aerials/thumbnails/\(asset).png"),screenSize:screenSize,
                            options:options,source:"selected aerial (thumbnail)")
    }

    func fileSnapshot(_ url: URL, screenSize: NSSize, options: [NSWorkspace.DesktopImageOptionKey:Any], source description: String = "desktop file (primary frame)") -> Snapshot? {
        // Decode a single bounded frame. Never expand an entire dynamic HEIC.
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source,CGImageSourceGetPrimaryImageIndex(source),[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:Int(Self.maximumDimension)
              ] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source,CGImageSourceGetPrimaryImageIndex(source),nil) as? [CFString:Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(image.width)
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(image.height)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let naturalSize = (5...8).contains(orientation) ? NSSize(width:height,height:width) : NSSize(width:width,height:height)
        return render(image,screenSize:screenSize,options:options,source:description,naturalSize:naturalSize)
    }

    static func pictureRect(image: NSSize, screen: NSSize, options: [NSWorkspace.DesktopImageOptionKey:Any]) -> CGRect {
        guard image.width > 0, image.height > 0, screen.width > 0, screen.height > 0 else { return .zero }
        let mode = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue:$0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clip = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        let size: NSSize
        switch mode {
        case .scaleAxesIndependently: size = screen
        case .scaleNone: size = image
        default:
            let x = screen.width/image.width, y = screen.height/image.height
            let scale = clip ? max(x,y) : min(x,y)
            size = NSSize(width:image.width*scale,height:image.height*scale)
        }
        return CGRect(x:(screen.width-size.width)/2,y:(screen.height-size.height)/2,width:size.width,height:size.height)
    }

    func render(_ image: CGImage, screenSize: NSSize, options: [NSWorkspace.DesktopImageOptionKey:Any], source: String, naturalSize: NSSize? = nil) -> Snapshot? {
        guard screenSize.width > 0, screenSize.height > 0 else { return nil }
        let scale = min(1,Self.maximumDimension/max(screenSize.width,screenSize.height))
        let canvas = CGRect(x:0,y:0,width:max(1,(screenSize.width*scale).rounded()),height:max(1,(screenSize.height*scale).rounded()))
        let rect = Self.pictureRect(image:naturalSize ?? NSSize(width:image.width,height:image.height),screen:screenSize,options:options)
            .applying(CGAffineTransform(scaleX:scale,y:scale))
        let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.deviceRGB)
            ?? NSColor(deviceRed:0,green:0,blue:0,alpha:1)
        let background = CIImage(color:CIColor(red:fill.redComponent,green:fill.greenComponent,blue:fill.blueComponent,alpha:1)).cropped(to:canvas)
        let picture = CIImage(cgImage:image).transformed(by:CGAffineTransform(scaleX:rect.width/CGFloat(image.width),y:rect.height/CGFloat(image.height)))
            .transformed(by:CGAffineTransform(translationX:rect.minX,y:rect.minY))
            .composited(over:background).cropped(to:canvas)
        let blurred = picture.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:Self.blurRadius*scale])
            .cropped(to:canvas).applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:Self.saturation])
            .applyingFilter("CIColorMatrix",parameters:[
                "inputRVector":CIVector(x:Self.colorGain,y:0,z:0,w:0),
                "inputGVector":CIVector(x:0,y:Self.colorGain,z:0,w:0),
                "inputBVector":CIVector(x:0,y:0,z:Self.colorGain,w:0),
                "inputAVector":CIVector(x:0,y:0,z:0,w:1),
                "inputBiasVector":CIVector(x:Self.colorBias,y:Self.colorBias,z:Self.colorBias,w:0)])
        guard let output = context.createCGImage(blurred,from:canvas) else { return nil }
        return Snapshot(image:NSImage(cgImage:output,size:screenSize),original:image,source:source,screenSize:screenSize)
    }
}
