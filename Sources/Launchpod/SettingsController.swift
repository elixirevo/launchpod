import AppKit
import UniformTypeIdentifiers
import LaunchpodCore

final class SettingsController: NSWindowController, NSWindowDelegate {
    weak var launcher: LauncherController?
    private let languagePopup = NSPopUpButton()
    private let shortcut = NSButton()
    private let gestureEnabled = NSButton(checkboxWithTitle:L10n.text("Open/close Launchpod with gestures", "제스처로 Launchpod 열기/닫기"),target:nil,action:nil)
    private let gesturePopup = NSPopUpButton()
    private let gestureStatus = NSTextField(wrappingLabelWithString:"")
    private let gesturePermission = NSButton()
    private var gestureObserver: NSObjectProtocol?

    private let columnPopup = NSPopUpButton()
    private let rowPopup = NSPopUpButton()
    private let iconPopup = NSPopUpButton()
    private let iconPreview = NSImageView()
    private let trackpadGesture: TrackpadGesture
    private let appIcons: AppIconSettings
    private var keyMonitor: Any?
    init(launcher: LauncherController, appIcons: AppIconSettings? = nil, trackpadGesture: TrackpadGesture? = nil) {
        self.launcher = launcher
        self.appIcons = appIcons ?? launcher.appIcons
        self.trackpadGesture = trackpadGesture ?? launcher.trackpadGesture
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 738), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.center()
        rebuildContent()
        gestureObserver = NotificationCenter.default.addObserver(forName:TrackpadGesture.settingsChanged,
            object:self.trackpadGesture,queue:.main) { [weak self] _ in self?.updateGestureControls() }
        NotificationCenter.default.addObserver(self, selector:#selector(rebuildContent), name:L10n.didChange, object:nil)
    }
    @objc private func rebuildContent() {
        guard let window = window, let launcher = launcher else { return }
        endRecording()
        window.title = L10n.text("Launchpod Settings", "Launchpod 설정"); window.isReleasedWhenClosed = false; window.delegate = self
        window.isRestorable = false
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 520, height: 738)); window.contentView = content
        func label(_ text: String, y: CGFloat, font: NSFont = .systemFont(ofSize: 13)) {
            let field = NSTextField(labelWithString: text); field.font = font
            field.frame = NSRect(x: 28, y: y, width: 460, height: 24); content.addSubview(field)
        }
        func button(_ title: String, y: CGFloat, action: Selector, x: CGFloat = 195, width: CGFloat = 295) {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded; b.frame = NSRect(x: x, y: y, width: width, height: 30); content.addSubview(b)
        }
        languagePopup.removeAllItems()
        columnPopup.removeAllItems(); rowPopup.removeAllItems(); iconPopup.removeAllItems(); gesturePopup.removeAllItems()
        gestureEnabled.title = L10n.text("Open/close Launchpod with gestures", "제스처로 Launchpod 열기/닫기")
        label("Launchpod", y: 22, font: .systemFont(ofSize: 23, weight: .semibold))
        label(L10n.text("See all your apps and arrange them your way.", "앱을 한눈에 보고, 원하는 위치에 정리하세요."), y: 53)
        label(L10n.text("Open / close shortcut", "열기 / 닫기 단축키"), y: 152)
        shortcut.title = HotKey.shared.label; shortcut.target = self; shortcut.action = #selector(recordShortcut)
        shortcut.bezelStyle = .rounded; shortcut.frame = NSRect(x: 195, y: 144, width: 295, height: 30); content.addSubview(shortcut)
        label(L10n.text("Grid", "격자"), y: 195)
        columnPopup.addItems(withTitles: (3...9).map { L10n.text("\($0) columns", "\($0)열") }); columnPopup.selectItem(at: launcher.launcherView.columns-3)
        rowPopup.addItems(withTitles: (3...7).map { L10n.text("\($0) rows", "\($0)행") }); rowPopup.selectItem(at: launcher.launcherView.rows-3)
        columnPopup.frame = NSRect(x: 198, y: 187, width: 135, height: 30); rowPopup.frame = NSRect(x: 349, y: 187, width: 135, height: 30)
        for popup in [columnPopup,rowPopup] { popup.target = self; popup.action = #selector(gridChanged); content.addSubview(popup) }
        label(L10n.text("App icon", "앱 아이콘"), y: 248)
        for choice in AppIconChoice.allCases {
            iconPopup.addItem(withTitle:choice.title)
            let thumbnail = self.appIcons.image(for:choice)?.copy() as? NSImage
            thumbnail?.size = NSSize(width:24,height:24)
            iconPopup.lastItem?.image = thumbnail
        }
        iconPopup.frame = NSRect(x:198,y: 237,width:218,height:32)
        iconPopup.target = self; iconPopup.action = #selector(iconChanged)
        iconPopup.setAccessibilityLabel(L10n.text("App icon", "앱 아이콘"))
        content.addSubview(iconPopup)
        iconPreview.frame = NSRect(x:426,y: 224,width:64,height:64)
        iconPreview.imageScaling = .scaleProportionallyUpOrDown
        iconPreview.setAccessibilityLabel(L10n.text("Selected app icon preview", "선택한 앱 아이콘 미리보기")); content.addSubview(iconPreview)
        let iconHint = NSTextField(labelWithString:L10n.text("Applies to the app file and Dock icon.", "앱 파일과 Dock 아이콘에 적용됩니다."))
        iconHint.font = .systemFont(ofSize:12); iconHint.textColor = .secondaryLabelColor
        iconHint.frame = NSRect(x:198,y: 284,width:296,height:20); content.addSubview(iconHint)
        label(L10n.text("Language", "언어"), y: 99)
        languagePopup.addItems(withTitles:AppLanguage.allCases.map(\.title))
        languagePopup.selectItem(at:AppLanguage.allCases.firstIndex(of:L10n.language) ?? 0)
        languagePopup.frame = NSRect(x:198,y:91,width:292,height:30)
        languagePopup.setAccessibilityLabel(L10n.text("Language", "언어"))
        languagePopup.target = self; languagePopup.action = #selector(languageChanged)
        content.addSubview(languagePopup)
        updateIconControls()
        label(L10n.text("Legacy Launchpad", "기존 Launchpad"), y: 328)
        button(L10n.text("Import This Mac’s Layout…", "이 Mac의 배치 가져오기…"), y: 318, action: #selector(importCurrent))
        button(L10n.text("Choose Launchpad Database…", "Launchpad DB 파일 선택…"), y: 353, action: #selector(importDatabase))
        label(L10n.text("Launchpod layout", "Launchpod 배치"), y: 402)
        button(L10n.text("Export…", "내보내기…"), y: 392, action: #selector(exportLayout), width: 140)
        button(L10n.text("Import…", "가져오기…"), y: 392, action: #selector(importLayout), x: 348, width: 142)
        label(L10n.text("App library", "앱 목록"), y: 445)
        button(L10n.text("Add App / Folder Location…", "앱 / 폴더 위치 추가…"), y: 435, action: #selector(addLocation))
        button(L10n.text("Restore All Hidden Apps", "숨긴 앱 모두 복원"), y: 470, action: #selector(showHidden))
        label(L10n.text("Trackpad gestures", "트랙패드 제스처"), y: 522)
        gestureEnabled.frame = NSRect(x:195,y: 515,width:295,height:26)
        gestureEnabled.target = self; gestureEnabled.action = #selector(gestureChanged)
        content.addSubview(gestureEnabled)
        gesturePopup.addItems(withTitles:LauncherGestureChoice.allCases.map(\.title))
        gesturePopup.font = .systemFont(ofSize:12)
        gesturePopup.frame = NSRect(x:195,y: 548,width:295,height:30)
        gesturePopup.target = self; gesturePopup.action = #selector(gestureChanged)
        gesturePopup.setAccessibilityLabel(L10n.text("Gesture to open Launchpod", "Launchpod 열기 제스처"))
        content.addSubview(gesturePopup)
        gestureStatus.font = .systemFont(ofSize:12); gestureStatus.textColor = .secondaryLabelColor
        gestureStatus.frame = NSRect(x:198,y: 588,width:292,height:40)
        content.addSubview(gestureStatus)
        gesturePermission.title = L10n.text("Accessibility Settings…", "손쉬운 사용 권한 설정…")
        gesturePermission.target = self; gesturePermission.action = #selector(gesturePermissionClicked)
        gesturePermission.bezelStyle = .rounded
        gesturePermission.frame = NSRect(x:195,y: 629,width:295,height:30)
        content.addSubview(gesturePermission)
        updateGestureControls()
        button(L10n.text("Rescan Apps", "앱 다시 검색"), y: 683, action: #selector(rescan), x: 28, width: 140)
        button(L10n.text("Open Launchpod", "Launchpod 열기"), y: 683, action: #selector(openLauncher), x: 345, width: 145)
    }
    @objc private func languageChanged() {
        guard AppLanguage.allCases.indices.contains(languagePopup.indexOfSelectedItem) else { return }
        L10n.select(AppLanguage.allCases[languagePopup.indexOfSelectedItem])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateGestureControls() {
        let gesture = trackpadGesture
        gestureEnabled.state = gesture.enabled ? .on : .off
        gesturePopup.selectItem(at:LauncherGestureChoice.allCases.firstIndex(of:gesture.choice) ?? 0)
        gesturePopup.isEnabled = gesture.enabled
        switch gesture.status {
        case .off: gestureStatus.stringValue = L10n.text("Gesture detection is off.", "제스처 감지가 꺼져 있습니다.")
        case .permissionRequired: gestureStatus.stringValue = L10n.text("Enable Launchpod in Accessibility settings.", "손쉬운 사용 권한에서 Launchpod를 켜 주세요.")
        case .listening: gestureStatus.stringValue = L10n.text("Pinch to open; spread your fingers to close.", "손가락을 오므리면 열리고, 벌리면 닫힙니다.")
        case .unavailable: gestureStatus.stringValue = L10n.text("Could not start gesture detection. Check Accessibility permissions and try again.", "제스처 감지를 시작하지 못했습니다. 손쉬운 사용 권한을 확인한 뒤 다시 시도해 주세요.")
        }
        gesturePermission.isHidden = !gesture.enabled || gesture.status == .listening
    }
    @objc private func gestureChanged() {
        guard LauncherGestureChoice.allCases.indices.contains(gesturePopup.indexOfSelectedItem) else { return }
        trackpadGesture.configure(enabled:gestureEnabled.state == .on,
            choice:LauncherGestureChoice.allCases[gesturePopup.indexOfSelectedItem])
        updateGestureControls()
    }
    @objc private func gesturePermissionClicked() { trackpadGesture.requestPermission(); updateGestureControls() }
    deinit { if let observer = gestureObserver { NotificationCenter.default.removeObserver(observer) } }
    func runLanguageChecks(outputDirectory: URL) throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain:"LanguageChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        defer { L10n.defaults.removePersistentDomain(forName:"app.launchpod.LanguageUIChecks.\(ProcessInfo.processInfo.processIdentifier)") }
        try check(L10n.language == .english && window?.title == "Launchpod Settings", "fresh UI defaults to English")
        let originalState = launcher!.state
        for language in [AppLanguage.korean, .english, .korean] {
            languagePopup.selectItem(at:AppLanguage.allCases.firstIndex(of:language)!)
            try check(languagePopup.sendAction(languagePopup.action,to:languagePopup.target), "language action is connected")
            try check(L10n.language == language, "picker saves selection")
            try check(window?.title == (language == .english ? "Launchpod Settings" : "Launchpod 설정"), "settings update immediately")
            try check(NSApp.mainMenu?.items.last?.title == (language == .english ? "Edit" : "편집"), "app menu updates immediately")
            try check(languagePopup.itemTitles == ["English", "한국어"], "both language names remain discoverable")
            try check(launcher!.state == originalState, "switching preserves layout and user names")
            let fresh = SettingsController(launcher:launcher!)
            try check(fresh.window?.title == window?.title, "new settings window restores selection")
            fresh.close()
            guard let view = window?.contentView else { continue }
            view.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
            for control in [languagePopup,columnPopup,rowPopup,iconPopup,gesturePopup] {
                try check(view.bounds.contains(control.frame), "picker remains inside window")
            }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
            RunLoop.current.run(until:Date().addingTimeInterval(0.2))
            if let window = window,
               let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]),
               let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) {
                try png.write(to:outputDirectory.appendingPathComponent("settings-\(language.rawValue).png"))
            } else { try check(false,"capture language settings") }
        }
        print("PASS: \(checks) language UI checks")
    }
    func runGestureSettingsChecks(outputDirectory: URL) throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain:"GestureSettingsChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
            checks += 1
        }
        try check(gesturePopup.itemTitles == LauncherGestureChoice.allCases.map(\.title),"settings expose the reference gesture choices")
        gestureEnabled.state = .off
        try check(gestureEnabled.sendAction(gestureEnabled.action,to:gestureEnabled.target),"checkbox action is connected")
        try check(!trackpadGesture.enabled && !gesturePopup.isEnabled,"switching off stops the listener and disables selection")
        gestureEnabled.state = .on
        _ = gestureEnabled.sendAction(gestureEnabled.action,to:gestureEnabled.target)
        for index in LauncherGestureChoice.allCases.indices {
            gesturePopup.selectItem(at:index)
            try check(gesturePopup.sendAction(gesturePopup.action,to:gesturePopup.target),"gesture choice action is connected")
            try check(trackpadGesture.choice == LauncherGestureChoice.allCases[index],"selected gesture is saved")
        }
        try check(gesturePermission.isHidden == (trackpadGesture.status == .listening),"permission control matches listener state")
        try check(!gestureStatus.stringValue.isEmpty,"status explains readiness or permission requirement")
        try check(gesturePermission.title == L10n.text("Accessibility Settings…", "손쉬운 사용 권한 설정…"),"permission control names the actual Accessibility pane")
        let controls: [NSView] = [gestureEnabled,gesturePopup,gestureStatus,gesturePermission]
        for control in controls { try check(window!.contentView!.bounds.contains(control.frame),"gesture control is inside settings") }
        for i in controls.indices { for j in controls.indices where j > i {
            try check(!controls[i].frame.intersects(controls[j].frame),"gesture controls do not overlap")
        } }
        try "PASS: \(checks) gesture settings checks\n".write(to:outputDirectory.appendingPathComponent("settings-checks.txt"),atomically:true,encoding:.utf8)
    }
    func captureGestureSettings(outputDirectory: URL) throws {
        guard let window = window, let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]),
              let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else {
            throw NSError(domain:"GestureSettingsChecks",code:1,userInfo:[NSLocalizedDescriptionKey:"Settings screenshot unavailable"])
        }
        try png.write(to:outputDirectory.appendingPathComponent("settings.png"))
    }
    private func updateIconControls() {
        iconPopup.selectItem(at:AppIconChoice.allCases.firstIndex(of:appIcons.choice) ?? 0)
        iconPreview.image = appIcons.image(for:appIcons.choice)
    }
    @objc private func iconChanged() {
        guard AppIconChoice.allCases.indices.contains(iconPopup.indexOfSelectedItem) else { return }
        do {
            try appIcons.select(AppIconChoice.allCases[iconPopup.indexOfSelectedItem])
            launcher?.rescan()
        }
        catch { launcher?.report(error) }
        updateIconControls()
    }
    func runAppIconChecks(outputDirectory: URL, phase: String) throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain:"Launchpod.IconChecks",code:1,
                userInfo:[NSLocalizedDescriptionKey:"App icon check failed: \(name)"]) }; checks += 1
        }
        func pixels(_ image: NSImage?) -> Data? {
            guard let image = image, let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:64,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
                let context = NSGraphicsContext(bitmapImageRep:bitmap) else { return nil }
            // The Dock rasterizes at 512pt. Match that representation instead
            // of comparing it with size-specific small-icon artwork in ICNS.
            var sourceRect = NSRect(x:0,y:0,width:512,height:512)
            guard let source = image.cgImage(forProposedRect:&sourceRect,context:nil,hints:nil) else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSImage(cgImage:source,size:NSSize(width:512,height:512)).draw(in:NSRect(x:0,y:0,width:64,height:64),from:.zero,operation:.copy,fraction:1)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.representation(using:.png,properties:[:])
        }
        func matchingPixels(_ a: Data?, _ b: Data?) -> Bool {
            func sample(_ data: Data?) -> [UInt8]? {
                guard let data = data, let source = CGImageSourceCreateWithData(data as CFData,nil),
                      let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { return nil }
                var bytes = [UInt8](repeating:0,count:16*16*4)
                let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                    guard let context = CGContext(data:buffer.baseAddress,width:16,height:16,bitsPerComponent:8,
                        bytesPerRow:16*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(image,in:CGRect(x:0,y:0,width:16,height:16)); return true
                }
                return rendered ? bytes : nil
            }
            guard let first = sample(a), let second = sample(b) else { return false }
            // AppKit may rasterize a different ICNS representation for the Dock
            // than for an image view. Compare artwork with a 5/255 mean channel
            // tolerance instead of requiring identical PNG antialiasing bytes.
            let error = zip(first,second).reduce(0) { $0+abs(Int($1.0)-Int($1.1)) }
            return Double(error)/Double(first.count) <= 5
        }
        let expected: AppIconChoice = phase == "restore-apps" ? .macOSApps : (phase == "restore-original" ? .originalLaunchpad : .launchpod)
        try check(["select-original","restore-original","select-apps","restore-apps","restore-default"].contains(phase),"known restart phase")
        try check(iconPopup.itemTitles == AppIconChoice.allCases.map(\.title),"settings offer all bundled icon choices")
        try check(AppIconChoice.allCases.allSatisfy { appIcons.image(for:$0)?.isValid == true },"all bundled icons load without system applications")
        try check(!matchingPixels(pixels(appIcons.image(for:.launchpod)),pixels(appIcons.image(for:.originalLaunchpad))),"the two icons contain different artwork")
        for other in [AppIconChoice.launchpod, .originalLaunchpad] {
            try check(!matchingPixels(pixels(appIcons.image(for:.macOSApps)),pixels(appIcons.image(for:other))),"macOS Apps artwork differs from \(other.title)")
        }
        try check(appIcons.choice == expected && iconPopup.indexOfSelectedItem == AppIconChoice.allCases.firstIndex(of:expected),"new process restores the saved selection")
        let actualIcon = pixels(NSApp.applicationIconImage), expectedIcon = pixels(appIcons.image(for:expected))
        if !matchingPixels(actualIcon,expectedIcon) {
            try actualIcon?.write(to:outputDirectory.appendingPathComponent("actual-icon.png"))
            try expectedIcon?.write(to:outputDirectory.appendingPathComponent("expected-icon.png"))
            print("Icon diagnostics: application=\(String(describing:NSApp.applicationIconImage?.size)), resource=\(String(describing:appIcons.image(for:expected)?.size))")
        }
        try check(matchingPixels(actualIcon,expectedIcon),"startup applies the selected Dock artwork")
        try check(matchingPixels(pixels(iconPreview.image),pixels(appIcons.image(for:expected))),"settings preview matches the saved selection")
        if phase != "restore-default" {
            let next: AppIconChoice = phase == "select-apps" ? .macOSApps : (phase == "select-original" ? .originalLaunchpad : .launchpod)
            iconPopup.selectItem(at:AppIconChoice.allCases.firstIndex(of:next)!)
            let sent = iconPopup.sendAction(iconPopup.action,to:iconPopup.target)
            try check(sent && appIcons.choice == next,"the real settings action changes the selection")
            try check(matchingPixels(pixels(NSApp.applicationIconImage),pixels(appIcons.image(for:next))),"selection immediately updates the Dock artwork")
            try check(matchingPixels(pixels(iconPreview.image),pixels(appIcons.image(for:next))),"selection immediately updates the preview")
        }
        window?.displayIfNeeded()
        try check(window?.contentView?.bounds.contains(iconPopup.frame) == true
            && window?.contentView?.bounds.contains(iconPreview.frame) == true
            && !iconPopup.frame.intersects(iconPreview.frame),"icon controls are visible and do not overlap")
        if let window = window, let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]),
           let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) {
            try png.write(to:outputDirectory.appendingPathComponent("settings-"+phase+".png"))
        } else { try check(false,"capture settings window") }
        print("PASS: \(checks) app icon settings checks (\(phase))")
    }
    @objc private func recordShortcut() {
        guard keyMonitor == nil else { return }
        shortcut.title = L10n.text("Press shortcut (Esc to cancel)", "조합 키를 누르세요 (Esc: 취소)")
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { self.endRecording(); return nil }
            if HotKey.shared.change(event: event) { self.endRecording() }
            else { NSSound.beep() }
            return nil
        }
    }
    private func endRecording() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }; keyMonitor = nil
        shortcut.title = HotKey.shared.label
    }
    func windowWillClose(_ notification: Notification) { endRecording() }
    @objc private func gridChanged() {
        let columns = columnPopup.indexOfSelectedItem+3, rows = rowPopup.indexOfSelectedItem+3
        UserDefaults.standard.set(columns, forKey: "columns"); UserDefaults.standard.set(rows, forKey: "rows")
        launcher?.mutate(L10n.text("Change Grid Size", "격자 크기 변경")) { $0.normalize(capacity: columns*rows, folderCapacity: columns*FolderStyle.maximumRows) }
    }
    @objc private func importCurrent() {
        guard let url = LegacyImporter.currentDatabaseURL else {
            launcher?.report(LayoutError.invalid(L10n.text("No legacy Launchpad database was found on this Mac. Choose a database file from an older Mac.", "이 Mac에서 기존 Launchpad DB를 찾지 못했습니다. 구형 Mac에서 가져온 DB 파일을 선택해 주세요."))); return
        }
        launcher?.importLegacy(url)
    }
    @objc private func importDatabase() {
        let panel = NSOpenPanel(); panel.message = L10n.text("Choose the legacy Launchpad database file.", "기존 Launchpad의 db 파일을 선택하세요.")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { launcher?.importLegacy(url) }
    }
    @objc private func exportLayout() { launcher?.exportLayout() }
    @objc private func importLayout() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { launcher?.importLayout(url) }
    }
    @objc private func addLocation() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.message = L10n.text("Choose app bundles or folders containing apps.", "앱 묶음 또는 앱이 들어 있는 폴더를 선택하세요.")
        if panel.runModal() == .OK { launcher?.addApplicationURLs(panel.urls) }
    }
    @objc private func showHidden() { launcher?.showHidden() }
    @objc private func rescan() { launcher?.rescan() }
    @objc private func openLauncher() { window?.orderOut(nil); launcher?.show() }
}
