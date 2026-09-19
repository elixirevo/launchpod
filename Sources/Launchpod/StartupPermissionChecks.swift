import LaunchpodCore
import AppKit
import ApplicationServices

/// Exercise the real startup decision and buttons without changing OS grants.
enum StartupPermissionChecks {
    static func run(outputDirectory: URL) throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain:"StartupPermissionChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
            checks += 1
        }
        let domain = "app.launchpod.StartupPermissionChecks."+UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        var presented = 0, requested = 0
        var captured: NSAlert?
        let later: (NSAlert) -> NSApplication.ModalResponse = { alert in
            presented += 1; captured = alert; return .alertSecondButtonReturn
        }
        let request = { requested += 1 }
        let denied = TrackpadGesture(defaults:defaults,permissionAvailable:{ false })
        denied.promptForPermissionAtStartup(present:later,request:request)
        try check(presented == 1 && requested == 0,"missing permission shows a reminder; Later does not request access")
        try check(captured?.buttons.map(\.title) == [L10n.text("Open Permission Settings", "권한 설정하기"),L10n.text("Later", "나중에")],"startup alert offers setup and Later")
        try check(captured?.informativeText.contains(L10n.text("Accessibility", "손쉬운 사용")) == true,"alert explains the required permission")
        try check(captured?.window.level == .modalPanel,"alert stays above the floating launcher")
        denied.promptForPermissionAtStartup(present:later,request:request)
        try check(presented == 1,"reactivation cannot repeat the startup alert")
        let relaunched = TrackpadGesture(defaults:defaults,permissionAvailable:{ false })
        relaunched.promptForPermissionAtStartup(present:{ _ in presented += 1; return .alertFirstButtonReturn },request:request)
        try check(presented == 2 && requested == 1,"next launch reminds again and setup invokes permission flow once")
        let allowed = TrackpadGesture(defaults:defaults,permissionAvailable:{ true })
        allowed.promptForPermissionAtStartup(present:later,request:request)
        try check(presented == 2 && requested == 1,"already authorized launch does not show a reminder")
        defaults.set(false,forKey:"trackpadGestureEnabled")
        let disabled = TrackpadGesture(defaults:defaults,permissionAvailable:{ false })
        disabled.promptForPermissionAtStartup(present:later,request:request)
        try check(presented == 2 && requested == 1,"disabled gesture does not request unnecessary permission")
        defaults.set(true,forKey:"trackpadGestureEnabled")
        var granted = false
        let newlyGranted = TrackpadGesture(defaults:defaults,permissionAvailable:{ granted })
        granted = true
        newlyGranted.promptForPermissionAtStartup(present:later,request:request)
        try check(presented == 2,"permission is checked when the delayed alert would appear")
        try check(defaults.object(forKey:"trackpadGestureChoice") == nil,"reminder leaves gesture preferences unchanged")
        try check(!captured!.informativeText.contains(L10n.text("Input Monitoring", "입력 모니터링")),"startup does not direct users to the wrong service")
        var operations: [String] = []
        var openedURL: URL?
        let registration = TrackpadGesture(defaults:defaults,permissionAvailable:{ false })
        registration.requestPermission(openSettings:{ url in openedURL = url; operations.append("settings") })
        try check(operations == ["settings"],"setup opens Settings directly without requesting a second system alert")
        try check(openedURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility","setup navigates to Accessibility")
        try check(registration.status == .permissionRequired,"opening Settings alone cannot imply a grant")
        try check(captured?.informativeText.contains(L10n.text("+ button", "+ 버튼")) == true,"alert explains how to add an app absent from the permission list")
        operations = []
        let alreadyGranted = TrackpadGesture(defaults:defaults,permissionAvailable:{ true })
        // Disabled avoids starting a real event tap in this permission-only test.
        defaults.set(false,forKey:"trackpadGestureEnabled")
        alreadyGranted.requestPermission(openSettings:{ _ in operations.append("settings") })
        try check(operations.isEmpty,"already authorized users are not prompted or redirected")
        defaults.set(true,forKey:"trackpadGestureEnabled")
        var explanations = 0
        let setup = TrackpadGesture(defaults:defaults,permissionAvailable:{ false })
        setup.promptForPermissionAtStartup(present:{ _ in explanations += 1; return .alertFirstButtonReturn },
            request:{ setup.requestPermission(openSettings:{ _ in operations.append("settings") }) })
        try check(explanations == 1 && operations == ["settings"],"startup setup flow shows exactly one explanation then opens Settings")
        try check(TrackpadGesture.hasPermission == AXIsProcessTrusted(),"runtime checks the same Accessibility service as LaunchOS")
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        let report = "PASS: \(checks) startup permission checks\nNo system permission prompt or settings change was performed.\n"
        try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        print(report)
    }
}
