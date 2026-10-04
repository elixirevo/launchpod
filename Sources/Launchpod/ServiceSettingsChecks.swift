import AppKit
import Carbon
import MacAppCore
import MacAppSettings

@MainActor enum ServiceSettingsChecks {
    static func run(outputDirectory: URL) throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "Launchpod.ServiceSettingsChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let domain = "app.launchpod.ServiceSettingsChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var registered: SettingsShortcut?
        var rejectedCode: UInt16?
        let hotKey = HotKey(defaults: defaults, register: { candidate in
            if let candidate, candidate.keyCode == rejectedCode { return -9878 }
            registered = candidate; return 0
        })
        try check(hotKey.shortcut?.displayTitle == "⌃⌥L", "Fresh shortcut retains the old default")
        defaults.set(40, forKey: "hotKeyCode")
        defaults.set(cmdKey | shiftKey, forKey: "hotKeyModifiers")
        defaults.set("⇧⌘K", forKey: "hotKeyLabel")
        let legacy = hotKey.shortcut
        try check(legacy?.keyCode == 40 && legacy?.modifierFlags == [.command, .shift] && legacy?.keyLabel == "K", "Legacy Carbon preferences map to the library shortcut")
        try check(hotKey.registerSaved() == 0 && registered == legacy, "Saved shortcut is registered")
        let model = hotKey.settingsModel()
        let id = "toggle-launchpod"
        model.beginRecording(id: id)
        try check(hotKey.isRecording && registered == nil, "Recording suspends the native shortcut")
        model.stopRecording()
        try check(!hotKey.isRecording && registered == legacy, "Cancel resumes the saved shortcut")
        let replacement = SettingsShortcut(keyCode: 35, modifiers: [.control, .option], keyLabel: "P")
        rejectedCode = replacement.keyCode
        model.setShortcut(replacement, for: id)
        try check(hotKey.shortcut == legacy && registered == legacy && model.errors[id] != nil, "Failed replacement preserves registration, preferences and UI value")
        model.beginRecording(id: id)
        model.setShortcut(replacement, for: id)
        try check(model.recordingID == id && hotKey.shortcut == legacy && registered == nil, "A failed recorded shortcut stays editable without overwriting saved keys")
        model.stopRecording()
        try check(registered == legacy, "Cancel after failure restores the old shortcut")
        rejectedCode = nil
        model.beginRecording(id: id)
        model.setShortcut(replacement, for: id)
        try check(model.recordingID == nil && !hotKey.isRecording && registered == replacement, "Successful recording resumes the new shortcut")
        try check(defaults.integer(forKey: "hotKeyModifiers") == controlKey | optionKey, "Saving keeps the existing Carbon preference format")
        model.setShortcut(nil, for: id)
        try check(hotKey.shortcut == nil && registered == nil && model.values[id] == nil, "Clear removes the global shortcut")
        let relaunched = HotKey(defaults: defaults, register: { _ in 0 })
        try check(relaunched.shortcut == nil, "Cleared shortcut stays disabled after relaunch")
        model.setShortcut(replacement, for: id)
        try check(relaunched.shortcut == replacement, "A cleared shortcut can be configured again")

        let consent = CrashReportingPreference(defaults: defaults)
        try check(!consent.activeEnabled && !consent.selection, "Crash reporting defaults to off")
        consent.select(true)
        try check(!consent.activeEnabled && consent.selection && consent.requiresRestart, "Opt-in is saved but does not activate reporting in this process")
        let nextLaunch = CrashReportingPreference(defaults: defaults)
        try check(nextLaunch.activeEnabled && !nextLaunch.requiresRestart, "The next launch reads the saved opt-in")
        nextLaunch.select(false)
        try check(nextLaunch.activeEnabled && !nextLaunch.selection && nextLaunch.requiresRestart, "Opt-out describes the same restart boundary")
        try check(!CrashReportingPreference(defaults: defaults).activeEnabled, "The following launch is opted out")
        let diagnostics = AppDiagnostics(isolated: true)
        diagnostics.prepare()
        try check(diagnostics.service?.isRunning == false, "Preparing onboarding configuration never starts Sentry")
        diagnostics.preference.select(true)
        try check(!diagnostics.preference.activeEnabled, "Opting in during setup preserves the launch-time consent boundary")
        diagnostics.start()
        try check(diagnostics.service != nil && diagnostics.error == nil, "The packaged public Sentry configuration loads")
        try check(diagnostics.service?.isRunning == false, "Isolated checks do not initialize Sentry")
        let service = diagnostics.service
        diagnostics.start()
        try check(diagnostics.service === service, "The app retains one diagnostics service for its lifetime")
        try check(service?.configuration.release == "\(Bundle.main.bundleIdentifier!)@\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")!)+\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")!)", "Sentry uses the app release metadata")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let report = "PASS: \(checks) shortcut, consent and bundled Sentry checks\nNo global shortcut, system permission or crash-report transmission was performed.\n"
        try report.write(to: outputDirectory.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}
