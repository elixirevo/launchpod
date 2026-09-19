import AppKit
import CryptoKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let source = URL(fileURLWithPath:CommandLine.arguments[1])
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Launchpod-FileIcon-"+UUID().uuidString)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
let target = directory.appendingPathComponent("Launchpod.app")
try FileManager.default.copyItem(at:source,to:target)
let domain = "app.launchpod.FileIconChecks."+UUID().uuidString
let defaults = UserDefaults(suiteName:domain)!
defer { defaults.removePersistentDomain(forName:domain); try? FileManager.default.removeItem(at:directory) }
var checks = 0, refreshes = 0
func expect(_ value: Bool, _ message: String) throws {
    guard value else { throw NSError(domain:"FileIconChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    checks += 1
}
func contentsDigest() throws -> [String:String] {
    var result: [String:String] = [:]
    let root = target.appendingPathComponent("Contents")
    for case let file as URL in FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])! {
        if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
            result[file.path] = SHA256.hash(data:try Data(contentsOf:file)).map { String(format:"%02x",$0) }.joined()
        }
    }
    return result
}
func pixels(_ image: NSImage) -> [UInt8] {
    var rect = NSRect(x:0,y:0,width:512,height:512)
    let cg = image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!
    var bytes=[UInt8](repeating:0,count:32*32*4)
    bytes.withUnsafeMutableBytes { b in
        let context=CGContext(data:b.baseAddress,width:32,height:32,bitsPerComponent:8,bytesPerRow:32*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg,in:CGRect(x:0,y:0,width:32,height:32))
    }
    return bytes
}
func matches(_ a:NSImage,_ b:NSImage) -> Bool {
    let left=pixels(a),right=pixels(b)
    return Double(zip(left,right).reduce(0) {$0+abs(Int($1.0)-Int($1.1))})/Double(left.count) < 5
}
func verifySignature(strict: Bool) throws {
    let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/codesign")
    p.arguments=["--verify","--deep"]+(strict ? ["--strict"] : [])+[target.path]
    try p.run();p.waitUntilExit()
    try expect(p.terminationStatus == 0,"code signature verification")
}
let bundle=Bundle(url:target)!
let settings=AppIconSettings(defaults:defaults,bundle:bundle,fileIconURL:target,refreshDock:{refreshes += 1})
let original=NSWorkspace.shared.icon(forFile:target.path)
let before=try contentsDigest()
for choice in [AppIconChoice.originalLaunchpad,.macOSApps] {
    try settings.select(choice)
    try expect(matches(NSWorkspace.shared.icon(forFile:target.path),settings.image(for:choice)!),"file icon matches \(choice)")
    try expect(settings.choice == choice,"successful file change saves selection")
    try verifySignature(strict:false)
}
let beforeRetry=refreshes
try settings.select(.macOSApps)
try expect(refreshes == beforeRetry+1,"reselecting the same file icon still refreshes a stale Dock tile")
let count=refreshes
let restored=AppIconSettings(defaults:defaults,bundle:bundle,fileIconURL:target,refreshDock:{refreshes += 1})
restored.applySavedChoice()
try expect(refreshes == count,"unchanged startup avoids another Dock restart")
NSWorkspace.shared.setIcon(nil,forFile:target.path,options:[])
restored.applySavedChoice()
try expect(refreshes == count+1 && matches(NSWorkspace.shared.icon(forFile:target.path),settings.image(for:.macOSApps)!),"startup restores a missing file icon")
let invalid=AppIconSettings(defaults:defaults,bundle:bundle,fileIconURL:directory.appendingPathComponent("Missing.app"))
var failed = false
do {try invalid.select(.originalLaunchpad)} catch {failed = true}
try expect(failed && settings.choice == .macOSApps,"failed file change preserves saved selection")
try settings.select(.launchpod)
try expect(matches(NSWorkspace.shared.icon(forFile:target.path),original),"default removes override and restores original file icon")
try expect(try contentsDigest() == before,"signed Contents files are unchanged")
try verifySignature(strict:true)
print("PASS: \(checks) file icon checks")
