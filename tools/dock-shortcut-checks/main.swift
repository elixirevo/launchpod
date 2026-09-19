import AppKit

let id = "app.launchpod.DockShortcutChecks."+UUID().uuidString
let dock = UserDefaults(suiteName:id+".dock")!
defer {
    dock.removePersistentDomain(forName:id+".dock")
}
var checks = 0, reloads = 0
func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
    checks += 1
}
let url = URL(fileURLWithPath:"/Applications/Launchpod Test.app")
let existing: [[String:Any]] = [["tile-type":"file-tile","tile-data":["bundle-identifier":"test.other","custom-key":"preserved"]]]
func add() -> Bool {
    DockShortcut.addIfNeeded(appURL:url,bundleID:"app.launchpod.Launchpod",dockDefaults:dock,reloadDock:{ reloads += 1 })
}
expect(!add() && reloads == 0,"unreadable Dock preferences are not overwritten")
dock.set(existing,forKey:"persistent-apps")
expect(add() && reloads == 1,"first run pins and reloads Dock once")
let tiles = dock.array(forKey:"persistent-apps") as! [[String:Any]]
expect(tiles.count == 2 && NSDictionary(dictionary:tiles[0]).isEqual(to:existing[0]),"other tiles retain their data and order")
let file = (tiles[1]["tile-data"] as! [String:Any])["file-data"] as! [String:Any]
expect(URL(string:file["_CFURLString"] as! String) == url,"shortcut preserves a path containing spaces")
expect(!add() && reloads == 1,"subsequent launches do not add or restart again")
dock.set(existing,forKey:"persistent-apps")
expect(add() && reloads == 2 && dock.array(forKey:"persistent-apps")!.count == 2,"launch or reopen restores a manually removed shortcut")
dock.set(tiles,forKey:"persistent-apps")
expect(!add() && reloads == 2 && dock.array(forKey:"persistent-apps")!.count == 2,"an existing shortcut is not duplicated")
dock.set([["tile-data":["file-data":["_CFURLString":url.absoluteString]]]],forKey:"persistent-apps")
expect(!add() && reloads == 2 && dock.array(forKey:"persistent-apps")!.count == 1,"URL-only existing shortcut is recognized")
let pinned: [[String:Any]] = [existing[0], ["GUID":123,"tile-type":"file-tile","tile-data":[
    "bundle-identifier":"app.launchpod.Launchpod", "book":Data([1,2,3]), "file-mod-date":10,
    "file-data":["_CFURLString":url.absoluteString,"_CFURLStringType":15]]], existing[0]]
dock.set(pinned,forKey:"persistent-apps")
let updated = DockShortcut.refreshIcon(appURL:url,bundleID:"app.launchpod.Launchpod",dockDefaults:dock,reloadDock:{reloads += 1})
let refreshed = dock.array(forKey:"persistent-apps") as! [[String:Any]]
expect(updated && refreshed.count == pinned.count,"refresh retains pinned item count")
expect(NSDictionary(dictionary:refreshed[0]).isEqual(to:pinned[0]) && NSDictionary(dictionary:refreshed[2]).isEqual(to:pinned[2]),"refresh preserves neighboring items and order")
let freshData=refreshed[1]["tile-data"] as! [String:Any]
expect((refreshed[1]["GUID"] as? NSNumber)?.uint32Value != 123 && freshData["book"] == nil && freshData["file-mod-date"] == nil,"refresh replaces stale tile identity and icon metadata")
dock.set(existing,forKey:"persistent-apps")
let reloadCount=reloads
expect(!DockShortcut.refreshIcon(appURL:url,bundleID:"app.launchpod.Launchpod",dockDefaults:dock,reloadDock:{reloads += 1}) && reloads == reloadCount,"icon refresh does not pin an absent shortcut")
print("PASS: \(checks) Dock shortcut and refresh checks")
