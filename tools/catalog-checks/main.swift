import AppKit
import LaunchpodCore

let fm = FileManager.default
let directory = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("launchpod-catalog-checks-"+UUID().uuidString)
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: directory) }
var checks = 0
func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw LayoutError.invalid("FAIL: "+message) }
    checks += 1
}
func fixture(_ name: String, parent: URL? = nil, info extra: [String:Any] = [:], executable: Bool = true) throws -> URL {
    let app = (parent ?? directory).appendingPathComponent(name+".app")
    let contents = app.appendingPathComponent("Contents")
    try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    var info: [String:Any] = ["CFBundleIdentifier":"test.launchpod."+name,
        "CFBundleName":name, "CFBundlePackageType":"APPL", "CFBundleExecutable":name]
    info.merge(extra) { _, new in new }
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
    if executable {
        let file = contents.appendingPathComponent("MacOS/"+name)
        // Discovery checks file permissions; this fixture is never launched.
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:file)
        try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
    }
    return app
}
do {
    let utility = try fixture("MenuUtility", info:["LSUIElement":true])
    let normal = try fixture("Regular")
    _ = try fixture("LoginHelper",parent:normal.appendingPathComponent("Contents/Library/LoginItems"),info:["LSUIElement":true])
    _ = try fixture("Background",info:["LSBackgroundOnly":true,"LSUIElement":true])
    _ = try fixture("Broken",executable:false)
    let launchpod = try fixture("Launchpod",info:["CFBundleIdentifier":"app.launchpod.Launchpod","LSUIElement":true])
    _ = try fixture("LegacyLaunchpad",info:["CFBundleIdentifier":"com.apple.launchpad.launcher"])
    _ = try fixture("Resource",info:["CFBundlePackageType":"BNDL"])
    let alias = directory.appendingPathComponent("Alias.app")
    try fm.createSymbolicLink(at:alias,withDestinationURL:utility)
    let found = AppCatalog.discover(roots:[directory,utility])
    print("Fixture catalog: "+found.map(\.title).joined(separator:", "))
    try expect(found.contains { $0.path == utility.path },"user-facing LSUIElement app appears in catalog")
    try expect(found.contains { $0.path == normal.path },"ordinary app remains discoverable")
    try expect(found.contains { $0.path == launchpod.path },"Launchpod itself appears in the catalog")
    try expect(found.count == 3,"embedded helpers, background services, invalid bundles and duplicate roots stay excluded")
    try expect(AppCatalog.discover(roots:[utility]).count == 1,"explicit agent-app path also works")
    var layout = LayoutState()
    layout.reconcile(found.filter { $0.path == normal.path })
    let existingID = layout.apps[0].id
    layout.hide(existingID)
    layout.reconcile(found)
    try layout.validate()
    try expect(layout.hidden == [existingID],"rescan preserves the user's hidden apps and their IDs")
    let result = AppSearch.results(for:"menuutility",in:layout)
    try expect(AppSearch.results(for:"launchpod",in:layout).contains { $0.path == launchpod.path },"Launchpod itself is placed and searchable")
    try expect(result.count == 1 && result[0].path == utility.path,"newly discovered agent is placed and searchable")
    let store = LayoutStore(directory:directory.appendingPathComponent("state"))
    try store.save(layout)
    let restored = try store.load()
    try expect(AppSearch.results(for:"LAUNCHPOD",in:restored).contains { $0.path == launchpod.path },"Launchpod remains searchable after save and reload")
    try expect(AppSearch.results(for:"MENUUTILITY",in:restored).count == 1,"agent remains searchable after save and reload")
    let args = CommandLine.arguments
    if let i = args.firstIndex(of:"--installed"), args.indices.contains(i+1) {
        let url = URL(fileURLWithPath:args[i+1]).resolvingSymlinksInPath().standardizedFileURL
        let installed = AppCatalog.discover(roots:[url])
        try expect(installed.count == 1 && installed[0].path == url.path,"installed app is discoverable: "+url.path)
        var actual = LayoutState(); actual.reconcile(installed)
        try expect(AppSearch.results(for:url.deletingPathExtension().lastPathComponent.lowercased(),in:actual).count == 1,
            "installed app is placed and searchable")
        print("Installed app: \(installed[0].title); \(installed[0].bundleID); \(installed[0].path)")
    }
    print("PASS: \(checks) catalog checks")
} catch {
    fputs("\(error.localizedDescription)\n",stderr)
    exit(1)
}
