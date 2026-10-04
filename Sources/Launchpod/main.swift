#if !arch(arm64)
#error("Launchpod supports Apple Silicon (arm64) Macs only.")
#endif

import AppKit
import LaunchpodCore
import MacAppCore
import MacAppSettings
import MacAppOnboarding

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var launcher: LauncherController!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private(set) var updates: UpdateController!
    private(set) var diagnostics: AppDiagnostics!
    private(set) var permissions: AppPermissions!
    private(set) var startup: AppStartup?
    var onboarding: AppOnboarding? { startup?.onboarding }
    private var featuresStarted = false
    private var isolatedChecks = false
    private var allowsAppFeatures: Bool { featuresStarted && (isolatedChecks || startup?.allowsAppUse == true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let isolated = args.contains("--data-dir") || args.contains("--preview-output")
        let preview = isolated && (args.contains("--preview-onboarding") || args.contains("--preview-terms"))
        isolatedChecks = isolated && !preview
        permissions = preview ? AppPermissions.preview() : AppPermissions()
        diagnostics = AppDiagnostics(isolated: isolated)
        diagnostics.prepare()
        if isolatedChecks { startLauncher(); return }
        // No launcher/catalog, global input listener, updater, SDK or Dock mutation before agreement.
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        item.submenu = appMenu; menu.addItem(item)
        appMenu.addItem(NSMenuItem(title: L10n.text("Quit Launchpod", "Launchpod 종료"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(), editMenu = NSMenu(title: L10n.text("Edit", "편집"))
        editItem.submenu = editMenu; menu.addItem(editItem)
        editMenu.addItem(NSMenuItem(title: L10n.text("Copy", "복사"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.text("Select All", "모두 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        NSApp.mainMenu = menu
        configureStartup(preview: preview)
    }

    @MainActor private func configureStartup(preview: Bool) {
        do {
            var receipt: TermsAcceptance?
            let icons = AppIconSettings()
            startup = try AppStartup(identity: SettingsIdentity(icon: icons.image(for: icons.choice)),
                permissions: permissions.settings, reporting: diagnostics.service == nil ? nil : diagnostics.preference,
                acceptanceStore: preview ? .init(read: { receipt }, write: { receipt = $0 }) : nil,
                onboardingStore: preview ? .init(readCompletedVersion: {
                    CommandLine.arguments.contains("--preview-terms") ? AppOnboarding.version : 0
                }, writeCompletedVersion: { _ in }) : nil,
                autosavePrefix: preview ? "Launchpod.Preview" : "Launchpod",
                startFeatures: { [weak self] in self?.startLauncher() },
                resumeFeatures: { [weak self] in self?.launcher?.show() })
            startup?.begin()
        } catch {
            // Missing legal resources must never silently unlock the app.
            let alert = NSAlert()
            alert.messageText = L10n.text("Unable to load the Terms of Use", "이용약관을 불러올 수 없습니다")
            alert.informativeText = L10n.text("Retry or quit and reinstall Launchpod. Your existing data has not been changed.",
                "다시 시도하거나 종료 후 Launchpod를 다시 설치해 주세요. 기존 데이터는 변경되지 않았습니다.")
            alert.addButton(withTitle: L10n.text("Quit", "종료"))
            alert.addButton(withTitle: L10n.text("Retry", "다시 시도"))
            if alert.runModal() == .alertSecondButtonReturn {
                DispatchQueue.main.async { [weak self] in self?.configureStartup(preview: preview) }
            } else { NSApp.terminate(nil) }
        }
    }

    @MainActor private func startLauncher() {
        guard !featuresStarted, isolatedChecks || startup?.allowsAppUse == true else { return }
        featuresStarted = true
        let startup = ProcessInfo.processInfo.systemUptime
        let args = CommandLine.arguments
        let isolated = args.contains("--data-dir") || args.contains("--preview-output")
        diagnostics.start()
        updates = UpdateController()
        updates.beforeShowingUpdate = { [weak self] in self?.launcher?.dismiss(restoreFocus:false) }
        NotificationCenter.default.addObserver(self, selector:#selector(languageChanged), name:L10n.didChange, object:nil)
        buildMenu()
        launcher = LauncherController()
        launcher.canUseApp = { [weak self] in self?.allowsAppFeatures == true }
        launcher.appIcons.applySavedChoice()
        HotKey.shared.action = { [weak self] in self?.toggle() }
        if !isolated {
            let hotKeyStatus = HotKey.shared.registerSaved()
            if hotKeyStatus != 0 { NSLog("Launchpod: hotkey registration failed (%d). Change it in Settings.",hotKeyStatus) }
        }
        buildStatusMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Launchpod")
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp,.rightMouseUp])
        restoreDockShortcutIfNeeded()
        launcher.trackpadGesture.isLauncherShown = { [weak self] in self?.launcher.isShown ?? false }
        launcher.trackpadGesture.onClose = { [weak self] in
            guard self?.allowsAppFeatures == true, NSApp.modalWindow == nil, NSEvent.pressedMouseButtons == 0, self?.onboarding?.isVisible != true else { return }
            self?.launcher.dismiss()
        }
        launcher.trackpadGesture.onOpen = { [weak self] in
            guard self?.allowsAppFeatures == true, NSApp.modalWindow == nil, NSEvent.pressedMouseButtons == 0, self?.onboarding?.isVisible != true else { return }
            self?.launcher.show()
        }
        launcher.hotCorners.canOpen = { [weak self] in self?.allowsAppFeatures == true && self?.launcher.isShown == false && self?.onboarding?.isVisible != true }
        launcher.hotCorners.onOpen = { [weak self] screen in self?.launcher.show(on:screen) }
        // Isolated layout/test runs must not install another global listener.
        if !args.contains("--data-dir") && !args.contains("--preview-output") {
            launcher.trackpadGesture.start()
            launcher.hotCorners.start()
        }
        if let i = args.firstIndex(of:"--app-collection-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                self.launcher.show()
                self.launcher.launcherView.runAppCollectionChecks(outputDirectory:URL(fileURLWithPath:args[i+1])) { result in
                    switch result {
                    case .success: NSApp.terminate(nil)
                    case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--editing-page-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                self.launcher.show()
                self.launcher.launcherView.runEditingPageChecks(outputDirectory:URL(fileURLWithPath:args[i+1])) { result in
                    switch result {
                    case .success: NSApp.terminate(nil)
                    case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--outside-click-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                self?.launcher.runOutsideClickChecks(outputDirectory:URL(fileURLWithPath:args[i+1])) { result in
                    switch result {
                    case .success: NSApp.terminate(nil)
                    case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--startup-rendering-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                self?.launcher.runStartupRenderingChecks(outputDirectory:URL(fileURLWithPath:args[i+1])) { result in
                    switch result {
                    case .success: NSApp.terminate(nil)
                    case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--hot-corner-settings-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                let domain = "app.launchpod.HotCornerSettingsChecks."+UUID().uuidString
                let defaults = UserDefaults(suiteName:domain)!
                let monitor = HotCornerMonitor(defaults:defaults)
                let settings = SettingsController(launcher:self.launcher,hotCorners:monitor)
                defer {
                    monitor.stop(); defaults.removePersistentDomain(forName:domain)
                    L10n.defaults.removePersistentDomain(forName:"app.launchpod.LanguageUIChecks.\(ProcessInfo.processInfo.processIdentifier)")
                }
                settings.showWindow(nil)
                do {
                    try settings.runHotCornerSettingsChecks(defaults:defaults,outputDirectory:URL(fileURLWithPath:args[i+1]))
                    settings.close(); NSApp.terminate(nil)
                } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
            }
        } else if let i = args.firstIndex(of:"--language-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                let settings = SettingsController(launcher:self.launcher, showOnboarding: {})
                settings.showWindow(nil)
                do {
                    try settings.runLanguageChecks(outputDirectory:URL(fileURLWithPath:args[i+1]))
                    settings.close(); NSApp.terminate(nil)
                } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
            }
        } else if let i = args.firstIndex(of:"--gesture-settings-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                let output = URL(fileURLWithPath:args[i+1])
                let domain = "app.launchpod.GestureSettingsChecks."+UUID().uuidString
                let defaults = UserDefaults(suiteName:domain)!
                let monitor = TrackpadGesture(defaults:defaults, permissionAvailable: { false })
                let settings = SettingsController(launcher:self.launcher,trackpadGesture:monitor)
                settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
                    do {
                        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                        try settings.runGestureSettingsChecks(outputDirectory:output)
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                            defer { monitor.stop(); defaults.removePersistentDomain(forName:domain) }
                            do { try settings.captureGestureSettings(outputDirectory:output); settings.close(); NSApp.terminate(nil) }
                            catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
                        }
                    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
                }
            }
        } else if let i = args.firstIndex(of:"--drag-refinement-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                self.launcher.show()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    let output = URL(fileURLWithPath:args[i+1])
                    do { try DockDragChecks.run(outputDirectory:output) }
                    catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
                    self.launcher.launcherView.runPageDropChecks(outputDirectory:output) { result in
                        switch result {
                        case .success: NSApp.terminate(nil)
                        case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                        }
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--menu-visibility-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                self?.launcher.runMenuVisibilityChecks(outputDirectory:URL(fileURLWithPath:args[i+1])) { result in
                    switch result {
                    case .success: NSApp.terminate(nil)
                    case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--optimization-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                self.launcher.show()
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                    self.launcher.launcherView.runOptimizationChecks(outputDirectory:URL(fileURLWithPath:args[i+1])) { result in
                        switch result {
                        case .success: NSApp.terminate(nil)
                        case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                        }
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--alignment-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                self.launcher.show()
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                    let output = URL(fileURLWithPath:args[i+1])
                    do { try self.launcher.launcherView.runPageAlignmentChecks(outputDirectory:output) }
                    catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
                    // Let WindowServer present the restored size before capture.
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                        do {
                            guard let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,
                                CGWindowID(self.launcher.window.windowNumber),[.boundsIgnoreFraming]),
                                let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else {
                                throw NSError(domain:"Launchpod.Alignment",code:1,userInfo:[NSLocalizedDescriptionKey:"Cannot capture alignment window"])
                            }
                            try png.write(to:output.appendingPathComponent("grid-current.png")); NSApp.terminate(nil)
                        } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
                    }
                }
            }
        } else if let i = args.firstIndex(of:"--icon-size-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                self.launcher.show()
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                    do {
                        try self.launcher.launcherView.runIconSizeChecks(outputDirectory:URL(fileURLWithPath:args[i+1]))
                        NSApp.terminate(nil)
                    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
                }
            }
        } else if let i = args.firstIndex(of:"--icon-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                do {
                    let output = URL(fileURLWithPath:args[i+1])
                    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                    let domainFile = output.appendingPathComponent("preferences-domain.txt")
                    let domain: String
                    if FileManager.default.fileExists(atPath:domainFile.path) { domain = try String(contentsOf:domainFile) }
                    else {
                        domain = "app.launchpod.IconChecks."+UUID().uuidString
                        try domain.write(to:domainFile,atomically:true,encoding:.utf8)
                    }
                    guard domain.hasPrefix("app.launchpod.IconChecks."), let defaults = UserDefaults(suiteName:domain) else {
                        throw NSError(domain:"Launchpod.IconChecks",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid isolated icon preferences"])
                    }
                    let phase = args.firstIndex(of:"--icon-check-phase").flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } ?? "select-original"
                    let icons = AppIconSettings(defaults:defaults); icons.applySavedChoice()
                    let settings = SettingsController(launcher:self.launcher,appIcons:icons)
                    settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                        do {
                            try settings.runAppIconChecks(outputDirectory:output,phase:phase)
                            defaults.synchronize()
                            if phase == "restore-default" { defaults.removePersistentDomain(forName:domain); defaults.synchronize() }
                            settings.close(); NSApp.terminate(nil)
                        } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
                    }
                } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
            }
        } else if let i = args.firstIndex(of:"--extraction-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            // Targeted folder-extraction regression checks, without the other
            // UI suites. Require an explicit isolated layout directory.
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                self.launcher.show()
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                    self.launcher.launcherView.runExtractionChecks(outputDirectory:URL(fileURLWithPath:args[i+1])) { result in
                        switch result {
                        case .success: NSApp.terminate(nil)
                        case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                        }
                    }
                }
            }
        } else if let i = args.firstIndex(of: "--ui-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
            launcher.onFirstScan = { [weak self] in
                guard let self = self else { return }
                // These older drag scenarios require densely populated root
                // pages. System grouping has its own migration checks.
                let apps = self.launcher.state.apps
                self.launcher.mutate("Isolated UI fixture") { layout in
                    layout = LayoutState()
                    layout.reconcile(apps,capacity:self.launcher.launcherView.capacity,folderCapacity:self.launcher.launcherView.folderCapacity)
                    layout.didGroupSystemApps = true; layout.systemFolderPolicyVersion = 2
                }
                print(String(format: "Catalog and initial view: %.0f ms", (ProcessInfo.processInfo.systemUptime-startup)*1000))
                self.launcher.show()
                print(String(format: "Window prepared: %.0f ms", (ProcessInfo.processInfo.systemUptime-startup)*1000))
                DispatchQueue.main.asyncAfter(deadline: .now()+1) {
                    do {
                        try self.launcher.launcherView.runUIChecks(outputDirectory: URL(fileURLWithPath: args[i+1]))
                        self.launcher.launcherView.runInteractionChecks(outputDirectory: URL(fileURLWithPath: args[i+1])) { result in
                            switch result {
                            case .success:
                                self.launcher.launcherView.runDragChecks(outputDirectory: URL(fileURLWithPath: args[i+1])) { result in
                                    switch result {
                                    case .success: NSApp.terminate(nil)
                                    case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                                    }
                                }
                            case .failure(let error): fputs("\(error.localizedDescription)\n",stderr); exit(1)
                            }
                        }
                    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
                }
            }
        } else if let i = args.firstIndex(of: "--onboarding-artwork"), args.indices.contains(i+1), args.contains("--data-dir"), args.contains("--windowed") {
            launcher.onFirstScan = { [weak self] in
                self?.launcher.launcherView.captureOnboardingArtwork(to: URL(fileURLWithPath: args[i+1])) { result in
                    switch result {
                    case .success: NSApp.terminate(nil)
                    case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); exit(1)
                    }
                }
            }
        } else if let i = args.firstIndex(of: "--preview-output"), args.indices.contains(i+1) {
            launcher.onFirstScan = { [weak self] in self?.launcher.writePreview(to: args[i+1]) }
        } else {
            launcher.show()
        }
    }
    @MainActor @discardableResult private func showOnboardingIfNeeded() -> Bool {
        guard let startup else { return !isolatedChecks && !featuresStarted }
        let presented = startup.presentIfNeeded()
        if presented { launcher?.dismiss(restoreFocus: false) }
        return presented
    }
    private func restoreDockShortcutIfNeeded() {
        let args = CommandLine.arguments
        guard !args.contains("--data-dir"), !args.contains("--preview-output") else { return }
        DockShortcut.addIfNeeded()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !showOnboardingIfNeeded(), allowsAppFeatures {
            restoreDockShortcutIfNeeded(); launcher?.toggle()
        }; return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { launcher?.prepareForTermination() }
    @objc private func languageChanged() {
        guard allowsAppFeatures else { return }
        buildMenu()
        buildStatusMenu()
        launcher?.launcherView.refreshLanguage()
    }
    private func buildStatusMenu() {
        statusMenu.removeAllItems()
        let show = NSMenuItem(title: L10n.text("Open Launchpod", "Launchpod 열기"), action: #selector(toggle), keyEquivalent: "")
        show.target = self; statusMenu.addItem(show)
        let settings = NSMenuItem(title: L10n.text("Settings…", "설정…"), action: #selector(settings), keyEquivalent: "")
        settings.target = self; statusMenu.addItem(settings)
        statusMenu.addItem(updates.makeCheckMenuItem())
        statusMenu.addItem(updates.makeAutomaticChecksMenuItem())
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: L10n.text("Quit", "종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    @MainActor @objc private func statusClicked(_ sender: Any?) {
        guard allowsAppFeatures else { _ = showOnboardingIfNeeded(); return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Reuse the startup menu. Attach only while tracking so a normal
            // left click continues to toggle the launcher instead of this menu.
            statusItem.menu = statusMenu
            defer { statusItem.menu = nil }
            statusItem.button?.performClick(nil)
        } else { toggle() }
    }
    @MainActor @objc private func toggle() {
        guard allowsAppFeatures else { _ = showOnboardingIfNeeded(); return }
        if onboarding?.isVisible == true { _ = showOnboardingIfNeeded() }
        else { launcher?.toggle() }
    }
    func showOnboardingForReview() {
        guard let onboarding else { return }
        do {
            launcher?.dismiss(restoreFocus: false)
            try onboarding.showForReview()
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("Could Not Open Introduction", "온보딩을 열 수 없습니다")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func settings() {
        guard allowsAppFeatures else { _ = showOnboardingIfNeeded(); return }
        launcher?.showSettings()
    }
    @objc private func undo() {
        guard allowsAppFeatures else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
        else { launcher?.undoLayout() }
    }
    @objc private func redo() {
        guard allowsAppFeatures else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.redo() }
        else { launcher?.redoLayout() }
    }
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let app = NSMenu(); appItem.submenu = app
        let preferences = NSMenuItem(title: L10n.text("Settings…", "설정…"), action: #selector(settings), keyEquivalent: ","); preferences.target = self
        app.addItem(preferences)
        app.addItem(updates.makeCheckMenuItem())
        app.addItem(updates.makeAutomaticChecksMenuItem())
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: L10n.text("Hide Launchpod", "Launchpod 가리기"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(NSMenuItem(title: L10n.text("Quit Launchpod", "Launchpod 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(appItem)
        let editItem = NSMenuItem(title: L10n.text("Edit", "편집"), action: nil, keyEquivalent: ""); let edit = NSMenu(title: L10n.text("Edit", "편집")); editItem.submenu = edit
        let undoItem = NSMenuItem(title: L10n.text("Undo Layout Change", "배치 실행 취소"), action: #selector(undo), keyEquivalent: "z"); undoItem.target = self; edit.addItem(undoItem)
        let redoItem = NSMenuItem(title: L10n.text("Redo Layout Change", "배치 다시 실행"), action: #selector(redo), keyEquivalent: "z"); redoItem.keyEquivalentModifierMask = [.command,.shift]; redoItem.target = self; edit.addItem(redoItem)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L10n.text("Cut", "오려두기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L10n.text("Copy", "복사"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L10n.text("Paste", "붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L10n.text("Select All", "모두 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(editItem); NSApp.mainMenu = main
    }
}

// Keep language smoke checks out of the user's preferences.
if CommandLine.arguments.contains("--language-checks") || CommandLine.arguments.contains("--hot-corner-settings-checks") {
    L10n.defaults = UserDefaults(suiteName:"app.launchpod.LanguageUIChecks.\(ProcessInfo.processInfo.processIdentifier)")!
    L10n.defaults.removePersistentDomain(forName:"app.launchpod.LanguageUIChecks.\(ProcessInfo.processInfo.processIdentifier)")
}
// Migrate before the first use of the immutable shared localizer.
if UserDefaults.standard.string(forKey: AppLocalizer.preferenceKey) == nil {
    let legacyLanguage = UserDefaults.standard.string(forKey: L10n.preferenceKey) ?? "en"
    if CommandLine.arguments.contains("--data-dir") || CommandLine.arguments.contains("--preview-output") {
        UserDefaults.standard.register(defaults: [AppLocalizer.preferenceKey: legacyLanguage])
    } else {
        UserDefaults.standard.set(legacyLanguage, forKey: AppLocalizer.preferenceKey)
    }
}
L10n.activeLanguage = { AppLocalizer.current.languageCode == "ko" ? .korean : .english }
let app = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of:"--dock-drag-checks"), CommandLine.arguments.indices.contains(index+1) {
    app.setActivationPolicy(.accessory)
    do {
        try DockDragChecks.run(outputDirectory:URL(fileURLWithPath:CommandLine.arguments[index+1]))
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--gesture-checks"), CommandLine.arguments.indices.contains(index+1) {
    app.setActivationPolicy(.accessory)
    do { try TrackpadGestureChecks.run(outputDirectory:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0) }
    catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--startup-permission-checks"), CommandLine.arguments.indices.contains(index+1) {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await StartupPermissionChecks.run(outputDirectory:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0) }
        catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
    }
    app.run()
}
if let index = CommandLine.arguments.firstIndex(of:"--system-gesture-checks"), CommandLine.arguments.indices.contains(index+1) {
    app.setActivationPolicy(.accessory)
    do { try SystemGestureFilterChecks.run(outputDirectory:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0) }
    catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--spread-close-checks"), CommandLine.arguments.indices.contains(index+1) {
    app.setActivationPolicy(.accessory)
    do { try SpreadCloseChecks.run(outputDirectory:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0) }
    catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--deleted-app-checks"), CommandLine.arguments.indices.contains(index+1) {
    app.setActivationPolicy(.accessory)
    do { try DeletedAppChecks.run(outputDirectory:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0) }
    catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--service-settings-checks"), CommandLine.arguments.indices.contains(index + 1), CommandLine.arguments.contains("--data-dir") {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        do { try ServiceSettingsChecks.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
if let index = CommandLine.arguments.firstIndex(of: "--onboarding-checks"), CommandLine.arguments.indices.contains(index + 1), CommandLine.arguments.contains("--data-dir") {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await OnboardingChecks.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// A pinned shortcut opens the launcher without a running-app indicator.
app.setActivationPolicy(.accessory)
app.run()
