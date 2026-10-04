import Foundation
import LaunchpodCore

func runInitialLayoutChecks(_ expect: (Bool, String) -> Void) throws {
    func app(_ id: String, _ bundle: String, _ path: String) -> AppRecord {
        AppRecord(id: id, title: id, bundleID: bundle, path: path)
    }
    let installed = app("A Installed", "vendor.app", "/Applications/A Installed.app")
    let composer = app("Icon Composer", "com.apple.IconComposer", "/Applications/Xcode.app/Contents/Applications/Icon Composer.app")
    let keychain = app("Keychain", "com.apple.keychainaccess", "/System/Library/CoreServices/Applications/Keychain Access.app")
    let notes = app("Notes", "com.apple.Notes", "/System/Applications/Notes.app")
    let safari = app("Safari", "com.apple.Safari", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")
    let terminal = app("Terminal", "com.apple.Terminal", "/System/Applications/Utilities/Terminal.app")
    let xcode = app("Xcode", "com.apple.dt.Xcode", "/Applications/Xcode.app")
    let catalog = [installed, composer, keychain, notes, safari, terminal, xcode]
    var fresh = LayoutState()
    fresh.reconcileCatalog(catalog)
    try fresh.validate()
    let tools = fresh.automaticSystemFolderID!
    expect(fresh.pages == [[notes.id, safari.id, tools], [installed.id, composer.id, xcode.id]],
        "initial pages show system apps and Tools first, installed apps on the next page")
    expect(Set(fresh.folder(tools)!.pages.flatMap { $0 }) == [keychain.id, terminal.id],
        "only macOS utilities enter the initial Tools folder")
    let initial = fresh
    fresh.reconcileCatalog(catalog)
    expect(fresh == initial, "catalog refresh keeps the initial page boundary")
    try fresh.move(xcode.id, to: ItemLocation(page: 0, index: 0))
    let personal = try fresh.makeFolder(with: notes.id, over: composer.id, title: "Personal")
    fresh.hide(safari.id)
    let customized = fresh
    fresh = try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(fresh))
    fresh.reconcileCatalog(catalog)
    expect(fresh == customized, "restart and refresh preserve manual order, folders and hiding")
    expect(fresh.location(of: notes.id)?.folderID == personal, "system apps can stay in a custom folder")

    var existing = LayoutState()
    existing.reconcile(catalog)
    existing.groupSystemAppsIfNeeded()
    let existingPages = existing.pages
    existing.reconcileCatalog(catalog)
    expect(existing.pages == existingPages, "existing layouts are not reordered during upgrade")
    var imported = LayoutState()
    imported.reconcile([xcode, safari, installed])
    let importedPages = imported.pages
    imported.reconcileCatalog([xcode, safari, installed])
    expect(imported.pages == importedPages, "imports without migration fields retain their order")

    var small = LayoutState()
    small.reconcileCatalog(catalog, capacity: 2, folderCapacity: 1)
    try small.validate()
    expect(small.pages == [[notes.id, small.automaticSystemFolderID!], [safari.id],
                           [installed.id, composer.id], [xcode.id]],
        "small grids keep Tools on page one and place system overflow before installed apps")
    var oneSlot = LayoutState()
    oneSlot.reconcileCatalog(catalog, capacity: 1, folderCapacity: 1)
    try oneSlot.validate()
    expect(oneSlot.pages[0] == [oneSlot.automaticSystemFolderID!], "one-slot grid keeps a valid Tools first page")
    var withoutTools = LayoutState()
    withoutTools.reconcileCatalog([installed, notes])
    expect(withoutTools.pages == [[notes.id], [installed.id]], "system and installed apps stay on separate pages without utilities")
    var installedOnly = LayoutState()
    installedOnly.reconcileCatalog([installed, composer, xcode], capacity: 2)
    expect(installedOnly.pages == [[installed.id, composer.id], [xcode.id]], "no blank system page when no bundled apps exist")
    var empty = LayoutState()
    empty.reconcileCatalog([])
    expect(empty == LayoutState(), "empty scan does not consume first-layout initialization")
    empty.reconcileCatalog(catalog)
    expect(empty.pages.first?.first == notes.id, "first successful scan still receives system-first order")
    let later = app("Z Installed", "vendor.later", "/Applications/Z Installed.app")
    fresh.reconcileCatalog(catalog + [later])
    expect(fresh.location(of: xcode.id)?.page == 0 && fresh.location(of: xcode.id)?.index == 0,
        "installing another app does not sort existing items again")
}
