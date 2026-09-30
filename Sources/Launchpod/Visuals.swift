import AppKit
import QuartzCore
import CoreImage
import LaunchpodCore

enum Motion {
    // Original -[ECPagerLayer scrollToPageIndex:], 0x1000dc960.
    static let pageDuration = 0.5
    static let pageCurve = CAMediaTimingFunction(controlPoints: 0, 0, 0.35841, 1.0019)
    // Original ECSBLayer.scrollWheel: coalesces phase-less events for 75 ms.
    static let scrollIdleDelay = 0.075
    static let enterDuration = 0.32
    static let exitDuration = 0.28
    static let holdDelay = 0.65
    static let pressScale = 1.1
    static let folderDropDuration = 0.25
    static let folderOpenDuration = 0.32
    static let folderHoverDelay = 1.0 // ECSBOpenGroupDragState.beginTransition, 1e9 ns
    static let folderPreviewDuration = 0.25
    static let insertionDelay = 0.15
    static let reorderDuration = 0.4 // ECSBMoveItemDragState.beginTransition, 0x100331ef8
    static let returnDuration = 0.32
    static func centeredScale(_ scale: CGFloat, on layer: CALayer) -> CATransform3D {
        let x = layer.bounds.width * (0.5-layer.anchorPoint.x)
        let y = layer.bounds.height * (0.5-layer.anchorPoint.y)
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -x, -y, 0)
    }
    static var reduced: Bool { CommandLine.arguments.contains("--reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func duration(_ value: Double) -> Double { reduced ? 0 : value }
}

enum FolderStyle {
    static let maximumRows = 5
    // Share the existing folder icon's tint with the expanded panel. The
    // already blurred wallpaper remains behind both; no dark HUD material.
    static let fill = NSColor(white:0.65,alpha:0.48)
    static let border = NSColor.white.withAlphaComponent(0.16)
    static let panelRadius: CGFloat = 36 // ECSBGroupLayer initWithGroup:...
    static func apply(to layer: CALayer?) {
        layer?.backgroundColor = fill.cgColor; layer?.borderColor = border.cgColor
        layer?.borderWidth = 1; layer?.cornerCurve = .continuous
    }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Share one text rectangle between placeholder drawing and the field editor.
final class SearchTextCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = min(rect.height,ceil((font ?? .systemFont(ofSize:15)).ascender-(font ?? .systemFont(ofSize:15)).descender)+2)
        return NSRect(x:rect.minX,y:rect.midY-height/2,width:rect.width,height:height)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds:rect) }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame:drawingRect(forBounds:rect),in:controlView,editor:textObj,delegate:delegate,start:selStart,length:selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame:drawingRect(forBounds:rect),in:controlView,editor:textObj,delegate:delegate,event:event)
    }
}

