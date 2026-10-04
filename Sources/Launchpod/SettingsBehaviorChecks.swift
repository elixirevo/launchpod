import AppKit
import LaunchpodCore
import MacAppSettings

@MainActor enum SettingsBehaviorChecks {
    static func run(launcher: LauncherController, menu: NSMenu, hasStatusItem: Bool,
                    openLauncher: () -> Void, outputDirectory: URL) throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LayoutError.invalid(message) }
            checks += 1
        }
        try check(!launcher.isShown && !launcher.window.isVisible, "Startup leaves the launcher closed")
        try check(hasStatusItem, "Resident startup has a menu bar icon")
        try check(menu.items.count > 3 && !menu.items[0].isSeparatorItem && menu.items[1].isSeparatorItem,
                  "Open Launchpod is separated from Settings")
        try check(menu.items[2].title == L10n.text("Settings…", "설정…"), "Settings follows the separator")
        openLauncher()
        try check(launcher.isShown, "Explicit reopen still opens the launcher")
        launcher.dismiss(restoreFocus: false)

        let domain = "app.launchpod.FeatureResetChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(9, forKey: "columns")
        defaults.set(7, forKey: "rows")
        defaults.set(["/tmp/extra-apps"], forKey: "additionalAppPaths")
        let preserved: [String: Any] = [AppOnboarding.completionKey: 1, AppStartup.acceptanceKey: Data("receipt".utf8),
            "MacAppLibrary.crashReportingEnabled": true, "hotKeyCode": 40, "customPreference": "keep"]
        for (key, value) in preserved { defaults.set(value, forKey: key) }
        let icons = AppIconSettings(defaults: defaults)
        try icons.select(.originalLaunchpad)
        var fixture = LayoutState()
        fixture.apps = ["a", "b", "c", "d", "e", "f"].map { AppRecord(id: $0, title: $0, bundleID: "fixture." + $0, path: "") }
        fixture.folders = [.init(id: "folder", title: "My Folder", pages: [["c", "b"]])]
        fixture.pages = [["f", "folder", "a", "e"]]
        fixture.hidden = ["d"]
        fixture.didGroupSystemApps = true
        fixture.systemFolderPolicyVersion = 2
        launcher.mutate("Reset fixture") { $0 = fixture }
        let settings = SettingsController(launcher: launcher, appIcons: icons)
        let original = launcher.state
        try check(original == fixture, "Reset fixture is installed in the isolated layout")

        settings.model.requestAppPlacementReset(confirm: { false })
        try check(try launcher.store.load() == original && launcher.state == original,
                  "Canceling placement reset leaves the saved layout unchanged")

        // A blocked layout save must keep preference values and restore the prior icon.
        let directory = launcher.store.directory
        let savedDirectory = directory.appendingPathExtension("reset-backup")
        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        try Data("not a directory".utf8).write(to: directory)
        do {
            defer {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.moveItem(at: savedDirectory, to: directory)
            }
            settings.model.requestAppPlacementReset(confirm: { true })
            try check(settings.model.error != nil && launcher.state == original,
                      "Failed placement save reports an error and keeps the original layout")
            var failed = false
            do { try launcher.restoreFeatureDefaults(appIcons: icons, defaults: defaults) }
            catch { failed = true }
            try check(failed && icons.choice == .originalLaunchpad, "Failed layout save rolls back the icon")
            try check(launcher.state == original && defaults.integer(forKey: "columns") == 9 && defaults.integer(forKey: "rows") == 7,
                      "Failed reset keeps the layout and grid preferences")
            try check(defaults.stringArray(forKey: "additionalAppPaths") == ["/tmp/extra-apps"], "Failed reset keeps added search locations")
        }
        try launcher.restoreFeatureDefaults(appIcons: icons, defaults: defaults)
        try check(icons.choice == .launchpod, "Reset restores the Launchpod icon")
        try check(defaults.object(forKey: "columns") == nil && defaults.object(forKey: "rows") == nil,
                  "Reset restores the default 7 by 5 grid")
        try check(defaults.object(forKey: "additionalAppPaths") == nil, "Reset removes only additional search locations")
        try check(launcher.state.hidden.isEmpty && launcher.state.pages == [["f", "folder", "a", "e", "d"]],
                  "Hidden apps return without changing the existing item order")
        try check(launcher.state.folders == original.folders, "Folder identity, title and child order survive reset")
        try check(try launcher.store.load() == launcher.state, "Restored visibility is persisted")
        for (key, value) in preserved {
            try check(NSDictionary(dictionary: [key: defaults.object(forKey: key)!]).isEqual(to: [key: value]),
                      "Reset preserves unrelated preference " + key)
        }
        launcher.mutate("Placement reset fixture") { $0 = fixture }
        let preferencesBefore = UserDefaults.standard.dictionaryRepresentation()
        settings.model.requestAppPlacementReset(confirm: { true })
        let resetPlacement = launcher.state
        try check(settings.model.error == nil, "Successful placement reset clears an earlier error")
        try check(resetPlacement.folders.isEmpty && resetPlacement.pages == [["a", "b", "c", "e", "f"]],
                  "Placement reset removes custom folders and sorts visible apps")
        try check(resetPlacement.hidden == ["d"], "Placement reset keeps hidden apps hidden")
        try check(try launcher.store.load() == resetPlacement, "Placement reset persists to the isolated layout")
        try check(NSDictionary(dictionary: preferencesBefore).isEqual(to: UserDefaults.standard.dictionaryRepresentation()),
                  "Placement reset leaves all settings unchanged")
        launcher.undoLayout()
        try check(launcher.state == fixture, "Undo restores original folders, order and hiding")
        launcher.redoLayout()
        try check(launcher.state == resetPlacement, "Redo restores the default arrangement")
        try check(settings.reset.actions.map(\.id) == ["language", "features"], "General includes language and feature reset actions")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let report = "PASS: \(checks) resident startup, status menu, feature-reset and placement-reset checks. Isolated preferences/layout; no login registration or production reset.\n"
        try report.write(to: outputDirectory.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}
