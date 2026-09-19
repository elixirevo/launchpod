import AppKit

/// Check the current Dock on every launch or reopen; restore a missing shortcut.
enum DockShortcut {
    @discardableResult
    static func addIfNeeded(appURL: URL = Bundle.main.bundleURL,
                            bundleID: String = Bundle.main.bundleIdentifier ?? "app.launchpod.Launchpod",
                            dockDefaults: UserDefaults? = UserDefaults(suiteName:"com.apple.dock"),
                            reloadDock: () -> Void = restartDock) -> Bool {
        guard appURL.pathExtension == "app",
              let dockDefaults = dockDefaults else { return false }
        dockDefaults.synchronize()
        // Do not replace an unreadable or managed Dock configuration.
        guard !dockDefaults.objectIsForced(forKey:"persistent-apps"),
              let tiles = dockDefaults.array(forKey:"persistent-apps") as? [[String:Any]] else { return false }
        let canonical = appURL.resolvingSymlinksInPath().standardizedFileURL
        let exists = tiles.contains { tile in
            guard let data = tile["tile-data"] as? [String:Any] else { return false }
            if data["bundle-identifier"] as? String == bundleID { return true }
            guard let file = data["file-data"] as? [String:Any],
                  let path = file["_CFURLString"] as? String else { return false }
            let url = path.hasPrefix("file:") ? URL(string:path) : URL(fileURLWithPath:path)
            return url?.resolvingSymlinksInPath().standardizedFileURL == canonical
        }
        guard !exists else { return false }
        let tile: [String:Any] = ["tile-type":"file-tile", "tile-data":[
                "bundle-identifier":bundleID,
                "file-label":appURL.deletingPathExtension().lastPathComponent,
                "file-type":41,
                "file-data":["_CFURLString":canonical.absoluteString,"_CFURLStringType":15]
            ]]
        dockDefaults.set(tiles+[tile],forKey:"persistent-apps")
        guard dockDefaults.synchronize() else { return false }
        reloadDock()
        return true
    }

    /// Give only this pinned tile a new identity, preserving its Dock position.
    /// Restarting Dock alone can retain the old tile's cached icon and bookmark.
    @discardableResult
    static func refreshIcon(appURL: URL = Bundle.main.bundleURL,
                            bundleID: String = Bundle.main.bundleIdentifier ?? "app.launchpod.Launchpod",
                            dockDefaults: UserDefaults? = UserDefaults(suiteName:"com.apple.dock"),
                            reloadDock: () -> Void = restartDock) -> Bool {
        guard appURL.pathExtension == "app", let dockDefaults = dockDefaults else { return false }
        dockDefaults.synchronize()
        guard !dockDefaults.objectIsForced(forKey:"persistent-apps"),
              var tiles = dockDefaults.array(forKey:"persistent-apps") as? [[String:Any]] else { return false }
        let canonical = appURL.resolvingSymlinksInPath().standardizedFileURL
        var changed = false
        for index in tiles.indices {
            guard let data = tiles[index]["tile-data"] as? [String:Any] else { continue }
            let file = data["file-data"] as? [String:Any]
            let path = file?["_CFURLString"] as? String ?? ""
            let url = path.hasPrefix("file:") ? URL(string:path) : URL(fileURLWithPath:path)
            guard data["bundle-identifier"] as? String == bundleID
                || url?.resolvingSymlinksInPath().standardizedFileURL == canonical else { continue }
            tiles[index] = ["GUID": UInt32.random(in:1...UInt32.max), "tile-type":"file-tile", "tile-data":[
                "bundle-identifier":bundleID,
                "file-label":appURL.deletingPathExtension().lastPathComponent,
                "file-type":41,
                "file-data":["_CFURLString":canonical.absoluteString,"_CFURLStringType":15]
            ]]
            changed = true
        }
        guard changed else { return false }
        dockDefaults.set(tiles,forKey:"persistent-apps")
        guard dockDefaults.synchronize() else { return false }
        reloadDock()
        return true
    }

    private static func restartDock() {
        // Let Dock consume the preferences change before terminating it;
        // immediate termination can flush its old cached tiles over our write.
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+1) {
            for dock in NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock") {
                kill(dock.processIdentifier,SIGTERM)
            }
        }
    }
}
