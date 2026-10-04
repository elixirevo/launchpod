import Foundation
import LaunchpodCore

func runUtilityGroupingChecks(_ expect: (Bool, String) -> Void) throws {
    func app(_ id: String, _ path: String, category: String? = nil) -> AppRecord {
        var result = AppRecord(id: id, title: id, bundleID: "test." + id, path: path)
        result.category = category
        return result
    }
    let terminal = AppRecord(id: "terminal", title: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app")
    let keychain = app("keychain", "/System/Library/CoreServices/Applications/Keychain Access.app")
    let composer = app("composer", "/Applications/Xcode.app/Contents/Applications/Icon Composer.app")
    let simulator = app("simulator", "/Applications/Renamed Xcode.app/Contents/Developer/Applications/Simulator.app")
    let utility = app("utility", "/Applications/Vendor.app", category: "public.app-category.utilities")
    let userTool = app("user", NSHomeDirectory() + "/Applications/Utilities/Tool.app")
    let ordinary = app("ordinary", "/Applications/Ordinary.app")
    let tools = [terminal, keychain, composer, simulator, utility, userTool]
    expect(tools.allSatisfy(\.isInitialUtility), "classify system, bundled, user and declared utilities")
    expect(!ordinary.isInitialUtility, "ordinary apps remain outside Tools")
    expect(!app("fake", "/System/Applications/UtilitiesFake/App.app").isInitialUtility, "utility directory boundaries are exact")
    expect(!app("fake", "/Applications/Example/Contents/Applications/App.app").isInitialUtility, "embedded tool requires an app bundle ancestor")
    expect(!app("helper", "/Applications/Xcode.app/Contents/Library/LoginItems/Helper.app").isInitialUtility, "internal helper directories are not tools")
    var fresh = LayoutState()
    fresh.reconcile(tools + [ordinary], capacity: 4, folderCapacity: 3)
    fresh.groupSystemAppsIfNeeded(capacity: 4, folderCapacity: 3)
    try fresh.validate()
    let folderID = fresh.automaticSystemFolderID!
    expect(Set(fresh.folder(folderID)!.pages.flatMap { $0 }) == Set(tools.map(\.id)), "fresh layout groups all utility kinds together")
    expect(fresh.folder(folderID)!.pages.map(\.count) == [3, 3], "tools paginate at folder capacity")
    expect(fresh.systemFolderPolicyVersion == 3, "expanded policy version persists")
    fresh.renameFolder(folderID, title: "My tools")
    try fresh.move(composer.id, to: ItemLocation(page: 0, index: 0))
    fresh.hide(keychain.id)
    let extra = app("extra", "/Applications/Utilities/Extra.app")
    fresh.reconcile(tools + [ordinary, extra])
    fresh.groupSystemAppsIfNeeded(newAppIDs: [extra.id])
    expect(fresh.location(of: extra.id)?.folderID == folderID, "new utilities join the existing automatic folder")
    expect(fresh.folder(folderID)?.title == "My tools", "renamed automatic folder keeps its name")
    expect(fresh.location(of: composer.id)?.folderID == nil, "rescan respects manually extracted utilities")
    expect(fresh.hidden.contains(keychain.id), "rescan respects hidden utilities")
    let restored = try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(fresh))
    var rescanned = restored
    rescanned.groupSystemAppsIfNeeded()
    expect(rescanned == restored, "save/reload does not repeat default grouping")
    expect(restored.app(utility.id)?.category == utility.category, "utility classification survives persistence")

    var upgrade = LayoutState()
    upgrade.reconcile([terminal, keychain, composer, simulator, ordinary])
    let existing = try upgrade.makeFolder(with: keychain.id, over: ordinary.id, title: "Personal")
    upgrade.hide(simulator.id)
    upgrade.didGroupSystemApps = true
    upgrade.systemFolderPolicyVersion = 2
    upgrade.groupSystemAppsIfNeeded()
    try upgrade.validate()
    expect(upgrade.location(of: terminal.id)?.folderID == nil, "upgrade preserves an old-policy utility moved out by the user")
    expect(upgrade.location(of: keychain.id)?.folderID == existing, "upgrade preserves custom folders")
    expect(upgrade.hidden == [simulator.id], "upgrade preserves hiding")
    expect(upgrade.location(of: composer.id)?.folderID == upgrade.automaticSystemFolderID && upgrade.automaticSystemFolderID != nil, "upgrade groups newly classified loose tools even when only one exists")

    var singleton = LayoutState()
    singleton.reconcile([terminal])
    singleton.groupSystemAppsIfNeeded()
    expect(singleton.location(of: terminal.id)?.folderID != nil, "a lone utility receives the default folder")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as! [String: Any]
    legacy.removeValue(forKey: "category")
    let decoded = try JSONDecoder().decode(AppRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    expect(decoded.category == nil, "old app records decode without category metadata")
}
