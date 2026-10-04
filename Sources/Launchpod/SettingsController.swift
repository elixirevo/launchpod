import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LaunchpodCore
import MacAppCore
import MacAppSettings

@MainActor
final class SettingsController {
    let model: LaunchpodSettingsModel
    let navigation = SettingsNavigation()
    let pages: SettingsPages
    let language: AppLanguageSettings
    let shortcuts: ShortcutSettingsModel
    let permissions: PermissionSettingsModel
    let support: SupportSettingsModel
    let reset: SettingsResetModel
    private let host: SettingsWindowController
    var window: NSWindow? { host.window }

    init(launcher: LauncherController, appIcons: AppIconSettings? = nil,
         trackpadGesture: TrackpadGesture? = nil, hotCorners: HotCornerMonitor? = nil,
         showOnboarding: (() -> Void)? = nil) {
        let model = LaunchpodSettingsModel(launcher: launcher, appIcons: appIcons ?? launcher.appIcons,
            trackpadGesture: trackpadGesture ?? launcher.trackpadGesture, hotCorners: hotCorners ?? launcher.hotCorners)
        self.model = model
        let isolated = CommandLine.arguments.contains("--data-dir")
        let language = isolated ? AppLanguageSettings(activeSelection: AppLocalizer.current.selection, save: { _ in }) : .shared
        self.language = language
        let shortcuts: ShortcutSettingsModel
        if isolated {
            let domain = "app.launchpod.ShortcutPreview.\(ProcessInfo.processInfo.processIdentifier)"
            let defaults = UserDefaults(suiteName: domain)!
            defaults.removePersistentDomain(forName: domain)
            shortcuts = HotKey(defaults: defaults, register: { _ in 0 }).settingsModel()
        } else { shortcuts = HotKey.shared.settingsModel() }
        self.shortcuts = shortcuts
        let permissions = (NSApp.delegate as? AppDelegate)?.permissions.settings ?? AppPermissions().settings
        self.permissions = permissions
        let diagnostics = (NSApp.delegate as? AppDelegate)?.diagnostics
        let pages = try! SettingsPages([
            .builtIn(.general),
            .custom(id: "launchpod", title: L10n.text("Features", "기능"), symbol: "display",
                    color: Color(red: 0.30, green: 0.68, blue: 0.94)) {
                LaunchpodSettingsContent(model: model)
            },
            .builtIn(.shortcuts), .builtIn(.permissions), .builtIn(.updates), .support, .builtIn(.about)
        ])
        self.pages = pages
        navigation.configure(pages)
        let identity = SettingsIdentity(icon: model.appIcons.image(for: model.appIcons.choice),
            website: URL(string: "https://github.com/elixirevo/launchpod")!)
        let delegate = NSApp.delegate as? AppDelegate
        let review = showOnboarding ?? (delegate?.onboarding == nil ? nil : { [weak delegate] in
            delegate?.showOnboardingForReview()
        })
        let support = try! SupportSettingsModel(diagnostics: .init(identity: identity), links: [
            try! SupportLink(.help, url: URL(string: "https://github.com/elixirevo/launchpod#readme")!),
            try! SupportLink(.contact, url: URL(string: "mailto:elixirevo@gmail.com")!),
            try! SupportLink(.reportIssue, url: URL(string: "https://github.com/elixirevo/launchpod/issues")!)
        ], showOnboarding: review)
        self.support = support
        // Reset actions live in General; their normal controls remain on the Features page.
        let reset = try! SettingsResetModel(actions: [
            SettingsResetAction(id: "language", title: L10n.text("Language", "언어"),
                detail: L10n.text("Use the system language on the next launch. Your layout and other preferences are kept.",
                                  "다음 실행부터 시스템 언어를 사용합니다. 배치와 나머지 설정은 유지됩니다.")) {
                language.select(.system)
            },
            SettingsResetAction(id: "features", title: L10n.text("Features", "기능"),
                detail: L10n.text("Restore the 7 × 5 grid and Launchpod icon, clear added search locations, and show hidden apps. App order and folders are kept.",
                                  "격자를 7 × 5로, 앱 아이콘을 Launchpod로 복원하고 추가 검색 위치와 앱 숨김을 초기화합니다. 앱 순서와 폴더는 유지됩니다.")) {
                try model.restoreFeatures()
            }
        ])
        self.reset = reset
        let updates: UpdateSettingsModel
        if let updater = (NSApp.delegate as? AppDelegate)?.updates, updater.isAvailable {
            updates = UpdateSettingsModel(canCheck: { updater.canCheck },
                automaticChecks: .init(read: { updater.automaticChecks }, write: { updater.automaticChecks = $0 })) {
                updater.check()
                return .handledExternally
            }
            updater.onSettingsChanged = { [weak updates] in
                updates?.refreshAutomaticChecks(); updates?.refreshAvailability()
            }
        } else {
            updates = UpdateSettingsModel(unavailableReason: L10n.text("Updates are not available in this build.", "이 빌드에서는 업데이트를 사용할 수 없습니다."))
        }
        let login = isolated ? nil : LaunchAtLoginModel()
        let navigation = self.navigation
        host = SettingsWindowController(title: L10n.text("Launchpod Settings", "Launchpod 설정"),
            autosaveName: isolated ? "Launchpod.Settings.Checks" : "Launchpod.Settings", navigation: navigation,
            onClose: { shortcuts.stopRecording() }) {
                AppSettingsView(identity: identity, navigation: navigation,
                    shortcuts: shortcuts, permissions: permissions,
                    updates: updates, language: language, launchAtLogin: login, pages: pages,
                    support: support, reset: reset, supportContent: { AnyView(LegalSettingsSection()) }, shortcutsContent: { AnyView(LaunchpodTriggerSettings(model: model)) }) {
                        if let diagnostics, diagnostics.service != nil {
                            DiagnosticsSettingsSection(preference: diagnostics.preference)
                        } else if let error = diagnostics?.error {
                            SettingsSection(L10n.text("Diagnostics", "진단")) { Text(error) }
                        }
                    }
            }
    }

