import AppKit
import CryptoKit
import ImageIO
import LaunchpodCore

/// Main-thread coordinator. Only decoding and disk IO run on the workers.
final class IconCache {
    private struct Request {
        let token: UUID
        let operation: BlockOperation
    }
    private struct Preparation {
        var keys: Set<String>
        let completion: (Bool) -> Void
    }
    private let cache = NSCache<NSString, NSImage>()
    private let previous = NSCache<NSString, NSImage>()
    private let workers = OperationQueue()
    private var pending: [String:Request] = [:]
    private var preparations: [UUID:Preparation] = [:]
    private let directory: URL?
    private let loader: (String) -> NSImage
    private var epoch: String
    private var completedLoads = 0
    let loadingImage = NSImage(systemSymbolName:"app",accessibilityDescription:L10n.text("Loading icon", "아이콘 로딩 중")) ?? NSImage(size:NSSize(width:128,height:128))
    private let unavailableImage = NSImage(systemSymbolName:"app.dashed",accessibilityDescription:L10n.text("App not found", "앱을 찾을 수 없습니다")) ?? NSImage(size:NSSize(width:128,height:128))
    var onImageReady: ((String) -> Void)?

    static var defaultDirectory: URL {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of:"--data-dir"), args.indices.contains(index+1) {
            return URL(fileURLWithPath:args[index+1]).appendingPathComponent("IconCache")
        }
        return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Launchpod/AppIcons-v1")
    }
    init(directory: URL? = IconCache.defaultDirectory, loader: @escaping (String) -> NSImage = IconCache.loadImage) {
        self.directory = directory; self.loader = loader
        epoch = directory.flatMap { try? String(contentsOf:$0.appendingPathComponent("epoch")) } ?? "0"
        cache.countLimit = 600; cache.totalCostLimit = 64*1024*1024
        previous.countLimit = 100; previous.totalCostLimit = 24*1024*1024
        workers.name = "app.launchpod.icons"; workers.qualityOfService = .userInitiated
        workers.maxConcurrentOperationCount = 2
        if let directory = directory { workers.addOperation { Self.prune(directory) } }
    }
    private func key(for app: AppRecord) -> String {
        ["256-sRGB",epoch,ProcessInfo.processInfo.operatingSystemVersionString,
         NSApp?.effectiveAppearance.name.rawValue ?? "",UserDefaults.standard.string(forKey:"AppleIconAppearanceTheme") ?? "",
         app.path,app.available ? "yes" : "no",String(app.iconRevision?.timeIntervalSinceReferenceDate ?? 0)].joined(separator:"\n")
    }
    private func file(for key: String) -> URL? {
        let digest = SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
        return directory?.appendingPathComponent(digest+".png")
    }
    func cachedImage(for app: AppRecord) -> NSImage? {
        guard app.available, !app.path.isEmpty else { return unavailableImage }
        return cache.object(forKey:key(for:app) as NSString)
    }
    func image(for app: AppRecord, priority: Operation.QueuePriority = .normal) -> NSImage {
        guard app.available, !app.path.isEmpty else { return unavailableImage }
        let key = key(for:app)
        if let image = cache.object(forKey:key as NSString) { return image }
        if let request = pending[key] {
            if priority.rawValue > request.operation.queuePriority.rawValue { request.operation.queuePriority = priority }
        } else {
            let token = UUID(), url = file(for:key), loader = self.loader
            let operation = BlockOperation { [weak self] in
                let image = autoreleasepool { () -> NSImage in
                    if let url = url, let image = Self.read(url) { return image }
                    let image = loader(app.path)
                    if let url = url { Self.write(image,to:url) }
                    return image
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.pending[key]?.token == token else { return }
                    self.pending.removeValue(forKey:key)
                    self.cache.setObject(image,forKey:key as NSString,cost:256*256*4)
                    self.previous.setObject(image,forKey:app.path as NSString,cost:256*256*4)
                    self.onImageReady?(app.path)
                    for id in Array(self.preparations.keys) {
                        self.preparations[id]?.keys.remove(key)
                        if self.preparations[id]?.keys.isEmpty == true { self.finish(id,ready:true) }
                    }
                    self.completedLoads += 1
                    if self.completedLoads % 32 == 0, let directory = self.directory {
                        self.workers.addOperation { Self.prune(directory) }
                    }
                }
            }
            operation.queuePriority = priority
            pending[key] = Request(token:token,operation:operation)
            workers.addOperation(operation)
        }
        return previous.object(forKey:app.path as NSString) ?? loadingImage
    }
    /// Warm only what will be visible. A cached reopen completes synchronously;
    /// slow or unavailable volumes cannot indefinitely delay showing the UI.
    @discardableResult
    func prepare(_ apps: [AppRecord], timeout: TimeInterval = 0.35, completion: @escaping (Bool) -> Void) -> UUID? {
        let missing = apps.filter { cachedImage(for:$0) == nil }
        guard !missing.isEmpty else { completion(true); return nil }
        let id = UUID()
        preparations[id] = Preparation(keys:Set(missing.map { key(for:$0) }),completion:completion)
        for app in missing { _ = image(for:app,priority:.veryHigh) }
        DispatchQueue.main.asyncAfter(deadline:.now()+timeout) { [weak self] in self?.finish(id,ready:false) }
        return id
    }
    func cancelPreparation(_ id: UUID?) { if let id = id { preparations.removeValue(forKey:id) } }
    private func finish(_ id: UUID, ready: Bool) {
        let callback = preparations.removeValue(forKey:id)?.completion
        callback?(ready)
    }
    func invalidate() {
        cache.removeAllObjects(); pending.removeAll(); workers.cancelAllOperations()
        // Old workers may still finish writing. An epoch makes those files
        // unreachable even after a process restart or appearance change.
        epoch = UUID().uuidString
        if let directory = directory {
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try? epoch.write(to:directory.appendingPathComponent("epoch"),atomically:true,encoding:.utf8)
        }
        for id in Array(preparations.keys) { finish(id,ready:false) }
    }
    func invalidateChanges(from old: [AppRecord], to new: [AppRecord]) {
        let records = Dictionary(uniqueKeysWithValues:new.map { ($0.id,$0) })
        for app in old where records[app.id] != app {
            let key = key(for:app)
            cache.removeObject(forKey:key as NSString)
            pending.removeValue(forKey:key)?.operation.cancel()
            if records[app.id]?.available != true { previous.removeObject(forKey:app.path as NSString) }
        }
    }
    static func loadImage(path: String) -> NSImage {
        let local = NSWorkspace.shared.icon(forFile:path).copy() as! NSImage
        var rect = NSRect(x:0,y:0,width:256,height:256)
        if let cg = local.cgImage(forProposedRect:&rect,context:nil,hints:nil),
           let context = CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(cg,in:CGRect(x:0,y:0,width:256,height:256))
            if let result = context.makeImage() { return NSImage(cgImage:result,size:NSSize(width:128,height:128)) }
        }
        return local
    }
    private static func read(_ url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath:url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:256
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage:image,size:NSSize(width:128,height:128))
    }
    private static func write(_ image: NSImage, to url: URL) {
        var rect = NSRect(x:0,y:0,width:256,height:256)
        guard let cg = image.cgImage(forProposedRect:&rect,context:nil,hints:nil),
              let data = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else { return }
        try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? data.write(to:url,options:.atomic)
    }
    private static func prune(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey,.fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(keys))) ?? [])
            .filter { $0.pathExtension == "png" }.compactMap { url -> (URL,Date,Int)? in
                guard let values = try? url.resourceValues(forKeys:keys) else { return nil }
                return (url,values.contentModificationDate ?? .distantPast,values.fileSize ?? 0)
            }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index,file) in files.enumerated() {
            bytes += file.2
            if index >= 600 || bytes > 64*1024*1024 { try? FileManager.default.removeItem(at:file.0) }
        }
    }
}
