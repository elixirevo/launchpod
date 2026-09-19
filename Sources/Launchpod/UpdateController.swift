import LaunchpodCore
import AppKit
import Sparkle

/// One updater for the lifetime of the menu-bar app. Unconfigured development
/// bundles and isolated UI checks must not contact the update server.
final class UpdateController: NSObject, NSMenuItemValidation, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    var beforeShowingUpdate: (() -> Void)?

    static func isConfigured(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    init(bundle: Bundle = .main, arguments: [String] = CommandLine.arguments) {
        super.init()
        guard !arguments.contains("--data-dir"), !arguments.contains("--preview-output"),
              bundle.bundleURL.pathExtension == "app",
              Self.isConfigured(bundle.infoDictionary ?? [:]) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: self)
        do {
            try controller.updater.start()
            self.controller = controller
        } catch {
            NSLog("Launchpod: updater could not start: %@", error.localizedDescription)
        }
    }

    func makeCheckMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.text("Check for Updates…", "업데이트 확인…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        if controller == nil { item.toolTip = L10n.text("Updates are not available in this build.", "이 빌드에서는 업데이트를 사용할 수 없습니다.") }
        return item
    }

    func makeAutomaticChecksMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.text("Automatically Check for Updates", "자동으로 업데이트 확인"), action: #selector(toggleAutomaticChecks(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let updater = controller?.updater else { return false }
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            menuItem.state = updater.automaticallyChecksForUpdates ? .on : .off
            return true
        }
        return updater.canCheckForUpdates
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        guard let controller = controller, controller.updater.canCheckForUpdates else { return }
        beforeShowingUpdate?()
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
    }

    @objc private func toggleAutomaticChecks(_ sender: Any?) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
    }

    func standardUserDriverWillShowModalAlert() {
        beforeShowingUpdate?()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { beforeShowingUpdate?() }
    }
}
