import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let publicKey = Data(repeating: 1, count: 32).base64EncodedString()
let valid: [String: Any] = ["SUFeedURL": "https://updates.example.com/appcast.xml", "SUPublicEDKey": publicKey]
precondition(UpdateController.isConfigured(valid))
for info: [String: Any] in [
    [:], ["SUFeedURL": "https://updates.example.com/appcast.xml"],
    ["SUFeedURL": "http://updates.example.com/appcast.xml", "SUPublicEDKey": publicKey],
    ["SUFeedURL": "https://user:secret@example.com/appcast.xml", "SUPublicEDKey": publicKey],
    ["SUFeedURL": "https://updates.example.com/appcast.xml", "SUPublicEDKey": "invalid"]
] { precondition(!UpdateController.isConfigured(info)) }

// A configured bundle must still stay inert in isolated runs. Menu validation
// must never fall back to the responder chain when the updater is unavailable.
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Contents"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixture) }
var info = valid
info["CFBundleIdentifier"] = "app.launchpod.UpdaterChecks"
info["CFBundleVersion"] = "1"
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: fixture.appendingPathComponent("Contents/Info.plist"))
let bundle = Bundle(url: fixture)!
for args in [["Launchpod", "--data-dir", "/tmp/isolated"], ["Launchpod", "--preview-output", "/tmp/preview.png"]] {
    let updater = UpdateController(bundle: bundle, arguments: args)
    let menu = NSMenu()
    menu.addItem(updater.makeCheckMenuItem())
    menu.addItem(updater.makeAutomaticChecksMenuItem())
    menu.update()
    precondition(menu.items.allSatisfy { !$0.isEnabled && $0.target === updater })
}
let unbundled = UpdateController(arguments: [])
precondition(!unbundled.validateMenuItem(unbundled.makeCheckMenuItem()))
print("PASS: Sparkle configuration, isolated runs, and disabled menu validation")
