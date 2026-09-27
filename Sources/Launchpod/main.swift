#if !arch(arm64)
#error("Launchpod supports Apple Silicon (arm64) Macs only.")
#endif

import AppKit
import LaunchpodCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var launcher: LauncherController!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var updates: UpdateController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let startup = ProcessInfo.processInfo.systemUptime
        updates = UpdateController()
        updates.beforeShowingUpdate = { [weak self] in self?.launcher?.dismiss(restoreFocus:false) }
        NotificationCenter.default.addObserver(self, selector:#selector(languageChanged), name:L10n.didChange, object:nil)
        buildMenu()
        launcher = LauncherController()
        launcher.appIcons.applySavedChoice()
        HotKey.shared.action = { [weak self] in self?.launcher.toggle() }
        let hotKeyStatus = HotKey.shared.registerSaved()
        if hotKeyStatus != 0 { NSLog("Launchpod: hotkey registration failed (%d). Change it in Settings.",hotKeyStatus) }
        buildStatusMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Launchpod")
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp,.rightMouseUp])
        let args = CommandLine.arguments
        restoreDockShortcutIfNeeded()
        launcher.trackpadGesture.isLauncherShown = { [weak self] in self?.launcher.isShown ?? false }
        launcher.trackpadGesture.onClose = { [weak self] in
            guard NSApp.modalWindow == nil, NSEvent.pressedMouseButtons == 0 else { return }
            self?.launcher.dismiss()
        }
        launcher.trackpadGesture.onOpen = { [weak self] in
            guard NSApp.modalWindow == nil, NSEvent.pressedMouseButtons == 0 else { return }
            self?.launcher.show()
        }
        launcher.hotCorners.canOpen = { [weak self] in self?.launcher.isShown == false }
        launcher.hotCorners.onOpen = { [weak self] screen in self?.launcher.show(on:screen) }
        // Isolated layout/test runs must not install another global listener.
        if !args.contains("--data-dir") && !args.contains("--preview-output") {
            launcher.trackpadGesture.start()
            launcher.hotCorners.start()
        }
        if let i = args.firstIndex(of:"--outside-click-checks"), args.indices.contains(i+1), args.contains("--data-dir") {
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
                let settings = SettingsController(launcher:self.launcher)
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
                let monitor = TrackpadGesture(defaults:defaults)
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
        } else if let i = args.firstIndex(of: "--preview-output"), args.indices.contains(i+1) {
            launcher.onFirstScan = { [weak self] in self?.launcher.writePreview(to: args[i+1]) }
        } else {
            launcher.show()
            if !args.contains("--data-dir") {
                DispatchQueue.main.asyncAfter(deadline:.now()+Motion.enterDuration) { [weak self] in
                    guard let self = self else { return }
                    self.launcher.trackpadGesture.promptForPermissionAtStartup(request: {
                        self.launcher.dismiss(restoreFocus:false)
                        self.launcher.trackpadGesture.requestPermission()
                    })
                }
            }
        }
    }
    private func restoreDockShortcutIfNeeded() {
        let args = CommandLine.arguments
        guard !args.contains("--data-dir"), !args.contains("--preview-output") else { return }
        DockShortcut.addIfNeeded()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreDockShortcutIfNeeded()
        launcher?.toggle(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { launcher?.prepareForTermination() }
    @objc private func languageChanged() {
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
    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Reuse the startup menu. Attach only while tracking so a normal
            // left click continues to toggle the launcher instead of this menu.
            statusItem.menu = statusMenu
            defer { statusItem.menu = nil }
            statusItem.button?.performClick(nil)
        } else { launcher.toggle() }
    }
    @objc private func toggle() { launcher?.toggle() }
    @objc private func settings() { launcher?.showSettings() }
    @objc private func undo() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
        else { launcher?.undoLayout() }
    }
    @objc private func redo() {
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
UserDefaults.standard.register(defaults:["AppleLanguages":[L10n.language.rawValue]])
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
    do { try StartupPermissionChecks.run(outputDirectory:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0) }
    catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
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
let delegate = AppDelegate()
app.delegate = delegate
// A pinned shortcut opens the launcher without a running-app indicator.
app.setActivationPolicy(.accessory)
app.run()
