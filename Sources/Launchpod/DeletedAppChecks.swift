import AppKit
import LaunchpodCore

enum DeletedAppChecks {
    static func run(outputDirectory: URL) throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LayoutError.invalid(name) }; checks += 1
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("Launchpod-deleted-apps-"+UUID().uuidString)
        let root = temp.appendingPathComponent("Applications")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:temp) }
        func makeApp(_ name: String, under directory: URL? = nil, bundleID: String? = nil) throws -> URL {
            let url = (directory ?? root).appendingPathComponent(name+".app")
            let executable = url.appendingPathComponent("Contents/MacOS/fixture")
            try fm.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to:executable)
            try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
            let plist = ["CFBundlePackageType":"APPL","CFBundleIdentifier":bundleID ?? "test.deleted."+name,
                         "CFBundleName":name,"CFBundleExecutable":"fixture"]
            try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let nested = root.appendingPathComponent("Tools/Nested")
        let urls = try [makeApp("Keep"),makeApp("Deleted"),makeApp("Hidden"),makeApp("Child",under:nested),makeApp("Moved")]
        let initial = AppCatalog.discover(roots:[root])
        try check(initial.count == 5,"fixture catalog discovers all apps including nested folder")
        func record(_ title: String) -> AppRecord { initial.first { $0.title == title }! }
        let keep = record("Keep"), deleted = record("Deleted"), hidden = record("Hidden"), child = record("Child"), moved = record("Moved")
        var state = LayoutState()
        state.apps = initial
        state.pages = [[keep.id,deleted.id,"folder"],[moved.id]]
        state.folders = [AppFolder(id:"folder",title:"내 폴더",pages:[[child.id]])]
        state.hidden = [hidden.id]
        try state.validate()
        let original = state
        let store = LayoutStore(directory:temp.appendingPathComponent("Layout"))
        try store.save(state)
        // Watch a nested parent; deleting its child does not notify the root vnode.
        let catalog = AppCatalog(roots:[root])
        var notified = false
        catalog.onChange = { notified = true }
        catalog.startWatching(appPaths:initial.map(\.path))
        try fm.removeItem(at:urls[3])
        let deadline = Date().addingTimeInterval(4)
        while !notified && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        try check(notified,"nested app deletion triggers a catalog refresh")
        try fm.removeItem(at:urls[1]); try fm.removeItem(at:urls[2])
        let destination = root.appendingPathComponent("Renamed.app")
        try fm.moveItem(at:urls[4],to:destination)
        let found = AppCatalog.discover(roots:[root])
        let removed = AppCatalog.removedPaths(previousApps:initial,discovered:found,roots:[root])
        try check(removed == Set([deleted.path,hidden.path,child.path,moved.path]),"only absent paths are classified as removed")
        state.reconcile(found,removedPaths:removed)
        try state.validate()
        try check(Set(state.apps.map(\.id)) == Set([keep.id,moved.id]),"deleted records removed while moved identity survives")
        try check(state.pages == [[keep.id],[moved.id]],"ghost slots removed without reshuffling surviving pages")
        try check(state.folders.isEmpty,"last deleted child removes its empty folder")
        try check(state.hidden.isEmpty,"deleted hidden record is removed")
        try check(state.app(moved.id)?.path == destination.path,"moved app retains ID and position")
        try store.save(state)
        try check(try store.load() == state,"cleanup persists across relaunch")
        let snapshot = state
        state.reconcile(AppCatalog.discover(roots:[root]),removedPaths:removed)
        try check(state == snapshot,"repeated scan is stable")
        var legacy = original
        for index in legacy.apps.indices { legacy.apps[index].available = false }
        legacy.reconcile(found,removedPaths:removed)
        try check(legacy == snapshot,"existing dashed unavailable records are cleaned too")
        var mixed = original
        mixed.folders[0].pages = [[child.id,keep.id]]
        mixed.pages[0].removeAll { $0 == keep.id }
        mixed.reconcile(found,removedPaths:removed)
        try mixed.validate()
        try check(mixed.folder("folder")?.pages == [[keep.id]],"partially deleted custom folder retains title and surviving child")
        try check(mixed.folder("folder")?.title == "내 폴더","custom folder name preserved")
        let offlineRoot = temp.appendingPathComponent("DisconnectedVolume/Applications")
        var offline = AppRecord(id:"offline",title:"Offline",bundleID:"offline",path:offlineRoot.appendingPathComponent("Offline.app").path)
        try check(AppCatalog.removedPaths(previousApps:[offline],discovered:[],roots:[offlineRoot]).isEmpty,"disconnected source is not treated as uninstall")
        offline.path = ""
        try check(AppCatalog.removedPaths(previousApps:[offline],discovered:[],roots:[root]).isEmpty,"unresolved import not mistaken for file deletion")
        try check(AppCatalog.removedPaths(previousApps:[keep],discovered:[],roots:[root]).isEmpty,"incomplete scan retains an existing bundle")
        try check(AppCatalog.removedPaths(previousApps:[deleted],discovered:[],roots:[temp.appendingPathComponent("Other")]).isEmpty,"apps outside scanned roots retained")
        let direct = try makeApp("Direct")
        let directRecord = AppCatalog.discover(roots:[direct])
        try fm.removeItem(at:direct)
        try check(AppCatalog.removedPaths(previousApps:directRecord,discovered:[],roots:[direct]) == Set([direct.path]),"a directly configured app deletion checks its parent")
        var empty = snapshot
        try fm.removeItem(at:urls[0]); try fm.removeItem(at:destination)
        empty.reconcile([],removedPaths:AppCatalog.removedPaths(previousApps:empty.apps,discovered:[],roots:[root]))
        try empty.validate()
        try check(empty.apps.isEmpty && empty.pages == [[]],"deleting every app keeps one valid empty page")
        // Deleting one of two copies must not remove or relocate the survivor.
        let first = try makeApp("CopyA",bundleID:"same"), second = try makeApp("CopyB",bundleID:"same")
        let copies = AppCatalog.discover(roots:[root])
        var duplicate = LayoutState(); duplicate.reconcile(copies)
        let survivorID = duplicate.apps.first { $0.path == second.path }!.id
        try fm.removeItem(at:first)
        let remaining = AppCatalog.discover(roots:[root])
        duplicate.reconcile(remaining,removedPaths:AppCatalog.removedPaths(previousApps:duplicate.apps,discovered:remaining,roots:[root]))
        try duplicate.validate()
        try check(duplicate.apps.count == 1 && duplicate.apps[0].id == survivorID,"same bundle ID copies do not resurrect deleted copy")
        let report = "PASS: \(checks) deleted-app checks\nTemporary app bundles only: discovery, nested directory notification, removal, folders, hidden apps, moves, duplicate bundles, persistence, unavailable sources.\nNo installed user apps or user layout were modified.\n"
        try fm.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        print(report)
    }
}
