import AppKit
import LaunchpodCore

final class AppCatalog {
    private let queue = DispatchQueue(label: "app.launchpod.catalog", qos: .utility)
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var watchedPaths = Set<String>()
    private var refreshTask: DispatchWorkItem?
    private let configuredRoots: [URL]?
    init(roots: [URL]? = nil) { configuredRoots = roots }
    var onChange: (() -> Void)?
    var additionalPaths: [String] { UserDefaults.standard.stringArray(forKey: "additionalAppPaths") ?? [] }
    var roots: [URL] {
        if let configuredRoots = configuredRoots { return configuredRoots }
        return ["/Applications", "/System/Applications", NSHomeDirectory()+"/Applications"].map { URL(fileURLWithPath: $0) }
        + additionalPaths.map { URL(fileURLWithPath: $0) }
    }
    func scan(previousApps: [AppRecord], completion: @escaping ([AppRecord], Set<String>) -> Void) {
        let roots = self.roots
        queue.async {
            let result = Self.discover(roots: roots)
            let removed = Self.removedPaths(previousApps:previousApps,discovered:result,roots:roots)
            DispatchQueue.main.async { completion(result,removed) }
        }
    }
    static func discover(roots: [URL]) -> [AppRecord] {
        let fm = FileManager.default
        var found: [AppRecord] = [], visited = Set<String>()
        func inspect(_ url: URL) {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            // LSUIElement controls Dock presence, not whether an app can be
            // launched by the user (e.g. PinShot or Tailscale). Embedded helpers
            // are already excluded by not descending into app bundles below.
            guard visited.insert(canonical.path).inserted, let bundle = Bundle(url: canonical) else { return }
            let packageType = bundle.infoDictionary?["CFBundlePackageType"] as? String
            // Some standalone system apps (e.g. Passwords) use XPC! rather
            // than APPL. Require macOS to identify those bundles as apps.
            guard (packageType == "APPL" || (packageType == "XPC!" &&
                    (try? canonical.resourceValues(forKeys:[.isApplicationKey]).isApplication) == true)),
                  (bundle.infoDictionary?["LSBackgroundOnly"] as? NSNumber)?.boolValue != true,
                  bundle.bundleIdentifier != "com.apple.launchpad.launcher",
                  let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path) else { return }
            let title = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
                ?? fm.displayName(atPath: canonical.path).replacingOccurrences(of: ".app", with: "", options: .anchored, range: nil)
            var record = AppRecord(title: title.hasSuffix(".app") ? String(title.dropLast(4)) : title,
                                   bundleID: bundle.bundleIdentifier ?? "", path: canonical.path)
            // Installed updates can change artwork without changing its path.
            // Finder custom icons live at the bundle root; include them so
            // selecting an icon also refreshes the launcher grid/search cache.
            record.iconRevision = [canonical, canonical.appendingPathComponent("Contents/Info.plist"),
                                   canonical.appendingPathComponent("Icon\r")].compactMap {
                (try? $0.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate
            }.max()
            found.append(record)
        }
        for root in roots {
            if root.pathExtension.lowercased() == "app" { inspect(root); continue }
            // Safari's /Applications entry is a hidden symlink to a visible
            // Cryptex app. Inspect hidden links before filtering hidden entries.
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isHiddenKey, .isSymbolicLinkKey, .isPackageKey], options: [], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in e {
                let values = try? url.resourceValues(forKeys:[.isHiddenKey, .isSymbolicLinkKey, .isPackageKey])
                if url.lastPathComponent.hasPrefix(".") { e.skipDescendants(); continue }
                if values?.isHidden == true {
                    let target = url.resolvingSymlinksInPath().standardizedFileURL
                    if url.pathExtension.lowercased() == "app", values?.isSymbolicLink == true,
                       (try? target.resourceValues(forKeys:[.isHiddenKey]).isHidden) == false {
                        inspect(url)
                    }
                    e.skipDescendants(); continue
                }
                if url.pathExtension.lowercased() == "app" { inspect(url); e.skipDescendants() }
                else if values?.isPackage == true { e.skipDescendants() }
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    /// A failed scan or disconnected volume is not evidence of uninstallation.
    /// Probe missing paths on the catalog queue and accept only ENOENT/ENOTDIR
    /// under an accessible source. Existing bundles may be mid-update.
    static func removedPaths(previousApps: [AppRecord], discovered: [AppRecord], roots: [URL]) -> Set<String> {
        let installed = Set(discovered.map(\.path))
        let sources = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        var removed = Set<String>()
        for app in previousApps where !app.path.isEmpty && !installed.contains(app.path) {
            let path = URL(fileURLWithPath:app.path).standardizedFileURL.path
            let source = sources.filter { path == $0.path || path.hasPrefix($0.path+"/") }
                .max { $0.path.count < $1.path.count }
            guard let source = source else { continue }
            let directory = source.pathExtension.lowercased() == "app" ? source.deletingLastPathComponent() : source
            guard (try? directory.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true else { continue }
            var info = stat()
            if stat(path,&info) != 0 && (errno == ENOENT || errno == ENOTDIR) { removed.insert(app.path) }
        }
        return removed
    }
    func startWatching(appPaths: [String] = []) {
        let sources = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        var paths = Set(sources.map { $0.pathExtension.lowercased() == "app" ? $0.deletingLastPathComponent().path : $0.path })
        // Directory vnode notifications are not recursive. Watch containing
        // directories too, including ancestors of apps in nested subfolders.
        for path in appPaths {
            var directory = URL(fileURLWithPath:path).deletingLastPathComponent()
            while sources.contains(where: { directory.path == $0.path || directory.path.hasPrefix($0.path+"/") }) {
                paths.insert(directory.path)
                directory.deleteLastPathComponent()
            }
        }
        guard paths != watchedPaths else { return }
        watchers.forEach { $0.cancel() }; watchers = []; watchedPaths = []
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                // A renamed/deleted directory can leave a watcher on an old inode.
                self?.watchedPaths.remove(path)
                self?.refreshTask?.cancel()
                let task = DispatchWorkItem { [weak self] in self?.onChange?() }
                self?.refreshTask = task
                DispatchQueue.main.asyncAfter(deadline: .now()+1, execute: task)
            }
            source.setCancelHandler { close(fd) }
            source.resume(); watchers.append(source); watchedPaths.insert(path)
        }
    }
    deinit {
        refreshTask?.cancel()
        watchers.forEach { $0.cancel() }
    }
}