    func showWindow(_ sender: Any?) { host.show() }
    func close() { host.close() }
}

@MainActor
final class LaunchpodSettingsModel: ObservableObject {
    weak var launcher: LauncherController?
    let appIcons: AppIconSettings
    let trackpadGesture: TrackpadGesture
    let hotCorners: HotCornerMonitor
    @Published var error: String?
    private var observers: [NSObjectProtocol] = []

    init(launcher: LauncherController, appIcons: AppIconSettings, trackpadGesture: TrackpadGesture, hotCorners: HotCornerMonitor) {
        self.launcher = launcher; self.appIcons = appIcons
        self.trackpadGesture = trackpadGesture; self.hotCorners = hotCorners
        observers.append(NotificationCenter.default.addObserver(forName: TrackpadGesture.settingsChanged,
            object: trackpadGesture, queue: .main) { [weak self] _ in self?.objectWillChange.send() })
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    var columns: Int { launcher?.launcherView.columns ?? 7 }
    var rows: Int { launcher?.launcherView.rows ?? 5 }
    func grid(columns: Int, rows: Int) {
        UserDefaults.standard.set(columns, forKey: "columns"); UserDefaults.standard.set(rows, forKey: "rows")
        launcher?.mutate(L10n.text("Change Grid Size", "격자 크기 변경")) {
            $0.normalize(capacity: columns * rows, folderCapacity: columns * FolderStyle.maximumRows)
        }
        objectWillChange.send()
    }
    func restoreFeatures() throws {
        guard let launcher else { throw CocoaError(.fileWriteUnknown) }
        try launcher.restoreFeatureDefaults(appIcons: appIcons)
        error = nil
        objectWillChange.send()
    }
    func selectIcon(_ choice: AppIconChoice) {
        do { try appIcons.select(choice); launcher?.rescan(); error = nil }
        catch { self.error = error.localizedDescription }
        objectWillChange.send()
    }
    func setCorner(_ corner: HotCorner, enabled: Bool) {
        var corners = hotCorners.enabledCorners
        if enabled { corners.insert(corner) } else { corners.remove(corner) }
        hotCorners.configure(corners: corners); objectWillChange.send()
    }
    func gesture(enabled: Bool, choice: LauncherGestureChoice) {
        trackpadGesture.configure(enabled: enabled, choice: choice); objectWillChange.send()
    }
    var gestureStatus: String {
        switch trackpadGesture.status {
        case .off: return L10n.text("Gesture detection is off.", "제스처 감지가 꺼져 있습니다.")
        case .permissionRequired: return L10n.text("Enable Launchpod in Accessibility settings.", "손쉬운 사용 권한에서 Launchpod를 켜 주세요.")
        case .listening: return L10n.text("Pinch to open; spread your fingers to close.", "손가락을 오므리면 열리고, 벌리면 닫힙니다.")
        case .unavailable: return L10n.text("Could not start gesture detection. Check Accessibility permissions and try again.", "제스처 감지를 시작하지 못했습니다. 손쉬운 사용 권한을 확인한 뒤 다시 시도해 주세요.")
        }
    }
    func importCurrent() {
        guard let url = LegacyImporter.currentDatabaseURL else {
            error = L10n.text("No legacy Launchpad database was found on this Mac. Choose a database file from an older Mac.", "이 Mac에서 기존 Launchpad DB를 찾지 못했습니다. 구형 Mac에서 가져온 DB 파일을 선택해 주세요."); return
        }
        launcher?.importLegacy(url)
    }
    func importDatabase() {
        let panel = NSOpenPanel(); panel.message = L10n.text("Choose the legacy Launchpad database file.", "기존 Launchpad의 db 파일을 선택하세요.")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { launcher?.importLegacy(url) }
    }
    func importLayout() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { launcher?.importLayout(url) }
    }
    func addLocation() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = L10n.text("Choose app bundles or folders containing apps.", "앱 묶음 또는 앱이 들어 있는 폴더를 선택하세요.")
        if panel.runModal() == .OK { launcher?.addApplicationURLs(panel.urls) }
    }
}

