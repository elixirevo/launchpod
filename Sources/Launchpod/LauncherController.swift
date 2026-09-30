import AppKit
import UniformTypeIdentifiers
import QuartzCore
import LaunchpodCore

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if (contentView as? LauncherView)?.routeAppCollection(event) == true { return }
        if (contentView as? LauncherView)?.routeItemDrag(event) == true { return }
        super.sendEvent(event)
    }
}

final class LauncherController: NSObject, NSWindowDelegate {
    private(set) var state = LayoutState()
    private(set) var isScanning = false
    let icons = IconCache()
    let appIcons = AppIconSettings(
        fileIconURL: CommandLine.arguments.contains("--data-dir") || CommandLine.arguments.contains("--preview-output") ? nil : Bundle.main.bundleURL,
        refreshDock: { DockShortcut.refreshIcon() })
    let trackpadGesture = TrackpadGesture()
    let hotCorners = HotCornerMonitor()
    private var openingScreen: NSScreen?
    let store: LayoutStore
    let catalog = AppCatalog()
    let launcherView = LauncherView(frame: .zero)
    var window: LauncherWindow!
    var retainedDragTile: AppTile?
    let menuTransition = MenuBarTransition()
    var isShown = false
    private(set) var isPreparingToShow = false
    private var iconPreparation: UUID?
    private var waitingForCatalog = false
    private var visibilityGeneration = 0
    private var outsideClickMonitor: Any?
    var isMonitoringOutsideClicks: Bool { outsideClickMonitor != nil }
    private var previousApp: NSRunningApplication?
    private var previousPresentation: NSApplication.PresentationOptions = []
    private let layoutUndo = UndoManager()
    private var hasLoaded = false
    private var loadFailed = false
    let wallpapers = WallpaperRenderer()
    private var screenSignature = ""
    private var settingsController: SettingsController?
    private var scanAgain = false
    var onFirstScan: (() -> Void)?