/// The magnifier and clear button have their own fixed slots. Native text
/// editing/IME cannot move the placeholder into either icon when focus changes.
final class SearchBox: FlippedView {
    static let height: CGFloat = 44
    static let topGap: CGFloat = 24
    let field = NSTextField()
    let magnifier = NSImageView()
    let clearButton = NSButton()
    var onClear: (() -> Void)?
    private let surface: NSView
    private let content = FlippedView()
    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = Self.height/2
            surface = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow; effect.blendingMode = .withinWindow; effect.state = .active
            effect.wantsLayer = true; effect.layer?.cornerRadius = Self.height/2; effect.layer?.masksToBounds = true
            surface = effect
        }
        super.init(frame: frame)
        appearance = NSAppearance(named:.darkAqua)
        wantsLayer = true; layer?.cornerRadius = Self.height/2
        addSubview(surface)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView { glass.contentView = content }
        else { surface.addSubview(content) }
        field.cell = SearchTextCell(textCell:"")
        field.isEditable = true; field.isSelectable = true
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.font = .systemFont(ofSize:15); field.textColor = .white
        field.cell?.usesSingleLineMode = true; field.lineBreakMode = .byClipping
        field.placeholderAttributedString = NSAttributedString(string:L10n.text("Search apps", "앱 검색"),attributes:[.foregroundColor:NSColor.white.withAlphaComponent(0.6),.font:NSFont.systemFont(ofSize:15)])
        field.focusRingType = .none
        magnifier.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:nil)
        magnifier.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        magnifier.imageScaling = .scaleProportionallyUpOrDown
        magnifier.setAccessibilityElement(false)
        clearButton.image = NSImage(systemSymbolName:"xmark.circle.fill",accessibilityDescription:L10n.text("Clear search", "검색 지우기"))
        clearButton.isBordered = false; clearButton.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        clearButton.target = self; clearButton.action = #selector(clearSearch)
        content.addSubview(magnifier); content.addSubview(field); content.addSubview(clearButton)
        updateState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        surface.frame = bounds; content.frame = bounds
        magnifier.frame = NSRect(x:16,y:bounds.midY-8,width:16,height:16)
        field.frame = NSRect(x:42,y:bounds.midY-13,width:max(0,bounds.width-84),height:26)
        clearButton.frame = NSRect(x:bounds.maxX-36,y:bounds.midY-10,width:20,height:20)
    }
    func refreshLanguage() {
        field.placeholderAttributedString = NSAttributedString(string:L10n.text("Search apps", "앱 검색"),attributes:[.foregroundColor:NSColor.white.withAlphaComponent(0.6),.font:NSFont.systemFont(ofSize:15)])
        clearButton.setAccessibilityLabel(L10n.text("Clear search", "검색 지우기"))
    }
    func updateState() {
        clearButton.isHidden = field.stringValue.isEmpty
        layer?.borderWidth = field.currentEditor() == nil ? 0 : 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
    }
    @objc private func clearSearch() { onClear?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current === field || current === clearButton { return hit }
            view = current.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

final class PageDots: FlippedView {
    var count = 1 { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private var pressedIndex: Int?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.incrementor)
        setAccessibilityLabel(L10n.text("Select page", "페이지 선택"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func center(of index: Int) -> NSPoint {
        // Original control: 15 pt indicator frames with 5 pt between frames.
        let width = CGFloat(count)*15+CGFloat(max(0,count-1))*5
        return NSPoint(x:floor(bounds.midX-width/2)+7.5+CGFloat(index)*20,y:bounds.midY)
    }
    private func index(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return (0..<count).first { abs(point.x-center(of: $0).x) <= 10 }
    }
    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<count {
            let p = center(of: i)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x-4.5,y: p.y-4.5,width: 9,height: 9)).fill()
            (i == selected ? NSColor.white : NSColor.white.withAlphaComponent(0.5)).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x-3.5, y: p.y-3.5, width: 7, height: 7)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        pressedIndex = index(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedIndex = nil }
        if let i = pressedIndex, i == index(at: convert(event.locationInWindow, from: nil)) { onSelect?(i) }
    }
    override func accessibilityValue() -> Any? { "\(selected+1) / \(count)" }
    override func accessibilityPerformIncrement() -> Bool {
        guard selected+1 < count else { return false }; onSelect?(selected+1); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard selected > 0 else { return false }; onSelect?(selected-1); return true
    }
}

struct TileContent: Equatable {
    var id: String
    var title: String
    var image: NSImage?
    var children: [NSImage] = []
    var isFolder = false
    var available = true
    var canRemove = false
    var fileURL: URL?
}

protocol TileDelegate: AnyObject {
    func tilePressed(_ tile: AppTile)
    func tileClicked(_ tile: AppTile)
    func tileHeld(_ tile: AppTile)
    func tileDragBegan(_ tile: AppTile, event: NSEvent)
    func tileDragEnded(_ tile: AppTile, operation: NSDragOperation, point: NSPoint)
    func tileRemove(_ tile: AppTile)
    func tileMenu(_ tile: AppTile) -> NSMenu?
}