@MainActor private struct LaunchpodSettingsContent: View {
    @ObservedObject var model: LaunchpodSettingsModel
    var body: some View {
        Group {
            SettingsSection(L10n.text("Appearance", "모양")) {
                SettingsPicker(L10n.text("Columns", "열"), selection: Binding(get: { model.columns }, set: { model.grid(columns: $0, rows: model.rows) })) {
                    ForEach(3...9, id: \.self) { Text(String($0)).tag($0) }
                }
                SettingsPicker(L10n.text("Rows", "행"), selection: Binding(get: { model.rows }, set: { model.grid(columns: model.columns, rows: $0) })) {
                    ForEach(3...7, id: \.self) { Text(String($0)).tag($0) }
                }
                SettingsPicker(L10n.text("App icon", "앱 아이콘"), selection: Binding(get: { model.appIcons.choice }, set: model.selectIcon)) {
                    ForEach(AppIconChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsRow(L10n.text("Selected app icon", "선택한 앱 아이콘"), detail: L10n.text("Applies to the app file and Dock icon.", "앱 파일과 Dock 아이콘에 적용됩니다.")) {
                    if let icon = model.appIcons.image(for: model.appIcons.choice) {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48)
                    }
                }
            }
            SettingsSection(L10n.text("Layout", "배치")) {
                SettingsRow(L10n.text("Legacy Launchpad", "기존 Launchpad")) {
                    Button(L10n.text("Import This Mac’s Layout…", "이 Mac의 배치 가져오기…"), action: model.importCurrent)
                }
                SettingsRow(L10n.text("Saved Launchpad database", "저장한 Launchpad 데이터베이스")) {
                    Button(L10n.text("Choose Database…", "DB 파일 선택…"), action: model.importDatabase)
                }
                SettingsRow(L10n.text("Launchpod layout", "Launchpod 배치")) {
                    Button(L10n.text("Export…", "내보내기…")) { model.launcher?.exportLayout() }
                    Button(L10n.text("Import…", "가져오기…"), action: model.importLayout)
                }
            }
            SettingsSection(L10n.text("App library", "앱 목록")) {
                SettingsRow(L10n.text("Search locations", "검색 위치")) { Button(L10n.text("Add App / Folder…", "앱 / 폴더 추가…"), action: model.addLocation) }
                SettingsRow(L10n.text("Hidden apps", "숨긴 앱")) { Button(L10n.text("Restore All", "모두 복원")) { model.launcher?.showHidden() } }
                SettingsRow(L10n.text("Installed apps", "설치된 앱")) { Button(L10n.text("Rescan Apps", "앱 다시 검색")) { model.launcher?.rescan() } }
            }
            if let error = model.error { Text(error).foregroundColor(.red).textSelection(.enabled) }
        }
    }
}

@MainActor private struct LaunchpodTriggerSettings: View {
    @ObservedObject var model: LaunchpodSettingsModel
    var body: some View {
        Group {
            SettingsSection(L10n.text("Open / close Launchpod", "Launchpod 열기 / 닫기")) {
                SettingsRow("Launchpod") {
                    Button(L10n.text("Open Launchpod", "Launchpod 열기")) {
                        NSApp.keyWindow?.orderOut(nil); model.launcher?.show()
                    }
                }
                SettingsToggle(L10n.text("Open/close with gestures", "제스처로 열기/닫기"), isOn: Binding(get: { model.trackpadGesture.enabled }, set: { model.gesture(enabled: $0, choice: model.trackpadGesture.choice) }))
                SettingsPicker(L10n.text("Trackpad gesture", "트랙패드 제스처"), selection: Binding(get: { model.trackpadGesture.choice }, set: { model.gesture(enabled: model.trackpadGesture.enabled, choice: $0) })) {
                    ForEach(LauncherGestureChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(!model.trackpadGesture.enabled)
                Text(model.gestureStatus).font(.callout).foregroundStyle(.secondary)
            }
            SettingsSection(L10n.text("Hot corners", "핫 코너"), footer: L10n.text("Move the pointer to a selected corner on any display to open Launchpod. To avoid duplicate actions, set the same corners to “–” in System Settings → Desktop & Dock → Hot Corners. Launchpod must be running.", "화면의 선택한 모서리로 마우스를 옮기면 Launchpod가 열립니다. 모든 모니터에 적용됩니다. 중복 실행을 막으려면 시스템 설정 → 데스크탑 및 Dock → 핫 코너에서 같은 모서리를 ‘–’로 설정하세요. Launchpod가 실행 중이어야 합니다.")) {
                ForEach(HotCorner.allCases, id: \.self) { corner in
                    SettingsToggle(corner.title, isOn: Binding(get: { model.hotCorners.enabledCorners.contains(corner) }, set: { model.setCorner(corner, enabled: $0) }))
                }
            }
        }
    }
}
