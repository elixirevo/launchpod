import AppKit
import QuartzCore
import LaunchpodCore

/// A pointer-following stack that never intercepts clicks on the next app.
final class AppCollectionView: FlippedView {
    private var icons: [NSImageView] = []
    private let badge = FlippedView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private(set) var count = 0
    var frontIconFrame: NSRect { icons.last.map { convert($0.bounds,from:$0) } ?? .zero }
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        badgeLabel.alignment = .center; badgeLabel.font = .boldSystemFont(ofSize:14)
        badgeLabel.textColor = .white; badgeLabel.drawsBackground = false; badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 13
        badge.addSubview(badgeLabel)
        addSubview(badge)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(images: [NSImage], iconSize: CGFloat, source: NSRect) {
        count = images.count
        icons.forEach { $0.removeFromSuperview() }
        icons = images.suffix(3).map { (image: NSImage) -> NSImageView in
            let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true; addSubview(view,positioned:.below,relativeTo:badge)
            return view
        }
        setFrameSize(NSSize(width:iconSize+28,height:iconSize+28))
        for (index,icon) in icons.enumerated() {
            let offset = CGFloat(icons.count-index-1)*7
            icon.frame = NSRect(x:offset,y:offset+10,width:iconSize,height:iconSize)
            icon.alphaValue = index == icons.count-1 ? 1 : 0.8
        }
        badgeLabel.stringValue = String(count)
        let textSize = badgeLabel.intrinsicContentSize
        badge.frame = NSRect(x:iconSize-12,y:0,width:max(26,textSize.width+12),height:26)
        // Keep the native text at its intrinsic height; a tall NSTextField
        // draws at the top even when its horizontal alignment is centered.
        badgeLabel.frame = NSRect(x:0,y:(badge.bounds.height-textSize.height)/2,width:badge.bounds.width,height:textSize.height)
        setAccessibilityLabel(L10n.text("\(count) apps collected", "앱 \(count)개 모음"))
        // Install new AppKit backing layers before adding the pickup animation.
        window?.displayIfNeeded()
        guard !Motion.reduced, let layer = icons.last?.layer else { return }
        let animation = CABasicAnimation(keyPath:"position")
        animation.fromValue = NSValue(point:NSPoint(x:source.midX-frame.minX,y:source.midY-frame.minY))
        animation.toValue = NSValue(point:layer.position)
        animation.duration = 0.2; animation.timingFunction = CAMediaTimingFunction(name:.easeOut)
        layer.add(animation,forKey:"collect")
    }
}
