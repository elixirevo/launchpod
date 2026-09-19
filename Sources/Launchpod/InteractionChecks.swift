import AppKit
import QuartzCore

/// Construct real AppKit scroll events without posting input to other apps.
func scrollCheckEvent(dx: Int32, dy: Int32 = 0, phase: CGScrollPhase? = nil,
                      precise: Bool = true, momentum: Bool = false) -> NSEvent {
    let event = CGEvent(scrollWheelEvent2Source:nil,units:precise ? .pixel : .line,
                        wheelCount:2,wheel1:dy,wheel2:dx,wheel3:0)!
    event.setIntegerValueField(.scrollWheelEventScrollPhase,value:Int64(phase?.rawValue ?? 0))
    event.setIntegerValueField(.scrollWheelEventMomentumPhase,value:momentum ? 1 : 0)
    return NSEvent(cgEvent:event)!
}

/// Measures the visible body of an installed icon, ignoring its transparent canvas
/// and faint shadow. Used to compare the folder with a real macOS app icon.
func opaqueIconBounds(_ image: NSImage) -> NSRect? {
    let size = 128
    // NSWorkspace icons default to 32pt. A nil proposed rect may select their
    // small artwork variant differently after the screen's scale changes.
    var proposed = NSRect(x:0,y:0,width:size,height:size)
    guard let source = image.cgImage(forProposedRect: &proposed,context: nil,hints: nil) else { return nil }
    var pixels = [UInt8](repeating: 0,count: size*size*4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress,width: size,height: size,bitsPerComponent: 8,
            bytesPerRow: size*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(source,in:CGRect(x:0,y:0,width:size,height:size)); return true
    }
    guard rendered else { return nil }
    var left = size, right = -1, bottom = size, top = -1
    for y in 0..<size { for x in 0..<size where pixels[(y*size+x)*4+3] >= 230 {
        left = min(left,x); right = max(right,x); bottom = min(bottom,y); top = max(top,y)
    } }
    guard right >= left else { return nil }
    return NSRect(x:CGFloat(left)/128,y:CGFloat(bottom)/128,width:CGFloat(right-left+1)/128,height:CGFloat(top-bottom+1)/128)
}

/// Exercises real AppKit mouse routing and timer/animation lifetimes in an isolated store.
struct InteractionCheckStep {
    var delay: TimeInterval = 0
    var perform: () throws -> Void
}

final class InteractionCheckSequence {
    private var steps: [InteractionCheckStep]
    private let completion: (Result<Void, Error>) -> Void
    init(_ steps: [InteractionCheckStep], completion: @escaping (Result<Void, Error>) -> Void) {
        self.steps = steps; self.completion = completion
    }
    func run() {
        guard !steps.isEmpty else { completion(.success(())); return }
        let step = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now()+step.delay) {
            do { try step.perform(); self.run() }
            catch { self.completion(.failure(error)) }
        }
    }
}