    override init() {
        let args = CommandLine.arguments
        let custom = args.firstIndex(of: "--data-dir").flatMap { args.indices.contains($0+1) ? args[$0+1] : nil }
        let directory = custom.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Launchpod")
        store = LayoutStore(directory: directory)
        super.init()
        layoutUndo.groupsByEvent = false
        screenSignature = screenGeometry()
        launcherView.controller = self
        icons.onImageReady = { [weak self] path in self?.launcherView.updateIcon(at:path) }
        let style: NSWindow.StyleMask = args.contains("--windowed") ? [.titled, .closable, .resizable] : [.borderless]
        window = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: style, backing: .buffered, defer: false)
        window.title = "Launchpod"; window.contentView = launcherView; window.delegate = self
        window.isReleasedWhenClosed = false; window.backgroundColor = .clear
        window.isRestorable = false
        window.isOpaque = false; window.hasShadow = false
        // All presentation is animated by our content layers, not by a second
        // automatic AppKit orderFront/orderOut window animation.
        window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        menuTransition.onBackgroundClick = { [weak self] in self?.dismiss() }
        if !args.contains("--windowed") { window.level = .floating }
        window.acceptsMouseMovedEvents = true
        do { state = try store.load(); hasLoaded = true }
        catch { loadFailed = true; DispatchQueue.main.async { self.report(error) } }
        catalog.onChange = { [weak self] in self?.rescan() }
        catalog.startWatching(appPaths:state.apps.map(\.path))
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(desktopSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(iconAppearanceChanged),name:Notification.Name("NSWorkspaceIconAppearanceConfigurationDidChangeNotification"),object:nil)
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(iconAppearanceChanged),name:Notification.Name("AppleInterfaceThemeChangedNotification"),object:nil)
        rescan()
    }
    @objc private func workspaceChanged() { rescan() }
    @objc private func accessibilityChanged() { launcherView.refresh() }
    @objc private func iconAppearanceChanged() {
        icons.invalidate()
        launcherView.refresh()
    }
    @objc private func desktopSpaceChanged() {
        guard isShown || window.isVisible || menuTransition.panel.isVisible else { return }
        // A Space change must not fade or order a menu cover onto the new Space.
        // Also invalidate pending preparation and an in-flight closing animation.
        dismissImmediately()
    }
    private func screenGeometry() -> String {
        NSScreen.screens.map { "\($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? ""):\($0.frame):\($0.backingScaleFactor)" }.joined(separator: "|")
    }
    @objc private func screensChanged() {
        let signature = screenGeometry()
        // Menu-bar presentation also posts this notification; it is not a monitor change.
        guard signature != screenSignature else { return }
        screenSignature = signature
        if isShown {
            if let screen = window.screen ?? NSScreen.main { launcherView.captureLayoutReservation(screen:screen) }
            fitWindow()
            if let screen = window.screen ?? NSScreen.main {
                launcherView.updateBackground(screen: screen)
                refreshMenuCover(screen:screen)
            }
        }
    }
    func rescan() {
        guard !loadFailed else { return }
        if isScanning { scanAgain = true; return }
        isScanning = true
        writableAppDirectories.removeAll(keepingCapacity:true)
        if state.apps.isEmpty { launcherView.refresh() }
        catalog.scan(previousApps:state.apps) { [weak self] found, removedPaths in
            guard let self = self else { return }
            self.isScanning = false
            var next = self.state
            next.reconcile(found, removedPaths:removedPaths, capacity: self.launcherView.capacity, folderCapacity: self.launcherView.folderCapacity)
            // Do not consume the one-time migration on an unavailable catalog.
            if !found.isEmpty { next.groupSystemAppsIfNeeded(capacity: self.launcherView.capacity, folderCapacity: self.launcherView.folderCapacity) }
            next.normalize(capacity: self.launcherView.capacity, folderCapacity: self.launcherView.folderCapacity)
            do {
                if next != self.state {
                    try self.store.save(next)
                    self.icons.invalidateChanges(from: self.state.apps, to: next.apps)
                    // Older undo snapshots must not resurrect uninstalled apps.
                    if !Set(self.state.apps.map(\.id)).isSubset(of:Set(next.apps.map(\.id))) {
                        self.layoutUndo.removeAllActions()
                    }
                    self.state = next
                    self.launcherView.refresh()
                }
            } catch { self.report(error) }
            self.catalog.startWatching(appPaths:self.state.apps.map(\.path))
            if self.waitingForCatalog, self.isShown {
                self.waitingForCatalog = false
                self.prepareHiddenShow(generation:self.visibilityGeneration)
            }
            let callback = self.onFirstScan; self.onFirstScan = nil; callback?()
            if self.scanAgain { self.scanAgain = false; self.rescan() }
        }
    }
    func mutate(_ name: String, _ operation: (inout LayoutState) throws -> Void) {
        guard !loadFailed else { return }
        launcherView.finishFolderDrop()
        do {
            let previous = state
            var next = state; try operation(&next)
            next.normalize(capacity: launcherView.capacity, folderCapacity: launcherView.folderCapacity)
            try next.validate()
            guard next != previous else { return }
            try store.save(next); state = next
            layoutUndo.beginUndoGrouping()
            layoutUndo.registerUndo(withTarget: self) { target in target.restore(previous, name: name) }
            layoutUndo.setActionName(name)
            layoutUndo.endUndoGrouping()
            launcherView.refresh()
        } catch { report(error) }
    }
    private func restore(_ saved: LayoutState, name: String) {
        mutate(name) { $0 = saved }
    }
    @objc func undoLayout() { layoutUndo.undo() }
    @objc func redoLayout() { layoutUndo.redo() }
    func toggle() { isShown ? dismiss() : show() }
    private func fitWindow() {
        launcherView.finishFolderDrop()
        let screens = NSScreen.screens
        let requested = openingScreen.flatMap { requested in screens.first { $0 == requested } }
        guard let screen = requested ?? screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        if CommandLine.arguments.contains("--windowed") { window.center() }
        else { window.setFrame(screen.frame, display: true) }
    }
    private func setPresentation(_ options: NSApplication.PresentationOptions) {
        // AppKit moves an on-screen menu-level strip when the menu reservation
        // changes (observed at y=832 in WindowServer on a 1080pt screen). It must
        // be ordered OUT before changing presentation, even if fully opaque.
        menuTransition.hide()
        if NSApp.presentationOptions != options { NSApp.presentationOptions = options }
    }
    private func refreshMenuCover(screen: NSScreen) {
        guard !isPreparingToShow, !CommandLine.arguments.contains("--windowed") else { return }
        menuTransition.prepare(screen:screen,image:wallpaper(for:screen),opacity:1,blocksMenuInteraction:true)
    }
    func show(on screen: NSScreen? = nil) {
        guard !isShown else { return }
        openingScreen = screen
        let fromHidden = !window.isVisible
        if fromHidden {
            previousApp = NSWorkspace.shared.frontmostApplication
            previousPresentation = NSApp.presentationOptions
        }
        visibilityGeneration += 1
        isShown = true
        if fromHidden {
            isPreparingToShow = true
            if state.apps.isEmpty && isScanning {
                waitingForCatalog = true
                let generation = visibilityGeneration
                // If catalog discovery is slow, still show its progress UI.
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in
                    guard let self = self, self.isShown, self.waitingForCatalog, self.visibilityGeneration == generation else { return }
                    self.waitingForCatalog = false; self.prepareHiddenShow(generation:generation)
                }
            } else { prepareHiddenShow(generation:visibilityGeneration) }
            return
        }
        fitWindow()
        let screen = window.screen ?? NSScreen.main!
        present(screen:screen,fromHidden:false)
    }
    private func prepareHiddenShow(generation: Int) {
        icons.cancelPreparation(iconPreparation); iconPreparation = nil
        fitWindow()
        guard let screen = window.screen ?? NSScreen.main else { isShown = false; isPreparingToShow = false; return }
        launcherView.prepareForShow(screen:screen)
        iconPreparation = icons.prepare(launcherView.initialIconRecords) { [weak self] _ in
            guard let self = self, self.isShown, self.visibilityGeneration == generation else { return }
            self.iconPreparation = nil; self.isPreparingToShow = false
            self.launcherView.refresh()
            self.present(screen:self.window.screen ?? screen,fromHidden:true)
        }
    }
    private func present(screen: NSScreen, fromHidden: Bool) {
        let fullScreen = !CommandLine.arguments.contains("--windowed")
        if fullScreen {
            menuTransition.prepare(screen: screen, image: wallpaper(for: screen),
                                   opacity: fromHidden ? 0 : menuTransition.opacity, blocksMenuInteraction:true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = 1
        if fromHidden {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            launcherView.layer?.opacity = 0
            CATransaction.commit()
        }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(launcherView)
        startOutsideClickMonitoring()
        launcherView.animateVisibility(showing: true, fromHidden: fromHidden)
        if fullScreen { menuTransition.animate(covering: true, duration: Motion.reduced ? 0.12 : Motion.enterDuration) }
        // Directory watchers are supplemented by a scan on each invocation.
        // Let the appearance finish before rebuilding the visible icon catalog.
        let generation = visibilityGeneration
        DispatchQueue.main.asyncAfter(deadline: .now()+(Motion.reduced ? 0.12 : Motion.enterDuration)) { [weak self] in
            guard let self = self, self.isShown, self.visibilityGeneration == generation else { return }
            // Keep the opaque top cover for the entire launcher session.
            // autoHideMenuBar would reveal the menu again on pointer hover;
            // hideMenuBar would also require disabling the Dock.
            self.rescan()
        }
    }
    func dismiss(restoreFocus: Bool = true) {
        guard isShown else { return }
        stopOutsideClickMonitoring()
        isShown = false
        visibilityGeneration += 1
        waitingForCatalog = false; isPreparingToShow = false
        icons.cancelPreparation(iconPreparation); iconPreparation = nil
        guard window.isVisible else { return }
        let generation = visibilityGeneration
        launcherView.cancelItemDrag()
        if !CommandLine.arguments.contains("--windowed"), let screen = window.screen {
            let opacity = menuTransition.panel.isVisible ? menuTransition.opacity : 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0; context.allowsImplicitAnimation = false
                // Restore the menu FIRST, then install its fading cover at the
                // final screen geometry. Never expose a strip across this change.
                setPresentation(previousPresentation)
                menuTransition.prepare(screen: screen, image: wallpaper(for: screen), opacity: opacity)
                menuTransition.animate(covering: false, duration: Motion.reduced ? 0.12 : Motion.exitDuration)
            }
        }
        launcherView.animateVisibility(showing: false) { [weak self] in
            guard let self = self, !self.isShown, self.visibilityGeneration == generation else { return }
            self.window.orderOut(nil); self.window.alphaValue = 1
            self.setPresentation(self.previousPresentation)
            if restoreFocus, self.previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.previousApp?.activate(options: [])
            }
        }
    }
    func prepareForTermination() {
        trackpadGesture.stop()
        hotCorners.stop()
        dismissImmediately()
    }
    private func dismissImmediately() {
        // Cancel pending handoffs and synchronously return menu ownership.
        stopOutsideClickMonitoring()
        visibilityGeneration += 1
        isShown = false
        waitingForCatalog = false; isPreparingToShow = false
        icons.cancelPreparation(iconPreparation); iconPreparation = nil
        launcherView.cancelItemDrag()
        window.orderOut(nil); window.alphaValue = 1
        setPresentation(previousPresentation)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let generation = visibilityGeneration
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
            guard let self = self, self.visibilityGeneration == generation else { return }
            self.handleExternalMouseDown(event)
        }
    }
    private func stopOutsideClickMonitoring() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor); outsideClickMonitor = nil }
    }
    func handleExternalMouseDown(_ event: NSEvent) {
        launcherView.cancelAppCollection()
        guard [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type),
              isShown, !launcherView.isDraggingItem, NSApp.modalWindow == nil else { return }
        // A global monitor's windowless mouse events use AppKit screen coordinates.
        // Use the click's position, not the pointer's later position at delivery.
        let point = event.window?.convertPoint(toScreen:event.locationInWindow) ?? event.locationInWindow
        guard !window.frame.contains(point) else { return }
        // Desktop clicks on another display need not change this window's key
        // status. Do not require focus, or reactivate the app we opened over.
        dismiss(restoreFocus:false)
    }
    deinit { stopOutsideClickMonitoring() }
    func windowDidResignKey(_ notification: Notification) {
        launcherView.cancelAppCollection()
        guard isShown, !launcherView.isDraggingItem, NSApp.modalWindow == nil,
              settingsController?.window?.isVisible != true else { return }
        dismiss(restoreFocus: false)
    }
    func wallpaper(for screen: NSScreen, refresh: Bool = false) -> NSImage? {
        wallpapers.snapshot(for:screen,refresh:refresh)?.image
    }
    func launch(_ app: AppRecord) {
        let url = URL(fileURLWithPath: app.path)
        guard app.available, !app.path.isEmpty, FileManager.default.fileExists(atPath: app.path) else {
            report(LayoutError.invalid(L10n.text("\(app.title) could not be found. Reinstall the app or add its location.", "\(app.title) 앱을 찾을 수 없습니다. 앱을 다시 설치하거나 위치를 추가해 주세요."))); return
        }
        dismiss(restoreFocus: false)
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            if let error = error { DispatchQueue.main.async { self?.report(error) } }
        }
    }
    // Presentation hints share a directory permission lookup. Execution and
    // context menus still validate against the filesystem at the time of use.
    private var writableAppDirectories: [String:Bool] = [:]
    func canOfferTrash(_ app: AppRecord) -> Bool {
        guard isRemovableApp(app) else { return false }
        let directory = URL(fileURLWithPath:app.path).deletingLastPathComponent().path
        if let writable = writableAppDirectories[directory] { return writable }
        let writable = FileManager.default.isWritableFile(atPath:directory)
        writableAppDirectories[directory] = writable
        return writable
    }
    private func isRemovableApp(_ app: AppRecord) -> Bool {
        guard app.available, !app.path.isEmpty, !app.path.hasPrefix("/System/"),
              !app.path.hasPrefix("/Applications/Safari.app"), app.bundleID != "app.launchpod.Launchpod" else { return false }
        return true
    }
    func canTrash(_ app: AppRecord) -> Bool {
        isRemovableApp(app) && FileManager.default.isWritableFile(atPath:URL(fileURLWithPath:app.path).deletingLastPathComponent().path)
    }
    func trash(_ app: AppRecord) {
        guard canTrash(app) else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("Move “\(app.title)” to the Trash?", "‘\(app.title)’을 휴지통으로 이동할까요?")
        alert.informativeText = L10n.text("The app will be moved to the Trash. You can restore it from there if needed.", "앱 파일을 휴지통으로 이동합니다. 필요한 경우 휴지통에서 복구할 수 있습니다.")
        alert.addButton(withTitle: L10n.text("Move to Trash", "휴지통으로 이동")); alert.addButton(withTitle: L10n.text("Cancel", "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: app.path), resultingItemURL: nil)
            mutate(L10n.text("Remove App", "앱 제거")) { $0.removeApp(app.id) }
        } catch { report(error) }
    }
    func itemMenu(id: String) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.representedObject = id; menu.addItem(item)
        }
        if state.folder(id) != nil { add(L10n.text("Rename Folder", "폴더 이름 변경"), #selector(renameItem(_:))) }
        else {
            add(L10n.text("Open", "열기"), #selector(openItem(_:)))
            add(L10n.text("Show in Finder", "Finder에서 보기"), #selector(revealItem(_:)))
            menu.addItem(.separator())
            add(L10n.text("Hide from Launchpod", "Launchpod에서 숨기기"), #selector(hideItem(_:)))
            if let app = state.app(id), !app.available { add(L10n.text("Remove from List", "목록에서 제거"), #selector(removeMissingItem(_:))) }
            if let app = state.app(id), canTrash(app) { add(L10n.text("Move to Trash…", "휴지통으로 이동…"), #selector(trashItem(_:))) }
        }
        menu.addItem(.separator()); add(L10n.text("Organize Apps", "앱 정리"), #selector(editItems(_:)))
        return menu
    }
    @objc private func openItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let app = state.app(id) { launch(app) } }
    @objc private func revealItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let app = state.app(id), !app.path.isEmpty {
            dismiss(restoreFocus: false); NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
        }
    }
    @objc private func hideItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { mutate(L10n.text("Hide App", "앱 숨기기")) { $0.hide(id) } } }
    @objc private func removeMissingItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { mutate(L10n.text("Remove Missing App", "없는 앱 제거")) { $0.removeApp(id) } } }
    @objc private func trashItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let app = state.app(id) { trash(app) } }
    @objc private func renameItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { launcherView.beginRenamingFolder(id) } }
    @objc private func editItems(_ sender: NSMenuItem) { launcherView.beginEditing() }
    func addApplicationURLs(_ urls: [URL]) {
        var paths = catalog.additionalPaths
        for url in urls where !paths.contains(url.path) { paths.append(url.path) }
        UserDefaults.standard.set(paths, forKey: "additionalAppPaths")
        catalog.startWatching(appPaths:state.apps.map(\.path)); rescan()
    }
    @objc func showSettings() {
        if settingsController == nil { settingsController = SettingsController(launcher: self) }
        dismiss(restoreFocus: false)
        settingsController?.showWindow(nil); settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func importLegacy(_ url: URL) {
        do {
            let preview = try LegacyImporter.read(url, matching: state.apps.filter(\.available))
            let alert = NSAlert(); alert.messageText = L10n.text("Import Launchpad Layout", "기존 Launchpad 배치 가져오기")
            alert.informativeText = preview.summary + L10n.text("\n\nThis replaces your current Launchpod layout. You can undo this from the Edit menu.", "\n\n현재 Launchpod 배치를 바꿉니다. 편집 메뉴에서 실행 취소할 수 있습니다.")
                + (preview.warnings.isEmpty ? "" : "\n\n"+preview.warnings.prefix(4).joined(separator: "\n"))
            alert.addButton(withTitle: L10n.text("Import", "가져오기")); alert.addButton(withTitle: L10n.text("Cancel", "취소"))
            if alert.runModal() == .alertFirstButtonReturn { mutate(L10n.text("Import Launchpad Layout", "Launchpad 배치 가져오기")) { $0 = preview.state; $0.didGroupSystemApps = true; $0.systemFolderPolicyVersion = 2 } }
        } catch { report(error) }
    }
    func importLayout(_ url: URL) {
        do {
            var incoming = try store.readExport(url)
            incoming.reconcile(state.apps.filter(\.available), capacity: launcherView.capacity, folderCapacity: launcherView.folderCapacity)
            let alert = NSAlert(); alert.messageText = L10n.text("Import saved layout?", "저장된 배치를 가져올까요?")
            alert.informativeText = L10n.text("This replaces your current layout with the saved layout. You can undo this change.", "현재 배치를 파일의 배치로 바꿉니다. 실행 취소할 수 있습니다.")
            alert.addButton(withTitle: L10n.text("Import", "가져오기")); alert.addButton(withTitle: L10n.text("Cancel", "취소"))
            if alert.runModal() == .alertFirstButtonReturn { mutate(L10n.text("Import Layout", "배치 가져오기")) { $0 = incoming; $0.didGroupSystemApps = true; $0.systemFolderPolicyVersion = 2 } }
        } catch { report(error) }
    }
    func exportLayout() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Launchpod-layout.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { do { try store.export(state, to: url) } catch { report(error) } }
    }
    func showHidden() { mutate(L10n.text("Restore Hidden Apps", "숨긴 앱 복원")) { $0.showAllHidden(capacity: self.launcherView.capacity, folderCapacity: self.launcherView.folderCapacity) } }
    func report(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "Launchpod"; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.text("OK", "확인")); alert.runModal()
    }
    func writePreview(to path: String) {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now()+1) {
            let view = self.launcherView
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
            NSApp.terminate(nil)
        }
    }
}
