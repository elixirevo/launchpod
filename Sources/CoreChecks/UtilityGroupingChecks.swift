import Foundation
import LaunchpodCore

func runUtilityGroupingChecks(_ expect: (Bool, String) -> Void) throws {
    func app(_ id: String, _ path: String, apple: Bool = true) -> AppRecord {
        AppRecord(id: id, title: id, bundleID: (apple ? "com.apple." : "vendor.") + id, path: path)
    }
    let terminal = AppRecord(id: "terminal", title: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app")
    let keychain = app("keychain", "/System/Library/CoreServices/Applications/Keychain Access.app")
    let archive = app("archive", "/System/Library/CoreServices/Applications/Archive Utility.app")
    let composer = app("composer", "/Applications/Xcode.app/Contents/Applications/Icon Composer.app")
    let simulator = app("simulator", "/Applications/Renamed Xcode.app/Contents/Developer/Applications/Simulator.app")
    let xcode = app("xcode", "/Applications/Xcode.app")
    let utility = app("utility", "/Applications/Utilities/Vendor.app", apple: false)
    let userTool = app("user", NSHomeDirectory() + "/Applications/Utilities/Tool.app")
    let notes = app("notes", "/System/Applications/Notes.app")
    let tools = [terminal, keychain, archive]
    let excluded = [composer, simulator, xcode, utility, userTool, notes]
    expect(tools.allSatisfy(\.isInitialUtility), "only macOS-bundled utilities qualify")
    expect(excluded.allSatisfy { !$0.isInitialUtility }, "installed utilities, Xcode and its tools, and general system apps stay outside Tools")
    expect(!app("fake", "/System/Applications/UtilitiesFake/App.app").isInitialUtility, "utility directory boundaries are exact")
    expect(!app("fake", "/System/Applications/Utilities/App.app", apple: false).isInitialUtility, "system utility classification requires an Apple identity")
    expect(!app("nested", "/System/Applications/Utilities/App.app/Contents/Applications/Nested.app").isInitialUtility, "nested tools are not inferred to ship with macOS")
    var fresh = LayoutState()
    fresh.reconcile(tools + excluded, capacity: 4, folderCapacity: 2)
    fresh.groupSystemAppsIfNeeded(capacity: 4, folderCapacity: 2)
    try fresh.validate()
    let folderID = fresh.automaticSystemFolderID!
    expect(Set(fresh.folder(folderID)!.pages.flatMap { $0 }) == Set(tools.map(\.id)), "fresh Tools folder contains only bundled system utilities")
    expect(fresh.folder(folderID)!.pages.map(\.count) == [2, 1], "tools paginate at folder capacity")
    expect(excluded.allSatisfy { fresh.location(of: $0.id)?.folderID == nil }, "fresh default leaves separately installed apps on root pages")
    expect(fresh.systemFolderPolicyVersion == 4, "restricted policy version persists")
    fresh.renameFolder(folderID, title: "My tools")
    try fresh.move(archive.id, to: ItemLocation(page: 0, index: 0))
    fresh.hide(keychain.id)
    let extra = app("extra", "/System/Applications/Utilities/Extra.app")
    let installed = app("installed", "/Applications/Utilities/Installed.app")
    fresh.reconcile(tools + excluded + [extra, installed])
    fresh.groupSystemAppsIfNeeded(newAppIDs: [extra.id, installed.id])
    expect(fresh.location(of: extra.id)?.folderID == folderID, "new system utilities join the automatic folder")
    expect(fresh.location(of: installed.id)?.folderID == nil, "new user-installed tools stay outside the automatic folder")
    expect(fresh.folder(folderID)?.title == "My tools", "renamed automatic folder keeps its name")
    expect(fresh.location(of: archive.id)?.folderID == nil, "rescan respects manually extracted system utilities")
    expect(fresh.hidden.contains(keychain.id), "rescan respects hidden utilities")
    let restored = try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(fresh))
    var rescanned = restored
    rescanned.groupSystemAppsIfNeeded()
    expect(rescanned == restored, "save/reload does not repeat default grouping")

    var upgrade = LayoutState()
    upgrade.reconcile(tools + excluded)
    let existing = try upgrade.makeFolder(with: keychain.id, over: notes.id, title: "Personal")
    upgrade.hide(simulator.id)
    upgrade.didGroupSystemApps = true
    upgrade.systemFolderPolicyVersion = 2
    upgrade.groupSystemAppsIfNeeded()
    try upgrade.validate()
    expect(upgrade.location(of: terminal.id)?.folderID == nil, "upgrade preserves old-policy utilities moved out by the user")
    expect(upgrade.location(of: keychain.id)?.folderID == existing, "upgrade preserves custom folders")
    expect(upgrade.hidden == [simulator.id], "upgrade preserves hiding")
    expect(upgrade.location(of: archive.id)?.folderID == upgrade.automaticSystemFolderID && upgrade.automaticSystemFolderID != nil, "upgrade groups newly classified macOS tools")
    expect(upgrade.location(of: composer.id)?.folderID == nil, "upgrade never groups Xcode tools")

    var broad = LayoutState()
    broad.reconcile(tools + excluded)
    let auto = try broad.makeFolder(with: composer.id, over: terminal.id, title: "Tools")
    try broad.move(utility.id, to: broad.endOfFolder(auto)!)
    let personal = try broad.makeFolder(with: simulator.id, over: notes.id, title: "Development")
    broad.automaticSystemFolderID = auto
    broad.didGroupSystemApps = true
    broad.systemFolderPolicyVersion = 3
    broad.hide(keychain.id)
    broad.groupSystemAppsIfNeeded()
    try broad.validate()
    expect(broad.folder(auto)?.pages.flatMap { $0 } == [terminal.id], "repair removes non-system apps from the tracked automatic folder")
    expect([composer, utility].allSatisfy { broad.location(of: $0.id)?.folderID == nil }, "mistakenly grouped tools return to root pages")
    expect(broad.location(of: simulator.id)?.folderID == personal, "repair preserves manually created folders")
    expect(broad.hidden == [keychain.id], "repair preserves hiding")
    let repaired = broad
    broad.groupSystemAppsIfNeeded()
    expect(broad == repaired, "broad-policy repair runs only once")

    try broad.move(composer.id, to: broad.endOfFolder(auto)!)
    broad.groupSystemAppsIfNeeded()
    expect(broad.location(of: composer.id)?.folderID == auto, "later manual placement in Tools remains allowed")
    var onlyInstalled = LayoutState()
    onlyInstalled.reconcile([composer, utility])
    onlyInstalled.automaticSystemFolderID = try onlyInstalled.makeFolder(with: composer.id, over: utility.id, title: "Tools")
    onlyInstalled.didGroupSystemApps = true
    onlyInstalled.systemFolderPolicyVersion = 3
    onlyInstalled.groupSystemAppsIfNeeded()
    try onlyInstalled.validate()
    expect(onlyInstalled.folders.isEmpty && onlyInstalled.automaticSystemFolderID == nil,
        "repair safely removes an automatic folder containing only installed apps")

    var singleton = LayoutState()
    singleton.reconcile([terminal])
    singleton.groupSystemAppsIfNeeded()
    expect(singleton.location(of: terminal.id)?.folderID != nil, "a lone system utility receives the default folder")
}
