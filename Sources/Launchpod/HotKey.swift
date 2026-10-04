import AppKit
import Carbon
import LaunchpodCore
import MacAppSettings

/// Owns the legacy preferences and native registration; recording UI belongs to MacAppSettings.
final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)?
    var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            let status = isRecording ? replaceRegistration(nil) : registerSaved()
            if status != noErr { NSLog("Launchpod: could not resume shortcut (%d)", status) }
        }
    }
    private let defaults: UserDefaults
    private let replaceRegistration: (SettingsShortcut?) -> OSStatus

    init(defaults: UserDefaults = .standard, register: ((SettingsShortcut?) -> OSStatus)? = nil) {
        self.defaults = defaults
        if let register { replaceRegistration = register }
        else {
            let native = NativeHotKeyRegistration()
            replaceRegistration = { native.replace(with: $0) }
            native.onPress = { [weak self] in
                guard let self, !self.isRecording else { return }
                self.action?()
            }
        }
    }

    var shortcut: SettingsShortcut? {
        if defaults.object(forKey: "hotKeyEnabled") != nil && !defaults.bool(forKey: "hotKeyEnabled") { return nil }
        let code = defaults.object(forKey: "hotKeyCode") == nil ? kVK_ANSI_L : defaults.integer(forKey: "hotKeyCode")
        guard (0...127).contains(code) else { return nil }
        let mods = defaults.object(forKey: "hotKeyModifiers") == nil ? controlKey | optionKey : defaults.integer(forKey: "hotKeyModifiers")
        var flags: NSEvent.ModifierFlags = []
        if mods & cmdKey != 0 { flags.insert(.command) }
        if mods & optionKey != 0 { flags.insert(.option) }
        if mods & controlKey != 0 { flags.insert(.control) }
        if mods & shiftKey != 0 { flags.insert(.shift) }
        let oldLabel = defaults.string(forKey: "hotKeyLabel") ?? "⌃⌥L"
        let keyLabel = String(oldLabel.drop(while: { "⌃⌥⇧⌘".contains($0) }))
        return SettingsShortcut(keyCode: UInt16(code), modifiers: flags, keyLabel: keyLabel)
    }

    @discardableResult func registerSaved() -> OSStatus { replaceRegistration(shortcut) }

    func setShortcut(_ value: SettingsShortcut?) throws {
        // Register first. A failed replacement keeps the old registration and saved preferences.
        let status = replaceRegistration(value)
        guard status == noErr else {
            throw NSError(domain: "Launchpod.HotKey", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
                L10n.text("This shortcut could not be registered. It may already be used by another app. Choose a different shortcut.",
                          "단축키를 등록하지 못했습니다. 다른 앱에서 사용 중일 수 있으니 다른 조합을 선택해 주세요.")])
        }
        defaults.set(value != nil, forKey: "hotKeyEnabled")
        if let value {
            defaults.set(Int(value.keyCode), forKey: "hotKeyCode")
            defaults.set(Int(value.carbonModifiers), forKey: "hotKeyModifiers")
            defaults.set(value.displayTitle, forKey: "hotKeyLabel")
        }
    }

    @MainActor func settingsModel() -> ShortcutSettingsModel {
        ShortcutSettingsModel([
            SettingsShortcutAction(id: "toggle-launchpod", title: L10n.text("Open / close Launchpod", "Launchpod 열기 / 닫기"),
                read: { self.shortcut }, write: { try self.setShortcut($0) })
        ], recordingChanged: { self.isRecording = $0 })
    }
}

private extension SettingsShortcut {
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

private final class NativeHotKeyRegistration {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: SettingsShortcut?
    private var sequence: UInt32 = 0
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<NativeHotKeyRegistration>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak owner] in owner?.onPress?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    func replace(with value: SettingsShortcut?) -> OSStatus {
        if let value, registered?.hasSameKey(as: value) == true { return noErr }
        var candidate: EventHotKeyRef?
        if let value {
            sequence &+= 1
            let id = EventHotKeyID(signature: OSType(0x4c6e5064), id: sequence)
            let result = RegisterEventHotKey(UInt32(value.keyCode), value.carbonModifiers, id,
                GetApplicationEventTarget(), 0, &candidate)
            guard result == noErr else { return result }
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate; registered = value
        return noErr
    }
}
