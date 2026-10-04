import Foundation
import LaunchpodCore

func runPlacementResetChecks(_ expect: (Bool, String) -> Void) throws {
    let notes = AppRecord(id: "notes", title: "Notes", bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app")
    let terminal = AppRecord(id: "terminal", title: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app")
    let keychain = AppRecord(id: "keychain", title: "Keychain", bundleID: "com.apple.keychainaccess", path: "/System/Library/CoreServices/Applications/Keychain Access.app")
    let xcode = AppRecord(id: "xcode", title: "Xcode", bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app")
    let composer = AppRecord(id: "composer", title: "Icon Composer", bundleID: "com.apple.IconComposer", path: "/Applications/Xcode.app/Contents/Applications/Icon Composer.app")
    let missing = AppRecord(id: "missing", title: "Missing", bundleID: "vendor.missing", path: "/Volumes/Offline/Missing.app", available: false)
    var layout = LayoutState()
    layout.apps = [xcode, terminal, missing, notes, keychain, composer]
    layout.folders = [AppFolder(id: "personal", title: "Personal", pages: [[notes.id, xcode.id]])]
    layout.pages = [["personal", missing.id, keychain.id, composer.id]]
    layout.hidden = [terminal.id]
    layout.didGroupSystemApps = true
    layout.systemFolderPolicyVersion = 4
    try layout.validate()
    let originalApps = Dictionary(uniqueKeysWithValues: layout.apps.map { ($0.id, $0) })
    layout.resetAppPlacement(capacity: 3, folderCapacity: 2)
    try layout.validate()
    expect(layout.folder("personal") == nil, "placement reset removes user-created folders")
    expect(layout.folders.count == 1 && layout.folders[0].pages == [[keychain.id]], "placement reset recreates only visible macOS utilities in Tools")
    expect(layout.pages == [[notes.id, layout.automaticSystemFolderID!], [composer.id, missing.id, xcode.id]], "reset uses system-first pages and alphabetical installed apps")
    expect(layout.hidden == [terminal.id], "reset preserves explicitly hidden apps")
    expect(Dictionary(uniqueKeysWithValues: layout.apps.map { ($0.id, $0) }) == originalApps, "reset preserves every app record including offline apps")
    expect(layout.app(missing.id)?.available == false, "reset does not falsely mark offline apps available")
    let roundTrip = try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(layout))
    expect(roundTrip == layout, "reset layout and policy survive export/reload")
    var allHidden = layout
    for id in allHidden.orderedAppIDs { allHidden.hide(id) }
    let hiddenIDs = Set(allHidden.hidden)
    allHidden.resetAppPlacement()
    try allHidden.validate()
    expect(allHidden.pages == [[]] && allHidden.folders.isEmpty && Set(allHidden.hidden) == hiddenIDs, "all-hidden reset stays valid without revealing apps")
    var empty = LayoutState()
    empty.resetAppPlacement()
    try empty.validate()
    expect(empty.pages == [[]] && empty.apps.isEmpty, "empty placement reset remains valid")
}
