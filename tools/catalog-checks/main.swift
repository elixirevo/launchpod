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
func fixture(_ name: String, parent: URL? = nil, info extra: [String:Any] = [:], packageType: String? = "APPL", executable: Bool = true) throws -> URL {
    let app = (parent ?? directory).appendingPathComponent(name+".app")
    let contents = app.appendingPathComponent("Contents")
    try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    var info: [String:Any] = ["CFBundleIdentifier":"test.launchpod."+name,
        "CFBundleName":name, "CFBundleExecutable":name]
    if let packageType { info["CFBundlePackageType"] = packageType }
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
    // Safari is a hidden symlink in /Applications to a visible Cryptex app.
    // Test discovery through the directory, not just a directly supplied app.
    let links = directory.appendingPathComponent("Links")
    let targets = directory.appendingPathComponent("Targets")
    try fm.createDirectory(at:links,withIntermediateDirectories:true)
    let safari = try fixture("Safari",parent:targets,info:["CFBundleIdentifier":"com.apple.Safari"])
    let safariLink = links.appendingPathComponent("Safari.app")
    try fm.createSymbolicLink(at:safariLink,withDestinationURL:safari)
    try expect(lchflags(safariLink.path,UInt32(UF_HIDDEN)) == 0,"mark Safari symlink hidden without hiding its target")
    try expect((try safariLink.resourceValues(forKeys:[.isHiddenKey])).isHidden == true,"fixture reproduces Safari's hidden attribute")
    let hidden = try fixture("Hidden",parent:links)
    try expect(chflags(hidden.path,UInt32(UF_HIDDEN)) == 0,"mark internal app hidden")
    let hiddenLink = links.appendingPathComponent("HiddenAlias.app")
    try fm.createSymbolicLink(at:hiddenLink,withDestinationURL:hidden)
    try expect(lchflags(hiddenLink.path,UInt32(UF_HIDDEN)) == 0,"mark internal alias hidden")
    _ = try fixture(".Internal",parent:links)
    _ = try fixture("Nested",parent:links.appendingPathComponent(".private"))
    let brokenLink = links.appendingPathComponent("Missing.app")
    try fm.createSymbolicLink(at:brokenLink,withDestinationURL:targets.appendingPathComponent("Missing.app"))
    let linked = AppCatalog.discover(roots:[links])
    try expect(linked.map(\.path) == [safari.path],"hidden symlink to visible app is discovered; hidden apps, private directories and broken links stay excluded")
    try expect(AppCatalog.discover(roots:[links,targets,safari]).count == 1,"symlink and target roots do not duplicate Safari")
    let passwords = try fixture("Passwords",parent:links,info:["CFBundlePackageType":"XPC!"])
    _ = try fixture("BackgroundXPC",parent:links,info:["CFBundlePackageType":"XPC!","LSBackgroundOnly":true])
    let recovered = AppCatalog.discover(roots:[links])
    try expect(recovered.count == 2 && recovered.contains { $0.path == passwords.path },"standalone XPC application is included; background XPC stays excluded")
    layout.reconcile(found + recovered)
    try layout.validate()
    try expect(layout.hidden == [existingID],"recovery preserves previously hidden apps")
    for query in ["safari","passwords"] {
        try expect(AppSearch.results(for:query,in:layout).count == 1,"recovered app appears in search: "+query)
    }
    try store.save(layout)
    let recoveredLayout = try store.load()
    try expect(AppSearch.results(for:"SAFARI",in:recoveredLayout).count == 1 && AppSearch.results(for:"PASSWORDS",in:recoveredLayout).count == 1,"recovered apps remain searchable after reload")
    // App suites expose tools in dedicated Applications directories, not arbitrary bundle internals.
    let suites = directory.appendingPathComponent("Suites")
    let suite = try fixture("RenamedToolSuite", parent:suites)
    let bundledTools = suite.appendingPathComponent("Contents/Applications")
    let iconComposer = try fixture("Icon Composer", parent:bundledTools, packageType:nil)
    let simulator = try fixture("Simulator", parent:suite.appendingPathComponent("Contents/Developer/Applications"))
    _ = try fixture("InternalLoginHelper", parent:suite.appendingPathComponent("Contents/Library/LoginItems"))
    _ = try fixture("SampleApp", parent:suite.appendingPathComponent("Contents/Resources/Examples"))
    _ = try fixture("FrameworkHelper", parent:suite.appendingPathComponent("Contents/Frameworks/Support"))
    _ = try fixture("BackgroundTool", parent:bundledTools, info:["LSBackgroundOnly":true])
    _ = try fixture("IconHelper", parent:iconComposer.appendingPathComponent("Contents/Library/LoginItems"))
    try fm.createSymbolicLink(at:bundledTools.appendingPathComponent("Parent.app"), withDestinationURL:suite)
    try fm.createSymbolicLink(at:bundledTools.appendingPathComponent("ToolAlias.app"), withDestinationURL:iconComposer)
    let suiteApps = AppCatalog.discover(roots:[suites,suite,bundledTools,iconComposer])
    try expect(Set(suiteApps.map(\.path)) == Set([suite.path,iconComposer.path,simulator.path]) && suiteApps.count == 3,
        "suite tools are found without helper/resource apps, duplicates or symlink loops")
    try expect(AppCatalog.discover(roots:[suite]).count == 3,"directly configured or renamed suite includes its tools")
    var suiteLayout = LayoutState(); suiteLayout.reconcile(suiteApps)
    try expect(AppSearch.results(for:"icon composer",in:suiteLayout).map(\.path) == [iconComposer.path],"bundled Icon Composer is searchable")
    try expect(AppSearch.results(for:"simulator",in:suiteLayout).map(\.path) == [simulator.path],"developer tools are searchable")
    let composerID = suiteLayout.apps.first { $0.path == iconComposer.path }!.id
    suiteLayout.hide(composerID)
    suiteLayout.reconcile(AppCatalog.discover(roots:[suites]))
    try expect(suiteLayout.hidden.contains(composerID) && AppSearch.results(for:"icon composer",in:suiteLayout).isEmpty,
        "rescanning bundled tools preserves explicit hiding")
    let removedToolPath = simulator.path
    try fm.removeItem(at:simulator)
    let afterToolRemoval = AppCatalog.discover(roots:[suites])
    let removedTools = AppCatalog.removedPaths(previousApps:suiteApps,discovered:afterToolRemoval,roots:[suites])
    try expect(removedTools == [removedToolPath],"removed bundled tools are recognized inside a scanned suite")
    suiteLayout.reconcile(afterToolRemoval,removedPaths:removedTools)
    try suiteLayout.validate()
    try store.save(suiteLayout)
    try expect(try store.load() == suiteLayout,"bundled tool catalog and hidden state persist")
    let args = CommandLine.arguments
    if let i = args.firstIndex(of:"--installed"), args.indices.contains(i+1) {
        let url = URL(fileURLWithPath:args[i+1]).resolvingSymlinksInPath().standardizedFileURL
        let installed = AppCatalog.discover(roots:[url])
        try expect(installed.filter { $0.path == url.path }.count == 1,"installed app is discoverable: "+url.path)
        var actual = LayoutState(); actual.reconcile(installed)
        try expect(AppSearch.results(for:url.deletingPathExtension().lastPathComponent.lowercased(),in:actual).count == 1,
            "installed app is placed and searchable")
        let target = installed.first { $0.path == url.path }!
        print("Installed app: \(target.title); \(target.bundleID); \(target.path)")
        let defaultScan = AppCatalog.discover(roots:AppCatalog().roots)
        try expect(defaultScan.contains { $0.path == url.path },"installed app is also discovered through default scan roots")
    }
    if args.contains("--audit-installed") {
        let installed = AppCatalog.discover(roots:AppCatalog().roots)
        let saved = LayoutStore(directory:fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Launchpod"))
        var state = try saved.load()
        let previousPaths = Set(state.apps.map(\.path))
        state.reconcile(installed)
        try state.validate()
        for app in installed where !previousPaths.contains(app.path) {
            print("Newly discovered: \(app.title); \(app.bundleID); \(app.path)")
            try expect(AppSearch.results(for:app.title,in:state).contains { $0.path == app.path },"newly discovered installed app is searchable")
        }
        print("Installed catalog: \(installed.count) apps (existing user layout read only)")
    }
    print("PASS: \(checks) catalog checks")
} catch {
    fputs("\(error.localizedDescription)\n",stderr)
    exit(1)
}
