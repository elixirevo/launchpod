import AppKit
import Carbon

final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var label: String { UserDefaults.standard.string(forKey: "hotKeyLabel") ?? "⌃⌥L" }
    private init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    @discardableResult func registerSaved() -> OSStatus {
        let defaults = UserDefaults.standard
        let code = defaults.object(forKey: "hotKeyCode") == nil ? UInt32(kVK_ANSI_L) : UInt32(defaults.integer(forKey: "hotKeyCode"))
        let mods = defaults.object(forKey: "hotKeyModifiers") == nil ? UInt32(controlKey|optionKey) : UInt32(defaults.integer(forKey: "hotKeyModifiers"))
        return register(code: code, modifiers: mods)
    }
    private func register(code: UInt32, modifiers: UInt32) -> OSStatus {
        if let old = hotKey { UnregisterEventHotKey(old); hotKey = nil }
        let id = EventHotKeyID(signature: OSType(0x4c6e5064), id: 1)
        return RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }
    func change(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command,.control,.option]).isEmpty else { return false }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard register(code: UInt32(event.keyCode), modifiers: modifiers) == noErr else { registerSaved(); return false }
        let key: String
        switch event.keyCode {
        case UInt16(kVK_Space): key = "Space"
        default: key = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        }
        let text = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
        UserDefaults.standard.set(Int(event.keyCode), forKey: "hotKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "hotKeyModifiers")
        UserDefaults.standard.set(text, forKey: "hotKeyLabel")
        return true
    }
}
