import AppKit
import SwiftUI
import LaunchpodCore
import MacAppCore
import MacAppSettings

private func requireSetting(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "Launchpod.SettingsChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

extension SettingsController {
    private func capture(_ name: String, in directory: URL, target: NSWindow? = nil) throws {
        let captureWindow = target ?? window
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        captureWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let window = captureWindow, let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadUnknown)
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func runLanguageChecks(outputDirectory: URL) throws {
        let code = AppLocalizer.current.languageCode
        try requireSetting(support.canShowOnboarding, "Help & Support offers onboarding review")
        let originalLayout = model.launcher!.state
        try requireSetting(pages.ids == [.builtIn(.general), .custom("launchpod"), .builtIn(.shortcuts), .builtIn(.permissions), .builtIn(.updates), .support, .builtIn(.about)], "App controls must be on page two with only one support page")
        try requireSetting(L10n.language.rawValue == code, "Host and library use the same active language")
        try requireSetting(NSApp.mainMenu?.items.last?.title == L10n.text("Edit", "편집"), "Menu follows the shared language")
        let selection = language.selection
        language.select(selection == .korean ? .english : .korean)
        try requireSetting(language.requiresRestart, "Language change requests a restart")
        try requireSetting(AppLocalizer.current.languageCode == code && L10n.language.rawValue == code, "Language stays consistent until restart")
        language.select(selection)
        try requireSetting(model.launcher!.state == originalLayout, "Changing language preserves layout")
        for locale in ["en", "ko"] {
            for document in LegalDocument.allCases {
                let content = try document.text(language: locale)
                try requireSetting(content.contains("elixirevo@gmail.com") && content.contains("2026") && !content.contains("{{"), "Legal resource is complete and contains the real contact")
                try requireSetting(content.components(separatedBy: "## ").count >= 13, "Legal resource contains all sections")
            }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window?.appearance = NSAppearance(named: appearance)
            window?.setContentSize(NSSize(width: 740, height: 500))
            for (id, label) in [(SettingsPageID.builtIn(.general), "general"), (.custom("launchpod"), "launchpod"), (.builtIn(.shortcuts), "shortcuts"), (.builtIn(.permissions), "permissions"), (.support, "support")] {
                navigation.select(id)
                try capture("\(code)-\(appearance.rawValue)-\(label)", in: outputDirectory)
            }
            for document in LegalDocument.allCases {
                let sheet = NSWindow(contentViewController: NSHostingController(rootView: LegalDocumentView(document: document)))
                window?.beginSheet(sheet)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                try capture("\(code)-\(appearance.rawValue)-\(document.rawValue)", in: outputDirectory, target: sheet)
                window?.endSheet(sheet); sheet.orderOut(nil)
            }
        }
        print("PASS: settings order, language migration contract, bundled legal documents, light/dark minimum-size captures (\(code))")
    }

    func runHotCornerSettingsChecks(defaults: UserDefaults, outputDirectory: URL) throws {
        let monitor = model.hotCorners
        try requireSetting(monitor.enabledCorners.isEmpty && !monitor.isListening, "Fresh corners are disabled")
        for corner in HotCorner.allCases { model.setCorner(corner, enabled: true) }
        model.setCorner(.topRight, enabled: false)
        let selected: Set<HotCorner> = [.topLeft, .bottomLeft, .bottomRight]
        try requireSetting(monitor.enabledCorners == selected, "Changing one corner preserves the other choices")
        try requireSetting(HotCornerMonitor(defaults: defaults).enabledCorners == selected, "Corners survive relaunch")
        try requireSetting(!monitor.isListening, "Isolated preferences do not start a monitor")
        monitor.canOpen = { false }; monitor.start()
        try requireSetting(monitor.isListening, "Enabled corners start monitoring")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try requireSetting(!monitor.isListening, "Sleep stops monitoring")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try requireSetting(monitor.isListening, "Wake resumes monitoring")
        monitor.configure(corners: []); monitor.stop()
        navigation.select(.builtIn(.shortcuts))
        try capture("hot-corners", in: outputDirectory)
        try "PASS: hot corner settings persistence and monitor lifecycle\n".write(to: outputDirectory.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
    }

    func runGestureSettingsChecks(outputDirectory: URL) throws {
        model.gesture(enabled: false, choice: .fourOrFive)
        try requireSetting(!model.trackpadGesture.enabled && model.trackpadGesture.status == .off, "Disabling gestures stops detection")
        for choice in LauncherGestureChoice.allCases {
            model.gesture(enabled: true, choice: choice)
            try requireSetting(model.trackpadGesture.choice == choice, "Gesture selection is persisted")
        }
        try requireSetting(!model.gestureStatus.isEmpty, "Gesture status is available")
        navigation.select(.builtIn(.shortcuts))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try "PASS: gesture settings and status\n".write(to: outputDirectory.appendingPathComponent("settings-checks.txt"), atomically: true, encoding: .utf8)
    }
    func captureGestureSettings(outputDirectory: URL) throws { try capture("settings", in: outputDirectory) }
}

extension SettingsController {
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
        try check(AppIconChoice.allCases.count == 3,"settings offer all bundled icon choices")
        try check(AppIconChoice.allCases.allSatisfy { model.appIcons.image(for:$0)?.isValid == true },"all bundled icons load without system applications")
        try check(!matchingPixels(pixels(model.appIcons.image(for:.launchpod)),pixels(model.appIcons.image(for:.originalLaunchpad))),"the two icons contain different artwork")
        for other in [AppIconChoice.launchpod, .originalLaunchpad] {
            try check(!matchingPixels(pixels(model.appIcons.image(for:.macOSApps)),pixels(model.appIcons.image(for:other))),"macOS Apps artwork differs from \(other.title)")
        }
        try check(model.appIcons.choice == expected,"new process restores the saved selection")
        let actualIcon = pixels(NSApp.applicationIconImage), expectedIcon = pixels(model.appIcons.image(for:expected))
        if !matchingPixels(actualIcon,expectedIcon) {
            try actualIcon?.write(to:outputDirectory.appendingPathComponent("actual-icon.png"))
            try expectedIcon?.write(to:outputDirectory.appendingPathComponent("expected-icon.png"))
            print("Icon diagnostics: application=\(String(describing:NSApp.applicationIconImage?.size)), resource=\(String(describing:model.appIcons.image(for:expected)?.size))")
        }
        try check(matchingPixels(actualIcon,expectedIcon),"startup applies the selected Dock artwork")
        try check(matchingPixels(pixels(model.appIcons.image(for:model.appIcons.choice)),pixels(model.appIcons.image(for:expected))),"settings preview matches the saved selection")
        if phase != "restore-default" {
            let next: AppIconChoice = phase == "select-apps" ? .macOSApps : (phase == "select-original" ? .originalLaunchpad : .launchpod)
            model.selectIcon(next)
            try check(model.appIcons.choice == next,"the real settings action changes the selection")
            try check(matchingPixels(pixels(NSApp.applicationIconImage),pixels(model.appIcons.image(for:next))),"selection immediately updates the Dock artwork")
            try check(matchingPixels(pixels(model.appIcons.image(for:model.appIcons.choice)),pixels(model.appIcons.image(for:next))),"selection immediately updates the preview")
        }
        navigation.select(.custom("launchpod"))
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        if let window = window, let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]),
           let png = NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) {
            try png.write(to:outputDirectory.appendingPathComponent("settings-"+phase+".png"))
        } else { try check(false,"capture settings window") }
        print("PASS: \(checks) app icon settings checks (\(phase))")
    }
}
