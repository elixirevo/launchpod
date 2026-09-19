import AppKit
import LaunchpodCore

let app = NSApplication.shared
var checks = 0
func check(_ condition: Bool, _ message: String) {
    guard condition else { fputs("Icon check failed: \(message)\n",stderr); exit(1) }
    checks += 1
}
func waitUntil(_ predicate: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow:3)
    while !predicate() && Date() < deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.002)) }
    check(predicate(),"asynchronous work completes within the test deadline")
}
func fixture() -> NSImage {
    let context = CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:1024,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x:0,y:0,width:256,height:256))
    return NSImage(cgImage:context.makeImage()!,size:NSSize(width:128,height:128))
}
final class Counter {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launchpod-icon-checks-"+UUID().uuidString)
defer { try? FileManager.default.removeItem(at:directory) }
let record = AppRecord(title:"Fixture",bundleID:"test.fixture",path:"/test/Fixture.app")
let loads = Counter(), gate = DispatchSemaphore(value:0)
let cache = IconCache(directory:directory) { _ in loads.increment(); gate.wait(); return fixture() }
check(cache.image(for:record) === cache.loadingImage,"healthy pending icon uses a loading image")
check(cache.image(for:record) === cache.loadingImage,"repeated request shares the in-flight job")
var ready: Bool?
cache.prepare([record,record],timeout:1) { ready = $0 }
gate.signal()
waitUntil { ready != nil }
check(ready == true && loads.value == 1,"preparation deduplicates requests and waits for the image")
check(cache.cachedImage(for:record) === cache.image(for:record),"warm reopen returns the same ready image synchronously")
var warm = false
cache.prepare([record]) { warm = $0 }
check(warm,"warm preparation does not delay showing the window")
var unavailable = record; unavailable.available = false
check(cache.image(for:unavailable) !== cache.loadingImage,"missing app is distinct from a loading app")
var unavailableReady = false
cache.prepare([unavailable]) { unavailableReady = $0 }
check(unavailableReady && loads.value == 1,"missing apps never hold up preparation or invoke the loader")

let diskLoads = Counter()
let reopened = IconCache(directory:directory) { _ in diskLoads.increment(); return fixture() }
var diskReady = false
reopened.prepare([record],timeout:1) { diskReady = $0 }
waitUntil { diskReady }
check(diskLoads.value == 0,"a fresh cache instance restores the persisted PNG without fetching the system icon")
var updated = record; updated.iconRevision = Date(timeIntervalSince1970:12345)
let old = reopened.image(for:record)
check(reopened.image(for:updated) === old,"retain last artwork while an installed update is loading")
waitUntil { reopened.cachedImage(for:updated) != nil }
check(diskLoads.value == 1,"app revision invalidates the old disk key")
reopened.invalidate()
let afterAppearance = IconCache(directory:directory) { _ in diskLoads.increment(); return fixture() }
var newAppearance = false
afterAppearance.prepare([record],timeout:1) { newAppearance = $0 }
waitUntil { newAppearance }
check(diskLoads.value == 2,"appearance invalidation survives process/cache recreation")

let slowGate = DispatchSemaphore(value:0)
let slow = IconCache(directory:nil) { _ in slowGate.wait(); return fixture() }
var timeoutResults: [Bool] = []
slow.prepare([record],timeout:0.02) { timeoutResults.append($0) }
waitUntil { !timeoutResults.isEmpty }
check(timeoutResults == [false],"a slow loader releases presentation at the bounded deadline")
slowGate.signal()
waitUntil { slow.cachedImage(for:record) != nil }
check(timeoutResults == [false],"late completion does not present the window twice")

let cancelGate = DispatchSemaphore(value:0)
let cancelled = IconCache(directory:nil) { _ in cancelGate.wait(); return fixture() }
var callbacks = 0
let request = cancelled.prepare([record],timeout:0.02) { _ in callbacks += 1 }
cancelled.cancelPreparation(request)
cancelGate.signal()
waitUntil { cancelled.cachedImage(for:record) != nil }
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.04))
check(callbacks == 0,"dismissing a pending show cancels both readiness and timeout callbacks")

let staleGate = DispatchSemaphore(value:0), started = Counter()
let stale = IconCache(directory:nil) { _ in started.increment(); staleGate.wait(); return fixture() }
_ = stale.image(for:record)
waitUntil { started.value == 1 }
stale.invalidate()
staleGate.signal()
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
check(stale.cachedImage(for:record) == nil,"an invalidated in-flight image cannot repopulate the cache")
print("PASS: \(checks) icon loading checks")