/// Native drag previews use logical points, as does the Dock's tilesize.
/// Never resize the shared NSImage: it is also used by the launcher grid.
enum DockDragPreview {
    static var iconSize: CGFloat {
        let value = UserDefaults(suiteName:"com.apple.dock")?.object(forKey:"tilesize") as? NSNumber
        return iconSize(configured:value?.doubleValue)
    }
    static func iconSize(configured: Double?) -> CGFloat {
        guard let value = configured, value.isFinite, value > 0 else { return 64 }
        return CGFloat(min(128,max(16,value)))
    }
    static func frame(source: NSRect, pointer: NSPoint?, iconSize: CGFloat) -> NSRect {
        let anchor = pointer ?? NSPoint(x:source.midX,y:source.midY)
        let x = source.width > 0 ? (anchor.x-source.minX)/source.width : 0.5
        let y = source.height > 0 ? (anchor.y-source.minY)/source.height : 0.5
        return NSRect(x:anchor.x-x*iconSize,y:anchor.y-y*iconSize,width:iconSize,height:iconSize)
    }
}

final class AppTile: FlippedView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("app.launchpod.item")
    var content: TileContent { didSet { if content != oldValue { updateContent() } } }
    weak var delegate: TileDelegate?
    var iconSize: CGFloat = 96 { didSet { if iconSize != oldValue { needsLayout = true } } }
    var iconTopInset: CGFloat? { didSet { if iconTopInset != oldValue { needsLayout = true } } }
    var editing = false { didSet { if editing != oldValue { updateWiggle(); needsLayout = true } } }
    var highlighted = false { didSet { updateHighlight() } }
    var dropHighlight = false { didSet { updateHighlight() } }
    private let iconView = NSImageView()
    private let folderView = FlippedView()
    private let miniatureViewport = FlippedView()
    private let miniatureGrid = FlippedView()
    private(set) var folderDropPreview = false
    private(set) var previewFirstRow = 0
    // A text layer keeps its contents even when the tile's model frame is
    // outside the viewport. AppKit text-field backing can be culled there.
    private let label = CATextLayer()
    private var titleWidth: CGFloat = 0
    private let removeButton = NSButton()
    private let selectionLayer = CALayer()
    private var miniature: [NSImageView] = []
    private var holdTimer: Timer?
    private var externalPreview: DockDragAnimation?
    private var downPoint = NSPoint.zero
    var mouseDownLocation: NSPoint { downPoint }
    private var held = false
    private var didDrag = false
    private(set) var pressed = false
    var labelFrame: NSRect { label.frame }
    var hasRenderedTitle: Bool { label.contents != nil && !label.isHidden && label.opacity > 0 && label.frame.width > 0 }
    var hiddenMiniatures = Set<Int>() { didSet { updateMiniatureVisibility() } }
    var iconFrame: NSRect {
        // Large cells must not pin their artwork to the top. Reserve room for
        // the label and selection padding when a smaller screen limits height.
        let y = iconTopInset ?? max(8, min((bounds.height-iconSize)/2, bounds.height-iconSize-35))
        return NSRect(x: (bounds.width-iconSize)/2, y: y, width: iconSize, height: iconSize)
    }
    var folderIconFrame: NSRect {
        // Original _backdropInsetForFrame uses 5/7/10/12 pt for <=60/<=80/<128/128+.
        // Very small custom grids cap the inset to keep the folder legible.
        let original: CGFloat = iconSize <= 60 ? 5 : (iconSize <= 80 ? 7 : (iconSize < 128 ? 10 : 12))
        let inset = min(original,iconSize*0.12)
        return iconFrame.insetBy(dx: inset,dy: inset)
    }
    var selectionFrame: NSRect {
        // Original _selectionFrame unions the icon and label, then adds padding.
        iconFrame.union(label.frame).insetBy(dx: -12, dy: -5)
            .intersection(bounds.insetBy(dx: 12, dy: 6))
    }
    var interactionFrame: NSRect { selectionFrame }
    func miniatureFrame(at index: Int) -> NSRect {
        let inset = floor(folderIconFrame.width*0.1)
        let size = (folderIconFrame.width-inset*2)/3
        return NSRect(x:folderIconFrame.minX+inset+CGFloat(index%3)*size,
                      y:folderIconFrame.minY+inset+CGFloat(index/3-previewFirstRow)*size, width:size,height:size)
    }
    func displayedMiniatureFrame(at index: Int) -> NSRect {
        let rect = miniatureFrame(at:index), body = folderIconFrame
        let scale: CGFloat = folderDropPreview ? CGFloat(Motion.pressScale) : 1
        return NSRect(x:body.midX+(rect.minX-body.midX)*scale,y:body.midY+(rect.minY-body.midY)*scale,
                      width:rect.width*scale,height:rect.height*scale)
    }
    func setFolderDropPreview(_ active: Bool, reservingSlot: Bool = true, animated: Bool = true) {
        guard content.isFolder else { return }
        let firstRow = active ? max(0,(max(0,content.children.count-(reservingSlot ? 0 : 1)))/3-2) : 0
        guard folderDropPreview != active || previewFirstRow != firstRow else { return }
        layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        let before = miniatureGrid.layer?.presentation()?.position ?? miniatureGrid.layer?.position ?? .zero
        let beforeTransform = folderView.layer?.presentation()?.transform ?? folderView.layer?.transform ?? CATransform3DIdentity
        folderDropPreview = active; previewFirstRow = firstRow
        CATransaction.begin(); CATransaction.setDisableActions(true)
        needsLayout = true; layoutSubtreeIfNeeded()
        folderView.layer?.transform = Motion.centeredScale(active ? CGFloat(Motion.pressScale) : 1,on:folderView.layer!)
        CATransaction.commit()
        updateHighlight(); updateWiggle()
        for (layer,key,from,to) in [
            (miniatureGrid.layer!,"position",NSValue(point:before),NSValue(point:miniatureGrid.layer!.position)),
            (folderView.layer!,"transform",NSValue(caTransform3D:beforeTransform),NSValue(caTransform3D:folderView.layer!.transform))] {
            layer.removeAnimation(forKey:"folderHover")
            if animated && !Motion.reduced {
                let animation = CABasicAnimation(keyPath:key); animation.fromValue = from; animation.toValue = to
                animation.duration = Motion.folderPreviewDuration; animation.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
                layer.add(animation,forKey:"folderHover")
            }
        }
    }

    init(content: TileContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        selectionLayer.cornerRadius = 12
        layer?.addSublayer(selectionLayer)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        folderView.wantsLayer = true
        FolderStyle.apply(to:folderView.layer)
        miniatureViewport.wantsLayer = true; miniatureViewport.layer?.masksToBounds = true
        miniatureGrid.wantsLayer = true
        folderView.addSubview(miniatureViewport); miniatureViewport.addSubview(miniatureGrid)
        label.alignmentMode = .center; label.truncationMode = .end; label.isWrapped = false
        label.fontSize = 13
        label.shadowColor = NSColor.black.cgColor; label.shadowOpacity = 0.65
        label.shadowRadius = 2; label.shadowOffset = CGSize(width: 0, height: -1)
        label.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(label)
        removeButton.title = "×"; removeButton.isBordered = false
        removeButton.font = .systemFont(ofSize: 18, weight: .medium)
        removeButton.contentTintColor = .black
        removeButton.wantsLayer = true
        removeButton.layer?.backgroundColor = NSColor(white: 0.87, alpha: 1).cgColor
        removeButton.layer?.cornerRadius = 11
        removeButton.target = self; removeButton.action = #selector(removeClicked)
        removeButton.setAccessibilityLabel(L10n.text("Delete \(content.title)", "\(content.title) 삭제"))
        addSubview(iconView); addSubview(folderView); addSubview(removeButton)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        updateContent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        label.contentsScale = window?.backingScaleFactor ?? 2
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        label.contentsScale = window?.backingScaleFactor ?? 2
        // Recycling a page detaches its tiles and AppKit removes their layer
        // animations. The cached editing flag stays true, so its didSet does
        // not restart the wiggle when the same tile returns to the window.
        updateWiggle()
    }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if !removeButton.isHidden && removeButton.frame.contains(local) { return removeButton }
        return interactionFrame.contains(local) ? self : nil
    }
    override func layout() {
        super.layout()
        iconView.frame = iconFrame; folderView.frame = folderIconFrame
        folderView.layer?.cornerRadius = folderIconFrame.width*0.22
        let inset = floor(folderIconFrame.width*0.1)
        let mini = (folderIconFrame.width-inset*2)/3
        miniatureViewport.frame = NSRect(x:inset,y:inset,width:mini*3,height:mini*3)
        miniatureGrid.frame = NSRect(x:0,y:-CGFloat(previewFirstRow)*mini,width:mini*3,
                                    height:CGFloat(max(3,(miniature.count+2)/3))*mini)
        for (i, image) in miniature.enumerated() {
            image.frame = NSRect(x: CGFloat(i%3)*mini, y: CGFloat(i/3)*mini, width: mini, height: mini)
        }
        let labelWidth = min(max(0,bounds.width-48), max(iconSize, titleWidth+4))
        label.frame = NSRect(x: (bounds.width-labelWidth)/2, y: iconFrame.maxY+7, width: labelWidth, height: 20)
        label.displayIfNeeded()
        removeButton.frame = NSRect(x: iconFrame.minX-4, y: iconFrame.minY-4, width: 22, height: 22)
        removeButton.isHidden = !editing || !content.canRemove
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionLayer.frame = selectionFrame
        CATransaction.commit()
    }
    func refreshLanguage() { updateContent() }
    private func updateContent() {
        removeButton.setAccessibilityLabel(L10n.text("Delete \(content.title)", "\(content.title) 삭제"))
        FolderStyle.apply(to:folderView.layer)
        if (label.string as? NSAttributedString)?.string != content.title {
            let title = NSAttributedString(string:content.title,attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.white])
            label.string = title; titleWidth = ceil(title.size().width)
            needsLayout = true
        }
        if iconView.image !== content.image { iconView.image = content.image }
        iconView.isHidden = content.isFolder
        folderView.isHidden = !content.isFolder
        iconView.alphaValue = content.available ? 1 : 0.35
        label.opacity = content.available ? 1 : 0.55
        removeButton.isHidden = !editing || !content.canRemove
        if miniature.count != content.children.count {
            miniature.forEach { $0.removeFromSuperview() }
            miniature = content.children.map { image in
                let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
                miniatureGrid.addSubview(view); return view
            }
            needsLayout = true
        } else {
            for (view,image) in zip(miniature,content.children) where view.image !== image { view.image = image }
        }
        updateMiniatureVisibility()
        toolTip = content.available ? content.title : L10n.text("\(content.title) — App not found", "\(content.title) — 앱을 찾을 수 없습니다")
        setAccessibilityLabel(content.title)
        setAccessibilityHelp(content.isFolder ? L10n.text("Open folder", "폴더 열기") : (content.available ? L10n.text("Open app", "앱 실행") : L10n.text("App not found", "앱을 찾을 수 없습니다")))
    }
    private func updateHighlight() {
        label.isHidden = dropHighlight || folderDropPreview
        selectionLayer.backgroundColor = NSColor.white.withAlphaComponent(dropHighlight ? 0.25 : (highlighted ? 0.15625 : 0)).cgColor
        selectionLayer.borderWidth = dropHighlight ? 2 : 0
        selectionLayer.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
    }
    private func setPressed(_ value: Bool) {
        pressed = value
        for view in [iconView, folderView] {
            // Original setDarkened: multiplies by gray 0.4 (0x100331ef8).
            // Preserve hue and alpha, like a black veil over the icon's pixels.
            view.contentFilters = value ? [CIFilter(name:"CIColorMatrix",parameters:[
                "inputRVector":CIVector(x:0.4,y:0,z:0,w:0),
                "inputGVector":CIVector(x:0,y:0.4,z:0,w:0),
                "inputBVector":CIVector(x:0,y:0,z:0.4,w:0),
                "inputAVector":CIVector(x:0,y:0,z:0,w:1)
            ])!] : []
        }
    }
    private func updateMiniatureVisibility() {
        for (index,view) in miniature.enumerated() { view.isHidden = hiddenMiniatures.contains(index) }
    }
    func animateFolderReveal() {
        guard !Motion.reduced else { return }
        let fade = CABasicAnimation(keyPath:"opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = Motion.folderDropDuration
        folderView.layer?.add(fade,forKey:"folderFormation")
    }
    private func pulse() {
        guard !Motion.reduced else { return }
        for view in [iconView, folderView] {
            guard let layer = view.layer else { continue }
            let pulse = CAKeyframeAnimation(keyPath: "transform")
            pulse.values = [NSValue(caTransform3D: CATransform3DIdentity),
                            NSValue(caTransform3D: Motion.centeredScale(CGFloat(Motion.pressScale), on: layer)),
                            NSValue(caTransform3D: CATransform3DIdentity)]
            pulse.keyTimes = [0, 0.5, 1]; pulse.duration = 0.22
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            layer.add(pulse, forKey: "pressPulse")
        }
    }
    private func updateWiggle() {
        for view in [iconView, folderView] {
            view.layer?.removeAnimation(forKey: "editing")
            guard window != nil && editing && !Motion.reduced && !folderDropPreview else { continue }
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            animation.values = [-0.018, 0.018, -0.018]
            animation.duration = 0.24 + Double(abs(content.id.hashValue % 5))*0.012
            animation.repeatCount = .infinity
            view.layer?.add(animation, forKey: "editing")
        }
    }
    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow; held = false; didDrag = false
        setPressed(true); delegate?.tilePressed(self)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Motion.holdDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.pressed, !self.didDrag else { return }
            self.held = true; self.setPressed(false); self.delegate?.tileHeld(self); self.pulse()
        }
        if let timer = holdTimer { RunLoop.main.add(timer, forMode: .common) }
    }
    override func mouseDragged(with event: NSEvent) {
        let distance = hypot(event.locationInWindow.x-downPoint.x, event.locationInWindow.y-downPoint.y)
        guard !didDrag && distance > 6 else { return }
        didDrag = true; holdTimer?.invalidate(); setPressed(false)
        delegate?.tileDragBegan(self, event: event)
    }
    func makeExternalDraggingItem(in view: NSView, at pointer: NSPoint? = nil,
                                  dockIconSize: CGFloat = DockDragPreview.iconSize) -> NSDraggingItem {
        let pasteboard = NSPasteboardItem(); pasteboard.setString(content.id, forType: Self.pasteboardType)
        if let url = content.fileURL { pasteboard.setString(url.absoluteString, forType: .fileURL) }
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        layoutSubtreeIfNeeded()
        // A file drag into the Dock carries only the app artwork. Capturing
        // the tile would also carry its title, selection and unused cell space.
        let frame = DockDragPreview.frame(source:convert(iconFrame,to:view),pointer:pointer,iconSize:dockIconSize)
        item.setDraggingFrame(frame, contents: content.image)
        return item
    }
    func beginExternalDrag(event: NSEvent, in view: NSView) {
        guard let window = view.window else { return }
        let pointer = view.convert(event.locationInWindow,from:nil)
        let source = convert(iconFrame,to:view)
        let screenFrame = window.convertToScreen(view.convert(source,to:nil))
        let screenPointer = window.convertPoint(toScreen:event.locationInWindow)
        externalPreview = DockDragAnimation(sourceFrame:screenFrame,pointer:screenPointer,
                                            artwork:content.image,dockSize:DockDragPreview.iconSize)
        // Handoff starts at exactly the grid size; the live session then shrinks.
        let item = makeExternalDraggingItem(in:view,at:pointer,dockIconSize:source.width)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        setPressed(false)
        if !didDrag && !held && interactionFrame.contains(convert(event.locationInWindow, from: nil)) { delegate?.tileClicked(self) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { delegate?.tileMenu(self) }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : (content.fileURL == nil ? [] : [.copy, .link])
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        externalPreview?.begin(session,at:screenPoint)
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        externalPreview?.move(to:screenPoint)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        externalPreview?.stop(); externalPreview = nil
        delegate?.tileDragEnded(self, operation: operation, point: screenPoint)
    }
    override func accessibilityPerformPress() -> Bool {
        delegate?.tileClicked(self)
        return true
    }
    @objc private func removeClicked() { delegate?.tileRemove(self) }
    deinit { holdTimer?.invalidate() }
}

