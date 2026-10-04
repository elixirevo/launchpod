import AppKit
import ApplicationServices
import MacAppSettings

/// Compatibility entry point for the shared permission checks. Startup now uses onboarding.
@MainActor enum StartupPermissionChecks {
    static func run(outputDirectory: URL) async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "StartupPermissionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks += 1
        }
        var status = SettingsPermissionStatus.notGranted
        var presented = 0, requested = 0
        var response = NSApplication.ModalResponse.alertSecondButtonReturn
        var probeFails = false
        let model = PermissionSettingsModel([
            SettingsPermission(id: "accessibility", title: "Accessibility", detail: "Trackpad gestures",
                readStatus: { if probeFails { throw CocoaError(.fileReadUnknown) }; return status },
                request: { requested += 1 })
        ], presentRequest: { _ in presented += 1; return response })
        let permissions = AppPermissions(settings: model)
        await permissions.settings.refresh()
        try check(presented == 0 && requested == 0, "Creating and refreshing permission controls never requests access")
        await permissions.settings.requestAccess(id: "accessibility")
        try check(presented == 1 && requested == 0, "Later cancels the library explanation")
        response = .alertFirstButtonReturn
        await permissions.settings.requestAccess(id: "accessibility")
        try check(presented == 2 && requested == 1, "An explicit confirmed request opens permission settings once")
        try check(model.statuses["accessibility"] == .notGranted, "Opening settings does not imply permission was granted")
        status = .granted
        await model.refresh()
        await model.requestAccess(id: "accessibility")
        try check(presented == 2 && model.statuses["accessibility"] == .granted, "Granted permission is refreshed without another prompt")
        probeFails = true
        await model.refresh()
        try check(model.statuses["accessibility"] == .unknown && presented == 2, "Probe failure stays unknown and does not prompt")
        try check(TrackpadGesture.hasPermission == AXIsProcessTrusted(), "Runtime uses the same read-only Accessibility probe")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let report = "PASS: \(checks) shared permission checks\nNo system prompt or settings change was performed.\n"
        try report.write(to: outputDirectory.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}
