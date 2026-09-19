import LaunchpodCore
import AppKit

enum AppIconChoice: String, CaseIterable {
    case launchpod, originalLaunchpad, macOSApps
    var title: String {
        switch self {
        case .launchpod: return "Launchpod"
        case .originalLaunchpad: return "Launchpad"
        case .macOSApps: return "Apps"
        }
    }
    var resourceName: String {
        // Bundle filenames are stable identifiers, independent of UI titles.
        switch self {
        case .launchpod: return "Launchpod"
        case .originalLaunchpad: return "OriginalLaunchpad"
        case .macOSApps: return "MacOSApps"
        }
    }
}

final class AppIconSettings {
    private let defaults: UserDefaults
    private let bundle: Bundle
    private var images: [AppIconChoice:NSImage] = [:]
    private let preferenceKey = "applicationIconChoice"
    private let fileIconURL: URL?
    private let refreshDock: () -> Void
    private let appliedFileIconKey = "appliedFileIconState"

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main,
         fileIconURL: URL? = nil, refreshDock: @escaping () -> Void = {}) {
        self.defaults = defaults; self.bundle = bundle
        self.fileIconURL = fileIconURL; self.refreshDock = refreshDock
    }
    var choice: AppIconChoice {
        defaults.string(forKey:preferenceKey).flatMap(AppIconChoice.init(rawValue:)) ?? .launchpod
    }
    func image(for choice: AppIconChoice) -> NSImage? {
        if let image = images[choice] { return image }
        guard let url = bundle.url(forResource:choice.resourceName,withExtension:"icns"),
              let image = NSImage(contentsOf:url), image.isValid else { return nil }
        images[choice] = image
        return image
    }
    func applySavedChoice() {
        NSApp.applicationIconImage = image(for:choice) ?? image(for:.launchpod)
        guard let image = image(for:choice), defaults.string(forKey:preferenceKey) != nil else { return }
        do { if try applyFileIcon(image,choice:choice) { refreshDock() } }
        catch { NSLog("Launchpod: %@",error.localizedDescription) }
    }
    private func fileIconState(for choice: AppIconChoice, at url: URL) -> String {
        let files = [url.appendingPathComponent("Contents/Info.plist"),
                     url.appendingPathComponent("Icon\r")]
        let revisions = files.map { file in
            ((try? file.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970).map { String($0) } ?? "missing"
        }
        return ([url.path,choice.rawValue]+revisions).joined(separator:"|")
    }
    private func applyFileIcon(_ image: NSImage, choice: AppIconChoice) throws -> Bool {
        guard let url = fileIconURL, url.pathExtension == "app" else { return false }
        let state = fileIconState(for:choice,at:url)
        guard defaults.string(forKey:appliedFileIconKey) != state else { return false }
        // Finder custom-icon metadata lives outside signed Contents resources.
        // Removing the override restores the original Icon Composer appearance.
        guard NSWorkspace.shared.setIcon(choice == .launchpod ? nil : image,forFile:url.path,options:[]) else {
            throw NSError(domain:"Launchpod.AppIcon",code:2,
                          userInfo:[NSLocalizedDescriptionKey:L10n.text("Could not change the app file icon. Make sure the app is in a writable Applications folder.", "앱 파일의 아이콘을 변경하지 못했습니다. 앱이 쓰기 가능한 응용 프로그램 폴더에 있는지 확인해 주세요.")])
        }
        defaults.set(fileIconState(for:choice,at:url),forKey:appliedFileIconKey)
        return true
    }
    func select(_ choice: AppIconChoice) throws {
        guard let image = image(for:choice) else {
            throw NSError(domain:"Launchpod.AppIcon",code:1,
                          userInfo:[NSLocalizedDescriptionKey:L10n.text("Could not load the selected icon.", "선택한 아이콘을 불러오지 못했습니다.")])
        }
        _ = try applyFileIcon(image,choice:choice)
        defaults.set(choice.rawValue,forKey:preferenceKey)
        NSApp.applicationIconImage = image
        // A repeated selection can repair a stale Dock tile even when the
        // Finder icon is already correct.
        if fileIconURL?.pathExtension == "app" { refreshDock() }
    }
}