/// Presentation only: the layout is committed once, then live-resolution icons
/// travel to their final folder slots. This view never intercepts mouse events.
final class FolderDropTransition: FlippedView {
    struct Source {
        var content: TileContent
        var icon: NSRect
        var label: NSRect
    }
    struct Flight {
        let image: NSImageView
        let label: NSTextField
        let from: NSRect
        let to: NSRect
        let disappears: Bool
    }
    private(set) var flights: [Flight] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func add(_ source: Source, to destination: NSRect, disappears: Bool = false) {
        let icon = NSImageView(frame:source.icon)
        icon.image = source.content.image; icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        let label = NSTextField(labelWithString:source.content.title)
        label.frame = source.label; label.font = .systemFont(ofSize:13)
        label.alignment = .center; label.textColor = .white
        label.lineBreakMode = .byTruncatingTail; label.wantsLayer = true
        label.layer?.shadowColor = NSColor.black.cgColor; label.layer?.shadowOpacity = 0.65
        label.layer?.shadowRadius = 2; label.layer?.shadowOffset = NSSize(width:0,height:-1)
        addSubview(icon); addSubview(label)
        flights.append(Flight(image:icon,label:label,from:source.icon,to:destination,disappears:disappears))
    }
    func animate(duration: TimeInterval, completion: @escaping () -> Void) {
        window?.displayIfNeeded(); CATransaction.flush()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        for flight in flights {
            // Keep the image backing at its original resolution throughout
            // the shrink, as the original _minimizeLayer: transform does.
            if let layer = flight.image.layer {
                let scale = flight.to.width/flight.from.width
                let position = NSPoint(x:flight.to.minX+layer.anchorPoint.x*flight.to.width,
                                       y:flight.to.minY+layer.anchorPoint.y*flight.to.height)
                let movement = CABasicAnimation(keyPath:"position")
                movement.fromValue = NSValue(point:layer.position); movement.toValue = NSValue(point:position)
                let shrink = CABasicAnimation(keyPath:"transform")
                shrink.fromValue = NSValue(caTransform3D:layer.transform)
                let transform = CATransform3DMakeScale(scale,scale,1)
                shrink.toValue = NSValue(caTransform3D:transform)
                let animations = CAAnimationGroup()
                animations.animations = [movement,shrink]; animations.duration = duration
                animations.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
                layer.position = position; layer.transform = transform
                layer.add(animations,forKey:"folderDrop")
                if flight.disappears {
                    let fade = CABasicAnimation(keyPath:"opacity")
                    fade.fromValue = 1; fade.toValue = 0; fade.duration = duration
                    layer.opacity = 0; layer.add(fade,forKey:"folderDropFade")
                }
            }
            let fade = CABasicAnimation(keyPath:"opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = min(0.12,duration)
            flight.label.layer?.opacity = 0; flight.label.layer?.add(fade,forKey:"folderDropLabel")
        }
        CATransaction.commit()
    }
}
