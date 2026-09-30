import AppKit
import QuartzCore
import LaunchpodCore

final class LauncherView: FlippedView, NSTextFieldDelegate, TileDelegate {
    weak var controller: LauncherController?
    private let wallpaper = NSImageView()
    private let searchBox = SearchBox()
    private var search: NSTextField { searchBox.field }
    private var grid = FlippedView()
    private let gridViewport = FlippedView()
    private let folderPanel = FlippedView()
    private let folderTitle = NSTextField()
    private var folderGrid = FlippedView()
    private let folderViewport = FlippedView()
    private let pageDots = PageDots()
    private let folderDots = PageDots()
    private let message = NSTextField(labelWithString: "")
    private var tiles: [AppTile] = []
    private var folderTiles: [AppTile] = []
    private var currentPage = 0
    private var folderPage = 0
    private var selectedID: String?
    private var currentResults: [String] = []
    private var folderSourceRect = NSRect.zero
    private var folderOpening = false
    private var folderClosing = false
    private var folderOpeningGeneration = 0
    private var folderOpeningLayers: [CALayer] = []
    private var folderOpeningOverlay: FlippedView?
    private var scrollAccumulator: CGFloat = 0
    private var scrollIdleTimer: Timer?
    private var ignoredScrollSequence = false
    private var lastPageTurn: TimeInterval = 0
    private var outgoingPage: FlippedView?
    private var outgoingOffset = 0
    private var outgoingIndex = 0
    private var pageTransition = false
    private var pageTransitionGeneration = 0
    private var queuedPage: (page: Int, inside: Bool, allowNew: Bool)?
    private var transientPage: ItemLocation?
    private struct BackgroundGesture {
        var start: NSPoint
        var last: NSPoint
        var lastTime: TimeInterval
        var velocity: CGFloat = 0
        var moved = false
        var paging = false
        var insideFolder: Bool
        var initialPage: Int
        var displacement: CGFloat = 0
        var fromScroll = false
        var scrollUsesX: Bool?
        var inputTranslation: CGFloat = 0
        var inheritedTarget: Int?
    }
    private var backgroundGesture: BackgroundGesture?
    private var neighboringPages: [(offset: Int, view: FlippedView)] = []
    private var settlingPage = false
    private var settlingInsideFolder = false
    private let reusableTiles = NSCache<NSString, AppTile>()
    private var warmupGeneration = 0
    private var pagingGeneration = 0
    private var pageAnimationPendingCommit = false
    private var pageAnimationSerial = 0
    private var pageTimingSamples: [String]?
    private var dragID: String?
    private var collectedAppIDs: [String] = []
    private var collectionBaseState: LayoutState?
    private var collectionView: AppCollectionView?
    private var collectionPoint = NSPoint.zero
    private var collectionMouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var collectionConsumesClick = false
    private var collectionEdgeTimer: Timer?
    private var collectionEdge = 0
    private var collectionHoverTimer: Timer?
    private var collectionHoverID: String?
    private var collectionGroupReady = false
    private var collectionEnteredFolder = false
    // Accepted positions belong to the ongoing drag. Persist once on release,
    // so Escape and Undo can still restore the complete original layout.
    private var dragLayout: LayoutState?
    private var dragBaseState: LayoutState?
    private var extractingFolderID: String?
    private var extractedFolderID: String?
    private var dropAfterFolderClose = false
    private var insertionCandidate: ItemLocation?
    private var insertionTimer: Timer?
    private var returningTile: AppTile?
    private var returnHiddenID: String?
    private var returnGeneration = 0
    private var menuHeights: [UInt32:(size:NSSize,height:CGFloat)] = [:]
    private var dockReservation = NSSize.zero
    private var draggedTile: AppTile?
    private var dragOffset = NSPoint.zero
    private var externalDrag = false
    private let dockDragRegion = DockDragRegion()
    private var lastDragPoint = NSPoint.zero
    private var dragFolderAtStart: String?
    private var springLoadedFolderID: String?
    private var springLoadedEntryPoint: NSPoint?
    private var dropPreviewFolderID: String?
    private var hoverID: String?
    private var hoverStarted: TimeInterval = 0
    private var hoverArmed = false
    private var edgeDirection = 0
    private var edgeTimer: Timer?
    private var hoverTimer: Timer?
    private var pendingDrop: ItemLocation?
    private var folderDrop: FolderDropTransition?
    private var folderDropGeneration = 0
    private var dropHiddenIDs = Set<String>()
    private var dropHiddenMinis: [String:Set<Int>] = [:]
    private var renameAfterDrop: String?
    private let insertionLine = FlippedView()
    private var interaction = InteractionState()
    var isDraggingItem: Bool { dragID != nil || !collectedAppIDs.isEmpty }
    var columns: Int { max(3, min(9, UserDefaults.standard.integer(forKey: "columns") == 0 ? 7 : UserDefaults.standard.integer(forKey: "columns"))) }
    var rows: Int { max(3, min(7, UserDefaults.standard.integer(forKey: "rows") == 0 ? 5 : UserDefaults.standard.integer(forKey: "rows"))) }
    var capacity: Int { columns*rows }
    var folderCapacity: Int { columns*FolderStyle.maximumRows }
    private var folderRows: Int {
        guard let folder = interaction.folderID.flatMap({ presentationState.folder($0) }) else { return 1 }
        var count = folder.pages.reduce(0) { $0+$1.count }
        // Reserve the next row while bringing an app into a full last row.
        if let id = dragID, state.app(id) != nil, presentationState.location(of:id)?.folderID != folder.id { count += 1 }
        return max(1,min(FolderStyle.maximumRows,(count+columns-1)/columns))
    }
    override var acceptsFirstResponder: Bool { true }
    private var state: LayoutState { controller?.state ?? LayoutState() }
    private var presentationState: LayoutState { dragLayout ?? state }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.32, alpha: 1).cgColor
        wallpaper.imageScaling = .scaleAxesIndependently
        // The processed wallpaper is opaque, including Reduce Transparency.
        // Its original color matrix supplies contrast without another black veil.
        addSubview(wallpaper)
        grid.wantsLayer = true; folderGrid.wantsLayer = true
        for viewport in [gridViewport, folderViewport] {
            viewport.wantsLayer = true; viewport.layer?.masksToBounds = true
        }
        addSubview(gridViewport); gridViewport.addSubview(grid)
        reusableTiles.countLimit = 210
        search.delegate = self; search.focusRingType = .none
        searchBox.onClear = { [weak self] in
            guard let self = self else { return }
            self.search.stringValue = ""
            self.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:self.search))
            self.window?.makeFirstResponder(self.search)
        }
        search.setAccessibilityLabel(L10n.text("Search apps", "앱 검색"))
        addSubview(searchBox)
        folderPanel.wantsLayer = true; folderPanel.layer?.cornerRadius = FolderStyle.panelRadius
        folderPanel.layer?.masksToBounds = true; FolderStyle.apply(to:folderPanel.layer)
        addSubview(folderPanel); addSubview(folderTitle); addSubview(folderViewport); folderViewport.addSubview(folderGrid)
        folderTitle.isBordered = false; folderTitle.drawsBackground = false
        folderTitle.wantsLayer = true
        folderTitle.textColor = .white; folderTitle.font = .systemFont(ofSize: 28, weight: .light)
        folderTitle.alignment = .center; folderTitle.delegate = self; folderTitle.focusRingType = .none
        folderTitle.setAccessibilityLabel(L10n.text("Folder name", "폴더 이름"))
        addSubview(pageDots); addSubview(folderDots)
        pageDots.onSelect = { [weak self] p in self?.changePage(p) }
        folderDots.onSelect = { [weak self] p in self?.changePage(p, insideFolder: true) }
        message.textColor = NSColor.white.withAlphaComponent(0.75); message.font = .systemFont(ofSize: 20, weight: .light)
        message.alignment = .center; addSubview(message)
        insertionLine.wantsLayer = true; insertionLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
        insertionLine.layer?.cornerRadius = 2; insertionLine.isHidden = true; addSubview(insertionLine)
        registerForDraggedTypes([AppTile.pasteboardType, .fileURL])
        showFolderViews(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize && frame.width > 0 && frame.height > 0 {
            // A slide/drag retains coordinates from its original screen size.
            // End that presentation before laying out the same page again.
            cancelItemDrag(); finishFolderOpening(); cancelBackgroundPaging(); cancelPageTransition()
        }
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func prepareForShow(screen: NSScreen) {
        captureLayoutReservation(screen:screen)
        interaction = InteractionState(); search.stringValue = ""; selectedID = nil
        stopHover(); dragID = nil; currentPage = min(currentPage, max(state.pages.count-1, 0))
        updateBackground(screen: screen)
        refresh()
    }
    func updateBackground(screen: NSScreen) { wallpaper.image = controller?.wallpaper(for:screen,refresh:true) }
    var initialIconRecords: [AppRecord] {
        guard state.pages.indices.contains(currentPage) else { return [] }
        return state.pages[currentPage].flatMap { id -> [AppRecord] in
            if let folder = state.folder(id) { return folder.pages.flatMap { $0 }.prefix(9).compactMap { state.app($0) } }
            return state.app(id).map { [$0] } ?? []
        }
    }
    func captureLayoutReservation(screen: NSScreen) {
        guard !CommandLine.arguments.contains("--windowed") else { dockReservation = .zero; return }
        let defaults = UserDefaults(suiteName:"com.apple.dock")
        let size = defaults?.double(forKey:"tilesize") ?? 64
        let extent = ceil(size >= 16 && size <= 128 ? size : 64)+20
        let side = ["left","right"].contains(defaults?.string(forKey:"orientation") ?? "bottom")
        // Reserve the Dock's resting footprint even with auto-hide enabled.
        // Transient visibleFrame changes must not resize a page under a swipe.
        dockReservation = side ? NSSize(width:max(extent,screen.frame.width-screen.visibleFrame.width),height:0)
            : NSSize(width:0,height:max(extent,screen.visibleFrame.minY-screen.frame.minY))
    }
    func refreshLanguage() {
        searchBox.refreshLanguage()
        search.setAccessibilityLabel(L10n.text("Search apps", "앱 검색"))
        folderTitle.setAccessibilityLabel(L10n.text("Folder name", "폴더 이름"))
        pageDots.setAccessibilityLabel(L10n.text("Select page", "페이지 선택"))
        folderDots.setAccessibilityLabel(L10n.text("Select page", "페이지 선택"))
        reusableTiles.removeAllObjects()
        for tile in tiles + folderTiles { tile.refreshLanguage() }
        refresh()
    }
    func refresh() {
        searchBox.updateState()
        if let base = collectionBaseState, base != state { cancelAppCollection(); return }
        // A catalog refresh or Undo must not be overwritten by an older drag.
        if let base = dragBaseState, base != state { cancelItemDrag(); return }
        guard !(folderClosing && dragID != nil) else { return }
        guard backgroundGesture?.paging != true, !settlingPage, !pageTransition else { return }
        finishItemReturn(refresh:false)
        finishFolderOpening()
        let layout = presentationState
        if let id = interaction.folderID, layout.folder(id) == nil { interaction.folderID = nil }
        let rootLimit = layout.pages.count-1+(isDraggingItem && transientPage?.folderID == nil && transientPage != nil ? 1 : 0)
        currentPage = max(0, min(currentPage, rootLimit))
        let searching = !interaction.query.isEmpty
        currentResults = searching ? AppSearch.results(for: interaction.query, in: state).map(\.id) : []
        var pages = searching ? chunk(currentResults, capacity) : layout.pages
        if !searching, isDraggingItem, let transient = transientPage, transient.folderID == nil, transient.page == pages.count { pages.append([]) }
        currentPage = min(currentPage, max(0, pages.count-1))
        let visible = pages.indices.contains(currentPage) ? pages[currentPage] : []
        buildTiles(visible, in: grid, storage: &tiles)
        pageDots.count = max(1, pages.count); pageDots.selected = currentPage
        pageDots.isHidden = false
        if let f = interaction.folderID.flatMap({ layout.folder($0) }) {
            var pages = f.pages
            if isDraggingItem, let transient = transientPage, transient.folderID == f.id, transient.page == pages.count { pages.append([]) }
            folderPage = min(folderPage, max(0, pages.count-1))
            let ids = pages.indices.contains(folderPage) ? pages[folderPage] : []
            buildTiles(ids, in: folderGrid, storage: &folderTiles)
            if !interaction.renaming { folderTitle.stringValue = f.title }
            folderDots.count = max(1, pages.count); folderDots.selected = folderPage
            folderDots.isHidden = f.pages.count < 2
        }
        showFolderViews(interaction.folderID != nil)
        message.stringValue = controller?.isScanning == true && state.apps.isEmpty ? L10n.text("Finding apps…", "앱을 찾는 중…") : (searching ? L10n.text("No results", "검색 결과 없음") : L10n.text("No apps to display", "표시할 앱이 없습니다"))
        message.isHidden = !visible.isEmpty || interaction.folderID != nil
        needsLayout = true; layoutSubtreeIfNeeded()
        updateSelection()
        warmAdjacentPages()
    }
    /// Prepare one tile per small scheduling slice. Skip already-live items
    /// immediately, and pause while a finger is controlling the page.
    private func warmAdjacentPages() {
        warmupGeneration += 1
        guard controller?.isPreparingToShow != true else { return }
        let generation = warmupGeneration
        let inside = interaction.folderID != nil
        let page = inside ? folderPage : currentPage
        let pages = visiblePages(insideFolder:inside)
        let ids = [1,-1,2,-2].filter { pages.indices.contains(page+$0) }.flatMap { pages[page+$0] }
        func warm(_ index: Int) {
            guard generation == self.warmupGeneration, index < ids.count else { return }
            if self.backgroundGesture?.paging == true {
                DispatchQueue.main.asyncAfter(deadline:.now()+1.0/60) { warm(index) }
                return
            }
            let live = Set((self.tiles+self.folderTiles
                + (self.outgoingPage?.subviews.compactMap { $0 as? AppTile } ?? [])
                + self.neighboringPages.flatMap { $0.view.subviews.compactMap { $0 as? AppTile } }).map { $0.content.id })
            var next = index
            while next < ids.count {
                let id = ids[next]; next += 1
                if self.reusableTiles.object(forKey:id as NSString) != nil || live.contains(id) { continue }
                let tile = AppTile(content:self.tileContent(id,priority:.low))
                let host = FlippedView(frame:(inside ? self.folderGrid : self.grid).bounds)
                self.layoutTiles([tile],in:host,rowCount:inside ? self.folderRows : self.rows,insideFolder:inside)
                tile.layoutSubtreeIfNeeded()
                self.reusableTiles.setObject(tile,forKey:id as NSString)
                break
            }
            let resume = next
            DispatchQueue.main.asyncAfter(deadline:.now()+1.0/120) { warm(resume) }
        }
        DispatchQueue.main.async { warm(0) }
    }
    private func chunk(_ ids: [String], _ size: Int) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min(ids.count, $0+size)]) }
    }
    private func tileContent(_ id: String, priority: Operation.QueuePriority = .normal) -> TileContent {
        if let f = presentationState.folder(id) {
            // Keep all slots for tail-scrolling/drop geometry, but only decode
            // the first nine while closed. Drag/open refresh requests the rest.
            let children = f.pages.flatMap { $0 }.compactMap { state.app($0) }.enumerated().compactMap { index,app -> NSImage? in
                guard let icons = controller?.icons else { return nil }
                if index < 9 || dragID != nil || interaction.folderID == id { return icons.image(for:app,priority:priority) }
                return icons.cachedImage(for:app) ?? icons.loadingImage
            }
            return TileContent(id: id, title: f.title, image: nil,
                               children: children, isFolder: true)
        }
        if let app = state.app(id) {
            return TileContent(id: id, title: app.title, image: controller?.icons.image(for: app,priority:priority), available: app.available,
                               canRemove: controller?.canOfferTrash(app) ?? false,
                               fileURL: app.available && !app.path.isEmpty ? URL(fileURLWithPath: app.path) : nil)
        }
        return TileContent(id: id, title: "", image: nil)
    }
    func updateIcon(at path: String) {
        let appIDs = Set(state.apps.filter { $0.path == path }.map(\.id))
        let folders = Set(presentationState.folders.filter { !$0.pages.flatMap { $0 }.allSatisfy { !appIDs.contains($0) } }.map(\.id))
        let views = tiles+folderTiles
            + (outgoingPage?.subviews.compactMap { $0 as? AppTile } ?? [])
            + neighboringPages.flatMap { $0.view.subviews.compactMap { $0 as? AppTile } }
            + [draggedTile,returningTile].compactMap { $0 }
        // Update artwork in place, even during motion. Never rebuild the page
        // or reset its gesture merely because a background icon finished.
        for tile in views where appIDs.contains(tile.content.id) || folders.contains(tile.content.id) {
            tile.content = tileContent(tile.content.id)
        }
    }
    private func buildTiles(_ ids: [String], in view: NSView, storage: inout [AppTile]) {
        // Stable views for unchanged pages keep focus and animations intact.
        let existing = Dictionary(uniqueKeysWithValues: storage.map { ($0.content.id, $0) })
        let visibleIDs = Set(ids)
        for tile in storage where !visibleIDs.contains(tile.content.id) {
            tile.removeFromSuperview()
            reusableTiles.setObject(tile,forKey:tile.content.id as NSString)
        }
        storage = ids.map { id in
            let content = tileContent(id)
            let cached = reusableTiles.object(forKey:id as NSString)
            let tile = existing[id] ?? (cached?.superview == nil ? cached : nil) ?? AppTile(content: content)
            reusableTiles.removeObject(forKey:id as NSString)
            tile.content = content; tile.delegate = self; tile.editing = interaction.editing
            if tile.superview == nil { view.addSubview(tile) }
            tile.isHidden = dragID == id || collectedAppIDs.contains(id) || returnHiddenID == id || dropHiddenIDs.contains(id)
            tile.hiddenMiniatures = dropHiddenMinis[id] ?? []
            tile.alphaValue = 1
            return tile
        }
    }
    override func layout() {
        super.layout()
        wallpaper.frame = bounds
        let menuHeight = menuBarHeight
        let searchWidth = min(360,max(0,bounds.width-40))
        searchBox.frame = NSRect(x: bounds.midX-searchWidth/2, y: menuHeight+SearchBox.topGap, width: searchWidth, height: SearchBox.height)
        let hMargin = rootHorizontalMargin
        let dockHeight = dockReservation.height
        let pageMetrics = rootPageMetrics
        pageDots.frame = NSRect(x:bounds.midX-150,y:pageMetrics.dotsCenterY-14,width:300,height:28)
        // A page includes its left/right margins. Only the physical screen edge
        // clips the moving page; the grid's inner margins move with it.
        gridViewport.frame = pageMetrics.grid
        if !pageTransition { grid.frame = pageContentFrame(insideFolder: false) }
        layoutTiles(tiles, in: grid, rowCount: rows)
        let titleHeight: CGFloat = 40, titleGap: CGFloat = 14, padding: CGFloat = 20
        let top = menuHeight+titleHeight+titleGap
        let bottom = max(48,dockHeight+20)
        let dotsHeight: CGFloat = folderDots.count > 1 ? 28 : 0
        let available = max(0,bounds.height-top-bottom)
        // Keep icon spacing stable as a folder grows, while reserving room for
        // five rows, its external title and the Dock even on a small display.
        let rowHeight = min(grid.bounds.height/CGFloat(rows),max(0,(available-padding*2-28)/CGFloat(FolderStyle.maximumRows)))
        let panelHeight = rowHeight*CGFloat(folderRows)+padding*2+dotsHeight
        let panelX = max(20,hMargin-padding)
        let panel = NSRect(x:panelX,y:max(top,min((bounds.height-panelHeight)/2,bounds.height-bottom-panelHeight)),
                           width:max(0,bounds.width-panelX*2),height:panelHeight)
        folderPanel.frame = panel
        FolderStyle.apply(to:folderPanel.layer)
        folderTitle.frame = NSRect(x:panel.minX+40,y:panel.minY-titleGap-titleHeight,width:max(0,panel.width-80),height:titleHeight)
        folderViewport.frame = NSRect(x:panel.minX,y:panel.minY+padding,width:panel.width,height:rowHeight*CGFloat(folderRows))
        if !pageTransition { folderGrid.frame = pageContentFrame(insideFolder: true) }
        layoutTiles(folderTiles, in: folderGrid, rowCount: folderRows, insideFolder:true)
        folderDots.frame = NSRect(x:bounds.midX-150,y:folderViewport.frame.maxY+4,width:300,height:20)
        message.frame = NSRect(x: bounds.midX-250, y: bounds.midY-20, width: 500, height: 40)
    }
    private func layoutTiles(_ list: [AppTile], in view: NSView, rowCount: Int, insideFolder: Bool = false) {
        let width = view.bounds.width/CGFloat(columns), height = view.bounds.height/CGFloat(rowCount)
        let icon = LaunchpadIconMetrics.fittedSize(preferred: preferredIconSize,
                                                  cell:NSSize(width:width,height:height))
        for (i, tile) in list.enumerated() {
            tile.frame = NSRect(x: CGFloat(i%columns)*width, y: CGFloat(i/columns)*height, width: width, height: height)
            tile.iconSize = icon
            tile.iconTopInset = insideFolder ? nil : LaunchpadPageMetrics.iconTop(cellHeight:height,iconSize:icon)
        }
    }
    private var rootPageMetrics: LaunchpadPageMetrics {
        let screen = window?.screen ?? NSScreen.main
        let fullScreen = !CommandLine.arguments.contains("--windowed")
        return LaunchpadPageMetrics(size:bounds.size,rows:rows,columns:columns,dockExtent:dockReservation.height,
            sideDockExtent:dockReservation.width,safeTop:fullScreen ? (screen?.safeAreaInsets.top ?? 0) : 0,
            searchBottom:menuBarHeight+SearchBox.topGap+SearchBox.height)
    }
    private var preferredIconSize: CGFloat {
        let reserved = NSSize(width:dockReservation.width,height:menuBarHeight+SearchBox.topGap+dockReservation.height)
        return LaunchpadIconMetrics.preferredSize(screen:bounds.size,reserved:reserved,rows:rows,columns:columns)
    }
    private func pageContentFrame(insideFolder: Bool) -> NSRect {
        let viewport = insideFolder ? folderViewport : gridViewport
        // Before the first layout a viewport can still be zero-sized. CGRect
        // insetting past that width yields a null rect with infinite origins.
        let inset = min(viewport.bounds.width/2, insideFolder ? 20 : rootHorizontalMargin)
        return NSRect(x:viewport.bounds.minX+inset,y:viewport.bounds.minY,
                      width:max(0,viewport.bounds.width-inset*2),height:viewport.bounds.height)
    }
    private var rootHorizontalMargin: CGFloat {
        // LaunchOS's seven-column reference uses centers at 1/8 ... 7/8
        // of the page width. Keep a half-cell gutter on either edge.
        let width = bounds.width
        let margin = width/CGFloat(2*(columns+1))
        return min(max(0,(width-CGFloat(columns)*72)/2), margin)
    }
    private var menuBarHeight: CGFloat {
        guard let screen = window?.screen ?? NSScreen.main else { return max(22,NSStatusBar.system.thickness) }
        let key = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let measured = max(NSStatusBar.system.thickness,max(screen.safeAreaInsets.top,screen.frame.maxY-screen.visibleFrame.maxY))
        let old = menuHeights[key]
        let height = old?.size == screen.frame.size ? max(measured,old!.height) : measured
        menuHeights[key] = (screen.frame.size,height)
        return height
    }
    private func pageStride(insideFolder: Bool) -> CGFloat {
        // Original ECPagerLayer: scroll offset = full pager width × page index.
        (insideFolder ? folderViewport : gridViewport).bounds.width
    }
    private func showFolderViews(_ show: Bool) {
        folderPanel.isHidden = !show; folderViewport.isHidden = !show; folderTitle.isHidden = !show
        folderDots.isHidden = !show || folderDots.count < 2
        gridViewport.alphaValue = 1; gridViewport.isHidden = show
        pageDots.isHidden = show
        searchBox.isHidden = show
    }
    func animateVisibility(showing: Bool, fromHidden: Bool = false, completion: (() -> Void)? = nil) {
        finishItemReturn()
        finishFolderOpening()
        cancelPageTransition()
        cancelBackgroundPaging()
        guard let root = layer else { completion?(); return }
        let duration = Motion.reduced ? 0.12 : (showing ? Motion.enterDuration : Motion.exitDuration)
        let curve = CAMediaTimingFunction(name: showing ? .easeIn : .easeOut)
        let opacity = fromHidden ? Float(0) : (root.presentation()?.opacity ?? root.opacity)
        let transforms = [grid, folderGrid].compactMap { view -> (CALayer, CATransform3D)? in
            guard let layer = view.layer else { return nil }
            return (layer, fromHidden ? Motion.centeredScale(1.05, on: layer) : (layer.presentation()?.transform ?? layer.transform))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.removeAnimation(forKey: "visibility")
        root.opacity = showing ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity; fade.toValue = root.opacity; fade.duration = duration; fade.timingFunction = curve
        root.add(fade, forKey: "visibility")
        for (layer, current) in transforms {
            layer.removeAnimation(forKey: "visibility")
            layer.transform = showing || Motion.reduced ? CATransform3DIdentity : Motion.centeredScale(1.05, on: layer)
            if !Motion.reduced {
                let zoom = CABasicAnimation(keyPath: "transform")
                zoom.fromValue = NSValue(caTransform3D: current); zoom.toValue = NSValue(caTransform3D: layer.transform)
                zoom.duration = duration; zoom.timingFunction = curve
                layer.add(zoom, forKey: "visibility")
            }
        }
        CATransaction.commit()
        // The controller checks a generation token when a closing animation finishes.
        if let completion = completion { DispatchQueue.main.asyncAfter(deadline: .now()+duration, execute: completion) }
    }
    private func cancelPageTransition() {
        pageTransitionGeneration += 1; pageTransition = false; queuedPage = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let outgoing = outgoingPage { recyclePage(outgoing) }; outgoingPage = nil
        for (view,inside) in [(grid,false),(folderGrid,true)] {
            view.layer?.removeAllAnimations(); view.layer?.transform = CATransform3DIdentity
            view.setFrameOrigin(pageContentFrame(insideFolder: inside).origin)
        }
        CATransaction.commit()
    }
    private var requestedPage: Int {
        if let queued = queuedPage { return queued.page }
        if settlingPage { return settlingInsideFolder ? folderDots.selected : pageDots.selected }
        return interaction.folderID == nil ? currentPage : folderPage
    }
    func changePage(_ page: Int, insideFolder: Bool? = nil, allowNew: Bool = false) {
        finishItemReturn()
        finishFolderOpening()
        finishFolderDrop()
        let inFolder = insideFolder ?? (interaction.folderID != nil)
        guard backgroundGesture == nil else { return }
        if pageTransition || settlingPage {
            let limit = max(0,visiblePages(insideFolder:inFolder).count-1+(allowNew ? 1 : 0))
            let target = max(0,min(page,limit))
            if !allowNew && dragID == nil && inFolder == (interaction.folderID != nil) {
                // Retarget from the pixels currently on screen, including when
                // multiple keys arrive in the same transaction before display.
                resumePageMotion(at:.zero,timestamp:ProcessInfo.processInfo.systemUptime,fromScroll:false)
                settleBackgroundPaging(at:ProcessInfo.processInfo.systemUptime,targetOverride:target)
            } else { queuedPage = (target,inFolder,allowNew) }
            return
        }
        let old = inFolder ? folderPage : currentPage
        let pageCount = inFolder ? (presentationState.folder(interaction.folderID ?? "")?.pages.count ?? 1)
            : (interaction.query.isEmpty ? presentationState.pages.count : max(1,chunk(currentResults,capacity).count))
        let new = max(0,min(page, pageCount-1+(allowNew ? 1 : 0)))
        guard new != old else { return }
        if abs(new-old) > 1 && !allowNew {
            // Indicator jumps retain real page indices and spacing as well.
            backgroundGesture = BackgroundGesture(start:.zero,last:.zero,lastTime:ProcessInfo.processInfo.systemUptime,
                moved:true,paging:true,insideFolder:inFolder,initialPage:old)
            settleBackgroundPaging(at:ProcessInfo.processInfo.systemUptime,targetOverride:new)
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        outgoingPage?.removeFromSuperview(); outgoingPage = nil
        if !Motion.reduced {
            let outgoing = inFolder ? folderGrid : grid
            let incoming = FlippedView(frame:outgoing.frame); incoming.wantsLayer = true
            outgoing.superview?.addSubview(incoming)
            // Keep the outgoing host and its backing layers intact.
            if inFolder { folderGrid = incoming; folderTiles = [] }
            else { grid = incoming; tiles = [] }
            outgoingOffset = new > old ? -1 : 1; outgoingIndex = old
            outgoingPage = outgoing
        }
        let movingGrid = inFolder ? folderGrid : grid
        if allowNew && new == pageCount {
            // A transient empty page is a drop target, persisted only on drop.
            transientPage = ItemLocation(folderID: inFolder ? interaction.folderID : nil, page: new, index: 0)
            if inFolder { folderPage = new; buildTiles([], in: folderGrid, storage: &folderTiles); folderDots.count = pageCount+1; folderDots.selected = new }
            else { currentPage = new; buildTiles([], in: grid, storage: &tiles); pageDots.count = pageCount+1; pageDots.selected = new; pageDots.isHidden = false }
        } else {
            if inFolder { folderPage = new } else { currentPage = new }
            selectedID = nil; refresh()
        }
        if let outgoing = outgoingPage {
            // AppKit installs a new view's backing layer during display. Install it
            // inside this transaction before adding explicit animations to it.
            let distance = CGFloat(new > old ? 1 : -1)*pageStride(insideFolder: inFolder)
            movingGrid.layer?.transform = CATransform3DMakeTranslation(distance,0,0)
            window?.displayIfNeeded()
            pageTransition = true; pageTransitionGeneration += 1
            let generation = pageTransitionGeneration
            animatePages([(movingGrid,distance,0),(outgoing,0,-distance)]) { [weak self] in
                guard let self = self, self.pageTransitionGeneration == generation else { return }
                let queued = self.queuedPage
                self.cancelPageTransition(); self.refresh()
                if let queued = queued { self.changePage(queued.page, insideFolder: queued.inside, allowNew: queued.allowNew) }
                else if self.dragID != nil { self.updateItemDrag(at:self.lastDragPoint) }
                else if !self.collectedAppIDs.isEmpty { self.updateAppCollection(at:self.collectionPoint) }
            }
        }
        lastPageTurn = ProcessInfo.processInfo.systemUptime
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
    private func animatePages(_ translations: [(NSView,CGFloat,CGFloat)], completion: @escaping () -> Void) {
        // Every page uses the same clock and curve. Complete when Core Animation
        // finishes, so rendering/setup time cannot shorten the visible movement.
        let start = CACurrentMediaTime()
        pageAnimationSerial += 1
        let serial = pageAnimationSerial
        pageAnimationPendingCommit = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pageAnimationSerial == serial else { return }
            self.pageAnimationPendingCommit = false
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { DispatchQueue.main.async(execute:completion) }
        for (view,from,to) in translations {
            guard let layer = view.layer else { continue }
            layer.transform = CATransform3DMakeTranslation(to,0,0)
            let slide = CABasicAnimation(keyPath:"transform.translation.x")
            slide.fromValue = from; slide.toValue = to
            slide.duration = Motion.pageDuration; slide.timingFunction = Motion.pageCurve
            slide.beginTime = layer.convertTime(start,from:nil)
            slide.fillMode = .backwards
            layer.add(slide,forKey:"page")
        }
        CATransaction.commit()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === folderTitle { interaction.renaming = true; return }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        searchBox.updateState()
        cancelPageTransition(); cancelBackgroundPaging()
        interaction.query = search.stringValue
        interaction.folderID = nil; currentPage = 0; selectedID = nil
        refresh(); selectedID = tiles.first?.content.id; updateSelection()
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        searchBox.updateState()
        if obj.object as? NSTextField === folderTitle { interaction.renaming = true }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        searchBox.updateState()
        guard obj.object as? NSTextField === folderTitle else { return }
        commitFolderName()
    }
    private func commitFolderName() {
        guard let id = interaction.folderID else { interaction.renaming = false; return }
        // The field editor owns uncommitted text until focus changes. Return's
        // delegate callback happens before NSTextField updates stringValue.
        let title = folderTitle.currentEditor()?.string ?? folderTitle.stringValue
        folderTitle.stringValue = title
        interaction.renaming = false
        controller?.mutate(L10n.text("Rename Folder", "폴더 이름 변경")) { $0.renameFolder(id, title: title) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if control === folderTitle {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                commitFolderName(); window?.makeFirstResponder(self); return true
            }
            return false
        }
        switch NSStringFromSelector(commandSelector) {
        case "cancelOperation:": cancel(); return true
        case "insertNewline:": activateSelection(); return true
        case "moveDown:": navigate(columns); return true
        case "moveUp:": navigate(-columns); return true
        case "moveLeft:": if !interaction.query.isEmpty { return false }; navigate(-1); return true
        case "moveRight:": if !interaction.query.isEmpty { return false }; navigate(1); return true
        default: return false
        }
    }
    override func keyDown(with event: NSEvent) {
        finishItemReturn()
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: activateSelection()
        case 123: cmd ? changePage(requestedPage-1) : navigate(-1)
        case 124: cmd ? changePage(requestedPage+1) : navigate(1)
        case 125: navigate(columns)
        case 126: navigate(-columns)
        case 51, 117:
            if cmd, let id = selectedID, let app = state.app(id) { controller?.trash(app) }
        default:
            guard !cmd, let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) else { super.keyDown(with: event); return }
            if interaction.folderID != nil { closeFolder(animated:false) }
            window?.makeFirstResponder(search)
            (search.currentEditor() as? NSTextView)?.interpretKeyEvents([event])
        }
    }
    override func flagsChanged(with event: NSEvent) {
        // Option reveals delete controls without requiring a long press.
        let held = event.modifierFlags.contains(.option)
        for tile in tiles+folderTiles { tile.editing = interaction.editing || held }
    }
    func cancel() {
        if !collectedAppIDs.isEmpty { cancelAppCollection(); return }
        if folderDrop != nil { finishFolderDrop(); return }
        if dragID != nil { cancelItemDrag(animated:true); return }
        if pageTransition { cancelPageTransition(); refresh(); return }
        if backgroundGesture != nil || settlingPage { cancelBackgroundPaging(); refresh(); return }
        if interaction.folderID != nil && !interaction.editing && !interaction.renaming { closeFolder(); return }
        switch interaction.cancel() {
        case .cancelDrag: stopHover()
        case .finishRename: commitFolderName(); window?.makeFirstResponder(self)
        case .stopEditing: refresh()
        case .closeFolder: closeFolder()
        case .clearSearch: search.stringValue = ""; currentPage = 0; refresh(); window?.makeFirstResponder(self)
        case .dismiss: controller?.dismiss()
        }
    }
    private func navigate(_ delta: Int) {
        let active = interaction.folderID == nil ? tiles : folderTiles
        guard !active.isEmpty else { return }
        let previous = active.firstIndex { $0.content.id == selectedID }
        let index = previous.map { $0+delta } ?? (delta < 0 ? active.count-1 : 0)
        if index >= active.count && delta == 1 {
            changePage((interaction.folderID == nil ? currentPage : folderPage)+1)
            selectedID = (interaction.folderID == nil ? tiles : folderTiles).first?.content.id
        } else if index < 0 && delta == -1 {
            changePage((interaction.folderID == nil ? currentPage : folderPage)-1)
            selectedID = (interaction.folderID == nil ? tiles : folderTiles).last?.content.id
        } else { selectedID = active[max(0,min(index,active.count-1))].content.id }
        updateSelection()
    }
    private func updateSelection() {
        for tile in tiles+folderTiles {
            tile.highlighted = tile.content.id == selectedID
            tile.setAccessibilitySelected(tile.content.id == selectedID)
        }
    }
    private func activateSelection() {
        let active = interaction.folderID == nil ? tiles : folderTiles
        guard let id = selectedID ?? active.first?.content.id else { return }
        activate(id)
    }
    private func activate(_ id: String) {
        if state.folder(id) != nil { openFolder(id) }
        else if let app = state.app(id) { controller?.launch(app) }
    }
    private func openFolder(_ id: String, page: Int = 0) {
        finishFolderDrop()
        finishFolderOpening(); cancelBackgroundPaging(); cancelPageTransition()
        guard presentationState.folder(id) != nil else { return }
        let source = tiles.first(where: { $0.content.id == id })
        let firstVisibleMiniature = (source?.previewFirstRow ?? 0)*3
        folderSourceRect = source.map { tile in
            let body = tile.folderIconFrame
            let inset = tile.folderDropPreview ? -body.width*CGFloat(Motion.pressScale-1)/2 : 0
            return convert(body.insetBy(dx:inset,dy:inset),from:tile)
        } ?? .zero
        let miniatures = source.map { tile in (firstVisibleMiniature..<firstVisibleMiniature+9).map {
            convert(tile.displayedMiniatureFrame(at:$0),from:tile)
        } } ?? []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        interaction.folderID = id; folderPage = page; selectedID = nil
        refresh(); window?.makeFirstResponder(self)
        if !Motion.reduced && !miniatures.isEmpty { animateFolderOpening(from:miniatures,firstVisibleMiniature:firstVisibleMiniature) }
    }
    private func animateFolderOpening(from miniatures: [NSRect], closing: Bool = false, firstVisibleMiniature: Int = 0) {
        folderClosing = closing
        let firstIndex = interaction.folderID.flatMap { presentationState.folder($0) }?.pages.prefix(folderPage).reduce(0) { $0+$1.count } ?? 0
        // ECSBGroupLayer.prepareForAnimatedShow starts at the item's backdrop
        // and minimizes its children before animatedShow restores the layout.
        // AppKit clips descendants to their view geometry even while their
        // presentation layers are outside it. Fly sharp icon copies in root
        // coordinates, then hand over to the live, interactive folder tiles.
        let overlay = FlippedView(frame:bounds); overlay.wantsLayer = true
        var flights: [(NSImageView,NSTextField,NSRect)] = []
        for (index,tile) in folderTiles.enumerated() {
            let icon = NSImageView(frame:convert(tile.iconFrame,from:tile))
            icon.image = tile.content.image; icon.imageScaling = .scaleProportionallyUpOrDown; icon.wantsLayer = true
            icon.alphaValue = tile.content.available ? 1 : 0.35
            let title = NSTextField(labelWithString:tile.content.title)
            title.frame = convert(tile.labelFrame,from:tile); title.font = .systemFont(ofSize:13)
            title.textColor = .white; title.alignment = .center; title.lineBreakMode = .byTruncatingTail
            title.wantsLayer = true; title.maximumNumberOfLines = 1
            title.alphaValue = tile.content.available ? 1 : 0.55
            icon.isHidden = tile.isHidden; title.isHidden = tile.isHidden
            overlay.addSubview(icon); overlay.addSubview(title)
            flights.append((icon,title,miniatures[max(0,min(firstIndex+index-firstVisibleMiniature,8))])); tile.alphaValue = 0
        }
        addSubview(overlay,positioned:.above,relativeTo:folderViewport); folderOpeningOverlay = overlay
        window?.displayIfNeeded()
        folderOpening = true; folderOpeningGeneration += 1
        guard let panel = folderPanel.layer else { finishFolderOpening(); return }
        let generation = folderOpeningGeneration, start = CACurrentMediaTime()
        func animation(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
            let result = CABasicAnimation(keyPath:key); result.fromValue = closing ? to : from; result.toValue = closing ? from : to
            return result
        }
        func add(_ layer: CALayer, _ animations: [CAAnimation]) {
            let group = CAAnimationGroup(); group.animations = animations
            group.duration = Motion.folderOpenDuration; group.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            group.beginTime = layer.convertTime(start,from:nil)
            group.fillMode = .forwards; group.isRemovedOnCompletion = false
            layer.add(group,forKey:"folderOpen"); folderOpeningLayers.append(layer)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.folderOpeningGeneration == generation else { return }
                self.finishFolderOpening()
            }
        }
        let source = folderSourceRect
        let position = NSPoint(x:source.minX+source.width*panel.anchorPoint.x,y:source.minY+source.height*panel.anchorPoint.y)
        add(panel,[animation("bounds",NSValue(rect:NSRect(origin:.zero,size:source.size)),NSValue(rect:panel.bounds)),
                   animation("position",NSValue(point:position),NSValue(point:panel.position)),
                   animation("cornerRadius",source.width*0.22,FolderStyle.panelRadius)])
        for (index,flight) in flights.enumerated() {
            guard let layer = flight.0.layer else { continue }
            let mini = flight.2
            let scale = mini.width/max(1,layer.bounds.width)
            let transform = CATransform3DMakeScale(scale,scale,1)
            let position = NSPoint(x:mini.minX+mini.width*layer.anchorPoint.x,y:mini.minY+mini.height*layer.anchorPoint.y)
            add(layer,[animation("transform",NSValue(caTransform3D:transform),NSValue(caTransform3D:CATransform3DIdentity)),
                       animation("position",NSValue(point:position),NSValue(point:layer.position)),
                       animation("opacity",(firstVisibleMiniature..<firstVisibleMiniature+9).contains(firstIndex+index) ? layer.opacity : 0,layer.opacity)])
            if let label = flight.1.layer {
                let position = NSPoint(x:mini.midX+label.bounds.width*scale*(label.anchorPoint.x-0.5),
                                       y:mini.maxY+7*scale+label.bounds.height*scale*label.anchorPoint.y)
                add(label,[animation("position",NSValue(point:position),NSValue(point:label.position)),
                           animation("transform",NSValue(caTransform3D:transform),NSValue(caTransform3D:CATransform3DIdentity)),
                           animation("opacity",0,label.opacity)])
            }
        }
        if let title = folderTitle.layer {
            let position = NSPoint(x:source.midX+title.bounds.width*(title.anchorPoint.x-0.5),
                                   y:source.minY-14+title.bounds.height*(title.anchorPoint.y-1))
            add(title,[animation("position",NSValue(point:position),NSValue(point:title.position)),animation("opacity",0,1)])
        }
        if !folderDots.isHidden, let dots = folderDots.layer { add(dots,[animation("opacity",0,1)]) }
        if closing {
            gridViewport.isHidden = false; pageDots.isHidden = false; searchBox.isHidden = false
            tiles.first { $0.content.id == interaction.folderID }?.alphaValue = 0
            for view in [gridViewport,pageDots,searchBox] {
                if let layer = view.layer { add(layer,[animation("opacity",1,0)]) }
            }
        }
        CATransaction.commit()
    }
    private func finishFolderOpening() {
        guard folderOpening else { return }
        let wasClosing = folderClosing
        folderOpening = false; folderClosing = false; folderOpeningGeneration += 1
        folderOpeningLayers.forEach { $0.removeAnimation(forKey:"folderOpen") }; folderOpeningLayers = []
        folderOpeningOverlay?.removeFromSuperview(); folderOpeningOverlay = nil
        folderTiles.forEach { $0.alphaValue = 1 }
        folderViewport.layer?.masksToBounds = true
        tiles.forEach { $0.alphaValue = 1 }
        if wasClosing { clearOpenFolder(); completeDragFolderExit() }
    }
    private func clearOpenFolder() {
        interaction.folderID = nil; interaction.renaming = false; selectedID = nil
        springLoadedFolderID = nil
        springLoadedEntryPoint = nil
        showFolderViews(false); refresh(); window?.makeFirstResponder(self)
    }
    private func closeFolder(animated: Bool = true) {
        finishFolderOpening()
        finishFolderDrop()
        cancelPageTransition()
        if interaction.renaming { commitFolderName() }
        guard animated, !Motion.reduced, let id = interaction.folderID,
              let source = tiles.first(where:{ $0.content.id == id }) else {
            clearOpenFolder(); completeDragFolderExit(); return
        }
        folderSourceRect = convert(source.folderIconFrame,from:source)
        let miniatures = (0..<9).map { convert(source.miniatureFrame(at:$0),from:source) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        animateFolderOpening(from:miniatures,closing:true)
        CATransaction.commit()
    }
    private func completeDragFolderExit() {
        guard let id = dragID else { return }
        if let folder = extractingFolderID {
            extractingFolderID = nil
            extractedFolderID = folder
            let layout = presentationState
            let items = layout.pages.indices.contains(currentPage) ? layout.pages[currentPage].filter { $0 != id } : []
            let removesFolder = items.contains(folder) && layout.folder(folder)?.pages.flatMap { $0 } == [id]
            let removed = removesFolder ? 1 : 0
            // A full page receives the extracted app in its last visible slot;
            // LayoutState carries the displaced item onto the following page.
            // move() removes an empty folder after insertion, so include that
            // soon-to-be-removed slot when computing the insertion index.
            acceptDragLocation(ItemLocation(page:currentPage,index:min(items.count-removed,capacity-1)+removed))
        }
        if dropAfterFolderClose {
            dropAfterFolderClose = false; commitItemDrop()
        } else { updateItemDrag(at:lastDragPoint) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if returningTile != nil { return self }
        if folderOpening || controller?.isShown == false { return self }
        let local = convert(point, from: superview)
        // Decorative views and the gaps between icons belong to the pager background.
        var view: NSView? = hit
        while let current = view, current !== self {
            if current === searchBox || current === search || current === pageDots || current === folderDots || current === folderTitle { return hit }
            if current is AppTile {
                if pageTransition || settlingPage || backgroundGesture?.paging == true { return self }
                return interaction.folderID != nil && !folderPanel.frame.contains(local) ? self : hit
            }
            view = current.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard controller?.isShown == true, !folderOpening, dragID == nil, returningTile == nil, backgroundGesture == nil else { return }
        if pageTransition || settlingPage {
            resumePageMotion(with:event, fromScroll:false)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let inside = interaction.folderID != nil && folderPanel.frame.contains(point)
        backgroundGesture = BackgroundGesture(start: point, last: point, lastTime: event.timestamp,
            insideFolder: inside, initialPage: inside ? folderPage : currentPage)
        selectedID = nil; updateSelection()
    }
    override func mouseDragged(with event: NSEvent) {
        guard var gesture = backgroundGesture, !gesture.fromScroll else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = point.x-gesture.start.x
        if hypot(delta, point.y-gesture.start.y) >= 3 { gesture.moved = true }
        if !gesture.paging && abs(delta) >= 3 && abs(delta) > abs(point.y-gesture.start.y) {
            if !gesture.insideFolder && interaction.folderID != nil { closeFolder(animated:false) }
            gesture.paging = true
            prepareNeighboringPages(insideFolder: gesture.insideFolder, page: gesture.initialPage)
        }
        let dt = event.timestamp-gesture.lastTime
        gesture.inputTranslation += point.x-gesture.last.x
        if dt > 0 { gesture.velocity = (point.x-gesture.last.x)/CGFloat(dt) }
        gesture.last = point; gesture.lastTime = event.timestamp
        if gesture.paging { positionBackgroundPages(delta:delta,gesture:&gesture) }
        backgroundGesture = gesture
    }
    private func positionBackgroundPages(delta: CGFloat, gesture: inout BackgroundGesture) {
        let view = gesture.insideFolder ? folderGrid : grid
        let pages = visiblePages(insideFolder: gesture.insideFolder)
        let edge = (delta > 0 && gesture.initialPage == 0) || (delta < 0 && gesture.initialPage == pages.count-1)
        let stride = pageStride(insideFolder: gesture.insideFolder)
        gesture.displacement = edge ? delta*0.22 : max(-stride,min(stride,delta))
        // Only mount the page about to enter the viewport. An interrupted
        // gesture already has the visible hosts; don't eagerly rebuild both sides.
        if gesture.displacement != 0 {
            prepareNeighbor(insideFolder:gesture.insideFolder,page:gesture.initialPage,
                            offset:gesture.displacement < 0 ? 1 : -1)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let transform = CATransform3DMakeTranslation(gesture.displacement,0,0)
        view.layer?.transform = transform
        for neighbor in neighboringPages { neighbor.view.layer?.transform = transform }
        CATransaction.commit()
    }
    override func mouseUp(with event: NSEvent) {
        guard let gesture = backgroundGesture, !gesture.fromScroll else { return }
        if gesture.paging { settleBackgroundPaging(at: event.timestamp); return }
        backgroundGesture = nil
        let point = convert(event.locationInWindow, from: nil)
        guard !gesture.moved, hypot(point.x-gesture.start.x,point.y-gesture.start.y) < 3, bounds.contains(point) else { return }
        if interaction.folderID != nil {
            if !folderPanel.frame.contains(gesture.start) { closeFolder() }
        } else if interaction.editing { interaction.editing = false; refresh() }
        else { controller?.dismiss() }
    }
    private func visiblePages(insideFolder: Bool) -> [[String]] {
        var pages = insideFolder ? (presentationState.folder(interaction.folderID ?? "")?.pages ?? [[]])
            : (interaction.query.isEmpty ? presentationState.pages : chunk(currentResults,capacity))
        if !collectedAppIDs.isEmpty, let transient = transientPage,
           transient.folderID == (insideFolder ? interaction.folderID : nil), transient.page == pages.count { pages.append([]) }
        return pages
    }
    private func recyclePage(_ view: FlippedView) {
        for tile in view.subviews.compactMap({ $0 as? AppTile }) {
            tile.removeFromSuperview()
            reusableTiles.setObject(tile,forKey:tile.content.id as NSString)
        }
        view.removeFromSuperview()
    }
    private func selectPageHost(_ view: FlippedView, insideFolder: Bool) {
        // AppKit may reorder subviews for hit testing. Grid order is spatial,
        // not the order of the host's subview array.
        let items = view.subviews.compactMap { $0 as? AppTile }.sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
        if insideFolder { folderGrid = view; folderTiles = items }
        else { grid = view; tiles = items }
    }
    /// Take over at the presentation position without dismantling any visible
    /// page or re-laying out its tiles. Rebase only the page hosts once.
    private func resumePageMotion(with event: NSEvent, fromScroll: Bool) {
        resumePageMotion(at:convert(event.locationInWindow,from:nil),timestamp:event.timestamp,fromScroll:fromScroll)
    }
    private func resumePageMotion(at point: NSPoint, timestamp: TimeInterval, fromScroll: Bool) {
        guard pageTransition || settlingPage else { return }
        var stamp = pageTimingSamples == nil ? 0 : CACurrentMediaTime()
        func mark(_ name: String) {
            guard pageTimingSamples != nil else { return }
            let now = CACurrentMediaTime()
            pageTimingSamples?.append("resume \(name): \((now-stamp)*1000) ms")
            stamp = now
        }
        let inside = settlingPage ? settlingInsideFolder : interaction.folderID != nil
        let active = inside ? folderGrid : grid
        let index = inside ? folderPage : currentPage
        let inheritedTarget = settlingPage ? (inside ? folderDots.selected : pageDots.selected) : index
        let stride = pageStride(insideFolder:inside)
        guard stride > 0 else { return }
        let pendingFrom = (active.layer?.animation(forKey:"page") as? CABasicAnimation)?.fromValue as? NSNumber
        let x = pageAnimationPendingCommit ? CGFloat(pendingFrom?.doubleValue ?? 0)
            : (active.layer?.presentation()?.transform.m41 ?? active.layer?.transform.m41 ?? 0)
        mark("presentation")
        var candidates: [(index:Int,offset:Int,view:FlippedView)] = [(index,0,active)]
        if let outgoing = outgoingPage { candidates.append((outgoingIndex,outgoingOffset,outgoing)) }
        candidates += neighboringPages.map { (index+$0.offset,$0.offset,$0.view) }
        let nearest = candidates.min { abs(x+CGFloat($0.offset)*stride) < abs(x+CGFloat($1.offset)*stride) }!
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Invalidate old completions without invoking teardown on retained hosts.
        pageTransitionGeneration += 1; pagingGeneration += 1; warmupGeneration += 1
        pageTransition = false; settlingPage = false; queuedPage = nil
        scrollIdleTimer?.invalidate(); scrollIdleTimer = nil
        outgoingPage = nil; neighboringPages = []
        selectPageHost(nearest.view,insideFolder:inside)
        let base = pageContentFrame(insideFolder:inside)
        mark("select host")
        for candidate in candidates {
            candidate.view.layer?.removeAnimation(forKey:"page")
            candidate.view.layer?.transform = CATransform3DIdentity
            let offset = candidate.index-nearest.index
            candidate.view.frame = base.offsetBy(dx:CGFloat(offset)*stride,dy:0)
            if candidate.view !== nearest.view { neighboringPages.append((offset,candidate.view)) }
        }
        mark("rebase hosts")
        if inside { folderPage = nearest.index } else { currentPage = nearest.index }
        (inside ? folderDots : pageDots).selected = nearest.index
        let displacement = x+CGFloat(nearest.offset)*stride
        let pages = visiblePages(insideFolder:inside)
        let edge = displacement > 0 && nearest.index == 0 || displacement < 0 && nearest.index == pages.count-1
        let raw = edge ? displacement/0.22 : displacement
        var gesture = BackgroundGesture(start:NSPoint(x:point.x-raw,y:point.y),last:point,lastTime:timestamp,
            moved:true,paging:true,insideFolder:inside,initialPage:nearest.index,fromScroll:fromScroll,inheritedTarget:inheritedTarget)
        mark("gesture setup")
        positionBackgroundPages(delta:raw,gesture:&gesture)
        mark("position")
        backgroundGesture = gesture
        CATransaction.commit()
        mark("commit")
    }
    private func prepareNeighboringPages(insideFolder: Bool, page: Int) {
        outgoingPage?.removeFromSuperview(); outgoingPage = nil
        let view = insideFolder ? folderGrid : grid
        view.layer?.removeAnimation(forKey: "page")
        let pages = visiblePages(insideFolder: insideFolder)
        for offset in [-1,1] where pages.indices.contains(page+offset) {
            prepareNeighbor(insideFolder:insideFolder,page:page,offset:offset)
        }
    }
    private func prepareNeighbor(insideFolder: Bool, page: Int, offset: Int) {
        let view = insideFolder ? folderGrid : grid
        let pages = visiblePages(insideFolder:insideFolder)
        guard offset != 0, pages.indices.contains(page+offset), !neighboringPages.contains(where: { $0.offset == offset }) else { return }
        let started = pageTimingSamples == nil ? 0 : CACurrentMediaTime()
        defer { if pageTimingSamples != nil { pageTimingSamples?.append("prepare page \(page+offset): \((CACurrentMediaTime()-started)*1000) ms") } }
        let preview = FlippedView(frame: view.frame.offsetBy(dx: CGFloat(offset)*pageStride(insideFolder: insideFolder), dy: 0))
        preview.wantsLayer = true
        var items: [AppTile] = []
        buildTiles(pages[page+offset], in: preview, storage: &items)
        layoutTiles(items, in: preview, rowCount: insideFolder ? folderRows : rows, insideFolder:insideFolder)
        preview.layoutSubtreeIfNeeded()
        view.superview?.addSubview(preview, positioned: .above, relativeTo: view)
        // AppKit installs a new view's backing layer during display. Finish
        // that installation before the first drag transform is applied.
        window?.displayIfNeeded()
        neighboringPages.append((offset,preview))
    }
    private func settleBackgroundPaging(at timestamp: TimeInterval, cancelled: Bool = false, targetOverride: Int? = nil) {
        guard let gesture = backgroundGesture else { return }
        scrollIdleTimer?.invalidate(); scrollIdleTimer = nil
        guard gesture.paging else { cancelBackgroundPaging(); return }
        let view = gesture.insideFolder ? folderGrid : grid
        let delta = gesture.displacement
        let stride = pageStride(insideFolder: gesture.insideFolder)
        let count = visiblePages(insideFolder: gesture.insideFolder).count
        let target = targetOverride ?? PageGesture.destination(initialPage:gesture.initialPage,inheritedTarget:gesture.inheritedTarget,
            translation:Double(gesture.inputTranslation),velocity:Double(gesture.velocity),inputAge:timestamp-gesture.lastTime,
            stride:Double(stride),pageCount:count,cancelled:cancelled)
        for offset in min(0,target-gesture.initialPage)...max(0,target-gesture.initialPage) {
            prepareNeighbor(insideFolder:gesture.insideFolder,page:gesture.initialPage,offset:offset)
        }
        let destination = -CGFloat(target-gesture.initialPage)*stride
        backgroundGesture = nil; settlingPage = true; settlingInsideFolder = gesture.insideFolder; pagingGeneration += 1
        let generation = pagingGeneration
        (gesture.insideFolder ? folderDots : pageDots).selected = target
        let complete: () -> Void = { [weak self] in
            guard let self = self, self.pagingGeneration == generation else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let queued = self.queuedPage; self.queuedPage = nil
            if let destination = self.neighboringPages.first(where: { $0.offset == target-gesture.initialPage }) {
                self.neighboringPages.removeAll { $0.view === destination.view }
                self.selectPageHost(destination.view,insideFolder:gesture.insideFolder)
                self.recyclePage(view)
                destination.view.layer?.removeAnimation(forKey:"page")
                destination.view.layer?.transform = CATransform3DIdentity
                destination.view.frame = self.pageContentFrame(insideFolder:gesture.insideFolder)
            }
            self.cancelBackgroundPaging()
            if gesture.insideFolder { self.folderPage = target } else { self.currentPage = target }
            self.selectedID = nil; self.refresh()
            if let queued = queued { self.changePage(queued.page,insideFolder:queued.inside,allowNew:queued.allowNew) }
        }
        if Motion.reduced { complete(); return }
        window?.displayIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var translations: [(NSView,CGFloat,CGFloat)] = [(view,delta,destination)]
        for neighbor in neighboringPages {
            // Put every page on the same transform animation instead of mixing
            // AppKit frame animation with a separate Core Animation clock.
            neighbor.view.setFrameOrigin(NSPoint(x:view.frame.minX+CGFloat(neighbor.offset)*stride,y:view.frame.minY))
            translations.append((neighbor.view,delta,destination))
        }
        animatePages(translations,completion:complete)
        CATransaction.commit()
    }
    private func cancelBackgroundPaging() {
        scrollIdleTimer?.invalidate(); scrollIdleTimer = nil
        guard backgroundGesture != nil || settlingPage || !neighboringPages.isEmpty else { return }
        pagingGeneration += 1; backgroundGesture = nil; settlingPage = false
        neighboringPages.forEach { recyclePage($0.view) }; neighboringPages = []
        queuedPage = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for view in [grid,folderGrid] { view.layer?.removeAnimation(forKey: "page"); view.layer?.transform = CATransform3DIdentity }
        CATransaction.commit()
    }
    override func scrollWheel(with event: NSEvent) {
        guard controller?.isShown == true, dragID == nil, event.momentumPhase.isEmpty else { return }
        finishItemReturn()
        finishFolderOpening()
        if event.hasPreciseScrollingDeltas { trackScroll(event); return }
        let now = ProcessInfo.processInfo.systemUptime
        // Coalesce one wheel burst, while accepting subsequent deliberate turns
        // before the 0.5 second animation finishes.
        guard backgroundGesture == nil, now-lastPageTurn > 0.12 else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollAccumulator += delta
        if abs(scrollAccumulator) >= 2 {
            changePage(requestedPage+(scrollAccumulator < 0 ? 1 : -1))
            lastPageTurn = now
            scrollAccumulator = 0
        }
    }
    private func trackScroll(_ event: NSEvent) {
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            ignoredScrollSequence = backgroundGesture != nil && backgroundGesture?.fromScroll != true
            if !ignoredScrollSequence && (pageTransition || settlingPage) { resumePageMotion(with:event,fromScroll:true) }
        }
        if ignoredScrollSequence && !event.phase.isEmpty {
            if ended { ignoredScrollSequence = false }
            return
        }
        if event.phase.isEmpty && (pageTransition || settlingPage) { resumePageMotion(with:event,fromScroll:true) }
        guard !pageTransition, !settlingPage, backgroundGesture == nil || backgroundGesture?.fromScroll == true else { return }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if ended && (dx == 0 && dy == 0 || event.phase.contains(.cancelled)) {
            if backgroundGesture?.fromScroll == true { settleBackgroundPaging(at:event.timestamp,cancelled:event.phase.contains(.cancelled)) }
            return
        }
        guard dx != 0 || dy != 0 else { return }
        if ended && backgroundGesture == nil { return }
        if backgroundGesture == nil {
            finishFolderDrop()
            let point = convert(event.locationInWindow,from:nil)
            let inside = interaction.folderID != nil
            backgroundGesture = BackgroundGesture(start:point,last:point,lastTime:event.timestamp,
                insideFolder:inside,initialPage:inside ? folderPage : currentPage,fromScroll:true)
            selectedID = nil; updateSelection()
        }
        guard var gesture = backgroundGesture else { return }
        if gesture.scrollUsesX == nil { gesture.scrollUsesX = abs(dx) >= abs(dy) }
        let amount = gesture.scrollUsesX == true ? dx : dy
        gesture.inputTranslation += amount
        let delta = gesture.last.x-gesture.start.x+amount
        if !gesture.paging && abs(delta) >= 3 {
            gesture.paging = true; gesture.moved = true
            prepareNeighboringPages(insideFolder:gesture.insideFolder,page:gesture.initialPage)
        }
        let dt = event.timestamp-gesture.lastTime
        if dt > 0 { gesture.velocity = amount/CGFloat(dt) }
        gesture.last.x = gesture.start.x+delta; gesture.lastTime = event.timestamp
        if gesture.paging { positionBackgroundPages(delta:delta,gesture:&gesture) }
        backgroundGesture = gesture
        if ended { settleBackgroundPaging(at:event.timestamp) }
        else if event.phase.isEmpty {
            scrollIdleTimer?.invalidate()
            scrollIdleTimer = Timer.scheduledTimer(withTimeInterval:Motion.scrollIdleDelay,repeats:false) { [weak self] _ in
                self?.settleBackgroundPaging(at:ProcessInfo.processInfo.systemUptime)
            }
            if let timer = scrollIdleTimer { RunLoop.main.add(timer,forMode:.common) }
        }
    }
    override func swipe(with event: NSEvent) {
        if event.deltaX != 0 { changePage(requestedPage+(event.deltaX < 0 ? 1 : -1)) }
    }
    override func magnify(with event: NSEvent) { if event.magnification > 0.15 { controller?.dismiss() } }
    /// Capture Command clicks before AppTile can launch, long-press or start a
    /// native drag. Mouse-up does not drop the stack; only releasing Command does.
    func routeAppCollection(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseUp, collectionConsumesClick {
            collectionConsumesClick = false; return true
        }
        let collecting = !collectedAppIDs.isEmpty
        let point = convert(event.locationInWindow,from:nil)
        switch event.type {
        case .flagsChanged where collecting:
            if !event.modifierFlags.contains(.command), let window = window {
                // Modifier events have no reliable mouse coordinates. Read the
                // pointer independently, including releases outside the window.
                finishAppCollection(at:convert(window.convertPoint(fromScreen:collectionMouseLocation()),from:nil))
            }
            return false
        case .mouseMoved where collecting, .leftMouseDragged where collecting:
            // AppKit can synthesize mouse-moved events as views change beneath
            // the pointer. Key release belongs to flagsChanged, not these events.
            if event.modifierFlags.contains(.command) { updateAppCollection(at:point) }
            return true
        case .keyDown where collecting:
            if event.keyCode == 53 { cancelAppCollection() }
            else if event.keyCode == 123 || event.keyCode == 124 {
                clearCollectionHover()
                changePage(requestedPage+(event.keyCode == 124 ? 1 : -1),allowNew:event.keyCode == 124)
            } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" { return false }
            return true
        case .rightMouseDown where collecting:
            cancelAppCollection(); return true
        case .leftMouseDown:
            collectionConsumesClick = false
            if collecting && !event.modifierFlags.contains(.command) {
                collectionConsumesClick = true; cancelAppCollection(); return true
            }
            guard controller?.isShown == true, interaction.editing, event.modifierFlags.contains(.command), dragID == nil else { return false }
            // Page indicators remain clickable while carrying a stack.
            let dots = interaction.folderID == nil ? pageDots : folderDots
            if !dots.isHidden && dots.frame.contains(point) { return false }
            collectionConsumesClick = true
            guard !pageTransition, !settlingPage, backgroundGesture == nil, !folderOpening else { return true }
            finishItemReturn(); finishFolderDrop()
            let active = interaction.folderID == nil ? tiles : folderTiles
            if let tile = active.first(where: { !$0.isHidden && $0.interactionFrame.contains($0.convert(point,from:self)) }) {
                if tile.content.isFolder {
                    clearCollectionHover(); collectionEnteredFolder = false; openFolder(tile.content.id)
                } else { collectApp(tile,at:point) }
            } else if interaction.folderID != nil && !folderPanel.frame.contains(point) {
                clearCollectionHover(); collectionEnteredFolder = false; closeFolder(animated:false)
            }
            if !collectedAppIDs.isEmpty { updateAppCollection(at:point) }
            return true
        default: return false
        }
    }
    private func collectApp(_ tile: AppTile, at point: NSPoint) {
        let id = tile.content.id
        guard state.app(id) != nil, !collectedAppIDs.contains(id) else { return }
        let source = convert(tile.iconFrame,from:tile)
        if collectedAppIDs.isEmpty {
            collectionBaseState = state
            collectionView = AppCollectionView(frame:.zero)
            addSubview(collectionView!)
            window?.makeFirstResponder(self)
        }
        collectedAppIDs.append(id)
        if interaction.folderID != nil { collectionEnteredFolder = true }
        selectedID = nil; updateSelection()
        if !interaction.query.isEmpty {
            interaction.query = ""; search.stringValue = ""
            if let location = state.location(of:id) {
                if let folder = location.folderID { openFolder(folder,page:location.page) }
                else { currentPage = location.page }
            }
        }
        let size = tile.iconSize
        collectionView?.setFrameOrigin(NSPoint(x:point.x-size/2+18,y:point.y-size/2+18))
        collectionView?.update(images:collectedAppIDs.map { tileContent($0).image ?? NSImage(size:NSSize(width:size,height:size)) },iconSize:size,source:source)
        refresh()
    }
    private func clearCollectionHover() {
        collectionHoverTimer?.invalidate(); collectionHoverTimer = nil
        collectionHoverID = nil; collectionGroupReady = false
        for tile in tiles+folderTiles { tile.dropHighlight = false }
        insertionLine.isHidden = true
    }
    func cancelAppCollection() { endAppCollection(refresh:true) }
    private func endAppCollection(refresh shouldRefresh: Bool) {
        guard !collectedAppIDs.isEmpty else { return }
        collectedAppIDs = []; collectionBaseState = nil
        collectionEnteredFolder = false
        collectionView?.removeFromSuperview(); collectionView = nil
        collectionEdgeTimer?.invalidate(); collectionEdgeTimer = nil; collectionEdge = 0
        clearCollectionHover(); transientPage = nil
        if shouldRefresh { refresh() }
    }
    private func collectionDestination(at point: NSPoint) -> (location: ItemLocation, group: String?)? {
        guard bounds.contains(point), !isOverDock(point) else { return nil }
        let inside = interaction.folderID != nil
        let view = inside ? folderGrid : grid
        let active = inside ? folderTiles : tiles
        let dots = inside ? folderDots : pageDots
        if !dots.isHidden && dots.frame.contains(point) {
            // Clicking a page dot leaves the pointer below the grid. Releasing
            // there should place the stack at the end of the selected page.
            let index = active.filter { !collectedAppIDs.contains($0.content.id) }.count
            return (ItemLocation(folderID:interaction.folderID,page:inside ? folderPage : currentPage,index:index),nil)
        }
        let local = view.convert(point,from:self)
        let viewport = inside ? folderViewport : gridViewport
        guard viewport.frame.contains(point), view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let width = view.bounds.width/CGFloat(columns), height = view.bounds.height/CGFloat(inside ? folderRows : rows)
        // Page-turn gutters are valid drop locations on the destination page.
        let column = max(0,min(columns-1,Int(floor(local.x/width))))
        let row = max(0,min((inside ? folderRows : rows)-1,Int(floor(local.y/height))))
        let raw = min(row*columns+column,active.count)
        let hovered = active.indices.contains(raw) ? active[raw] : nil
        if let tile = hovered, !collectedAppIDs.contains(tile.content.id),
           tile.iconFrame.insetBy(dx:tile.iconSize*0.18,dy:tile.iconSize*0.08).contains(tile.convert(point,from:self)) {
            if let folder = state.folder(tile.content.id), var destination = state.endOfFolder(folder.id) {
                destination.index -= folder.pages[destination.page].filter { collectedAppIDs.contains($0) }.count
                return (destination,folder.id)
            }
            if !inside { return (ItemLocation(page:currentPage,index:raw),tile.content.id) }
        }
        let after = hovered != nil && local.x > (CGFloat(column)+0.5)*width ? 1 : 0
        let index = active.prefix(raw+after).filter { !collectedAppIDs.contains($0.content.id) }.count
        return (ItemLocation(folderID:interaction.folderID,page:inside ? folderPage : currentPage,index:index),nil)
    }
    private func updateAppCollection(at point: NSPoint) {
        guard !collectedAppIDs.isEmpty else { return }
        collectionPoint = point
        if let stack = collectionView {
            stack.setFrameOrigin(NSPoint(x:point.x-(stack.frame.width-28)/2+18,y:point.y-(stack.frame.height-28)/2+18))
        }
        if interaction.folderID != nil && !folderOpening {
            if folderPanel.frame.insetBy(dx:-35,dy:-35).contains(point) { collectionEnteredFolder = true }
            else if collectionEnteredFolder {
                clearCollectionHover(); collectionEnteredFolder = false; closeFolder(animated:false)
            }
        }
        let edge = bounds.contains(point) && !isOverDock(point) ? (point.x < 30 ? -1 : (point.x > bounds.width-30 ? 1 : 0)) : 0
        if edge != collectionEdge {
            collectionEdgeTimer?.invalidate(); collectionEdgeTimer = nil; collectionEdge = edge
            if edge != 0 {
                collectionEdgeTimer = Timer.scheduledTimer(withTimeInterval:0.75,repeats:true) { [weak self] _ in
                    guard let self = self, !self.collectedAppIDs.isEmpty, !self.pageTransition, !self.settlingPage else { return }
                    self.clearCollectionHover()
                    self.changePage(self.requestedPage+self.collectionEdge,allowNew:self.collectionEdge > 0)
                }
                RunLoop.main.add(collectionEdgeTimer!,forMode:.common)
            }
        }
        guard !pageTransition, !settlingPage, backgroundGesture == nil, !folderOpening else { clearCollectionHover(); return }
        let target = collectionDestination(at:point)?.group
        if target != collectionHoverID {
            clearCollectionHover(); collectionHoverID = target
            if let target = target {
                if state.folder(target) != nil {
                    (tiles+folderTiles).first { $0.content.id == target }?.dropHighlight = true
                } else {
                    collectionHoverTimer = Timer.scheduledTimer(withTimeInterval:Motion.holdDelay,repeats:false) { [weak self] _ in
                        guard let self = self, self.collectionHoverID == target, !self.collectedAppIDs.isEmpty else { return }
                        self.collectionGroupReady = true
                        self.tiles.first { $0.content.id == target }?.dropHighlight = true
                    }
                    RunLoop.main.add(collectionHoverTimer!,forMode:.common)
                }
            }
        }
    }
    private func finishAppCollection(at point: NSPoint) {
        guard !collectedAppIDs.isEmpty else { return }
        // Preserve the requested page before dismantling its transition. A
        // scroll's currentPage still names the source until settling finishes.
        var destinationPage = requestedPage
        let destinationCount = state.pageList(in:interaction.folderID).count
        let createPage = queuedPage?.allowNew == true && destinationPage >= destinationCount
        if let gesture = backgroundGesture, gesture.paging {
            destinationPage = PageGesture.destination(initialPage:gesture.initialPage,inheritedTarget:gesture.inheritedTarget,
                translation:Double(gesture.inputTranslation),velocity:Double(gesture.velocity),inputAge:ProcessInfo.processInfo.systemUptime-gesture.lastTime,
                stride:Double(pageStride(insideFolder:gesture.insideFolder)),pageCount:visiblePages(insideFolder:gesture.insideFolder).count,cancelled:false)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        cancelPageTransition(); cancelBackgroundPaging(); finishFolderOpening()
        if createPage {
            destinationPage = destinationCount
            transientPage = ItemLocation(folderID:interaction.folderID,page:destinationPage,index:0)
        }
        if interaction.folderID == nil { currentPage = destinationPage } else { folderPage = destinationPage }
        refresh()
        guard collectionBaseState == state, let target = collectionDestination(at:point) else { cancelAppCollection(); return }
        let ids = collectedAppIDs
        let stack = collectionView
        if let stack = stack {
            stack.setFrameOrigin(NSPoint(x:point.x-(stack.frame.width-28)/2+18,y:point.y-(stack.frame.height-28)/2+18))
        }
        let sourceIcon = stack.map { convert($0.frontIconFrame,from:$0) } ?? NSRect(origin:point,size:.zero)
        var next = state
        do {
            if let group = target.group, state.app(group) != nil, collectionHoverID == group, collectionGroupReady {
                try next.makeFolder(withApps:ids,over:group,capacity:capacity,folderCapacity:folderCapacity)
            } else {
                var destination = target.location
                // An unarmed app hover is an insertion before that app.
                if let group = target.group, state.app(group) != nil {
                    let active = interaction.folderID == nil ? tiles : folderTiles
                    destination.index = active.prefix { $0.content.id != group }.filter { !ids.contains($0.content.id) }.count
                }
                try next.moveApps(ids,to:destination,capacity:capacity,folderCapacity:folderCapacity)
            }
            endAppCollection(refresh:false)
            // Removing a whole source page can shift the destination's index.
            // Keep the view on the placed apps (or their closed folder).
            if let landing = next.location(of:ids[0]) {
                if interaction.folderID == landing.folderID {
                    if landing.folderID == nil { currentPage = landing.page }
                    else { folderPage = landing.page }
                } else if interaction.folderID == nil, let folder = landing.folderID {
                    currentPage = next.location(of:folder)?.page ?? currentPage
                }
            }
            controller?.mutate(L10n.text("Move apps", "앱 함께 이동")) { $0 = next }
            // A no-op drop also needs to reveal the original tiles.
            refresh()
            guard !Motion.reduced else { return }
            // Reused AppKit views can replace their backing layers on display.
            // Install them within this transaction before attaching animations,
            // so no frame exposes the final position before the flight starts.
            window?.displayIfNeeded()
            for tile in tiles+folderTiles where ids.contains(tile.content.id) && !tile.isHidden {
                guard let layer = tile.layer, let host = tile.superview else { continue }
                let local = host.convert(NSPoint(x:sourceIcon.midX,y:sourceIcon.midY),from:self)
                let animation = CABasicAnimation(keyPath:"position")
                animation.fromValue = NSValue(point:NSPoint(x:local.x+tile.bounds.width*layer.anchorPoint.x-tile.iconFrame.midX,
                                                            y:local.y+tile.bounds.height*layer.anchorPoint.y-tile.iconFrame.midY))
                animation.toValue = NSValue(point:layer.position); animation.duration = Motion.returnDuration
                animation.timingFunction = CAMediaTimingFunction(name:.easeOut)
                layer.add(animation,forKey:"collectionDrop")
            }
            // Apps inside a closed folder have no live tiles. Animate the
            // pointer stack into that folder instead of making it disappear.
            if interaction.folderID == nil, let folder = next.location(of:ids[0])?.folderID,
               let destination = tiles.first(where:{ $0.content.id == folder }), let stack = stack {
                addSubview(stack)
                window?.displayIfNeeded()
                if let layer = stack.layer {
                    let target = convert(destination.folderIconFrame,from:destination)
                    let travel = CABasicAnimation(keyPath:"position")
                    travel.fromValue = NSValue(point:layer.position)
                    travel.toValue = NSValue(point:NSPoint(x:layer.position.x+target.midX-sourceIcon.midX,
                                                          y:layer.position.y+target.midY-sourceIcon.midY))
                    let shrink = CABasicAnimation(keyPath:"transform.scale")
                    shrink.fromValue = 1; shrink.toValue = target.width/max(1,sourceIcon.width)/3
                    let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 1; fade.toValue = 0
                    let flight = CAAnimationGroup(); flight.animations = [travel,shrink,fade]
                    flight.duration = Motion.returnDuration; flight.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
                    flight.fillMode = .forwards; flight.isRemovedOnCompletion = false
                    layer.add(flight,forKey:"collectionDrop")
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+Motion.returnDuration) { stack.removeFromSuperview() }
            }
        } catch { cancelAppCollection(); controller?.report(error) }
    }

    func tilePressed(_ tile: AppTile) { finishFolderDrop(); selectedID = nil; updateSelection() }
    func tileClicked(_ tile: AppTile) { selectedID = nil; updateSelection(); activate(tile.content.id) }
    func tileHeld(_ tile: AppTile) {
        guard dragID == nil else { return }
        interaction.editing = true; selectedID = nil; refresh()
    }
    func tileRemove(_ tile: AppTile) { if let app = state.app(tile.content.id) { controller?.trash(app) } }
    func tileMenu(_ tile: AppTile) -> NSMenu? { controller?.itemMenu(id: tile.content.id) }
    func tileDragBegan(_ tile: AppTile, event: NSEvent) {
        finishItemReturn()
        finishFolderDrop()
        cancelPageTransition(); cancelBackgroundPaging()
        dragID = tile.content.id; dragFolderAtStart = interaction.folderID; interaction.dragging = true
        dragBaseState = state; dragLayout = nil; extractingFolderID = nil; dropAfterFolderClose = false
        extractedFolderID = nil
        selectedID = nil
        let original = convert(tile.bounds, from: tile)
        let down = convert(tile.mouseDownLocation, from: nil)
        dragOffset = NSPoint(x: down.x-original.minX, y: down.y-original.minY)
        let floating = AppTile(content: tile.content)
        floating.frame = original; floating.iconSize = tile.iconSize; floating.iconTopInset = tile.iconTopInset; floating.delegate = self
        addSubview(floating); floating.layoutSubtreeIfNeeded(); draggedTile = floating
        tile.isHidden = true
        controller?.retainedDragTile = tile
        if !interaction.query.isEmpty {
            interaction.query = ""; search.stringValue = ""
            let location = state.location(of: tile.content.id)
            currentPage = location?.folderID == nil ? (location?.page ?? 0) : 0
        }
        refresh()
        updateItemDrag(at: convert(event.locationInWindow, from: nil))
    }
    func tileDragEnded(_ tile: AppTile, operation: NSDragOperation, point: NSPoint) {
        if operation.isEmpty, let window = window {
            let local = convert(window.convertPoint(fromScreen:point),from:nil)
            draggedTile?.setFrameOrigin(NSPoint(x:local.x-dragOffset.x,y:local.y-dragOffset.y))
        }
        cancelItemDrag(animated:operation.isEmpty)
    }
    /// Own the complete mouse stream even when a source view leaves its page/folder.
    func routeItemDrag(_ event: NSEvent) -> Bool {
        guard dragID != nil, !externalDrag else { return false }
        switch event.type {
        case .leftMouseDragged:
            if dropAfterFolderClose { return true }
            let point = convert(event.locationInWindow, from: nil)
            // Taking an app out of a folder remains a layout operation, even
            // over the Dock or outside the window. A native file drag would
            // bypass folder exit and restore the saved folder on cancellation.
            if dragFolderAtStart != nil {
                updateItemDrag(at:point); return true
            }
            if let floating = draggedTile, floating.content.fileURL != nil,
               (!bounds.contains(point) || isOverDock(point)) {
                externalDrag = true; stopHover()
                floating.setFrameOrigin(NSPoint(x:point.x-dragOffset.x,y:point.y-dragOffset.y))
                floating.isHidden = true
                floating.beginExternalDrag(event: event, in: self)
            } else { updateItemDrag(at: point) }
            return true
        case .leftMouseUp:
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) || dragFolderAtStart != nil {
                if !pageTransition && hypot(point.x-lastDragPoint.x, point.y-lastDragPoint.y) > 1 { updateItemDrag(at: point) }
                commitItemDrop()
            } else { cancelItemDrag(animated:true) }
            return true
        case .keyDown:
            if event.keyCode == 53 { cancelItemDrag(animated:true) }
            return true
        default: return false
        }
    }
    private func isOverDock(_ point: NSPoint) -> Bool {
        guard !CommandLine.arguments.contains("--windowed"), let window = window, window.screen != nil else { return false }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        return dockDragRegion.contains(screenPoint)
    }
    func cancelItemDrag(animated: Bool = false) {
        cancelAppCollection()
        finishItemReturn()
        finishFolderDrop()
        guard let id = dragID else { return }
        let floating = draggedTile, originalFrame = draggedTile?.frame ?? .zero
        let origin = state.location(of:id)
        dragID = nil; externalDrag = false; interaction.dragging = false
        dragLayout = nil; dragBaseState = nil; extractingFolderID = nil; dropAfterFolderClose = false
        extractedFolderID = nil; dragFolderAtStart = nil
        springLoadedFolderID = nil; springLoadedEntryPoint = nil
        transientPage = nil
        draggedTile = nil
        stopHover(); controller?.retainedDragTile = nil
        cancelPageTransition()
        finishFolderOpening()
        if animated, let origin = origin {
            // After a commit this is the newly saved home; cancellation uses
            // the original home. Both hand over the complete icon and label.
            if let folder = origin.folderID {
                if interaction.folderID != folder { openFolder(folder,page:origin.page); finishFolderOpening() }
                folderPage = origin.page
            } else {
                if interaction.folderID != nil { closeFolder(animated:false) }
                currentPage = origin.page
            }
        }
        refresh()
        let destination = (interaction.folderID == nil ? tiles : folderTiles).first { $0.content.id == id }
        guard animated, !Motion.reduced, let floating = floating, let destination = destination,
              originalFrame.width > 0 else { floating?.removeFromSuperview(); return }
        returningTile = floating; returnHiddenID = id; destination.isHidden = true
        floating.isHidden = false; floating.delegate = nil
        let targetFrame = convert(destination.bounds,from:destination)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        floating.frame = targetFrame; floating.iconSize = destination.iconSize; floating.iconTopInset = destination.iconTopInset; floating.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        returnGeneration += 1
        let generation = returnGeneration
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.returnGeneration == generation else { return }
                self.finishItemReturn()
            }
        }
        if let layer = floating.layer {
            let move = CABasicAnimation(keyPath:"position")
            move.fromValue = NSValue(point:NSPoint(x:originalFrame.minX+originalFrame.width*layer.anchorPoint.x,
                                                   y:originalFrame.minY+originalFrame.height*layer.anchorPoint.y))
            move.toValue = NSValue(point:layer.position)
            let scale = CABasicAnimation(keyPath:"transform")
            scale.fromValue = NSValue(caTransform3D:CATransform3DMakeScale(originalFrame.width/max(1,targetFrame.width),
                originalFrame.height/max(1,targetFrame.height),1))
            scale.toValue = NSValue(caTransform3D:CATransform3DIdentity)
            let group = CAAnimationGroup(); group.animations = [move,scale]; group.duration = Motion.returnDuration
            group.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            layer.add(group,forKey:"itemReturn")
        }
        CATransaction.commit()
    }
    private func finishItemReturn(refresh shouldRefresh: Bool = true) {
        guard let floating = returningTile else { return }
        returnGeneration += 1; returningTile = nil; returnHiddenID = nil
        floating.removeFromSuperview()
        if shouldRefresh { refresh() }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = sender.draggingPasteboard.string(forType: AppTile.pasteboardType), state.location(of: id) != nil else {
            return sender.draggingPasteboard.availableType(from: [.fileURL]) != nil ? .copy : []
        }
        updateItemDrag(at: convert(sender.draggingLocation, from: nil))
        return .move
    }
    private func setInsertionCandidate(_ candidate: ItemLocation?) {
        guard candidate != insertionCandidate else { return }
        insertionTimer?.invalidate(); insertionTimer = nil
        insertionCandidate = candidate
        guard let candidate = candidate, let id = dragID else { return }
        insertionTimer = Timer.scheduledTimer(withTimeInterval:Motion.insertionDelay,repeats:false) { [weak self] _ in
            guard let self = self, self.dragID == id, self.insertionCandidate == candidate,
                  self.interaction.folderID == candidate.folderID,
                  (candidate.folderID == nil ? self.currentPage : self.folderPage) == candidate.page else { return }
            self.acceptDragLocation(candidate)
        }
        if let timer = insertionTimer { RunLoop.main.add(timer,forMode:.common) }
    }
    private func acceptDragLocation(_ destination: ItemLocation) {
        guard let id = dragID else { return }
        var next = presentationState
        do { try next.move(id,to:destination,capacity:capacity,folderCapacity:folderCapacity) }
        catch { return }
        let active = interaction.folderID == nil ? tiles : folderTiles
        let frames = Dictionary(uniqueKeysWithValues:active.map { ($0.content.id,$0.layer?.presentation()?.frame ?? $0.frame) })
        dragLayout = next; pendingDrop = next.location(of:id)
        if transientPage?.folderID == destination.folderID && transientPage?.page == destination.page { transientPage = nil }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        refresh(); window?.displayIfNeeded()
        // Only neighbors that remain on this page move. Overflow disappears
        // immediately instead of flying into a nonexistent row below the grid.
        for tile in (interaction.folderID == nil ? tiles : folderTiles) {
            guard let layer = tile.layer else { continue }
            layer.removeAnimation(forKey:"dragReflow")
            guard !Motion.reduced, tile.content.id != id, let from = frames[tile.content.id], from != tile.frame else { continue }
            let move = CABasicAnimation(keyPath:"position")
            move.fromValue = NSValue(point:NSPoint(x:from.minX+from.width*layer.anchorPoint.x,y:from.minY+from.height*layer.anchorPoint.y))
            move.toValue = NSValue(point:layer.position)
            move.duration = Motion.reorderDuration; move.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            layer.add(move,forKey:"dragReflow")
        }
        CATransaction.commit()
    }
    private func updateItemDrag(at point: NSPoint) {
        guard let id = dragID else { return }
        lastDragPoint = point
        draggedTile?.setFrameOrigin(NSPoint(x: point.x-dragOffset.x, y: point.y-dragOffset.y))
        // Keep pointer capture while the folder contracts. A mouse-up during
        // this transition is resolved by the group-closed completion.
        if folderClosing { return }
        finishFolderOpening()
        if pageTransition {
            // The cursor can leave the edge before the incoming page settles.
            // Stop repeated edge turns now; re-evaluate insertion on completion.
            let view = interaction.folderID == nil ? grid : folderGrid
            let frame = convert(view.bounds,from:view)
            if point.x >= frame.minX+12 && point.x <= frame.maxX-12 {
                edgeTimer?.invalidate(); edgeTimer = nil; edgeDirection = 0
            }
            return
        }
        if interaction.folderID != nil {
            if folderPanel.frame.insetBy(dx:-35,dy:-35).contains(point) { springLoadedEntryPoint = nil }
            else if springLoadedEntryPoint.map({ hypot(point.x-$0.x,point.y-$0.y) > 35 }) ?? true {
                if presentationState.location(of:id)?.folderID == interaction.folderID { extractingFolderID = interaction.folderID }
                stopHover(); closeFolder(animated:true); return
            }
        }
        if let folder = springLoadedFolderID, interaction.folderID == folder,
           presentationState.location(of:id)?.folderID != folder {
            pendingDrop = presentationState.endOfFolder(folder)
            return
        }
        let inside = interaction.folderID != nil
        let active = inside ? folderTiles : tiles
        let view = inside ? folderGrid : grid
        let local = view.convert(point, from: self)
        let cellW = view.bounds.width/CGFloat(columns)
        let cellH = view.bounds.height/CGFloat(inside ? folderRows : rows)
        guard cellW > 0, cellH > 0 else { return }
        let withinGrid = view.bounds.contains(local)
        let column = Int(floor(local.x/cellW)), row = Int(floor(local.y/cellH))
        let rawIndex = row*columns+column
        // Use accepted slot geometry, never the animated neighbors' positions.
        // Otherwise a neighbor moving under the pointer changes its own target.
        let hovered = withinGrid && active.indices.contains(rawIndex) ? active[rawIndex] : nil
        let target = hovered?.content.id
        let cell = NSRect(x:CGFloat(column)*cellW,y:CGFloat(row)*cellH,width:cellW,height:cellH)
        let artwork = hovered?.iconFrame ?? draggedTile?.iconFrame ?? .zero
        let nearCenter = hovered.map { _ in
            artwork.insetBy(dx:artwork.width*0.18,dy:artwork.height*0.08)
                .offsetBy(dx:cell.minX,dy:cell.minY).contains(local)
        } ?? false
        // The folder revealed by its close animation must not capture the
        // extracted app again during this same mouse gesture.
        let overSourceFolder = target != nil && target == extractedFolderID
        let groupAllowed = !overSourceFolder && state.app(id) != nil && target != id && nearCenter &&
            (target.flatMap { presentationState.folder($0) } != nil || (!inside && target.flatMap { state.app($0) } != nil))
        if target != hoverID || !groupAllowed {
            clearDropHighlight(); hoverID = groupAllowed ? target : nil
            hoverStarted = ProcessInfo.processInfo.systemUptime; hoverArmed = false
            hoverTimer?.invalidate()
            if groupAllowed {
                let existingFolder = target.flatMap { presentationState.folder($0) } != nil
                if existingFolder { hovered?.setFolderDropPreview(true) }
                hoverTimer = Timer.scheduledTimer(withTimeInterval: existingFolder ? Motion.folderHoverDelay : Motion.holdDelay, repeats: false) { [weak self] _ in
                    guard let self = self, let target = self.hoverID else { return }
                    self.hoverArmed = true
                    (self.tiles+self.folderTiles).first { $0.content.id == target }?.dropHighlight = true
                    self.insertionLine.isHidden = true
                    if self.presentationState.folder(target) != nil {
                        let destination = self.presentationState.endOfFolder(target)
                        self.openFolder(target,page:destination?.page ?? 0); self.stopHover()
                        self.springLoadedFolderID = target; self.springLoadedEntryPoint = self.lastDragPoint
                        self.pendingDrop = destination
                    }
                }
                if let timer = hoverTimer { RunLoop.main.add(timer, forMode: .common) }
            }
        }
        let remaining = active.filter { $0.content.id != id }
        let sameOriginSlot = target == id
        // Blank rows and screen margins are not implicit "append" targets.
        // Only an occupied cell or the first empty cell accepts insertion.
        let nearRow = local.y >= cell.minY+artwork.minY-12 && local.y <= cell.minY+artwork.maxY+32
        let acceptsInsertion = withinGrid && nearRow && !groupAllowed && !overSourceFolder && !sameOriginSlot && rawIndex <= active.count
        var candidate: ItemLocation?
        if acceptsInsertion {
            let targetIndex = remaining.firstIndex { $0.content.id == target }
            let insertion = min(targetIndex.map { $0+(local.x < cell.midX ? 0 : 1) } ?? rawIndex,remaining.count)
            let destination = ItemLocation(folderID:interaction.folderID,page:inside ? folderPage : currentPage,index:insertion)
            if destination != presentationState.location(of:id) { candidate = destination }
        }
        setInsertionCandidate(candidate)
        insertionLine.isHidden = true
        let frame = convert(view.bounds, from: view)
        let edge = point.x < frame.minX+12 ? -1 : (point.x > frame.maxX-12 ? 1 : 0)
        if edge != edgeDirection {
            edgeDirection = edge; edgeTimer?.invalidate()
            if edge != 0 {
                edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                    guard let self = self, self.dragID != nil else { return }
                    self.setInsertionCandidate(nil)
                    self.hoverTimer?.invalidate(); self.hoverID = nil; self.hoverArmed = false; self.clearDropHighlight()
                    let old = self.interaction.folderID == nil ? self.currentPage : self.folderPage
                    self.changePage(old+self.edgeDirection, allowNew: self.edgeDirection > 0)
                    self.pendingDrop = nil
                }
                if let timer = edgeTimer { RunLoop.main.add(timer, forMode: .common) }
            }
        }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { stopHover() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.string(forType: AppTile.pasteboardType) == dragID, dragID != nil {
            commitItemDrop(); return true
        }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let apps = urls.filter { $0.pathExtension.lowercased() == "app" }
        if !apps.isEmpty { controller?.addApplicationURLs(apps); return true }
        return false
    }
    private func pageDropFallback(in layout: LayoutState, for id: String) -> ItemLocation? {
        guard let location = layout.location(of:id) else { return nil }
        let inside = interaction.folderID != nil
        let page = inside ? folderPage : currentPage
        guard location.folderID != interaction.folderID || location.page != page else { return nil }
        let limit = inside ? folderCapacity : capacity
        if let candidate = insertionCandidate, candidate.folderID == interaction.folderID, candidate.page == page {
            return ItemLocation(folderID:candidate.folderID,page:page,index:min(candidate.index,max(0,limit-1)))
        }
        let pages = inside ? layout.folder(interaction.folderID!)?.pages ?? [[]] : layout.pages
        let count = pages.indices.contains(page) ? pages[page].filter { $0 != id }.count : 0
        return ItemLocation(folderID:interaction.folderID,page:page,index:min(count,max(0,limit-1)))
    }
    private func commitItemDrop() {
        guard let id = dragID else { return }
        if folderClosing { dropAfterFolderClose = true; return }
        finishFolderOpening()
        func snapshot(_ tile: AppTile) -> FolderDropTransition.Source {
            FolderDropTransition.Source(content:tile.content,icon:convert(tile.iconFrame,from:tile),label:convert(tile.labelFrame,from:tile))
        }
        let moving = draggedTile.map(snapshot)
        let targetSource = hoverArmed ? tiles.first(where: { $0.content.id == hoverID && !$0.content.isFolder }).map(snapshot) : nil
        var accepted = presentationState
        var hasAcceptedPosition = dragLayout != nil
        // An edge turn is itself a choice of destination page. If no insertion
        // slot settled there, land at its end (last visible slot on a full page).
        // An explicit folder target retains priority over the page fallback.
        let targetsFolder = (hoverID != extractedFolderID && hoverID.flatMap { accepted.folder($0) } != nil)
            || (hoverArmed && hoverID.flatMap { accepted.app($0) } != nil)
            || (springLoadedFolderID != nil && springLoadedFolderID != extractedFolderID && interaction.folderID == springLoadedFolderID)
        if !targetsFolder, let destination = pageDropFallback(in:accepted,for:id) {
            do {
                try accepted.move(id,to:destination,capacity:capacity,folderCapacity:folderCapacity)
                hasAcceptedPosition = true
            } catch { controller?.report(error); cancelItemDrag(animated:true); return }
        }
        let originFolder = accepted.location(of:id)?.folderID
        let rootFrames = Dictionary(uniqueKeysWithValues:tiles.map { ($0.content.id,$0.layer?.presentation()?.frame ?? $0.frame) })
        let previewFolder = tiles.first { $0.content.id == hoverID && $0.folderDropPreview }?.content.id
        var newFolder: String?
        // The following mutation saves all accepted moves as one Undo action.
        // Its refresh must render the committed state, not the drag snapshot.
        dragBaseState = nil; dragLayout = nil
        if let target = hoverID, target != extractedFolderID, let destination = accepted.endOfFolder(target) {
            controller?.mutate(L10n.text("Move to Folder", "폴더로 이동")) {
                $0 = accepted; try $0.move(id, to: destination, capacity: self.capacity, folderCapacity: self.folderCapacity)
            }
        } else if let target = springLoadedFolderID, target != extractedFolderID, interaction.folderID == target, originFolder != target,
                  let destination = accepted.endOfFolder(target) {
            controller?.mutate(L10n.text("Move to Folder", "폴더로 이동")) {
                $0 = accepted; try $0.move(id,to:destination,capacity:self.capacity,folderCapacity:self.folderCapacity)
            }
        } else if hoverArmed, let target = hoverID, state.app(target) != nil {
            controller?.mutate(L10n.text("Create Folder", "폴더 만들기")) {
                $0 = accepted; newFolder = try $0.makeFolder(with: id, over: target, capacity: self.capacity, folderCapacity:self.folderCapacity)
            }
        } else if hasAcceptedPosition {
            controller?.mutate(L10n.text("Move App", "앱 이동")) { $0 = accepted }
        } else {
            cancelItemDrag(animated:true); return
        }
        let destinationFolder = state.location(of:id)?.folderID
        let entersFolder = destinationFolder != nil && originFolder != destinationFolder
        cancelItemDrag(animated:!entersFolder)
        guard entersFolder, let folder = destinationFolder, let moving = moving else { return }
        let destinationPage = state.location(of:id)?.page ?? 0
        let turnsPage = interaction.folderID == folder && destinationPage != folderPage
        if turnsPage { changePage(destinationPage,insideFolder:true) }
        if Motion.reduced {
            if let created = newFolder { beginRenamingFolder(created) }
            return
        }
        let transition = FolderDropTransition(frame:bounds)
        transition.wantsLayer = true; transition.autoresizingMask = [.width,.height]
        var sources = [moving]
        if newFolder != nil, let target = targetSource { sources.append(target) }
        if interaction.folderID == folder {
            for source in sources {
                if let destination = folderTiles.first(where: { $0.content.id == source.content.id }) {
                    transition.add(source,to:convert(destination.iconFrame,from:destination))
                    dropHiddenIDs.insert(source.content.id)
                }
            }
        } else if let destination = tiles.first(where: { $0.content.id == folder }), let group = state.folder(folder) {
            if previewFolder == folder {
                destination.setFolderDropPreview(true,reservingSlot:false,animated:false)
                dropPreviewFolderID = folder
            }
            let children = group.pages.flatMap { $0 }
            for source in sources {
                guard let index = children.firstIndex(of:source.content.id) else { continue }
                let visible = index/3 >= destination.previewFirstRow && index/3 < destination.previewFirstRow+3
                let slot = visible ? index : min(index,8)
                transition.add(source,to:convert(destination.displayedMiniatureFrame(at:slot),from:destination),disappears:!visible)
                if visible { dropHiddenMinis[folder,default:[]].insert(index) }
            }
        }
        guard !transition.flights.isEmpty else {
            if let created = newFolder { beginRenamingFolder(created) }
            return
        }
        folderDropGeneration += 1
        let generation = folderDropGeneration
        folderDrop = transition; renameAfterDrop = newFolder
        refresh(); addSubview(transition)
        // A full folder may be paging while refresh is deferred. Keep its
        // incoming destination hidden until both the page and icon arrive.
        for tile in folderTiles where dropHiddenIDs.contains(tile.content.id) { tile.isHidden = true }
        let duration = turnsPage ? max(Motion.pageDuration,Motion.folderDropDuration) : Motion.folderDropDuration
        for tile in tiles {
            guard let before = rootFrames[tile.content.id], before.origin != tile.frame.origin, let layer = tile.layer else { continue }
            let slide = CABasicAnimation(keyPath:"position")
            slide.fromValue = NSValue(point:NSPoint(x:before.minX+before.width*layer.anchorPoint.x,
                y:before.minY+before.height*layer.anchorPoint.y))
            slide.toValue = NSValue(point:layer.position); slide.duration = duration
            slide.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut)
            layer.add(slide,forKey:"folderReflow")
        }
        if newFolder != nil { tiles.first { $0.content.id == folder }?.animateFolderReveal() }
        transition.animate(duration:duration) { [weak self] in
            guard let self = self, self.folderDropGeneration == generation else { return }
            self.finishFolderDrop(complete:true)
        }
    }
    func finishFolderDrop(complete: Bool = false) {
        guard let transition = folderDrop else { return }
        let rename = complete ? renameAfterDrop : nil
        folderDropGeneration += 1; folderDrop = nil; renameAfterDrop = nil
        transition.removeFromSuperview(); dropHiddenIDs.removeAll(); dropHiddenMinis.removeAll()
        if let id = dropPreviewFolderID { tiles.first { $0.content.id == id }?.setFolderDropPreview(false) }
        dropPreviewFolderID = nil
        for tile in tiles { tile.layer?.removeAnimation(forKey:"folderReflow") }
        refresh()
        if let id = rename, state.folder(id) != nil, controller?.isShown == true { beginRenamingFolder(id) }
    }
    private func clearDropHighlight() {
        for tile in tiles+folderTiles {
            tile.dropHighlight = false
            if tile.content.id != dropPreviewFolderID { tile.setFolderDropPreview(false) }
        }
    }
    private func stopHover() {
        edgeTimer?.invalidate(); hoverTimer?.invalidate(); edgeTimer = nil; hoverTimer = nil
        edgeDirection = 0; hoverID = nil; hoverArmed = false; pendingDrop = nil
        insertionTimer?.invalidate(); insertionTimer = nil; insertionCandidate = nil
        insertionLine.isHidden = true; clearDropHighlight()
    }
    func beginRenamingFolder(_ id: String) {
        openFolder(id); folderTitle.selectText(nil); interaction.renaming = true
    }
    func beginEditing() { guard dragID == nil else { return }; interaction.editing = true; refresh() }

    /// Focused regression for releases after an edge page turn. Uses an
    /// isolated --data-dir and never runs the broader interaction suites.
    func runPageDropChecks(outputDirectory: URL, completion: @escaping (Result<Void,Error>) -> Void) {
        guard let controller = controller, let window = window else { return }
        let original = state
        var fixture = LayoutState(), folderFixture = LayoutState()
        var count = 0, sourceID = "", folderID = ""
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LayoutError.invalid("Page drop check failed: "+message) }; count += 1
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
            window.sendEvent(NSEvent.mouseEvent(with:type,location:convert(point,to:nil),modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
                eventNumber:0,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!)
        }
        func start(page: Int) throws {
            finishItemReturn(); currentPage = page; refresh()
            let source = tiles[0]; sourceID = source.content.id
            let point = source.convert(NSPoint(x:source.iconFrame.midX,y:source.iconFrame.midY),to:self)
            mouse(.leftMouseDown,point); mouse(.leftMouseDragged,NSPoint(x:point.x+10,y:point.y))
            try check(dragID == sourceID,"source begins an internal app drag")
        }
        func edge() {
            let view = interaction.folderID == nil ? grid : folderGrid
            let frame = convert(view.bounds,from:view)
            mouse(.leftMouseDragged,NSPoint(x:frame.maxX-5,y:frame.midY))
        }
        func blankDrop() {
            let point = interaction.folderID == nil ? NSPoint(x:bounds.midX,y:searchBox.frame.maxY+4)
                : convert(NSPoint(x:folderGrid.bounds.midX,y:folderGrid.bounds.maxY-2),from:folderGrid)
            mouse(.leftMouseDragged,point); mouse(.leftMouseUp,point)
        }
        func restore() { finishItemReturn(); controller.mutate("Restore page drop fixture") { $0 = fixture }; currentPage = 0; refresh() }
        let wait = Motion.pageDuration+Motion.returnDuration+0.1
        let steps: [InteractionCheckStep] = [
            .init { [self] in
                interaction = InteractionState(); currentPage = 0
                let installed = state.apps.filter(\.available)
                try check(!installed.isEmpty,"artwork fixture is available")
                let apps = (0..<(capacity*2+8)).map { i -> AppRecord in
                    var app = installed[i%installed.count]; app.id = "page-drop-\(i)"; return app
                }
                fixture.reconcile(apps,capacity:capacity,folderCapacity:folderCapacity)
                fixture.didGroupSystemApps = true; fixture.systemFolderPolicyVersion = 2
                restore(); try start(page:0)
                blankDrop()
                try check(state == fixture,"blank release on the original page does not move anything")
            },
            .init(delay:wait) { try start(page:0); edge() },
            .init(delay:0.85) { [self] in
                try check(currentPage == 1 && dragID == sourceID,"holding the edge turns the page without ending the drag")
                try check(Motion.reduced || pageTransition,"test releases while the page is still transitioning")
                blankDrop()
                try check(state.location(of:sourceID) == ItemLocation(page:1,index:capacity-1),"blank drop on a full page keeps the app in its last slot")
                try check(state.pages[2].first == fixture.pages[1].last,"the previous last app overflows to the following page")
                try check(try controller.store.load() == state,"cross-page drop persists immediately")
            },
            .init(delay:wait) { [self] in
                try check(dragID == nil && !pageTransition && returningTile == nil,"cross-page release cleans up the drag and animation")
                controller.undoLayout(); try check(state == fixture,"one Undo restores the entire cross-page drop")
                try start(page:1); edge()
            },
            .init(delay:0.85) { [self] in
                try check(currentPage == 2,"edge turn reaches the partially filled page")
                blankDrop()
                try check(state.location(of:sourceID) == ItemLocation(page:2,index:fixture.pages[2].count),"blank release appends to a partially filled page")
            },
            .init(delay:wait) { restore(); try start(page:2); edge() },
            .init(delay:0.85) { [self] in
                try check(currentPage == 3 && transientPage != nil,"edge turn exposes a new empty page")
                blankDrop()
                try check(state.pages.count == 4 && state.pages[3] == [sourceID],"blank release saves the new page and its app")
            },
            .init(delay:wait) { [self] in
                restore(); try start(page:0)
                acceptDragLocation(ItemLocation(page:0,index:3))
                try check(dragLayout != nil && state == fixture,"first-page insertion remains an uncommitted preview")
                edge()
            },
            .init(delay:0.85) { [self] in
                blankDrop()
                try check(state.location(of:sourceID)?.page == 1,"the visible page wins over an accepted slot on the previous page")
            },
            .init(delay:wait) { [self] in
                restore(); try start(page:0); changePage(1,allowNew:true)
            },
            .init(delay:Motion.pageDuration+0.08) { [self] in
                let last = tiles[capacity-1]
                let point = last.convert(NSPoint(x:last.bounds.maxX-5,y:last.iconFrame.midY),to:self)
                mouse(.leftMouseDragged,point)
                try check(insertionCandidate?.index == capacity && pendingDrop == nil,"last-cell insertion is still an unconfirmed candidate")
                mouse(.leftMouseUp,point)
                try check(state.location(of:sourceID) == ItemLocation(page:1,index:capacity-1),"unconfirmed end insertion cannot spill the dragged app past the chosen full page")
            },
            .init(delay:wait) { restore(); try start(page:0); edge() },
            .init(delay:0.85) { [self] in
                cancelItemDrag(animated:true)
                try check(state == fixture,"cancelling after a page turn does not commit the fallback")
            },
            .init(delay:wait) { [self] in
                restore()
                controller.mutate("Folder page drop fixture") { layout in
                    folderID = try layout.makeFolder(with:layout.apps[0].id,over:layout.apps[1].id)
                    for app in layout.apps[2..<(self.folderCapacity+8)] {
                        try layout.move(app.id,to:layout.endOfFolder(folderID)!,folderCapacity:self.folderCapacity)
                    }
                }
                folderFixture = state; openFolder(folderID); finishFolderOpening()
                let source = folderTiles[0]; sourceID = source.content.id
                let point = source.convert(NSPoint(x:source.iconFrame.midX,y:source.iconFrame.midY),to:self)
                mouse(.leftMouseDown,point); mouse(.leftMouseDragged,NSPoint(x:point.x+10,y:point.y)); edge()
            },
            .init(delay:0.85) { [self] in
                try check(folderPage == 1 && interaction.folderID == folderID,"folder edge turn preserves the open folder")
                blankDrop()
                try check(state.location(of:sourceID)?.folderID == folderID && state.location(of:sourceID)?.page == 1,"blank release also lands on the next folder page")
                controller.undoLayout(); try check(state == folderFixture,"folder page move is one undoable action")
            }
        ]
        InteractionCheckSequence(steps) { [self] result in
            cancelItemDrag(); finishItemReturn(); cancelPageTransition(); closeFolder(animated:false)
            controller.mutate("Restore original isolated layout") { $0 = original }
            do {
                try result.get()
                let report = "PASS: \(count) cross-page drop checks\nOnly changed drag/drop behavior was tested.\n"
                try report.write(to:outputDirectory.appendingPathComponent("page-drop-checks.txt"),atomically:true,encoding:.utf8)
                print(report); completion(.success(()))
            } catch { completion(.failure(error)) }
        }.run()
    }

    func runDragChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        runDragVacancyChecks(outputDirectory:outputDirectory) { [weak self] result in
            switch result {
            case .success:
                self?.runExtractionChecks(outputDirectory:outputDirectory) { result in
                    switch result {
                    case .success: self?.runFolderAndDragChecks(outputDirectory:outputDirectory,completion:completion)
                    case .failure: completion(result)
                    }
                }
            case .failure: completion(result)
            }
        }
    }
    private func runDragVacancyChecks(outputDirectory: URL, completion: @escaping (Result<Void,Error>) -> Void) {
        guard let controller = controller, let window = window else { return }
        var checks = 0, sourceID = ""
        let original = state, originalSize = frame.size
        var frames: [String:NSRect] = [:], liftedFrame = NSRect.zero, originFrame = NSRect.zero
        var saved = Data(), accepted = original
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LayoutError.invalid("Drag vacancy check failed: \(name)") }; checks += 1
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
            window.sendEvent(NSEvent.mouseEvent(with:type,location:convert(point,to:nil),modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
                eventNumber:0,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!)
        }
        func start() throws {
            guard let source = tiles.first(where:{ $0.content.id == sourceID }) else { throw LayoutError.invalid("Vacancy fixture source missing") }
            let point = convert(NSPoint(x:source.iconFrame.midX,y:source.iconFrame.midY),from:source)
            mouse(.leftMouseDown,point); mouse(.leftMouseDragged,NSPoint(x:point.x+10,y:point.y))
            try check(dragID == sourceID && pendingDrop == nil,"lifting the source keeps its original placeholder")
        }
        func idlePoint() -> NSPoint { NSPoint(x:bounds.midX,y:searchBox.frame.maxY+4) }
        func neighborsUnchanged() -> Bool { tiles.allSatisfy { $0.frame == frames[$0.content.id] } }
        let steps: [InteractionCheckStep] = [
            .init { [self] in
                cancelItemDrag(); closeFolder(animated:false); cancelPageTransition(); cancelBackgroundPaging()
                interaction = InteractionState(); search.stringValue = ""; currentPage = 0; refresh()
                sourceID = tiles.filter { !$0.content.isFolder }.dropFirst().first!.content.id
                frames = Dictionary(uniqueKeysWithValues:tiles.map { ($0.content.id,$0.frame) })
                originFrame = convert(tiles.first { $0.content.id == sourceID }!.bounds,from:tiles.first { $0.content.id == sourceID }!)
                saved = try Data(contentsOf:controller.store.directory.appendingPathComponent("layout.json"))
                try start(); mouse(.leftMouseDragged,idlePoint())
            },
            .init(delay:Motion.reorderDuration+0.1) { [self] in
                try check(pendingDrop == nil && neighborsUnchanged(),"screen margins neither choose an insertion index nor fill the source slot")
                liftedFrame = draggedTile!.frame
                mouse(.leftMouseUp,idlePoint())
                try check(state == original && dragID == nil,"invalid release preserves the complete saved layout")
                if !Motion.reduced {
                    try check(returningTile != nil && returnHiddenID == sourceID && tiles.first { $0.content.id == sourceID }?.isHidden == true,
                              "return keeps one floating icon and hides its destination until landing")
                    try check(returningTile?.hasRenderedTitle == true && returningTile?.content.title == state.app(sourceID)?.title,
                              "returning tile retains its app name")
                }
            },
            .init(delay:0.12) { [self] in
                if !Motion.reduced {
                    guard let live = returningTile?.layer?.presentation()?.frame else { throw LayoutError.invalid("Missing return presentation") }
                    try check(hypot(live.midX-liftedFrame.midX,live.midY-liftedFrame.midY) > 2
                        && hypot(live.midX-originFrame.midX,live.midY-originFrame.midY) > 2,"return visibly moves between the release and source positions")
                    window.displayIfNeeded(); CATransaction.flush()
                    let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming])!
                    try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent("drag-returning.png"))
                }
            },
            .init(delay:Motion.returnDuration+0.1) { [self] in
                try check(returningTile == nil && returnHiddenID == nil && neighborsUnchanged() && tiles.allSatisfy { !$0.isHidden },"return removes temporary views and restores every original slot")
                try check(try Data(contentsOf:controller.store.directory.appendingPathComponent("layout.json")) == saved,"invalid release never writes the layout")
                try start()
                let target = tiles.filter { !$0.content.isFolder && $0.content.id != sourceID }.last!
                let point = convert(NSPoint(x:target.bounds.width-15,y:target.iconFrame.midY),from:target)
                mouse(.leftMouseDragged,point)
                try check(pendingDrop == nil && neighborsUnchanged(),"passing an insertion candidate does not immediately compact the source gap")
            },
            .init(delay:Motion.insertionDelay+Motion.reorderDuration+0.1) { [self] in
                try check(pendingDrop != nil && !neighborsUnchanged() && state == original,"a settled target moves the placeholder without saving intermediate data")
                accepted = presentationState
                mouse(.leftMouseDragged,idlePoint())
            },
            .init(delay:Motion.reorderDuration+0.1) { [self] in
                try check(presentationState == accepted && !neighborsUnchanged(),"leaving an accepted target retains the new vacancy and compacted neighbors")
                try check(try Data(contentsOf:controller.store.directory.appendingPathComponent("layout.json")) == saved,"accepted positions remain unsaved while holding the mouse")
                liftedFrame = draggedTile!.frame
                mouse(.leftMouseUp,idlePoint())
                try check(state == accepted && (try controller.store.load()) == accepted,"release over a margin commits the last accepted position")
                let destination = tiles.first { $0.content.id == sourceID }!
                originFrame = convert(destination.bounds,from:destination)
                if !Motion.reduced { try check(returningTile != nil && destination.isHidden,"a successful move animates the full tile into its new home") }
            },
            .init(delay:0.12) { [self] in
                if !Motion.reduced {
                    guard let live = returningTile?.layer?.presentation()?.frame else { throw LayoutError.invalid("Missing landing presentation") }
                    try check(hypot(live.midX-liftedFrame.midX,live.midY-liftedFrame.midY) > 2
                        && hypot(live.midX-originFrame.midX,live.midY-originFrame.midY) > 2,"successful landing visibly moves between release and the new slot")
                    window.displayIfNeeded(); CATransaction.flush()
                    let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming])!
                    try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent("drag-landing.png"))
                }
                setFrameSize(NSSize(width:originalSize.width-1,height:originalSize.height)); refresh()
                try check(returningTile == nil && returnHiddenID == nil,"resizing interrupts the return without leaving a hidden source")
                setFrameSize(originalSize); refresh()
                controller.undoLayout()
                try check(state == original && (try controller.store.load()) == original,"one Undo restores the whole accepted drag and saved layout")
                print("PASS: \(checks) drag vacancy and return checks")
            }
        ]
        InteractionCheckSequence(steps,completion:completion).run()
    }
    func runExtractionChecks(outputDirectory: URL, completion: @escaping (Result<Void,Error>) -> Void) {
        guard let controller = controller, let window = window else { return }
        do { try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true) }
        catch { completion(.failure(error)); return }
        let original = state, ids = state.orderedAppIDs
        var fixture = original, folderID = "", sourceID = "", displacedID = "", checks = 0
        var panelFrame = NSRect.zero, liftedFrame = NSRect.zero
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LayoutError.invalid("Folder extraction check failed: \(name)") }; checks += 1
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
            window.sendEvent(NSEvent.mouseEvent(with:type,location:convert(point,to:nil),modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
                eventNumber:0,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!)
        }
        func idle() -> NSPoint { NSPoint(x:bounds.midX,y:searchBox.frame.maxY+4) }
        func capture(_ name: String) throws {
            window.displayIfNeeded(); CATransaction.flush()
            guard let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]) else {
                throw LayoutError.invalid("Cannot capture extraction window")
            }
            try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent(name+".png"))
        }
        func setup(full: Bool, children: Int, page: Int = 0) throws {
            cancelItemDrag(); finishItemReturn(); closeFolder(animated:false); cancelPageTransition(); cancelBackgroundPaging()
            interaction = InteractionState(); search.stringValue = ""; currentPage = 0
            try check(ids.count > capacity+children,"enough apps for extraction fixture")
            let group = AppFolder(title:"꺼내기 검증",pages:[Array(ids.prefix(children))])
            folderID = group.id; sourceID = ids[0]
            let remaining = Array(ids.dropFirst(children)), count = full ? capacity-1 : 5
            controller.mutate("Extraction fixture") {
                $0 = original; $0.folders = [group]
                $0.pages = [[group.id]+Array(remaining.prefix(count))]+self.chunk(Array(remaining.dropFirst(count)),self.capacity)
                if page != 0 { $0.pages.swapAt(0,page) }
            }
            fixture = state; displacedID = fixture.pages[0].last!
            currentPage = page; refresh()
            openFolder(folderID); finishFolderOpening(); panelFrame = folderPanel.frame
        }
        func liftAndExit(at exitPoint: NSPoint? = nil) throws {
            guard let tile = folderTiles.first(where:{ $0.content.id == sourceID }) else { throw LayoutError.invalid("Extraction source missing") }
            let point = convert(NSPoint(x:tile.iconFrame.midX,y:tile.iconFrame.midY),from:tile)
            mouse(.leftMouseDown,point); mouse(.leftMouseDragged,NSPoint(x:point.x+10,y:point.y))
            mouse(.leftMouseDragged,exitPoint ?? idle())
            try check(dragID == sourceID && draggedTile != nil,"extraction preserves the complete floating app tile")
            try check(Motion.reduced ? interaction.folderID == nil : folderClosing,"exiting the panel starts its close transition")
        }
        let steps: [InteractionCheckStep] = [
            .init { try setup(full:true,children:2); try liftAndExit() },
            .init(delay:0.10) { [self] in
                mouse(.leftMouseDragged,NSPoint(x:idle().x+25,y:idle().y))
                if !Motion.reduced {
                    guard let live = folderPanel.layer?.presentation()?.frame else { throw LayoutError.invalid("Missing extraction close presentation") }
                    try check(folderClosing && live.width < panelFrame.width-2 && live.width > folderSourceRect.width+2,
                              "continued pointer movement does not cut the folder contraction short")
                    try capture("folder-extract-closing")
                }
            },
            .init(delay:Motion.folderOpenDuration+0.08) { [self] in
                try check(interaction.folderID == nil && !folderOpening && folderOpeningOverlay == nil,"extraction finishes all folder close layers")
                try check(presentationState.location(of:sourceID) == ItemLocation(page:0,index:capacity-1),"a full page gives the extracted app its last visible slot")
                try check(presentationState.pages[1].first == displacedID,"the displaced last app remains first on the following page")
                try check(tiles.count == capacity && tiles.last?.content.id == sourceID && tiles.last?.isHidden == true,"the extracted app owns one hidden destination slot")
                try check(!grid.subviews.compactMap { $0 as? AppTile }.contains { $0.content.id == displacedID }
                    && tiles.allSatisfy { grid.bounds.contains($0.frame) } && outgoingPage == nil,"overflow is removed immediately without an extra animated row or ghost")
                try check(state == fixture && (try controller.store.load()) == fixture,"folder extraction is provisional until mouse release")
                try capture("folder-extract-full-page")
                liftedFrame = draggedTile!.frame
                mouse(.leftMouseUp,NSPoint(x:idle().x+25,y:idle().y))
                try check(state.location(of:sourceID) == ItemLocation(page:0,index:capacity-1),"blank release commits the extracted app to the current page end")
                try check(state.folder(folderID)?.pages[0].count == 1,"extraction preserves the remaining folder child")
                if !Motion.reduced { try check(returningTile != nil && returnHiddenID == sourceID,"extraction uses the landing animation instead of returning to the folder") }
            },
            .init(delay:0.10) { [self] in
                if !Motion.reduced {
                    guard let live = returningTile?.layer?.presentation()?.frame else { throw LayoutError.invalid("Missing extraction landing presentation") }
                    try check(hypot(live.midX-liftedFrame.midX,live.midY-liftedFrame.midY) > 2,"extracted icon and label move toward the page end")
                    try capture("folder-extract-landing")
                }
            },
            .init(delay:Motion.returnDuration+0.1) { [self] in
                try check(returningTile == nil && tiles.allSatisfy { !$0.isHidden },"landing reveals the page without leftover hidden apps")
                try check(try controller.store.load() == state,"extracted layout survives reload")
                controller.undoLayout()
                try check(state == fixture,"one Undo restores folder membership and displaced app")
                try check(tiles.last?.content.id == displacedID && tiles.last?.layer?.animation(forKey:"dragReflow") == nil,"the restored overflow app appears without sliding up from below")
                try setup(full:false,children:2,page:1); try liftAndExit()
            },
            .init(delay:0.08) { [self] in
                mouse(.leftMouseUp,idle())
                if !Motion.reduced {
                    try check(folderClosing && dropAfterFolderClose && dragID == sourceID && state == fixture,
                              "release during contraction waits for group-closed completion")
                }
            },
            .init(delay:Motion.folderOpenDuration+Motion.returnDuration+0.15) { [self] in
                try check(currentPage == 1 && state.pages[1].last == sourceID && state.pages[1].count == fixture.pages[1].count+1,"early release appends to the partial current page, including page two")
                try check(state.pages[0] == fixture.pages[0],"extraction on page two preserves page one")
                try check(state.location(of:sourceID)?.folderID == nil && interaction.folderID == nil && dragID == nil && !dropAfterFolderClose,
                          "early release cannot reopen the source folder")
                try check(returningTile == nil && folderOpeningOverlay == nil,"deferred drop leaves no transition views")
                controller.undoLayout(); try check(state == fixture,"deferred extraction is one undoable move")
                try setup(full:true,children:1); try liftAndExit()
            },
            .init(delay:0.08) {
                window.sendEvent(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!)
            },
            .init(delay:Motion.folderOpenDuration+Motion.returnDuration+0.1) { [self] in
                try check(state == fixture && dragID == nil && !dropAfterFolderClose && dragLayout == nil,"Escape cancels extraction and invalidates pending close callbacks")
                try check(interaction.folderID == folderID && folderTiles.first?.isHidden == false,"Escape returns the app to its original folder")
                try liftAndExit()
            },
            .init(delay:Motion.folderOpenDuration+0.1) { [self] in
                try check(presentationState.folder(folderID) == nil && presentationState.pages[0].last == sourceID,"extracting the last child removes the empty folder and keeps the app on this page")
                try check(presentationState.pages[1] == fixture.pages[1],"removing the empty folder frees a slot without displacing another app")
                mouse(.leftMouseUp,idle())
            },
            .init(delay:Motion.returnDuration+0.1) { [self] in
                try check(state.folder(folderID) == nil && state.pages[0].last == sourceID,"last-child extraction persists without returning into an empty folder")
                try state.validate(); try check(try controller.store.load() == state,"all extracted apps remain unique and persisted")
                controller.undoLayout(); try check(state == fixture,"Undo restores the removed folder and its only child")
                try setup(full:true,children:2); try liftAndExit()
            },
            .init(delay:Motion.folderOpenDuration+0.1) { [self] in
                let sourceFolder = tiles.first { $0.content.id == folderID }!
                let point = convert(NSPoint(x:sourceFolder.iconFrame.midX,y:sourceFolder.iconFrame.midY),from:sourceFolder)
                mouse(.leftMouseDragged,point)
                try check(hoverID == nil && insertionCandidate == nil,"the source folder is neither a drop target nor an insertion target after extraction")
            },
            .init(delay:Motion.folderHoverDelay+0.15) { [self] in
                try check(interaction.folderID == nil && springLoadedFolderID == nil && !folderOpening,"holding the extracted app over its source folder does not reopen it")
                try check(presentationState.pages[0].last == sourceID && tiles.last?.isHidden == true,"the last slot remains reserved while hovering the source folder")
                mouse(.leftMouseUp,lastDragPoint)
                try check(state.pages[0].last == sourceID && state.location(of:sourceID)?.folderID == nil,"release over the old folder lands at the page end")
            },
            .init(delay:Motion.returnDuration+0.1) { [self] in
                try check(interaction.folderID == nil && returningTile == nil && tiles.last?.isHidden == false,"the extracted app appears in the final slot after landing")
                try check(state.pages[1].first == displacedID && (try controller.store.load()) == state,"the displaced app is retained on the next page and saved")
                controller.undoLayout(); try check(state == fixture,"Undo restores the source folder after a source-folder release")
                try setup(full:true,children:2)
                // Jump directly from the folder to the screen's bottom edge.
                // On fullscreen this reaches the Dock reservation; in window
                // mode it exercises the same bottom-edge layout gesture.
                let point = NSPoint(x:bounds.midX,y:bounds.maxY-1)
                try liftAndExit(at:point)
                try check(!externalDrag && draggedTile?.isHidden == false,"a direct downward extraction keeps internal pointer capture and its floating tile")
                if !CommandLine.arguments.contains("--windowed"), let screen = window.screen, screen.visibleFrame.minY > screen.frame.minY {
                    try check(isOverDock(point),"the fullscreen regression reaches the actual Dock reservation")
                }
            },
            .init(delay:Motion.folderOpenDuration+0.1) { [self] in
                try check(extractedFolderID == folderID && interaction.folderID == nil && !externalDrag,"Dock-edge extraction closes the folder without handing off a file drag")
                try check(state == fixture && presentationState.pages[0].last == sourceID && tiles.last?.isHidden == true,"holding over the Dock reserves the final slot without saving")
                try check(tiles.count == capacity && !tiles.contains { $0.content.id == displacedID },"the former last app disappears while the extracted app is held")
                try capture("folder-extract-dock-edge")
                mouse(.leftMouseUp,lastDragPoint)
                try check(state.pages[0].last == sourceID && state.pages[1].first == displacedID,"Dock-edge mouse-up places the app last and retains overflow")
            },
            .init(delay:Motion.returnDuration+0.1) { [self] in
                try check(interaction.folderID == nil && dragID == nil && tiles.last?.isHidden == false,"Dock-edge release cannot return the app to its source folder")
                controller.undoLayout(); try check(state == fixture,"Dock-edge extraction is one undoable change")
                try setup(full:true,children:2)
                let point = NSPoint(x:bounds.midX,y:bounds.maxY+20)
                try liftAndExit(at:point)
                try check(!bounds.contains(point) && !externalDrag,"leaving the window during extraction does not start an external file drag")
                mouse(.leftMouseUp,point)
                if !Motion.reduced { try check(folderClosing && dropAfterFolderClose,"outside-window release also waits for the folder close") }
            },
            .init(delay:Motion.folderOpenDuration+Motion.returnDuration+0.15) { [self] in
                try check(interaction.folderID == nil && state.pages[0].last == sourceID,"outside-window release lands at the page end instead of cancelling into the folder")
                try check(state.pages[1].first == displacedID && (try controller.store.load()) == state,"outside-window extraction preserves all apps after reload")
                try check(dragID == nil && !externalDrag && returningTile == nil && extractedFolderID == nil,"outside-window completion cleans up its drag state")
                controller.undoLayout(); try check(state == fixture,"outside-window extraction undoes atomically")
                controller.mutate("Restore extraction fixture") { $0 = original }
                closeFolder(animated:false); currentPage = 0; refresh()
                try check(state == original,"extraction checks restore the original layout")
                print("PASS: \(checks) folder extraction and landing checks")
            }
        ]
        InteractionCheckSequence(steps,completion:completion).run()
    }
    private func runFolderAndDragChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        runFolderPresentationChecks(outputDirectory:outputDirectory) { [weak self] result in
            switch result {
            case .success:
                self?.runPageMotionChecks(outputDirectory:outputDirectory) { [weak self] result in
                    switch result {
                    case .success: self?.runItemDragChecks(outputDirectory:outputDirectory,completion:completion)
                    case .failure: completion(result)
                    }
                }
            case .failure: completion(result)
            }
        }
    }
    private func runFolderPresentationChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let controller = controller, let window = window else { return }
        var checks = 0, folderID = ""
        let original = state, originalSize = frame.size, appIDs = state.orderedAppIDs
        var expectedSource = NSRect.zero
        var geometry = ["apps,rows,pages,panel_x,panel_y,panel_width,panel_height,title_bottom,icon_size"]
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LayoutError.invalid("Folder presentation check failed: \(description)") }
            checks += 1
        }
        func capture(_ name: String) throws {
            window.displayIfNeeded(); CATransaction.flush()
            guard let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]) else {
                throw LayoutError.invalid("Cannot capture folder window")
            }
            try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent(name+".png"))
        }
        var steps: [InteractionCheckStep] = []
        let counts = [1,columns,columns+1,columns*2+1,columns*3+1,columns*4+1,folderCapacity,folderCapacity+1]
        for (caseIndex,count) in counts.enumerated() {
            steps.append(.init { [self] in
                closeFolder(animated:false); cancelItemDrag(); cancelBackgroundPaging(); cancelPageTransition()
                interaction = InteractionState(); search.stringValue = ""; currentPage = 0
                try check(appIDs.count >= count,"enough installed apps for \(count)-item folder")
                let children = Array(appIDs.prefix(count)), remaining = Array(appIDs.dropFirst(count))
                controller.mutate("Folder presentation fixture") { layout in
                    layout = original
                    let folder = AppFolder(title:"폴더 검증 \(count)",pages:self.chunk(children,self.folderCapacity))
                    folderID = folder.id; layout.folders = [folder]
                    layout.pages = self.chunk(remaining,self.capacity)
                    if layout.pages.isEmpty { layout.pages = [[]] }
                    layout.pages[0].insert(folder.id,at:min(caseIndex%2 == 0 ? 0 : self.capacity-1,layout.pages[0].count))
                }
                guard let source = tiles.first(where:{ $0.content.id == folderID }) else { throw LayoutError.invalid("Folder fixture missing") }
                expectedSource = convert(source.folderIconFrame,from:source)
                let iconFill = source.subviews.compactMap { $0 as? FlippedView }.first?.layer?.backgroundColor
                openFolder(folderID)
                try check(folderRows == min(5,(count+columns-1)/columns),"\(count) apps reserve the necessary rows, capped at five")
                try check(folderTiles.count == min(count,folderCapacity),"all apps through row five are visible on the first page")
                try check(folderTitle.frame.maxY+10 <= folderPanel.frame.minY && !folderTitle.isHidden,"editable title is above the panel")
                try check(folderPanel.layer?.backgroundColor == iconFill,"panel shares the folder icon's color and alpha")
                try check(gridViewport.isHidden && pageDots.isHidden && searchBox.isHidden,"folder hides the background app pages and search field")
                try check(folderDots.isHidden == (count <= folderCapacity),"folder dots appear only for multiple pages")
                try check(folderTiles.allSatisfy { folderGrid.bounds.contains($0.frame) && $0.bounds.contains($0.labelFrame) },"all rows and labels fit in the panel")
                try check(bounds.contains(folderTitle.frame) && bounds.contains(folderPanel.frame),"panel and external title fit the screen")
                if !Motion.reduced {
                    let group = folderPanel.layer?.animation(forKey:"folderOpen") as? CAAnimationGroup
                    let animations = group?.animations?.compactMap { $0 as? CABasicAnimation } ?? []
                    let size = (animations.first { $0.keyPath == "bounds" }?.fromValue as? NSValue)?.rectValue.size
                    let position = (animations.first { $0.keyPath == "position" }?.fromValue as? NSValue)?.pointValue
                    let anchor = folderPanel.layer!.anchorPoint
                    let expected = NSPoint(x:expectedSource.minX+expectedSource.width*anchor.x,y:expectedSource.minY+expectedSource.height*anchor.y)
                    try check(folderOpening && size == expectedSource.size && position == expected,"expansion starts at this folder's actual icon, including lower/right positions")
                    let icons = folderOpeningOverlay?.subviews.compactMap { $0 as? NSImageView } ?? []
                    try check(icons.count == folderTiles.count && icons.allSatisfy { $0.layer?.animation(forKey:"folderOpen") != nil },"folder children expand from the miniature positions")
                } else { try check(!folderOpening && folderViewport.layer?.masksToBounds == true,"reduced motion opens without expansion layers") }
            })
            if caseIndex == 0 && !Motion.reduced {
                steps.append(.init(delay:0.12) { [self] in
                    let frame = folderPanel.layer?.presentation()?.frame ?? .zero
                    try check(frame.width > expectedSource.width+10 && frame.width < folderPanel.frame.width-10,"panel is visibly expanding between its endpoints")
                    let icon = folderOpeningOverlay?.subviews.compactMap { $0 as? NSImageView }.first
                    let iconFrame = icon?.layer?.presentation()?.frame ?? .zero
                    try check(iconFrame.width > 5 && frame.intersects(iconFrame) && icon?.isHidden == false,
                              "expanding icon stays visible in root coordinates outside the final folder viewport")
                    try capture("folder-expanding")
                })
            }
            steps.append(.init(delay:Motion.folderOpenDuration+0.1) { [self] in
                try check(!folderOpening && folderOpeningLayers.isEmpty && folderOpeningOverlay == nil && folderTiles.allSatisfy { $0.alphaValue == 1 } && folderViewport.layer?.masksToBounds == true,"opening leaves no animation layers or unclipped viewport")
                let titlePoint = NSPoint(x:folderTitle.frame.midX,y:folderTitle.frame.midY)
                try check(hitTest(convert(titlePoint,to:superview)) === folderTitle,"title outside the panel still receives editing clicks")
                let panel = folderPanel.frame
                geometry.append(String(format:"%d,%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f",count,folderRows,folderDots.count,
                    panel.minX,panel.minY,panel.width,panel.height,folderTitle.frame.maxY,folderTiles.first?.iconSize ?? 0))
                if [1,columns*2+1,columns*4+1,folderCapacity+1].contains(count) { try capture("folder-\(count)-apps") }
                if count > folderCapacity { changePage(1,insideFolder:true) }
            })
            if count > folderCapacity {
                steps.append(.init(delay:Motion.pageDuration+0.1) { [self] in
                    try check(folderPage == 1 && folderRows == 5 && folderTiles.map { $0.content.id } == [appIDs[count-1]],"overflow page keeps five-row geometry and the final app")
                    try check(gridViewport.isHidden && !pageTransition,"folder paging never reveals the root apps")
                })
            }
            steps.append(.init { [self] in
                if caseIndex%2 == 0 { cancel() }
                else {
                    let point = convert(NSPoint(x:10,y:bounds.midY),to:nil)
                    for type: NSEvent.EventType in [.leftMouseDown,.leftMouseUp] {
                        window.sendEvent(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],
                            timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,
                            context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!)
                    }
                }
                if !Motion.reduced {
                    let animations = (folderPanel.layer?.animation(forKey:"folderOpen") as? CAAnimationGroup)?.animations?.compactMap { $0 as? CABasicAnimation } ?? []
                    let size = (animations.first { $0.keyPath == "bounds" }?.toValue as? NSValue)?.rectValue.size
                    try check(folderClosing && size == expectedSource.size,"Escape or background click shrinks the panel back to the original icon size")
                    try check(!gridViewport.isHidden && tiles.first { $0.content.id == folderID }?.alphaValue == 0,"root returns with no duplicate destination folder")
                } else { try check(interaction.folderID == nil && !folderOpening,"reduced motion closes immediately") }
            })
            if caseIndex == 0 && !Motion.reduced {
                steps.append(.init(delay:0.12) { [self] in
                    let frame = folderPanel.layer?.presentation()?.frame ?? .zero
                    try check(frame.width > expectedSource.width+10 && frame.width < folderPanel.frame.width-10,"closing visibly shrinks between its endpoints")
                    try capture("folder-contracting")
                })
            }
            steps.append(.init(delay:Motion.folderOpenDuration+0.1) { [self] in
                try check(interaction.folderID == nil && !folderOpening && !folderClosing && folderOpeningOverlay == nil && folderOpeningLayers.isEmpty,
                          "close completion removes temporary views and folder state")
                try check(folderPanel.isHidden && !gridViewport.isHidden && !searchBox.isHidden && tiles.allSatisfy { $0.alphaValue == 1 },"closing restores root icons and hit targets")
            })
        }
        steps.append(.init { [self] in
            closeFolder(animated:false); openFolder(folderID); closeFolder()
        })
        steps.append(.init(delay:Motion.folderOpenDuration+0.1) { [self] in
            try check(interaction.folderID == nil && !gridViewport.isHidden && folderPanel.isHidden && !folderOpening,"closing during expansion cannot reopen the folder from a stale callback")
            openFolder(folderID)
            setFrameSize(NSSize(width:originalSize.width-1,height:originalSize.height)); refresh()
            try check(interaction.folderID == folderID && !folderOpening && gridViewport.isHidden && folderViewport.layer?.masksToBounds == true,"resize cancels expansion and retains the folder")
            setFrameSize(originalSize); closeFolder(); openFolder(folderID); finishFolderOpening()
            try check(interaction.folderID == folderID && !folderClosing && gridViewport.isHidden,"reopening during contraction cancels its pending close")
            closeFolder(); setFrameSize(NSSize(width:originalSize.width-1,height:originalSize.height))
            try check(interaction.folderID == nil && !folderOpening && folderOpeningOverlay == nil,"resize during contraction completes cleanup")
            setFrameSize(originalSize); closeFolder(animated:false)
            controller.mutate("Restore folder presentation fixture") { $0 = original }
            try check(state == original && (try controller.store.load()) == original,"folder checks restore all saved apps and folders")
        })
        InteractionCheckSequence(steps) { result in
            do { try geometry.joined(separator:"\n").appending("\n").write(to:outputDirectory.appendingPathComponent("folder-geometry.csv"),atomically:true,encoding:.utf8) }
            catch { completion(.failure(error)); return }
            if case .success = result { print("PASS: \(checks) folder presentation checks") }
            completion(result)
        }.run()
    }
    private func runPageMotionChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        var checks = 0
        let originalState = state, originalSize = frame.size
        var releaseOffset: CGFloat = 0
        var samples = ["transition,seconds,progress,page_separation,stride"]
        var sampleTimer: Timer?
        var separations: [CGFloat] = []
        var trackedFolder = ""
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LayoutError.invalid("Page motion check failed: \(description)") }
            checks += 1
        }
        func record(_ name: String) {
            sampleTimer?.invalidate()
            guard !Motion.reduced, let layer = grid.layer,
                  let animation = layer.animation(forKey:"page") as? CABasicAnimation,
                  let from = animation.fromValue as? NSNumber, let to = animation.toValue as? NSNumber,
                  let other = outgoingPage ?? neighboringPages.first?.view else { return }
            let start = CACurrentMediaTime()
            let distance = to.doubleValue-from.doubleValue, stride = bounds.width
            sampleTimer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { _ in
                let elapsed = CACurrentMediaTime()-start
                guard elapsed <= Motion.pageDuration, let current = layer.presentation(), let neighbor = other.layer?.presentation() else { return }
                let progress = (Double(current.transform.m41)-from.doubleValue)/distance
                let separation = abs(neighbor.frame.minX-current.frame.minX)
                separations.append(abs(separation-stride))
                samples.append(String(format:"%@,%.4f,%.5f,%.2f,%.2f",name,elapsed,progress,separation,stride))
            }
            if let timer = sampleTimer { RunLoop.main.add(timer,forMode:.common) }
        }
        let wait = Motion.pageDuration+0.1
        let steps: [InteractionCheckStep] = [
            .init { [self] in
                cancelItemDrag(); cancelBackgroundPaging(); cancelPageTransition()
                interaction = InteractionState(); search.stringValue = ""; currentPage = 0; refresh()
                let event = scrollCheckEvent(dx:-3,precise:false)
                try check(!event.hasPreciseScrollingDeltas,"line-wheel fixture uses discrete deltas")
                lastPageTurn = 0; scrollWheel(with:event)
                try check(currentPage == 1,"wheel advances to the next page")
                if !Motion.reduced {
                    scrollWheel(with:event)
                    try check(pageTransition && queuedPage == nil,"repeated wheel events do not queue an extra page during motion")
                    record("wheel")
                }
            },
            .init(delay:0.25) { [self] in
                if !Motion.reduced {
                    let x = grid.layer?.presentation()?.transform.m41 ?? 0
                    try check(pageTransition && x > 1 && x < bounds.width*0.5,"wheel animation retains its visible deceleration tail")
                }
            },
            .init(delay:0.35) { [self] in
                try check(currentPage == 1 && !pageTransition && outgoingPage == nil,"wheel settles without leftover pages")
                let event = scrollCheckEvent(dx:80,phase:.began)
                try check(event.hasPreciseScrollingDeltas && event.phase.contains(.began),"pixel fixture retains its AppKit gesture phase")
                scrollWheel(with:event)
                try check(backgroundGesture?.fromScroll == true && currentPage == 1 && !pageTransition,
                          "precise scrolling follows input without jumping at the old 32pt threshold")
            },
            .init(delay:0.18) { [self] in
                scrollWheel(with:scrollCheckEvent(dx:Int32(bounds.width*0.3)-80,phase:.changed))
                releaseOffset = grid.layer?.transform.m41 ?? 0
                try check(abs(releaseOffset-bounds.width*0.3) < 2 && currentPage == 1,
                          "successive deltas move the page continuously until fingers lift")
                scrollWheel(with:scrollCheckEvent(dx:0,phase:.ended))
                if !Motion.reduced { try check(settlingPage,"finger release starts deceleration"); record("scroll-release") }
            },
            .init(delay:0.25) { [self] in
                if !Motion.reduced {
                    let x = grid.layer?.presentation()?.transform.m41 ?? 0
                    try check(settlingPage && x > releaseOffset && x < bounds.width-1,
                              "release is still moving after the former 0.22s cutoff")
                }
            },
            .init(delay:0.35) { [self] in
                try check(currentPage == 0 && !settlingPage && neighboringPages.isEmpty && grid.layer?.transform.m41 == 0,
                          "continuous scroll settles once with clean geometry")
                scrollWheel(with:scrollCheckEvent(dx:-800,momentum:true))
                try check(currentPage == 0 && backgroundGesture == nil,"OS momentum cannot trigger a second page")
                scrollWheel(with:scrollCheckEvent(dx:-Int32(bounds.width*0.3),phase:.began))
                scrollWheel(with:scrollCheckEvent(dx:0,phase:.cancelled))
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 0 && !settlingPage,"cancelled trackpad gesture returns to its original page")
                scrollWheel(with:scrollCheckEvent(dx:-Int32(bounds.width*0.3)))
                try check(backgroundGesture?.fromScroll == true && scrollIdleTimer != nil,"phase-less precise input waits for idle")
            },
            .init(delay:Motion.scrollIdleDelay+0.04) { [self] in
                try check(Motion.reduced ? currentPage == 1 : settlingPage,"phase-less input settles after the original idle interval")
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 1 && backgroundGesture == nil && scrollIdleTimer == nil,"phase-less scroll finishes without a live timer")
                scrollWheel(with:scrollCheckEvent(dx:100,phase:.began))
                setFrameSize(NSSize(width:originalSize.width-1,height:originalSize.height)); refresh()
                scrollWheel(with:scrollCheckEvent(dx:0,phase:.ended))
                try check(currentPage == 1 && backgroundGesture == nil && !settlingPage && neighboringPages.isEmpty,
                          "resizing cancels the old scroll coordinates without a late page change")
                setFrameSize(originalSize); refresh()
                if let folder = state.folders.first {
                    trackedFolder = folder.id; openFolder(folder.id)
                    scrollWheel(with:scrollCheckEvent(dx:60,phase:.began))
                    try check(backgroundGesture?.insideFolder == true && (folderGrid.layer?.transform.m41 ?? 0) > 0
                        && grid.layer?.transform.m41 == 0,"folder scrolling moves its own page with edge resistance")
                    scrollWheel(with:scrollCheckEvent(dx:0,phase:.cancelled))
                }
            },
            .init(delay:wait) { [self] in
                if !trackedFolder.isEmpty {
                    try check(interaction.folderID == trackedFolder && folderPage == 0 && !settlingPage,"folder edge return retains the open folder")
                    closeFolder(animated:false)
                }
                if !Motion.reduced {
                    try check(separations.count >= 8 && separations.allSatisfy { $0 < 2 },"both moving pages keep the same separation on every sampled frame")
                }
                try check(state == originalState && (try controller!.store.load()) == originalState,"paging preserves saved apps and folders")
            }
        ]
        InteractionCheckSequence(steps) { result in
            sampleTimer?.invalidate()
            do { try samples.joined(separator:"\n").appending("\n").write(to:outputDirectory.appendingPathComponent("page-motion.csv"),atomically:true,encoding:.utf8) }
            catch { completion(.failure(error)); return }
            if case .success = result { print("PASS: \(checks) page timing and scroll checks") }
            completion(result)
        }.run()
    }
    private func runItemDragChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let controller = controller, let window = window else { return }
        var checks = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LayoutError.invalid("Drag UI check failed: \(description)") }
            checks += 1
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: type, location: convert(point,to:nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
        }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
            let character = code == 36 ? "\r" : (code == 53 ? "\u{1b}" : "")
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!)
        }
        func center(_ tile: AppTile) -> NSPoint { tile.convert(NSPoint(x:tile.iconFrame.midX,y:tile.iconFrame.midY),to:self) }
        func start(_ tile: AppTile) {
            let point = center(tile)
            mouse(.leftMouseDown,point)
            mouse(.leftMouseDragged,NSPoint(x:point.x+10,y:point.y))
        }
        func capture(_ name: String) throws {
            window.displayIfNeeded(); CATransaction.flush()
            guard let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]) else {
                throw LayoutError.invalid("Cannot capture own window")
            }
            try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent(name+".png"))
        }
        var original = LayoutState()
        var expected: [String] = []
        var source: AppTile!
        var sourceID = "", targetID = "", newFolderID = "", thirdID = ""
        var drop = NSPoint.zero
        var folderOrder: [String] = []
        var beforeFullFolder = LayoutState()
        var fullFolderID = ""
        let steps: [InteractionCheckStep] = [
            .init { [self] in
                cancelItemDrag(); cancelPageTransition(); cancelBackgroundPaging()
                interaction = InteractionState(); search.stringValue = ""; selectedID = nil; currentPage = 0; refresh()
                // Inspect a presented forward slide before reversing it.
                // Opposite keys in one runloop now correctly coalesce to no motion.
                key(124,flags:.command)
            },
            .init(delay: 0.1) { [self] in
                if !Motion.reduced {
                    try check(pageTransition && outgoingPage?.superview === gridViewport && gridViewport.frame.minX == 0 && gridViewport.frame.width == bounds.width, "page clipping occurs at screen edges, not at grid margins")
                    let x = grid.layer?.presentation()?.frame.minX ?? 0
                    try check(x > grid.frame.minX && x < grid.frame.minX+pageStride(insideFolder: false), "whole page moves continuously between endpoints (x=\(x))")
                    let outgoingX = outgoingPage?.layer?.presentation()?.frame.minX ?? 0
                    try check(outgoingX < grid.frame.minX-10, "outgoing page moves into the former fixed margin (x=\(outgoingX))")
                    try check(abs((x-outgoingX)-bounds.width) < 2, "pages travel a full screen width including both margins")
                    let gap = x-(outgoingX+grid.bounds.width)
                    try check(abs(gap-(gridViewport.bounds.width-grid.bounds.width)) < 2, "moving pages preserve both content margins")
                    try check(gridViewport.subviews.count == 2, "one outgoing page only during rapid direction changes")
                }
                try capture("page-transition")
                key(123,flags:.command)
            },
            .init(delay: Motion.pageDuration*2+0.2) { [self] in
                try check(currentPage == 0 && !pageTransition && outgoingPage == nil, "queued reverse turn settles without stale page")
                try check(gridViewport.subviews.count == 1 && grid.frame == pageContentFrame(insideFolder:false), "no previous-page views remain and the page retains its margins")
                let apps = tiles.filter { !$0.content.isFolder }
                try check(apps.count >= 6, "enough real apps for drag scenarios")
                original = state; source = apps[0]; sourceID = source.content.id
                let target = apps[3]
                expected = state.pages[0].filter { $0 != sourceID }
                expected.insert(sourceID,at:expected.firstIndex(of:target.content.id)!+1)
                drop = target.convert(NSPoint(x:target.bounds.width-15,y:target.iconFrame.midY),to:self)
                start(source)
                try check(dragID == sourceID && source.isHidden, "real mouse drag lifts source leaving an empty slot")
                try check(!interaction.editing && tiles.allSatisfy { !$0.editing }, "starting a drag does not enter edit mode")
                try check(draggedTile?.content.title == source.content.title && draggedTile?.content.image === source.content.image, "drag retains original icon and title together")
                try check(draggedTile?.hasRenderedTitle == true && draggedTile?.content.title == source.content.title, "drag contains a rendered title")
                mouse(.leftMouseDragged,drop)
                try check(state == original, "drag preview does not save intermediate moves")
            },
            .init(delay: Motion.holdDelay+0.1) { [self] in
                try check(dragID == sourceID && !interaction.editing && tiles.allSatisfy { !$0.editing },
                    "holding a stationary drag past the long-press deadline does not enable editing")
                try capture("icon-drag")
                let frame = draggedTile!.frame
                try check(abs(frame.minX+dragOffset.x-drop.x) < 1 && abs(frame.minY+dragOffset.y-drop.y) < 1, "icon and label follow the original pointer anchor")
                mouse(.leftMouseUp,drop)
                try check(state.pages[0] == expected && dragID == nil, "mouse-up commits same-page reordering")
                try check(!interaction.editing, "dropping from normal mode stays in normal mode")
                try check(try controller.store.load() == state, "reordered layout persists")
                controller.undoLayout(); try check(state == original, "drag reorder has a single undo step")
                controller.redoLayout(); try check(state.pages[0] == expected, "drag reorder can be redone")
                original = state
                source = tiles.first { !$0.content.isFolder }!
                start(source); mouse(.leftMouseDragged,NSPoint(x:drop.x-30,y:drop.y))
                key(53)
                try check(dragID == nil && state == original && (Motion.reduced ? !source.isHidden : returningTile != nil), "Escape cancels drag and returns source without saving")
                mouse(.leftMouseUp,drop)
                try check(controller.isShown, "cancelled drag release does not launch or dismiss")
                finishItemReturn()
                let apps = tiles.filter { !$0.content.isFolder }
                source = apps[0]; sourceID = source.content.id; targetID = apps[1].content.id
                drop = center(apps[1]); start(source); mouse(.leftMouseDragged,drop)
            },
            .init(delay: 0.72) { [self] in
                try check(hoverArmed && hoverID == targetID && tiles.first { $0.content.id == targetID }?.dropHighlight == true, "stationary overlap arms folder creation")
                try check(!interaction.editing, "folder hover dwell does not trigger long-press edit mode")
                try capture("folder-hover")
                mouse(.leftMouseUp,drop)
                newFolderID = state.location(of:sourceID)?.folderID ?? ""
                try check(!newFolderID.isEmpty && state.location(of:targetID)?.folderID == newFolderID, "mouse drop creates a folder containing both apps")
                if !Motion.reduced {
                    try check(folderDrop?.flights.count == 2 && dropHiddenMinis[newFolderID]?.count == 2,
                        "both original icons remain in flight while the folder miniatures are hidden")
                }
            },
            .init(delay: 0.08) { [self] in
                if !Motion.reduced {
                    guard let flight = folderDrop?.flights.first, let frame = flight.image.layer?.presentation()?.frame else {
                        throw LayoutError.invalid("Missing folder formation animation")
                    }
                    try check(frame.width < flight.from.width-1 && frame.width > flight.to.width+1,
                        "folder creation visibly shrinks the dragged icon between endpoints")
                    try check(flight.image.bounds.width == flight.from.width, "shrinking preserves the source image backing resolution")
                    try check(tiles.contains { $0.layer?.animation(forKey:"folderReflow") != nil }, "remaining icons animate into the space released by folder creation")
                    try capture("folder-forming")
                }
            },
            .init(delay: 0.3) { [self] in
                try check(folderDrop == nil && dropHiddenMinis.isEmpty && interaction.folderID == newFolderID && interaction.renaming,
                    "created folder opens with editable title after both icons land")
                guard let editor = folderTitle.currentEditor() as? NSTextView else { throw LayoutError.invalid("Folder title editor missing") }
                editor.insertText("작업 도구",replacementRange:editor.selectedRange())
                key(36)
                try check(state.folder(newFolderID)?.title == "작업 도구" && !interaction.renaming,
                    "typing and Return rename the folder (stored=\(state.folder(newFolderID)?.title ?? "nil"), editor=\(folderTitle.currentEditor()?.string ?? "nil"), responder=\(String(describing:window.firstResponder)))")
                try check(try controller.store.load().folder(newFolderID)?.title == "작업 도구", "folder name persists")
                try capture("folder-created")
                closeFolder(animated:false)
                source = tiles.first { !$0.content.isFolder }!; thirdID = source.content.id
                drop = center(tiles.first { $0.content.id == newFolderID }!)
                start(source); mouse(.leftMouseDragged,drop)
            },
            .init(delay: 0.04) { [self] in
                mouse(.leftMouseUp,drop)
                try check(state.location(of:thirdID)?.folderID == newFolderID && interaction.folderID == nil,
                    "quick drop adds to a closed folder before the hover-open delay")
                try check(state.folder(newFolderID)?.pages.flatMap { $0 }.last == thirdID,"quick drop appends after existing children")
                if !Motion.reduced { try check(folderDrop?.flights.count == 1, "closed-folder drop keeps the live icon visible in flight") }
            },
            .init(delay: 0.08) { [self] in
                if !Motion.reduced {
                    guard let flight = folderDrop?.flights.first, let frame = flight.image.layer?.presentation()?.frame else {
                        throw LayoutError.invalid("Missing closed-folder drop animation")
                    }
                    try check(frame.width < flight.from.width-1 && frame.width > flight.to.width+1,
                        "quick drop shrinks toward the exact miniature slot")
                    try capture("folder-quick-drop")
                }
                controller.undoLayout()
                try check(folderDrop == nil && dropHiddenMinis.isEmpty && state.location(of:thirdID)?.folderID == nil,
                    "undo during drop cancels presentation and restores the app once")
            },
            .init(delay: 0.3) { [self] in
                try check(interaction.folderID == nil && folderDrop == nil, "cancelled drop completion cannot reopen or hide a folder later")
                source = tiles.first { $0.content.id == thirdID }!
                drop = center(tiles.first { $0.content.id == newFolderID }!)
                start(source); mouse(.leftMouseDragged,drop)
            },
            .init(delay: Motion.folderHoverDelay+0.1) { [self] in
                try check(interaction.folderID == newFolderID && dragID == thirdID, "holding over an existing folder opens it during drag")
                try check(!interaction.editing, "hover-opening a folder retains normal mode")
                mouse(.leftMouseUp,drop)
                try check(state.location(of:thirdID)?.folderID == newFolderID && folderTiles.count == 3, "drop adds a third app to the open folder")
                try check(state.folder(newFolderID)?.pages.flatMap { $0 }.last == thirdID,"spring-loaded drop appends after existing children")
                folderOrder = state.folder(newFolderID)!.pages[0]
                if !Motion.reduced { try check(dropHiddenIDs.contains(thirdID), "open-folder destination is hidden until the moving icon arrives") }
            },
            .init(delay: 0.08) { [self] in
                if !Motion.reduced {
                    guard let flight = folderDrop?.flights.first, let frame = flight.image.layer?.presentation()?.frame else {
                        throw LayoutError.invalid("Missing open-folder drop animation")
                    }
                    try check(hypot(frame.midX-flight.from.midX,frame.midY-flight.from.midY) > 2
                        && hypot(frame.midX-flight.to.midX,frame.midY-flight.to.midY) > 2,
                        "drop into an open folder visibly travels toward its grid slot")
                    try capture("folder-open-drop")
                }
            },
            .init(delay: 0.3) { [self] in
                try check(folderDrop == nil && dropHiddenIDs.isEmpty && folderTiles.allSatisfy { !$0.isHidden },
                    "landing reveals the destination without duplicate or hidden icons")
                source = folderTiles[0]; sourceID = source.content.id
                let target = folderTiles[2]
                drop = target.convert(NSPoint(x:target.bounds.width-15,y:target.iconFrame.midY),to:self)
                start(source); mouse(.leftMouseDragged,drop)
            },
            .init(delay: 0.22) { [self] in
                mouse(.leftMouseUp,drop)
                try check(state.folder(newFolderID)?.pages[0] == Array(folderOrder.dropFirst())+[sourceID], "mouse drag reorders folder contents")
            },
            .init(delay:Motion.returnDuration+0.1) { [self] in
                try check(returningTile == nil, "reordered icon lands before editing the folder title")
                // A title click must also work after the initial creation flow.
                interaction.editing = false; refresh()
                let titlePoint = NSPoint(x:folderTitle.frame.midX,y:folderTitle.frame.midY)
                // NSTextField tracks the press in a nested AppKit event loop.
                let release = NSEvent.mouseEvent(with:.leftMouseUp,location:convert(titlePoint,to:nil),modifierFlags:[],
                    timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0)!
                NSApp.postEvent(release,atStart:true); mouse(.leftMouseDown,titlePoint)
            },
            .init(delay:0.06) { [self] in
                guard let editor = folderTitle.currentEditor() as? NSTextView else { throw LayoutError.invalid("Folder title editor missing after click") }
                try check(window.firstResponder === editor, "title click focuses its field editor")
                editor.selectAll(nil); editor.insertText("자주 쓰는 앱",replacementRange:editor.selectedRange()); key(36)
                try check(state.folder(newFolderID)?.title == "자주 쓰는 앱", "clicking existing folder title supports renaming")
                source = folderTiles[0]; sourceID = source.content.id; start(source)
                drop = NSPoint(x:gridViewport.frame.minX+grid.bounds.width/CGFloat(columns)*0.4,y:70)
                mouse(.leftMouseDragged,drop)
                try check(dragID == sourceID && (Motion.reduced ? interaction.folderID == nil : folderClosing), "drag outside folder keeps pointer capture while the folder shrinks")
            },
            .init(delay:Motion.folderOpenDuration+0.08) { [self] in
                try check(interaction.folderID == nil && dragID == sourceID,"folder close completion retains the extracted floating tile")
                let target = tiles[0]
                drop = target.convert(NSPoint(x:15,y:target.iconFrame.midY),to:self)
                mouse(.leftMouseDragged,drop)
            },
            .init(delay:Motion.insertionDelay+0.08) { [self] in
                mouse(.leftMouseUp,drop)
                try check(state.location(of:sourceID)?.folderID == nil && state.folder(newFolderID)?.pages.flatMap { $0 }.count == 2, "drop extracts app from folder to root")
                try check(try controller.store.load() == state, "folder and extraction changes survive reload")
                try state.validate()
                try capture("drag-result")
                finishItemReturn()
                original = state
                source = tiles.first { !$0.content.isFolder }!; sourceID = source.content.id
                start(source)
                drop = grid.convert(NSPoint(x:grid.bounds.maxX+15,y:grid.bounds.midY),to:self)
                mouse(.leftMouseDragged,drop)
            },
            .init(delay: 1.0) { [self] in
                try check(currentPage == 1 && dragID == sourceID, "edge dwell changes page while retaining the dragged item")
                let target = tiles[0]
                drop = target.convert(NSPoint(x:15,y:target.iconFrame.midY),to:self)
                mouse(.leftMouseDragged,drop)
            },
            .init(delay:Motion.pageDuration+Motion.insertionDelay+0.12) { [self] in
                try check(pendingDrop == ItemLocation(page:1,index:0), "cross-page insertion settles after pointer stops during transition (page=\(currentPage), transition=\(pageTransition), candidate=\(String(describing:insertionCandidate)), pending=\(String(describing:pendingDrop)), hover=\(String(describing:hoverID)))")
                mouse(.leftMouseUp,drop)
                try check(state.location(of:sourceID)?.page == 1 && state.pages[1].first == sourceID, "drop moves an app to another page")
                controller.undoLayout(); try check(state == original, "cross-page move undoes atomically")
                changePage(state.pages.count-1)
            },
            .init(delay: Motion.pageDuration+0.08) { [self] in
                original = state
                source = tiles.first { !$0.content.isFolder }!; sourceID = source.content.id
                start(source)
                drop = grid.convert(NSPoint(x:grid.bounds.maxX+15,y:grid.bounds.midY),to:self)
                mouse(.leftMouseDragged,drop)
            },
            .init(delay: 1.3) { [self] in
                try check(currentPage == state.pages.count && tiles.isEmpty && dragID == sourceID, "last-page edge opens a stable empty drop page")
                key(53); mouse(.leftMouseUp,drop)
                try check(state == original && transientPage == nil && currentPage == state.pages.count-1, "cancelling empty-page drag restores layout without saving an empty page")
                beginEditing()
                source = tiles.first { !$0.content.isFolder }!
                start(source); key(53); mouse(.leftMouseUp,center(source))
                try check(interaction.editing && dragID == nil, "dragging preserves edit mode when the user had explicitly enabled it")
                interaction.editing = false; refresh()
                beforeFullFolder = state
                let ids = Array(state.pages.flatMap { $0 }.filter { state.app($0) != nil }.prefix(folderCapacity+1))
                try check(ids.count == folderCapacity+1, "enough apps to exercise a full folder")
                sourceID = ids.last!
                controller.mutate("Full folder fixture") { layout in
                    fullFolderID = try layout.makeFolder(with:ids[0],over:ids[1],capacity:self.capacity)
                    for id in ids.dropFirst(2).dropLast() {
                        try layout.move(id,to:ItemLocation(folderID:fullFolderID,page:0,index:self.folderCapacity),
                            capacity:self.capacity,folderCapacity:self.folderCapacity)
                    }
                    // At 35+1 items the source can start on root page two.
                    // Put both targets on the same root page for this drop test.
                    try layout.move(sourceID,to:ItemLocation(page:0,index:1),capacity:self.capacity,folderCapacity:self.folderCapacity)
                }
                currentPage = 0; refresh()
                guard let moving = tiles.first(where:{ $0.content.id == sourceID }),
                      let folder = tiles.first(where:{ $0.content.id == fullFolderID }) else {
                    throw LayoutError.invalid("Full-folder drag fixture is not visible")
                }
                source = moving; drop = center(folder); drop.x += source.iconSize*0.25
                start(source); mouse(.leftMouseDragged,drop)
            },
            .init(delay:0.1) { [self] in
                if !Motion.reduced {
                    let folder = tiles.first { $0.content.id == fullFolderID }!
                    let body = folder.subviews.compactMap { $0 as? FlippedView }.first!
                    let miniGrid = body.subviews.first?.subviews.first
                    let position = miniGrid?.layer?.presentation()?.frame.minY ?? 0
                    try check(position < -1 && position > (miniGrid?.frame.minY ?? 0)+1,
                              "miniature content visibly scrolls between the first and final rows")
                    try capture("folder-preview-scrolling")
                }
            },
            .init(delay:0.25) { [self] in
                guard let folder = tiles.first(where:{ $0.content.id == fullFolderID }) else { throw LayoutError.invalid("Missing hovered folder") }
                try check(interaction.folderID == nil && folder.folderDropPreview && folder.previewFirstRow == max(0,folderCapacity/3-2),
                          "hover enlarges the closed folder and scrolls its miniature grid to the insertion row")
                let body = folder.subviews.compactMap { $0 as? FlippedView }.first!
                let presentation = body.layer?.presentation()
                try check(!folder.isHidden && folder.alphaValue == 1 && body.frame.width > 0 && (presentation?.frame.width ?? 0) > body.frame.width*1.05,
                          "hover enlargement is present in the rendered layer")
                let diagnostic = "tile=\(folder.frame) body=\(body.frame) rendered=\(String(describing:presentation?.frame)) transform=\(String(describing:presentation?.transform.m11)) floating=\(String(describing:draggedTile?.frame)) root=\(grid.frame)\n"
                try diagnostic.write(to:outputDirectory.appendingPathComponent("folder-hover-geometry.txt"),atomically:true,encoding:.utf8)
                try capture("folder-preview-tail")
                mouse(.leftMouseUp,drop)
                try check(state.folder(fullFolderID)?.pages.flatMap { $0 }.last == sourceID && state.location(of:sourceID)?.page == 1,
                          "quick drop into a full closed folder appends on the next page")
                if !Motion.reduced {
                    try check(folderDrop?.flights.count == 1 && dropHiddenMinis[fullFolderID]?.contains(folderCapacity) == true,
                              "tail miniatures remain scrolled with the incoming slot hidden during landing")
                }
            },
            .init(delay:Motion.folderDropDuration+0.1) { [self] in
                try check(folderDrop == nil && dropPreviewFolderID == nil && tiles.first { $0.content.id == fullFolderID }?.folderDropPreview == false,
                          "landing restores the normal folder preview")
                controller.undoLayout()
                source = tiles.first { $0.content.id == sourceID }!
                drop = center(tiles.first { $0.content.id == fullFolderID }!)
                start(source); mouse(.leftMouseDragged,drop)
            },
            .init(delay:0.15) { [self] in
                key(53)
                try check(dragID == nil && tiles.first { $0.content.id == fullFolderID }?.folderDropPreview == false,
                          "Escape cancels the hover preview and its drag")
            },
            .init(delay:Motion.folderHoverDelay+0.1) { [self] in
                try check(interaction.folderID == nil && tiles.first { $0.content.id == fullFolderID }?.previewFirstRow == 0,
                          "cancelled hover returns to the top and cannot open later")
                source = tiles.first { $0.content.id == sourceID }!
                drop = center(tiles.first { $0.content.id == fullFolderID }!)
                start(source); mouse(.leftMouseDragged,drop)
            },
            .init(delay:Motion.folderHoverDelay+0.1) { [self] in
                try check(folderTiles.count == folderCapacity && interaction.folderID == fullFolderID, "hover opens a full folder")
                mouse(.leftMouseUp,drop)
                try check(state.location(of:sourceID)?.page == 1 && folderPage == 1,
                    "dropping into a full folder navigates to the inserted app's new page")
            },
            .init(delay:0.08) { [self] in
                if !Motion.reduced {
                    try check(pageTransition && folderDrop?.flights.count == 1 && dropHiddenIDs.contains(sourceID),
                        "full-folder page and icon animate together without duplicating the destination")
                    try capture("folder-full-drop")
                }
            },
            .init(delay:Motion.pageDuration+0.08) { [self] in
                try check(folderDrop == nil && !pageTransition && folderTiles.count == 1 && folderTiles[0].content.id == sourceID && !folderTiles[0].isHidden,
                    "full-folder landing leaves the new page visible and interactive")
                try check(try controller.store.load() == state, "full-folder overflow saves one consistent layout")
                closeFolder(animated:false); controller.undoLayout(); controller.undoLayout()
                try check(state == beforeFullFolder, "full-folder drop and its fixture undo without losing app order")
                print("PASS: \(checks) page and item-drag checks")
            }
        ]
        InteractionCheckSequence(steps,completion:completion).run()
    }

    /// Only root grid alignment and the repositioned page controls.
    func runPageAlignmentChecks(outputDirectory: URL) throws {
        guard let controller = controller, let window = window else { throw LayoutError.invalid("UI controller missing") }
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        let originalSize = frame.size, originalPage = currentPage, originalState = state
        let url = controller.store.directory.appendingPathComponent("layout.json")
        let saved = try Data(contentsOf:url)
        var count = 0, report: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LayoutError.invalid("Page alignment check failed: \(name)") }; count += 1
        }
        defer { currentPage = originalPage; setFrameSize(originalSize); refresh() }
        let reference = LaunchpadPageMetrics(size:NSSize(width:1920,height:1080),rows:5,columns:7,
            dockExtent:73,sideDockExtent:0,safeTop:0,searchBottom:50)
        try check(reference.grid == NSRect(x:0,y:65,width:1920,height:875) && reference.dotsCenterY == 959.5,
                  "observed original reference grid and page control")
        try check(LaunchpadPageMetrics.iconTop(cellHeight:175,iconSize:128) == 4,
                  "original first icon top 69 pt and row step 175 pt")
        let notch = LaunchpadPageMetrics(size:NSSize(width:1920,height:1080),rows:5,columns:7,
            dockExtent:73,sideDockExtent:0,safeTop:38,searchBottom:63)
        try check(notch.grid.minY >= 103 && notch.grid.maxY < notch.dotsCenterY-14,
                  "notch reserve clears the header and controls")
        for size in [NSSize(width:1024,height:768),NSSize(width:1280,height:800),NSSize(width:1440,height:900),
                     NSSize(width:1920,height:1080),NSSize(width:2560,height:1440),NSSize(width:3840,height:2160),
                     NSSize(width:2160,height:3840),originalSize] {
            currentPage = 0; setFrameSize(size); refresh(); layoutSubtreeIfNeeded()
            guard let first = tiles.first else { throw LayoutError.invalid("No app for alignment check") }
            let icon = first.convert(first.iconFrame,to:self), rowHeight = grid.bounds.height/CGFloat(rows)
            try check(rowHeight.rounded(.down) == rowHeight,"integer row spacing at \(size)")
            try check(icon.minY >= searchBox.frame.maxY+8 && gridViewport.frame.maxY < pageDots.frame.minY,
                      "header, rows and page dots remain separate at \(size)")
            try check(abs(grid.frame.midX-gridViewport.bounds.midX) < 0.5,"horizontal centering at \(size)")
            if size.width == 1920 && size.height == 1080 && rows == 5 && columns == 7 {
                try check(first.iconSize == 128,"accepted icon size retained at 1920x1080")
            }
            for tile in tiles {
                try check(tile.bounds.contains(tile.iconFrame.union(tile.labelFrame)) && tile.bounds.contains(tile.interactionFrame),
                          "image, title and click area fit at \(size)")
            }
            if tiles.count > columns {
                let next = tiles[columns].convert(tiles[columns].interactionFrame,to:self)
                try check(next.minY-first.convert(first.interactionFrame,to:self).maxY >= 8,"separate row click areas")
            }
            let copy = AppTile(content:first.content), page = FlippedView(frame:grid.bounds)
            page.addSubview(copy); layoutTiles([copy],in:page,rowCount:rows); page.layoutSubtreeIfNeeded()
            try check(copy.iconFrame == first.iconFrame,"transition copy uses the same artwork position")
            let frame = first.frame
            if state.pages.count > 1 {
                currentPage = state.pages.count-1; refresh(); layoutSubtreeIfNeeded()
                try check(tiles.first?.frame == frame && tiles.first?.iconFrame == copy.iconFrame,
                          "sparse last page uses the same row origin and icon placement")
            }
            report.append("\(Int(size.width))x\(Int(size.height)): grid=\(gridViewport.frame); first icon=\(icon); row step=\(rowHeight); last row icon top=\(icon.minY+CGFloat(rows-1)*rowHeight); page dots center y=\(pageDots.frame.midY)")
        }
        currentPage = originalPage; setFrameSize(originalSize); refresh(); layoutSubtreeIfNeeded()
        let onSelect = pageDots.onSelect
        var clicked: Int?
        pageDots.onSelect = { clicked = $0 }
        defer { pageDots.onSelect = onSelect }
        for index in 0..<pageDots.count {
            clicked = nil
            let center = pageDots.center(of:index), location = pageDots.convert(center,to:nil)
            if index > 0 { try check(center.x-pageDots.center(of:index-1).x == 20,"original twenty-point dot spacing") }
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:0,
                    windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) else {
                    throw LayoutError.invalid("Cannot create page control event")
                }
                if type == .leftMouseDown { pageDots.mouseDown(with:event) } else { pageDots.mouseUp(with:event) }
            }
            try check(clicked == index,"repositioned page dot selects its own index")
        }
        try check(state == originalState && (try Data(contentsOf:url)) == saved,"alignment preserves stored app order and folders")
        report.append("Current display: \(originalSize), scale=\(window.backingScaleFactor); root rows=\(rows), columns=\(columns)")
        report.append("PASS: \(count) page alignment checks; other UI suites were not run")
        try report.joined(separator:"\n").appending("\n").write(to:outputDirectory.appendingPathComponent("alignment-checks.txt"),atomically:true,encoding:.utf8)
        print(report.last!)
    }

    /// Focused icon sizing checks. No page gestures, folder mutations or other UI suites.
    func runIconSizeChecks(outputDirectory: URL) throws {
        guard let controller = controller else { throw LayoutError.invalid("UI controller missing") }
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        let originalSize = frame.size, originalState = state
        let layoutURL = controller.store.directory.appendingPathComponent("layout.json")
        let saved = try Data(contentsOf:layoutURL)
        var count = 0, report: [String] = []
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LayoutError.invalid("Icon size check failed: \(description)") }
            count += 1
        }
        defer { setFrameSize(originalSize); refresh() }
        // 1920x1080 was also observed in the original app: a 240 px cache is
        // displayed in a 128 pt canvas (206 px App Store body at 2x).
        // Other fixtures evaluate the recovered formula with an 85 pt public
        // screen reservation; they are not claims of captures on those displays.
        let fixtures: [(CGFloat,CGFloat,CGFloat)] = [(1024,768,72),(1280,800,80),
            (1440,900,96),(1680,1050,128),(1920,1080,128),(2560,1440,128),
            (3840,2160,128),(2160,3840,128)]
        for (width,height,expected) in fixtures {
            let size = LaunchpadIconMetrics.preferredSize(screen:NSSize(width:width,height:height),
                reserved:NSSize(width:0,height:85),rows:5,columns:7)
            try check(size == expected,"reference formula at \(width)x\(height): \(size), expected \(expected)")
        }
        try check(LaunchpadIconMetrics.fittedSize(preferred:128,cell:NSSize(width:72,height:60)) == 24,
                  "dense grids shrink icons to fit the title")
        try check(LaunchpadIconMetrics.fittedSize(preferred:128,cell:NSSize(width:72,height:55)) == 20,
                  "original twenty-point lower bound")
        for size in fixtures.map({ NSSize(width:$0.0,height:$0.1) })+[originalSize] {
            setFrameSize(size); refresh(); layoutSubtreeIfNeeded()
            guard let first = tiles.first else { throw LayoutError.invalid("No app for icon size check") }
            let icon = first.convert(first.iconFrame,to:self)
            try check(first.iconSize <= preferredIconSize && first.iconSize >= 20,
                      "icon respects reference size and minimum at \(size)")
            try check(first.iconSize == 20 || Int(first.iconSize)%8 == 0,"eight-point steps at \(size)")
            for tile in tiles {
                try check(tile.iconSize == first.iconSize && tile.iconFrame.size == NSSize(width:first.iconSize,height:first.iconSize),
                          "all app and folder icon canvases agree at \(size)")
                try check(tile.bounds.contains(tile.iconFrame.union(tile.labelFrame)) && tile.bounds.contains(tile.interactionFrame),
                          "icon, label and click area fit at \(size)")
            }
            if tiles.count > 1 {
                let a = first.convert(first.interactionFrame,to:self), b = tiles[1].convert(tiles[1].interactionFrame,to:self)
                try check(b.minX-a.maxX >= 12,"horizontal click gutter at \(size)")
            }
            if tiles.count > columns {
                let next = tiles[columns].convert(tiles[columns].interactionFrame,to:self)
                try check(next.minY-first.convert(first.interactionFrame,to:self).maxY >= 8,"vertical click gutter at \(size)")
            }
            let midpoint = icon.midY+CGFloat(rows-1)*grid.bounds.height/CGFloat(rows)/2
            try check(icon.minY > searchBox.frame.maxY && midpoint < pageDots.frame.minY,
                      "icon rows lie between the header and page controls at \(size)")
            try check(gridViewport.frame.minY > searchBox.frame.maxY && gridViewport.frame.maxY < pageDots.frame.minY,
                      "icons clear the header and page controls at \(size)")
            // The same sizing path is used by outgoing/neighboring pages and
            // folder grids. Check those view sizes without exercising gestures.
            let copy = AppTile(content:first.content), page = FlippedView(frame:grid.bounds)
            page.addSubview(copy); layoutTiles([copy],in:page,rowCount:rows); page.layoutSubtreeIfNeeded()
            try check(copy.iconSize == first.iconSize,"transition copy keeps the displayed size")
            for folderRowCount in [1,3,5] {
                page.setFrameSize(NSSize(width:grid.bounds.width,height:grid.bounds.height/CGFloat(rows)*CGFloat(folderRowCount)))
                layoutTiles([copy],in:page,rowCount:folderRowCount,insideFolder:true); page.layoutSubtreeIfNeeded()
                try check(copy.iconSize == first.iconSize,"folder row count does not change icon size")
            }
            report.append("\(Int(size.width))x\(Int(size.height)): preferred=\(preferredIconSize) pt; displayed=\(first.iconSize) pt; icon=\(icon); cell=\(first.bounds.size); row midpoint=\(midpoint)")
        }
        setFrameSize(originalSize); refresh(); layoutSubtreeIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in:bounds) else { throw LayoutError.invalid("Icon size capture unavailable") }
        cacheDisplay(in:bounds,to:bitmap)
        guard let png = bitmap.representation(using:.png,properties:[:]) else { throw LayoutError.invalid("Icon size PNG unavailable") }
        try png.write(to:outputDirectory.appendingPathComponent("grid-current.png"))
        try check(state == originalState && (try Data(contentsOf:layoutURL)) == saved,"sizing preserves app order and folders on disk")
        report.append("Current display: \(originalSize); backing scale=\(window?.backingScaleFactor ?? 1); rows=\(rows); columns=\(columns)")
        report.append("PASS: \(count) icon sizing checks; other UI suites were not run")
        try report.joined(separator:"\n").appending("\n").write(to:outputDirectory.appendingPathComponent("icon-size-checks.txt"),atomically:true,encoding:.utf8)
        print(report.last!)
    }


    /// Regression coverage for labels, interrupted gestures, input routing and
    /// live tile reuse. Only called with an explicit isolated --data-dir.
    func runOptimizationChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let controller = controller else { return }
        let original = state
        var checks = 0
        var initialTiles: [AppTile] = []
        var fixture = LayoutState()
        var latencies: [Double] = []
        var inputLatencies: [Double] = []
        pageTimingSamples = []
        var beforePaging = Data()
        var folderID = ""
        var progressSamples: [CGFloat] = []
        var progressDetails: [String] = []
        var progressTimer: Timer?
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LayoutError.invalid("Optimization check failed: "+message) }
            checks += 1
        }
        func capture(_ name: String) throws {
            window?.displayIfNeeded(); CATransaction.flush()
            // Render only our own view; WindowServer capture may be unavailable
            // on Tahoe. Presentation continuity is asserted separately below.
            guard let bitmap = bitmapImageRepForCachingDisplay(in:bounds) else { throw LayoutError.invalid("Optimization bitmap unavailable") }
            cacheDisplay(in:bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent(name+".png"))
        }
        func positions(presentation: Bool) -> [String:CGFloat] {
            let active = interaction.folderID != nil ? folderGrid : grid
            let views = [active]+(outgoingPage.map { [$0] } ?? [])+neighboringPages.map(\.view)
            var result: [String:CGFloat] = [:]
            for view in views {
                let layer = presentation ? (view.layer?.presentation() ?? view.layer) : view.layer
                let origin = (layer?.frame.minX ?? view.frame.minX)
                for tile in view.subviews.compactMap({ $0 as? AppTile }) {
                    result[tile.content.id] = origin+tile.frame.midX
                }
            }
            return result
        }
        func pageHosts() -> [FlippedView] {
            [interaction.folderID != nil ? folderGrid : grid]
                + (outgoingPage.map { [$0] } ?? []) + neighboringPages.map(\.view)
        }
        func timedScroll(_ event: NSEvent) {
            let start = CACurrentMediaTime()
            scrollWheel(with:event)
            inputLatencies.append((CACurrentMediaTime()-start)*1000)
        }
        func takeOver(dx: Int32) throws {
            let hosts = pageHosts()
            let before = positions(presentation:true)
            let start = CACurrentMediaTime()
            timedScroll(scrollCheckEvent(dx:dx,phase:.began))
            latencies.append((CACurrentMediaTime()-start)*1000)
            try check(backgroundGesture?.fromScroll == true && !pageTransition && !settlingPage,"new gesture takes over immediately (shown=\(controller.isShown), page=\(currentPage), folder=\(folderPage), transition=\(pageTransition), settling=\(settlingPage), ignored=\(ignoredScrollSequence))")
            try check(hosts.allSatisfy { old in pageHosts().contains { $0 === old } },"takeover retains every mounted page host and its tile layers")
            let frames = pageHosts().map { ($0,$0.frame) }
            timedScroll(scrollCheckEvent(dx:0,phase:.changed))
            try check(frames.allSatisfy { $0.0.frame == $0.1 },"tracking leaves AppKit page frames fixed")
            let after = positions(presentation:false)
            let shared = Set(before.keys).intersection(after.keys)
            try check(!shared.isEmpty,"interruption retains visible content")
            try check(shared.allSatisfy { abs(after[$0]!-before[$0]!-CGFloat(dx)) < 2 },"interruption preserves presentation positions plus input delta")
            let active = interaction.folderID != nil ? folderGrid : grid
            let allTiles = ([active]+neighboringPages.map(\.view)).flatMap { $0.subviews.compactMap { $0 as? AppTile } }
            try check(allTiles.allSatisfy(\.hasRenderedTitle),"current and neighboring page titles retain rendered contents")
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
            guard let window = window else { return }
            let event = NSEvent.mouseEvent(with:type,location:convert(point,to:nil),modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
                eventNumber:0,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
        }
        var draggedID = ""
        let wait = Motion.pageDuration+0.15
        let steps: [InteractionCheckStep] = [
            .init { [self] in
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                let installed = state.apps.filter(\.available)
                try check(!installed.isEmpty,"installed apps available for artwork fixtures")
                let apps = (0..<capacity*3).map { i -> AppRecord in
                    var app = installed[i%installed.count]; app.id = "optimization-\(i)"; return app
                }
                fixture.reconcile(apps,capacity:capacity,folderCapacity:folderCapacity)
                fixture.didGroupSystemApps = true; fixture.systemFolderPolicyVersion = 2
                controller.mutate("Optimization fixture") { $0 = fixture }
                interaction = InteractionState(); currentPage = 0; refresh()
                try runGeometryChecks(outputDirectory:outputDirectory)
                try check(searchBox.frame.minY-menuBarHeight >= 24,"search has a separate 24pt gap below the menu/notch")
                let iconRect = searchBox.magnifier.frame
                let textRect = search.cell!.drawingRect(forBounds:search.bounds).offsetBy(dx:search.frame.minX,dy:search.frame.minY)
                try check(!iconRect.intersects(textRect) && abs(iconRect.midY-textRect.midY) < 0.5,"search icon and placeholder have separate slots and a shared vertical center")
                window?.makeFirstResponder(search)
                try check(search.currentEditor() != nil,"empty search accepts native text editing")
                if let editor = search.currentEditor() as? NSTextView {
                    let editorRect = searchBox.convert(editor.bounds,from:editor)
                    try check(!editorRect.intersects(iconRect) && editorRect.minX >= search.frame.minX-1,"focused editor cannot overlap the magnifier")
                }
                search.stringValue = "메모"
                controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
                searchBox.clearButton.performClick(nil)
                try check(search.stringValue.isEmpty && interaction.query.isEmpty,"clear button restores the empty native input")
                window?.makeFirstResponder(self)
                let restingGrid = grid.frame, restingIcons = tiles.map(\.frame), restingDots = pageDots.frame
                for _ in 0..<3 {
                    NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
                    refresh()
                }
                try check(grid.frame == restingGrid && tiles.map(\.frame) == restingIcons && pageDots.frame == restingDots,"transient screen notifications do not resize the Dock-reserved page")
                try check(abs(tiles[0].frame.width-bounds.width/CGFloat(columns+1)) < 0.5,"horizontal app spacing follows the LaunchOS reference")
                try capture("grid")
                try check(tiles.allSatisfy(\.hasRenderedTitle),"all initial labels have rendered backing")
                let source = tiles[0], externalItem = source.makeExternalDraggingItem(in:self)
                let components = externalItem.imageComponents ?? []
                try check(components.count == 1 && (components.first?.contents as? NSImage) === source.content.image,
                          "external drag contains only the original app artwork")
                try check(externalItem.draggingFrame == DockDragPreview.frame(source:source.convert(source.iconFrame,to:self),pointer:nil,iconSize:DockDragPreview.iconSize),
                          "Dock drag uses the configured Dock size and keeps the icon center")
                try check((externalItem.item as? NSPasteboardItem)?.string(forType:.fileURL) == source.content.fileURL?.absoluteString,
                          "icon-only drag preserves the application's file URL")
                try check(NSRunningApplication.current.activationPolicy == .accessory
                          && Bundle.main.object(forInfoDictionaryKey:"LSUIElement") as? Bool == true,
                          "running launcher uses the agent policy without a Dock running tile")
                initialTiles = tiles
                beforePaging = try Data(contentsOf:controller.store.fileURL)
                changePage(1)
                if !Motion.reduced {
                    try check(Set(outgoingPage?.subviews.compactMap { ($0 as? AppTile).map(ObjectIdentifier.init) } ?? []) == Set(initialTiles.map(ObjectIdentifier.init)),"outgoing page retains all actual tile objects (shown=\(controller.isShown), count=\(outgoingPage?.subviews.count ?? -1))")
                }
            },
            .init(delay:0.26) { [self] in
                try capture("page-in-motion")
                if !Motion.reduced { try takeOver(dx:-40) }
                else { timedScroll(scrollCheckEvent(dx:-40,phase:.began)) }
                timedScroll(scrollCheckEvent(dx:-Int32(bounds.width*0.3),phase:.changed))
                timedScroll(scrollCheckEvent(dx:0,phase:.ended))
            },
            .init(delay:0.2) { [self] in
                if !Motion.reduced { try takeOver(dx:40) }
                else { timedScroll(scrollCheckEvent(dx:40,phase:.began)) }
                try capture("gesture-takeover")
                timedScroll(scrollCheckEvent(dx:Int32(bounds.width*0.3),phase:.changed))
                timedScroll(scrollCheckEvent(dx:0,phase:.ended))
            },
            .init(delay:wait) { [self] in
                try check(!pageTransition && !settlingPage && neighboringPages.isEmpty && outgoingPage == nil,"rapid gestures settle with no leftover page views")
                try check(tiles.map { $0.content.id } == fixture.pages[currentPage],"settled page contents match the selected page")
                try check(try Data(contentsOf:controller.store.fileURL) == beforePaging,"page gestures never rewrite layout data")
                currentPage = 0; refresh()
                changePage(requestedPage+1); changePage(requestedPage+1); changePage(requestedPage+1)
                try check(queuedPage == nil && requestedPage == 2,"rapid keyboard commands retarget immediately without waiting for completion")
                if !Motion.reduced {
                    let pending = (grid.layer?.animation(forKey:"page") as? CABasicAnimation)?.fromValue as? NSNumber
                    try check(currentPage == 0 && abs(pending?.doubleValue ?? .infinity) < 0.5,"same-run-loop retarget starts at the original visible page")
                }
            },
            .init(delay:wait*2) { [self] in
                try check(currentPage == 2 && !pageTransition,"rapid forward commands accumulate and clamp to the last page")
                changePage(1)
                let target = state.apps[0]
                search.stringValue = target.title
                controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
                try check(!pageTransition && !settlingPage && tiles.contains { $0.content.id == target.id },"search cancels page motion and shows results immediately")
                let point = search.convert(NSPoint(x:search.bounds.midX,y:search.bounds.midY),to:self)
                try check(hitTest(convert(point,to:superview)) !== self,"glass search remains an interactive text input")
                try capture("search")
                interaction.query = ""; search.stringValue = ""; currentPage = 0; refresh()
                controller.mutate("Optimization folder fixture") { layout in
                    folderID = try layout.makeFolder(with:layout.apps[0].id,over:layout.apps[1].id)
                    for app in layout.apps[2..<(self.folderCapacity+2)] {
                        try layout.move(app.id,to:layout.endOfFolder(folderID)!,folderCapacity:self.folderCapacity)
                    }
                }
                openFolder(folderID)
            },
            .init(delay:0.4) { [self] in changePage(1,insideFolder:true) },
            .init(delay:0.26) { [self] in
                if !Motion.reduced { try takeOver(dx:40) }
                else { timedScroll(scrollCheckEvent(dx:40,phase:.began)) }
                timedScroll(scrollCheckEvent(dx:Int32(folderViewport.bounds.width*0.3),phase:.changed))
                timedScroll(scrollCheckEvent(dx:0,phase:.ended))
            },
            .init(delay:wait) { [self] in
                try check(folderPage == 0 && interaction.folderID == folderID && !settlingPage,"folder pages support interrupted reverse scrolling")
                try check(grid.layer?.transform.m41 == 0,"folder gestures leave root page geometry unchanged")
                closeFolder(animated:false)
                controller.mutate("Restore optimization fixture") { $0 = fixture }
                currentPage = 0; refresh(); changePage(1)
            },
            .init(delay:wait) { [self] in
                changePage(0)
            },
            .init(delay:wait) { [self] in
                try check(tiles.map { $0.content.id } == fixture.pages[0] && tiles.allSatisfy(\.hasRenderedTitle),"returning pages retain all labels")
                let modification = try controller.store.fileURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
                let app = controller.state.apps[0], cache = controller.icons
                let icon = cache.image(for:app)
                cache.invalidateChanges(from:controller.state.apps,to:controller.state.apps)
                try check(cache.image(for:app) === icon,"unchanged catalog retains cached icon identity")
                try check(try controller.store.fileURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate == modification,"cache reuse performs no layout writes")
                try capture("final-grid")
                let tile = tiles[0]; draggedID = tile.content.id
                let origin = tile.convert(NSPoint(x:tile.iconFrame.midX,y:tile.iconFrame.midY),to:self)
                mouse(.leftMouseDown,at:origin)
                mouse(.leftMouseDragged,at:NSPoint(x:origin.x+10,y:origin.y))
                try check(dragID == draggedID && draggedTile?.hasRenderedTitle == true,"reused tile starts an icon drag with a visible name")
                let target = tiles[3]
                mouse(.leftMouseDragged,at:target.convert(NSPoint(x:target.bounds.width-15,y:target.iconFrame.midY),to:self))
            },
            .init(delay:Motion.insertionDelay+0.15) { [self] in
                try check(pendingDrop != nil,"reused tiles accept an insertion candidate")
                mouse(.leftMouseUp,at:lastDragPoint)
            },
            .init(delay:Motion.returnDuration+0.2) { [self] in
                try check(dragID == nil && draggedTile == nil && state.location(of:draggedID)?.index != 0,"dragging a reused tile commits its new position")
                try state.validate()
                changePage(1)
            },
            .init(delay:0.26) { [self] in
                let point = NSPoint(x:bounds.midX,y:searchBox.frame.maxY+4)
                mouse(.leftMouseDown,at:point)
                try check(backgroundGesture != nil && !pageTransition,"mouse background can take over an automatic page turn")
                mouse(.leftMouseDragged,at:NSPoint(x:point.x+100,y:point.y))
                mouse(.leftMouseUp,at:NSPoint(x:point.x+100,y:point.y))
            },
            .init(delay:wait) { [self] in
                try check(backgroundGesture == nil && !settlingPage && controller.isShown,"mouse takeover finishes without dismissing the launcher")
                currentPage = 0; refresh(); changePage(1)
                if !Motion.reduced {
                    progressTimer = Timer.scheduledTimer(withTimeInterval:1.0/120,repeats:true) { [self] _ in
                        let x = grid.layer?.presentation()?.transform.m41 ?? grid.layer?.transform.m41 ?? 0
                        progressSamples.append(CGFloat(currentPage)-x/pageStride(insideFolder:false))
                        let slide = grid.layer?.animation(forKey:"page") as? CABasicAnimation
                        progressDetails.append("x=\(x) presentation=\(grid.layer?.presentation() != nil) pending=\(pageAnimationPendingCommit) model=\(grid.layer?.transform.m41 ?? 0) from=\(String(describing:slide?.fromValue)) begin=\(slide?.beginTime ?? -1)")
                    }
                    RunLoop.main.add(progressTimer!,forMode:.common)
                }
            },
            .init(delay:0.16) { [self] in
                timedScroll(scrollCheckEvent(dx:-10,phase:.began))
                timedScroll(scrollCheckEvent(dx:0,phase:.ended))
                try check(pageDots.selected == 1,"short continuation retains the committed next page despite its positive residual offset")
            },
            .init(delay:0.10) { [self] in
                timedScroll(scrollCheckEvent(dx:-10,phase:.began))
                timedScroll(scrollCheckEvent(dx:0,phase:.ended))
                try check(pageDots.selected == 1,"a second continuation does not reselect the previous page")
            },
            .init(delay:wait) { [self] in
                progressTimer?.invalidate(); progressTimer = nil
                try check(currentPage == 1 && !settlingPage,"successive short forward gestures settle on the intended page")
                if !Motion.reduced {
                    try check(progressSamples.count > 8 && zip(progressSamples,progressSamples.dropFirst()).allSatisfy { $1 >= $0-0.002 },"sampled forward progress never jumps backward")
                }
                currentPage = 0; refresh(); changePage(1)
            },
            .init(delay:0.06) { [self] in
                timedScroll(scrollCheckEvent(dx:-Int32(bounds.width*0.3),phase:.began))
                timedScroll(scrollCheckEvent(dx:0,phase:.ended))
                try check(pageDots.selected == 2,"an early strong continuation advances from the previous destination")
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 2 && tiles.map { $0.content.id } == state.pages[2],"an early double turn adopts the correct prepared page")
                changePage(0)
            },
            .init(delay:0.16) {
                if !Motion.reduced { try takeOver(dx:20) }
                timedScroll(scrollCheckEvent(dx:0,phase:.ended))
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 0 && !settlingPage && neighboringPages.isEmpty,"interrupted multi-page indicator jump keeps its destination and clears hosts")
            }
        ]
        InteractionCheckSequence(steps) { [self] result in
            progressTimer?.invalidate()
            try? pageTimingSamples?.joined(separator:"\n").write(to:outputDirectory.appendingPathComponent("page-timings.txt"),atomically:true,encoding:.utf8)
            try? progressSamples.map(String.init(describing:)).joined(separator:"\n").write(to:outputDirectory.appendingPathComponent("forward-progress.txt"),atomically:true,encoding:.utf8)
            try? progressDetails.joined(separator:"\n").write(to:outputDirectory.appendingPathComponent("forward-details.txt"),atomically:true,encoding:.utf8)
            cancelPageTransition(); cancelBackgroundPaging(); closeFolder(animated:false)
            controller.mutate("Restore original isolated layout") { $0 = original }
            guard case .success = result else { completion(result); return }
            let saved = try? Data(contentsOf:controller.store.fileURL)
            let modified = try? controller.store.fileURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
            let record = original.apps.first
            let image = record.map { controller.icons.image(for:$0) }
            controller.onFirstScan = {
                do {
                    try check(!controller.isScanning && controller.state == original,"unchanged real catalog scan preserves the model")
                    try check(try Data(contentsOf:controller.store.fileURL) == saved,"unchanged real catalog scan preserves saved bytes")
                    try check(try controller.store.fileURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate == modified,"unchanged real catalog scan skips file writes")
                    if let record = record { try check(controller.icons.image(for:record) === image,"unchanged real scan keeps icon cache entries") }
                } catch { completion(.failure(error)); return }
                let report = "PASS: \(checks) optimization checks\nGesture handler times (ms; not physical FPS): \(latencies)\nAll scroll event handler times (ms): \(inputLatencies)\n"
                print(report)
                try? self.pageTimingSamples?.joined(separator:"\n").write(to:outputDirectory.appendingPathComponent("page-timings.txt"),atomically:true,encoding:.utf8)
                self.pageTimingSamples = nil
                try? report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
                completion(.success(()))
            }
            controller.rescan()
        }.run()
    }

    private func runGeometryChecks(outputDirectory: URL) throws {
        let originalSize = frame.size, originalPage = currentPage
        let originalState = state
        let savedLayout = try Data(contentsOf: controller!.store.directory.appendingPathComponent("layout.json"))
        var report: [String] = [], checks = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LayoutError.invalid("Geometry UI check failed: \(description)") }
            checks += 1
        }
        defer {
            setFrameSize(originalSize); currentPage = originalPage
            interaction.query = ""; search.stringValue = ""; refresh()
        }
        for size in [NSSize(width:1024,height:768), NSSize(width:1440,height:900),
                     NSSize(width:1920,height:1080), NSSize(width:2560,height:1440),
                     NSSize(width:3840,height:2160), NSSize(width:2160,height:3840), originalSize] {
            setFrameSize(size); refresh()
            guard let first = tiles.first else { throw LayoutError.invalid("No tile for geometry check") }
            let icon = first.convert(first.iconFrame,to:self)
            let cellHeight = grid.bounds.height/CGFloat(rows)
            let center = icon.midY+CGFloat(rows-1)*cellHeight/2
            let label = first.convert(first.labelFrame,to:self)
            try check(searchBox.frame.size == NSSize(width:min(360,size.width-40),height:SearchBox.height) && searchBox.frame.minY == menuBarHeight+SearchBox.topGap,
                      "search clears the menu/notch by the dedicated top gap at \(size)")
            try check(gridViewport.frame.minY-searchBox.frame.maxY >= 8 && Int(first.iconSize)%8 == 0,
                      "grid reserves the lower header gap and icons use original eight-point size steps")
            try check(icon.minY > searchBox.frame.maxY && center < pageDots.frame.minY,
                      "reserved icon rows fit between the header and page controls at \(size)")
            try check(abs(grid.frame.midX-gridViewport.bounds.midX) < 0.5,
                      "grid has balanced horizontal margins at \(size)")
            try check(gridViewport.frame.minY > searchBox.frame.maxY && gridViewport.frame.maxY < pageDots.frame.minY,
                      "grid clears search and page controls at \(size)")
            try check(first.bounds.contains(first.iconFrame.union(first.labelFrame)) && first.bounds.contains(first.interactionFrame),
                      "icon, title and click area fit their cell at \(size)")
            if tiles.count > columns {
                let lower = tiles[columns].convert(tiles[columns].interactionFrame,to:self)
                try check(lower.minY-first.convert(first.interactionFrame,to:self).maxY >= 8,
                          "rows retain separate click areas at \(size)")
            }
            try check(pageStride(insideFolder:false) == size.width && gridViewport.subviews.count == 1,
                      "resized pages retain full-width travel without stale layers")
            report.append("\(Int(size.width))x\(Int(size.height)): search=\(searchBox.frame); menu height=\(menuBarHeight); grid=\(grid.convert(grid.bounds,to:self)); icon=\(icon); label=\(label); row centers midpoint=\(center); screen midpoint=\(bounds.midY)")
        }
        if state.pages.count > 1 {
            currentPage = 0; refresh(); changePage(1)
            setFrameSize(NSSize(width:1441,height:901)); refresh()
            try check(currentPage == 1 && !pageTransition && outgoingPage == nil && tiles.map { $0.content.id } == state.pages[1],
                      "resizing during a page turn retains the target page and removes old geometry")
        }
        interaction.query = state.apps.first?.title ?? "test"; search.stringValue = interaction.query
        let query = interaction.query
        setFrameSize(NSSize(width:1921,height:1081)); refresh()
        try check(interaction.query == query && search.stringValue == query, "resize preserves active search")
        try check(state == originalState && (try Data(contentsOf: controller!.store.directory.appendingPathComponent("layout.json"))) == savedLayout,
                  "geometry changes preserve the stored app order and folders")
        try report.joined(separator:"\n").appending("\n").write(to:outputDirectory.appendingPathComponent("resolution-geometry.txt"),atomically:true,encoding:.utf8)
        print("PASS: \(checks) resolution geometry checks")
    }

    /// Runs against a caller-supplied temporary store; never launches or deletes apps.
    func runUIChecks(outputDirectory: URL) throws {
        guard let controller = controller else { throw LayoutError.invalid("UI controller missing") }
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LayoutError.invalid("UI check failed: \(name)") }
            count += 1
        }
        func capture(_ name: String) throws {
            layoutSubtreeIfNeeded()
            // Remove transient animation layers before recording a settled state.
            finishFolderOpening()
            outgoingPage?.removeFromSuperview(); outgoingPage = nil
            grid.layer?.removeAllAnimations(); folderGrid.layer?.removeAllAnimations(); folderPanel.layer?.removeAllAnimations()
            guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { throw LayoutError.invalid("UI bitmap unavailable") }
            cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LayoutError.invalid("PNG unavailable") }
            try png.write(to: outputDirectory.appendingPathComponent(name+".png"))
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        refresh()
        try runGeometryChecks(outputDirectory:outputDirectory)
        if let screen = window?.screen, let snapshot = controller.wallpapers.snapshot(for:screen) {
            try check(wallpaper.image === snapshot.image,"launcher uses the current processed desktop snapshot")
            try check(snapshot.image.size == screen.frame.size,"wallpaper preserves the current screen dimensions")
            let info = "source=\(snapshot.source)\nscreen=\(screen.frame)\nblurRadius=\(WallpaperRenderer.blurRadius)pt\nsaturation=\(WallpaperRenderer.saturation)\ncolorGain=\(WallpaperRenderer.colorGain)\ncolorBias=\(WallpaperRenderer.colorBias)\n"
            try info.write(to:outputDirectory.appendingPathComponent("wallpaper.txt"),atomically:true,encoding:.utf8)
            var rect = CGRect(origin:.zero,size:snapshot.image.size)
            for (name,image) in [("desktop-picture",snapshot.original),("blurred-wallpaper",snapshot.image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!)] {
                try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent(name+".png"))
            }
        } else { try check(false,"desktop picture is available") }
        try check(!tiles.isEmpty && tiles.count <= capacity, "real catalog rendered")
        try check(tiles.allSatisfy { grid.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }, "root icons fit grid")
        if let tile = tiles.first {
            let point = tile.superview!.convert(NSPoint(x: tile.bounds.midX,y: tile.iconFrame.midY), from: tile)
            try check(tile.hitTest(point) === tile, "icon hit testing")
        }
        try capture("grid")
        if state.pages.count > 1 {
            changePage(1)
            try check(tiles.map { $0.content.id } == state.pages[1], "page navigation renders target")
            changePage(0)
        }
        let ids = state.orderedAppIDs
        try check(ids.count >= 2, "catalog supports folder scenario")
        var folderID = ""
        controller.mutate("UI folder check") { folderID = try $0.makeFolder(with: ids[0], over: ids[1]) }
        try check(!folderID.isEmpty && state.folder(folderID) != nil, "folder model and root synchronized")
        openFolder(folderID)
        try check(folderTiles.count == 2 && !folderPanel.isHidden, "folder panel contains both apps")
        try check(folderTiles.allSatisfy { folderGrid.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }, "folder icons fit panel")
        try check(folderViewport.frame.width == folderPanel.frame.width && folderGrid.frame.minX > 0, "folder pages include their side margins")
        let reference = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
        guard let referenceBody = opaqueIconBounds(reference) else { throw LayoutError.invalid("Reference icon alpha unavailable") }
        let folderIcon = AppTile(content: tileContent(folderID))
        folderIcon.frame = NSRect(x:0,y:0,width:192,height:190)
        for size: CGFloat in [64,96,128] {
            folderIcon.iconSize = size; folderIcon.layoutSubtreeIfNeeded()
            let body = folderIcon.subviews.compactMap { $0 as? FlippedView }.first!
            try check(abs(body.frame.width-referenceBody.width*size) <= 4,
                "folder body matches opaque app icon at \(size)pt (folder=\(body.frame.width), app=\(referenceBody.width*size))")
            try check(body.frame.midX == folderIcon.iconFrame.midX && body.frame.midY == folderIcon.iconFrame.midY && body.subviews.allSatisfy { body.bounds.contains($0.frame) }, "folder stays centered and contains all mini icons")
        }
        folderTitle.stringValue = "검증 폴더"; commitFolderName()
        try check(state.folder(folderID)?.title == "검증 폴더", "folder rename persisted")
        try capture("folder")
        beginEditing(); cancel()
        try check(!interaction.editing && interaction.folderID == folderID, "Escape ends editing before closing folder")
        cancel(); finishFolderOpening()
        try check(interaction.folderID == nil && folderPanel.isHidden, "Escape closes folder")
        search.stringValue = state.app(ids[0])!.title
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try check(tiles.contains { $0.content.id == ids[0] }, "search finds app inside folder")
        let queryBeforeScreenNotification = interaction.query
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try check(interaction.query == queryBeforeScreenNotification, "presentation-only screen notifications preserve search")
        try capture("search")
        cancel()
        try check(interaction.query.isEmpty && controller.isShown, "Escape clears query before dismissing (query=\(interaction.query), shown=\(controller.isShown), renaming=\(interaction.renaming), editing=\(interaction.editing))")
        controller.mutate("UI folder extraction") { try $0.move(ids[0], to: ItemLocation(page: 0,index: 0)) }
        try check(state.location(of: ids[0])?.folderID == nil && state.folder(folderID) != nil, "folder extraction preserves singleton")
        let persisted = try controller.store.load()
        try check(persisted == state, "UI mutations survive store reload")
        controller.undoLayout()
        try check(state.location(of: ids[0])?.folderID == folderID, "layout undo restores folder membership")
        controller.redoLayout()
        try check(state.location(of: ids[0])?.folderID == nil, "layout redo restores extraction")
        print("PASS: \(count) native UI checks; \(state.apps.count) discovered apps")
    }

    func runAppCollectionChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let controller = controller, let window = window else { completion(.failure(LayoutError.invalid("No UI window"))); return }
        var messages: [String] = []
        var original = LayoutState(), moved = LayoutState()
        var pointer = NSPoint.zero
        let previousPointer = collectionMouseLocation
        collectionMouseLocation = { pointer }
        var dropSamples: [String:NSPoint] = [:]
        let ids = (0..<12).map { "collection-\($0)" }
        let group = "collection-folder"
        let wait = Motion.pageDuration+0.2
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw LayoutError.invalid("App collection check failed: "+message) }
            messages.append(message)
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, command: Bool = true) -> NSEvent {
            pointer = window.convertPoint(toScreen:self.convert(point,to:nil))
            return NSEvent.mouseEvent(with:type,location:self.convert(point,to:nil),modifierFlags:command ? [.command] : [],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0)!
        }
        func tile(_ id: String) throws -> AppTile {
            guard let tile = (self.interaction.folderID == nil ? self.tiles : self.folderTiles).first(where: { $0.content.id == id }) else {
                throw LayoutError.invalid("Missing collection fixture tile: "+id)
            }
            return tile
        }
        func point(_ id: String) throws -> NSPoint {
            let item = try tile(id)
            return self.convert(NSPoint(x:item.iconFrame.midX,y:item.iconFrame.midY),from:item)
        }
        func pick(_ id: String) throws {
            let p = try point(id)
            // Assert capture before dispatching a mouse-up: no test can launch an app.
            try check(self.routeAppCollection(mouse(.leftMouseDown,p)),"Command click is captured: "+id)
            window.sendEvent(mouse(.leftMouseUp,p))
        }
        func release(_ point: NSPoint) {
            pointer = window.convertPoint(toScreen:self.convert(point,to:nil))
            // Actual modifier events need not carry the pointer position.
            window.sendEvent(NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:55)!)
        }
        func reset() {
            self.cancelAppCollection(); self.cancelPageTransition(); self.cancelBackgroundPaging(); self.closeFolder(animated:false)
            self.currentPage = 0; self.interaction.editing = true
            controller.mutate("Reset collection fixture") { $0 = original }; self.refresh()
        }
        let steps: [InteractionCheckStep] = [
            .init(delay:0.8) { [self] in
                original.apps = ids.enumerated().map { AppRecord(id:$0.element,title:"App \($0.offset+1)",bundleID:"test."+$0.element,path:"",available:false) }
                original.pages = [Array(ids[0...3]),Array(ids[4...7]),[group,ids[8]]]
                original.folders = [AppFolder(id:group,title:"Collected apps",pages:[Array(ids[9...11])])]
                original.didGroupSystemApps = true; original.systemFolderPolicyVersion = 2
                reset()
                interaction.editing = false
                try check(!routeAppCollection(mouse(.leftMouseDown,try point(ids[0]))),"Command collection is disabled outside editing")
                interaction.editing = true; refresh()
                try check(!routeAppCollection(mouse(.leftMouseDown,try point(ids[0]),command:false)),"ordinary clicks retain their normal route")
                try pick(ids[2]); try pick(ids[0]); try pick(ids[2])
                try check(collectedAppIDs == [ids[2],ids[0]] && collectionView?.count == 2,"pickup order and badge count exclude duplicates")
                if let badge = collectionView?.subviews.first(where:{ $0.subviews.contains { $0 is NSTextField } }),
                   let bitmap = badge.bitmapImageRepForCachingDisplay(in:badge.bounds) {
                    badge.cacheDisplay(in:badge.bounds,to:bitmap)
                    var whiteRows: [Int] = []
                    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9,
                           min(color.redComponent,color.greenComponent,color.blueComponent) > 0.9 { whiteRows.append(y) }
                    } }
                    let center = whiteRows.min().flatMap { first in whiteRows.max().map { Double(first+$0+1)/2 } }
                    let scale = Double(bitmap.pixelsHigh)/badge.bounds.height
                    try check(center.map { abs($0-Double(bitmap.pixelsHigh)/2) <= 1.5*scale } == true,"rendered count digits are vertically centered in badge")
                    try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                    try bitmap.representation(using:.png,properties:[:])?.write(to:outputDirectory.appendingPathComponent("badge.png"))
                } else { try check(false,"badge renders for alignment check") }
                try check(state == original && (try tile(ids[2])).isHidden && (try tile(ids[0])).isHidden,"pickup hides source tiles without saving layout")
                let p = NSPoint(x:bounds.midX,y:bounds.midY)
                window.sendEvent(mouse(.mouseMoved,p))
                try check(collectionPoint == p && collectionView?.hitTest(p) == nil,"stack follows mouse movement and lets clicks through")
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                if let bitmap = bitmapImageRepForCachingDisplay(in:bounds) {
                    cacheDisplay(in:bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])?.write(to:outputDirectory.appendingPathComponent("collected.png"))
                }
                changePage(1)
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 1 && collectedAppIDs.count == 2,"stack survives page change")
                let p = try point(ids[5])
                window.sendEvent(mouse(.mouseMoved,p)); release(p)
                try check(state.pages[1] == [ids[4],ids[2],ids[0],ids[5],ids[6],ids[7]],"Command release inserts apps in pickup order")
                try check(collectedAppIDs.isEmpty && collectionView == nil && interaction.editing,"drop clears stack and keeps editing active")
            },
            .init(delay:0.035) {
                if !Motion.reduced {
                    for id in [ids[2],ids[0]] {
                        let layer = try tile(id).layer!
                        guard let visible = layer.presentation() else { throw LayoutError.invalid("Missing drop presentation") }
                        try check(layer.animation(forKey:"collectionDrop") != nil && hypot(visible.position.x-layer.position.x,visible.position.y-layer.position.y) > 1,
                                  "dropped app is visibly in flight after display: "+id)
                        dropSamples[id] = visible.position
                    }
                }
            },
            .init(delay:0.07) {
                if !Motion.reduced {
                    for id in [ids[2],ids[0]] {
                        let visible = try tile(id).layer!.presentation()!.position, before = dropSamples[id]!
                        try check(hypot(visible.x-before.x,visible.y-before.y) > 1,"drop animation moves across rendered frames: "+id)
                    }
                }
            },
            .init(delay:Motion.returnDuration) { [self] in
                for id in [ids[2],ids[0]] {
                    let layer = try tile(id).layer!
                    let position = layer.presentation()?.position ?? layer.position
                    try check(hypot(position.x-layer.position.x,position.y-layer.position.y) < 1,"drop animation reaches its destination: "+id)
                    try check(!Motion.reduced || layer.animation(forKey:"collectionDrop") == nil,"reduced motion omits drop flight: "+id)
                }
                moved = state; controller.undoLayout()
                try check(state == original,"one undo restores entire batch")
                controller.redoLayout(); try check(state == moved,"one redo restores entire batch")
                reset(); try pick(ids[1]); cancel()
                try check(state == original && collectedAppIDs.isEmpty && !(try tile(ids[1])).isHidden && interaction.editing,"Escape restores source without leaving edit mode")
                try pick(ids[0]); release(NSPoint(x:-20,y:-20))
                try check(state == original && collectionView == nil,"release outside launcher cancels")
                // Releasing Command before mouse-up must not activate the source.
                let p2 = try point(ids[0])
                try check(routeAppCollection(mouse(.leftMouseDown,p2)),"early-release click captured")
                release(p2)
                try check(routeAppCollection(mouse(.leftMouseUp,p2,command:false)),"mouse-up after Command release is consumed")
                try check(state == original,"dropping at original slot is a no-op")
                changePage(2)
            },
            .init(delay:wait) {
                try pick(ids[8]); try pick(group)
            },
            .init(delay:Motion.folderOpenDuration+0.2) { [self] in
                try check(interaction.folderID == group && collectedAppIDs == [ids[8]],"Command-click opens a folder while carrying apps (folder=\(interaction.folderID ?? "nil"), count=\(collectedAppIDs.count))")
                try pick(ids[10]); try pick(ids[9])
                try check(collectedAppIDs == [ids[8],ids[10],ids[9]],"collection spans root and folder")
                let outside = NSPoint(x:bounds.midX,y:folderPanel.frame.minY-45)
                window.sendEvent(mouse(.mouseMoved,outside))
                try check(interaction.folderID == nil && collectedAppIDs.count == 3,"leaving folder carries collected apps back to root")
                let p = try point(group); window.sendEvent(mouse(.mouseMoved,p)); release(p)
                try check(state.folder(group)?.pages.flatMap { $0 } == [ids[11],ids[8],ids[10],ids[9]],"drop on existing folder appends whole collection")
                try check(Motion.reduced || subviews.contains { $0 is AppCollectionView && $0.layer?.animation(forKey:"collectionDrop") != nil },"closed-folder drop flies into the folder")
                reset(); try pick(ids[2]); try pick(ids[1])
                window.sendEvent(mouse(.mouseMoved,try point(ids[0])))
            },
            .init(delay:Motion.holdDelay+0.1) { [self] in
                try check(collectionGroupReady,"dwelling over an app arms folder creation")
                release(try point(ids[0]))
                try check(state.folders.contains { $0.pages.flatMap { $0 } == [ids[0],ids[2],ids[1]] },"armed app drop creates one folder in pickup order")
                reset(); try pick(ids[0]); changePage(state.pages.count,allowNew:true)
            },
            .init(delay:wait+0.2) { [self] in
                try check(currentPage == original.pages.count,"collection can navigate to a new final page")
                release(convert(NSPoint(x:grid.bounds.width/CGFloat(columns)/2,y:40),from:grid))
                try check(state.pages.last == [ids[0]],"release persists new page")
                try check(try controller.store.load() == state,"batch move persists to isolated layout store")
                reset(); try pick(ids[0]); changePage(1)
                release(try point(ids[5]))
                try check(state.pages[1] == [ids[4],ids[0],ids[5],ids[6],ids[7]],"Command release during page animation commits to the destination page")
                reset(); try pick(ids[0]); changePage(2)
                release(convert(NSPoint(x:grid.bounds.midX,y:40),from:grid))
                try check(currentPage == 2 && state.location(of:ids[0])?.page == 2,"release during a multi-page transition keeps the requested page")
                reset(); try pick(ids[0]); changePage(2,allowNew:true); changePage(3,allowNew:true)
                release(convert(NSPoint(x:grid.bounds.midX,y:40),from:grid))
                try check(currentPage == 3 && state.location(of:ids[0])?.page == 3,"release preserves a queued new final page")
                reset(); try pick(ids[0])
                scrollWheel(with:scrollCheckEvent(dx:-Int32(bounds.width*0.7),phase:.began))
                release(convert(NSPoint(x:grid.bounds.midX,y:40),from:grid))
                try check(currentPage == 1 && state.location(of:ids[0])?.page == 1,"release during an active swipe places apps on the next page")
                reset(); try pick(ids[0])
                scrollWheel(with:scrollCheckEvent(dx:-Int32(bounds.width*0.7),phase:.began))
                scrollWheel(with:scrollCheckEvent(dx:0,phase:.ended))
                release(convert(NSPoint(x:grid.bounds.midX,y:40),from:grid))
                try check(currentPage == 1 && state.location(of:ids[0])?.page == 1,"release while a swipe settles keeps its destination")
                reset(); try pick(ids[0]); changePage(1)
                var edgePoint = NSPoint(x:bounds.maxX-2,y:gridViewport.frame.midY)
                if isOverDock(edgePoint) { edgePoint.x = 2 }
                release(edgePoint)
                try check(state.location(of:ids[0])?.page == 1,"release in a page-turn gutter stays on the destination page")
                reset()
                for id in ids.prefix(4) { try pick(id) }
                changePage(1); release(try point(ids[5]))
                try check(currentPage == 0 && state.pages[0] == [ids[4]]+Array(ids.prefix(4))+Array(ids[5...7]),"removing the source page keeps the destination visible")
                reset(); interaction.query = "App 9"; search.stringValue = interaction.query; refresh()
                try pick(ids[8])
                try check(interaction.query.isEmpty && currentPage == 2 && collectedAppIDs == [ids[8]],"picking a search result returns to its original page")
                reset(); try pick(ids[0])
                window.sendEvent(mouse(.mouseMoved,NSPoint(x:bounds.maxX-2,y:gridViewport.frame.midY)))
            },
            .init(delay:0.75+wait) { [self] in
                window.sendEvent(mouse(.mouseMoved,NSPoint(x:bounds.midX,y:bounds.midY)))
                try check(currentPage > 0 && collectedAppIDs == [ids[0]] && collectionEdge == 0 && collectionEdgeTimer == nil,"edge dwell changes page and stops when pointer leaves edge")
                let dot = convert(pageDots.center(of:1),from:pageDots)
                window.sendEvent(mouse(.leftMouseDown,dot)); window.sendEvent(mouse(.leftMouseUp,dot))
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 1 && collectedAppIDs == [ids[0]],"page dots remain clickable while collecting")
                release(convert(pageDots.center(of:1),from:pageDots))
                try check(state.location(of:ids[0])?.page == 1 && state.pages[1].last == ids[0],"release over the page indicator places apps on the selected page")
                reset(); try pick(ids[0])
                controller.mutate("Concurrent layout change") { $0.renameFolder(group,title:"Changed") }
                try check(collectedAppIDs.isEmpty && state.folder(group)?.title == "Changed","concurrent changes cancel stale collection without overwriting layout")
                reset(); try pick(ids[0])
                controller.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:window))
                try check(collectedAppIDs.isEmpty && collectionView == nil && state == original,"focus loss cancels collection")
                try state.validate()
                let report = "PASS: \(messages.count) app collection checks\n"+messages.joined(separator:"\n")+"\n"
                print(report)
                try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
            }
        ]
        InteractionCheckSequence(steps) { [self] result in
            collectionMouseLocation = previousPointer; completion(result)
        }.run()
    }

    func runEditingPageChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let controller = controller, let window = window else { completion(.failure(LayoutError.invalid("No UI window"))); return }
        var messages: [String] = []
        var original: [AppTile] = [], folderOriginal: [AppTile] = []
        var rotation: CGFloat = 0
        let folderID = "editing-page-fixture"
        let wait = Motion.pageDuration+0.2
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LayoutError.invalid("Editing page check failed: "+message) }
            messages.append(message)
        }
        func checkWiggle(_ list: [AppTile], _ phase: String) throws {
            try check(!list.isEmpty && list.allSatisfy { tile in
                tile.editing && tile.subviews.filter { $0.layer?.animation(forKey:"editing") != nil }.count == (Motion.reduced ? 0 : 2)
            },phase+": editing animations match motion preference")
        }
        func iconLayer(_ tile: AppTile) -> CALayer? { tile.subviews.first { $0 is NSImageView }?.layer }
        let steps: [InteractionCheckStep] = [
            .init(delay:0.8) { [self] in
                let apps = Array(state.apps.prefix(4))
                try check(apps.count == 4,"four installed apps available for isolated fixture")
                controller.mutate("Editing page fixture") { layout in
                    layout = LayoutState(); layout.apps = apps
                    layout.pages = [[apps[0].id,folderID],[apps[1].id]]
                    layout.folders = [AppFolder(id:folderID,title:"Editing check",pages:[[apps[2].id],[apps[3].id]])]
                    layout.didGroupSystemApps = true; layout.systemFolderPolicyVersion = 2
                }
                original = tiles
                let tile = tiles[0]
                tile.mouseDown(with:NSEvent.mouseEvent(with:.leftMouseDown,location:tile.convert(NSPoint(x:tile.iconFrame.midX,y:tile.iconFrame.midY),to:nil),
                    modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!)
            },
            .init(delay:Motion.holdDelay+0.3) { [self] in
                original[0].mouseUp(with:NSEvent.mouseEvent(with:.leftMouseUp,location:original[0].mouseDownLocation,
                    modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0)!)
                try check(interaction.editing,"long press enters editing")
                try checkWiggle(tiles,"initial root page")
                changePage(1)
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 1 && !pageTransition,"right page settles")
                try checkWiggle(tiles,"right root page")
                changePage(0)
            },
            .init(delay:wait) { [self] in
                try check(currentPage == 0 && !pageTransition,"return page settles")
                try check(tiles.count == original.count && zip(tiles,original).allSatisfy { $0 === $1 },"return reuses original app and folder tiles")
                try checkWiggle(tiles,"returned root page")
                rotation = iconLayer(tiles[0])?.presentation()?.transform.m12 ?? 0
            },
            .init(delay:0.07) { [self] in
                if !Motion.reduced {
                    try check(abs((iconLayer(tiles[0])?.presentation()?.transform.m12 ?? 0)-rotation) > 0.0001,"returned icon visibly continues rotating")
                }
                openFolder(folderID)
            },
            .init(delay:Motion.folderOpenDuration+0.2) { [self] in
                folderOriginal = folderTiles
                try checkWiggle(folderTiles,"initial folder page")
                changePage(1,insideFolder:true)
            },
            .init(delay:wait) { [self] in
                try checkWiggle(folderTiles,"right folder page")
                changePage(0,insideFolder:true)
            },
            .init(delay:wait) { [self] in
                try check(folderPage == 0 && folderTiles.first === folderOriginal.first,"folder return reuses original tile")
                try checkWiggle(folderTiles,"returned folder page")
                cancel()
                try check(!interaction.editing && folderTiles.allSatisfy { tile in
                    !tile.editing && tile.subviews.allSatisfy { $0.layer?.animation(forKey:"editing") == nil }
                },"leaving editing stops animations")
                closeFolder(animated:false)
                changePage(1)
            },
            .init(delay:wait) { [self] in changePage(0) },
            .init(delay:wait) { [self] in
                try check(tiles.allSatisfy { tile in
                    !tile.editing && tile.subviews.allSatisfy { $0.layer?.animation(forKey:"editing") == nil }
                },"normal page return does not restart editing")
                try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
                let report = "PASS: \(messages.count) editing page checks\n"+messages.joined(separator:"\n")+"\n"
                try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
                print(report)
            }
        ]
        InteractionCheckSequence(steps,completion:completion).run()
    }

    func runInteractionChecks(outputDirectory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let controller = controller, let window = window else { completion(.failure(LayoutError.invalid("No UI window"))); return }
        var checks = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LayoutError.invalid("Interaction check failed: \(description)") }
            checks += 1
        }
        func send(_ type: NSEvent.EventType, _ local: NSPoint, time: TimeInterval? = nil) {
            let event = NSEvent.mouseEvent(with: type, location: self.convert(local, to: nil), modifierFlags: [],
                timestamp: time ?? ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
        }
        func capture(_ name: String) throws {
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else {
                throw LayoutError.invalid("Cannot capture own window")
            }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try bitmap.representation(using: .png, properties: [:])!.write(to: outputDirectory.appendingPathComponent(name+".png"))
        }
        // A snapshot during the fade misses the later presentation handoff.
        // Sample across the entire sequence, including the frame after entry ends.
        var menuSamples: [String] = []
        var misplacedMenuSurface: String?
        var menuTimer: Timer?
        if !CommandLine.arguments.contains("--windowed") {
            let started = ProcessInfo.processInfo.systemUptime
            menuTimer = Timer(timeInterval: 1.0/120, repeats: true) { _ in
                let panel = controller.menuTransition.panel
                guard panel.isVisible, let screen = window.screen else { return }
                let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(panel.windowNumber)) as? [[String:Any]]
                guard let entry = entries?.first, entry[kCGWindowIsOnscreen as String] as? Bool == true,
                      let dictionary = entry[kCGWindowBounds as String] as? [String:Any],
                      let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return }
                let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)-screen.frame.maxY
                let line = String(format:"%.4f",ProcessInfo.processInfo.systemUptime-started)
                    + " AppKit=\(panel.frame) WindowServer=\(frame) options=\(NSApp.presentationOptions.rawValue)"
                menuSamples.append(line)
                if abs(frame.minY-top) > 1 || abs(frame.minX-screen.frame.minX) > 1
                    || abs(frame.width-screen.frame.width) > 1 || abs(frame.height-panel.frame.height) > 1 {
                    if misplacedMenuSurface == nil { misplacedMenuSurface = line }
                }
            }
            RunLoop.main.add(menuTimer!, forMode: .common)
        }
        var menuSurfaceFrame: CGRect?
        func checkMenuSurface(_ phase: String) throws {
            let panel = controller.menuTransition.panel
            guard let screen = window.screen else { throw LayoutError.invalid("No menu screen") }
            try check(window.animationBehavior == .none && panel.animationBehavior == .none, "AppKit cannot add an independent window ordering animation")
            try check(abs(panel.frame.maxY-screen.frame.maxY) < 1 && panel.frame.height < max(80,screen.safeAreaInsets.top+1), "menu surface is confined to the screen top")
            let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(panel.windowNumber)) as? [[String:Any]]
            guard let dictionary = entries?.first?[kCGWindowBounds as String] as? [String:Any],
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { throw LayoutError.invalid("Menu surface not found in WindowServer") }
            let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)-screen.frame.maxY
            try check(abs(frame.minY-top) < 1 && abs(frame.minX-screen.frame.minX) < 1 && abs(frame.height-panel.frame.height) < 1,
                "WindowServer places the strip at the menu bar, never near the bottom")
            try check(panel.contentView?.bounds.size == panel.frame.size && panel.contentView?.layer?.masksToBounds == true,
                "menu drawing is clipped to its thin backing surface")
            if let previous = menuSurfaceFrame {
                try check(previous == frame, "menu surface size stays stable while the menu switches between hidden and visible")
            }
            menuSurfaceFrame = frame
            let line = "\(phase): AppKit=\(panel.frame), WindowServer=\(frame), opacity=\(controller.menuTransition.opacity)\n"
            let url = outputDirectory.appendingPathComponent("menu-strip-geometry.txt")
            let previous = (try? String(contentsOf: url)) ?? ""
            try (previous+line).write(to: url,atomically:true,encoding:.utf8)
        }
        var gap = NSPoint.zero
        var tile: AppTile!
        var colorTile: AppTile?
        var colorPoints: [NSPoint] = []
        var normalColors: [NSColor] = []
        func hueDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let distance = abs(a.hueComponent-b.hueComponent)
            return min(distance,1-distance)
        }
        func sampleColors() throws -> [NSColor] {
            window.displayIfNeeded(); CATransaction.flush()
            guard let cg = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming]) else {
                throw LayoutError.invalid("Cannot capture press colors")
            }
            let bitmap = NSBitmapImageRep(cgImage:cg)
            let scale = CGFloat(cg.width)/window.frame.width
            return try colorPoints.map { point in
                let location = self.convert(point,to:nil)
                guard let color = bitmap.colorAt(x:Int(location.x*scale),y:cg.height-1-Int(location.y*scale))?.usingColorSpace(.deviceRGB) else {
                    throw LayoutError.invalid("Cannot sample press pixel")
                }
                return color
            }
        }
        var iconPoint = NSPoint.zero
        var pageLayout: [[String]] = []
        var downTime: TimeInterval = 0
        var maximumPulseScale: CGFloat = 1
        var pulseMonitor: Timer?
        var pulseFrame: CGImage?
        let visibilityWait = max(Motion.enterDuration,Motion.exitDuration)+0.08
        let steps: [InteractionCheckStep] = [
            .init { [self] in
                let image = NSImage(size:NSSize(width:128,height:128),flipped:false) { _ in
                    NSColor.red.setFill(); NSRect(x:16,y:16,width:48,height:96).fill()
                    NSColor.blue.setFill(); NSRect(x:64,y:16,width:48,height:96).fill()
                    return true
                }
                let sample = AppTile(content:TileContent(id:"press-color-check",title:"색상 확인",image:image))
                sample.frame = NSRect(x:4,y:78,width:144,height:152); sample.iconSize = 96
                addSubview(sample); sample.layoutSubtreeIfNeeded(); colorTile = sample
                colorPoints = [NSPoint(x:sample.iconFrame.minX+sample.iconSize*0.3,y:sample.iconFrame.midY),
                    NSPoint(x:sample.iconFrame.minX+sample.iconSize*0.7,y:sample.iconFrame.midY),
                    NSPoint(x:sample.iconFrame.minX+2,y:sample.iconFrame.minY+2)].map { sample.convert($0,to:self) }
            },
            .init(delay:0.06) {
                normalColors = try sampleColors()
                try check(normalColors[0].redComponent > 0.9 && normalColors[0].saturationComponent > 0.7
                    && normalColors[1].blueComponent > 0.9 && normalColors[1].saturationComponent > 0.7,
                    "press fixture has saturated red and blue pixels (\(normalColors))")
                send(.leftMouseDown,colorPoints[0])
            },
            .init(delay:0.08) {
                let colors = try sampleColors()
                try capture("press-color")
                try check(colorTile?.pressed == true && colors[0].redComponent < normalColors[0].redComponent*0.85
                    && colors[0].redComponent > 0.15 && colors[0].saturationComponent >= normalColors[0].saturationComponent-0.05
                    && hueDistance(colors[0],normalColors[0]) < 0.02,
                    "press darkens red without desaturating it (pressed=\(colorTile?.pressed == true), rgb=\(colors[0]), normal=\(normalColors[0]))")
                try check(colors[1].blueComponent < normalColors[1].blueComponent*0.85
                    && colors[1].blueComponent > 0.15 && colors[1].saturationComponent >= normalColors[1].saturationComponent-0.05
                    && hueDistance(colors[1],normalColors[1]) < 0.02,
                    "press darkens blue without adding gray")
                try check(abs(colors[2].redComponent-normalColors[2].redComponent) < 0.02
                    && abs(colors[2].greenComponent-normalColors[2].greenComponent) < 0.02
                    && abs(colors[2].blueComponent-normalColors[2].blueComponent) < 0.02,
                    "press preserves transparent icon margins")
                let report = zip(normalColors,colors).enumerated().map { index,pair in
                    "sample \(index): normal=\(pair.0), pressed=\(pair.1), hue delta=\(hueDistance(pair.0,pair.1)), saturation \(pair.0.saturationComponent) -> \(pair.1.saturationComponent)"
                }.joined(separator:"\n")+"\n"
                try report.write(to:outputDirectory.appendingPathComponent("press-colors.txt"),atomically:true,encoding:.utf8)
                // No delegate on this diagnostic tile, so release cannot launch an app.
                send(.leftMouseUp,colorPoints[0])
            },
            .init(delay:0.06) {
                let colors = try sampleColors()
                try check(colorTile?.pressed == false && abs(colors[0].redComponent-normalColors[0].redComponent) < 0.02
                    && abs(colors[1].blueComponent-normalColors[1].blueComponent) < 0.02, "release restores original icon colors")
                colorTile?.removeFromSuperview(); colorTile = nil
            },
            .init { [self] in
                interaction.editing = false; interaction.folderID = nil; interaction.query = ""; search.stringValue = ""; selectedID = nil
                changePage(0); refresh(); layoutSubtreeIfNeeded()
                try check(tiles.count >= 2 && state.pages.count >= 2, "two pages available")
                let first = tiles[0], second = tiles[1]
                let a = first.convert(first.interactionFrame, to: self)
                let b = second.convert(second.interactionFrame, to: self)
                gap = NSPoint(x: (a.maxX+b.minX)/2,y: a.midY)
                try check(b.minX-a.maxX >= 20, "horizontal click targets have a gap")
                try check(hitTest(convert(gap,to: superview)) === self, "gap routes to background through real view tree")
                if tiles.count > columns {
                    let lower = tiles[columns].convert(tiles[columns].interactionFrame,to: self)
                    try check(lower.minY-a.maxY >= 12, "vertical click targets have a gap")
                }
                navigate(1)
                try check(first.highlighted && first.selectionFrame.width < first.bounds.width-20, "keyboard selection fits icon and label")
                pageLayout = state.pages; downTime = ProcessInfo.processInfo.systemUptime
                send(.leftMouseDown,gap,time:downTime)
                try check(controller.isShown && backgroundGesture != nil, "background mouse-down does not dismiss")
                send(.leftMouseDragged,NSPoint(x: gap.x-grid.bounds.width*0.4,y:gap.y),time:downTime+0.4)
                try check(backgroundGesture?.paging == true && !neighboringPages.isEmpty && (grid.layer?.transform.m41 ?? 0) < -20, "background drag tracks pointer and reveals next page")
            },
            .init(delay: 0.06) { [self] in
                let neighbor = neighboringPages.first!
                let expectedX = grid.frame.minX+CGFloat(neighbor.offset)*pageStride(insideFolder:false)+(backgroundGesture?.displacement ?? 0)
                try check(abs((neighbor.view.layer?.presentation()?.frame.minX ?? -1)-expectedX) < 1, "adjacent page is visibly following the pointer")
                let currentX = grid.layer?.presentation()?.frame.minX ?? 0
                let neighborX = neighbor.view.layer?.presentation()?.frame.minX ?? 0
                try check(abs(abs(neighborX-currentX)-bounds.width) < 2, "background dragging preserves the full-screen page stride")
                try capture("background-drag")
                send(.leftMouseUp,NSPoint(x: gap.x-grid.bounds.width*0.4,y:gap.y),time:downTime+0.46)
            },
            .init(delay: Motion.pageDuration+0.1) { [self] in
                try check(currentPage == 1 && controller.isShown, "background release settles on next page without dismissing")
                try check(state.pages == pageLayout, "background paging does not change saved app order")
                try check(!pageDots.isHidden && pageDots.count == state.pages.count && pageDots.selected == 1, "visible page dots follow drag")
                if !CommandLine.arguments.contains("--windowed"), let screen = window.screen {
                    let rect = window.convertToScreen(convert(pageDots.frame, to: nil))
                    try check(rect.minY >= screen.visibleFrame.minY+16, "page dots stay above Dock")
                }
                let dot = pageDots.convert(pageDots.center(of: 0),to:self)
                try check(hitTest(convert(dot,to:superview)) === pageDots, "page dots receive pointer events")
                send(.leftMouseDown,dot); send(.leftMouseUp,dot)
                try check(currentPage == 0 && pageDots.selected == 0 && controller.isShown, "clicking page dot navigates without dismissing")
            },
            .init(delay: Motion.pageDuration+0.08) { [self] in
                let multiPage = state
                controller.mutate("Single-page indicator check") { layout in
                    for id in layout.orderedAppIDs.dropFirst() { layout.hide(id) }
                }
                try check(state.pages.count == 1 && pageDots.count == 1 && !pageDots.isHidden, "single page retains its indicator")
                controller.mutate("Restore multiple pages") { $0 = multiPage }
            },
            .init(delay: Motion.pageDuration+0.05) { [self] in
                try capture("page-dots")
                downTime = ProcessInfo.processInfo.systemUptime
                send(.leftMouseDown,gap,time:downTime)
                send(.leftMouseDragged,NSPoint(x:gap.x+80,y:gap.y),time:downTime+0.3)
                try check((grid.layer?.transform.m41 ?? 0) < 80, "first page resists dragging beyond edge")
                send(.leftMouseUp,NSPoint(x:gap.x+80,y:gap.y),time:downTime+0.5)
            },
            .init(delay: Motion.pageDuration+0.1) { [self] in
                try check(currentPage == 0 && controller.isShown, "edge drag springs back without closing")
                send(.leftMouseDown,gap)
                send(.leftMouseDragged,NSPoint(x:gap.x-30,y:gap.y))
                cancel()
                try check(backgroundGesture == nil && grid.layer?.transform.m41 == 0 && controller.isShown, "Escape cancels background drag")
                send(.leftMouseUp,gap)
                tile = tiles[0]; iconPoint = tile.convert(NSPoint(x:tile.iconFrame.midX,y:tile.iconFrame.midY),to:self)
                selectedID = tile.content.id; updateSelection()
                send(.leftMouseDown,iconPoint)
                try check(tile.pressed && selectedID == nil && !tile.highlighted, "mouse press shades icon and clears keyboard selection")
                pulseMonitor = Timer.scheduledTimer(withTimeInterval: 0.01,repeats: true) { _ in
                    let image = tile.subviews.compactMap { $0 as? NSImageView }.first!
                    let scale = image.layer?.presentation()?.transform.m11 ?? 1
                    maximumPulseScale = max(maximumPulseScale,scale)
                    if scale > 1.045 && pulseFrame == nil {
                        pulseFrame = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming])
                    }
                }
            },
            .init(delay: 0.05) { try capture("pressed-icon") },
            .init(delay: Motion.holdDelay) { [self] in
                pulseMonitor?.invalidate()
                try check(interaction.editing && !tile.pressed && !tile.highlighted && selectedID == nil, "long press enters edit without sticky selection or shading")
                if !Motion.reduced {
                    try check(maximumPulseScale > 1.005, "long-press pulse visibly enlarges icon")
                }
                if let frame = pulseFrame {
                    try NSBitmapImageRep(cgImage:frame).representation(using:.png,properties:[:])!.write(to:outputDirectory.appendingPathComponent("hold-pulse.png"))
                } else { try capture("hold-pulse") }
            },
            .init(delay: 0.27) { [self] in
                send(.leftMouseUp,iconPoint)
                try check(!tile.highlighted && !tile.pressed, "releasing long press leaves no selection box")
                try capture("after-hold")
                send(.leftMouseDown,gap); send(.leftMouseUp,gap)
                try check(!interaction.editing && controller.isShown, "background click exits edit first")
                send(.leftMouseDown,gap); send(.leftMouseUp,gap)
                try check(!controller.isShown && window.isVisible && layer?.animation(forKey:"visibility") != nil, "dismiss keeps window visible for exit transition")
            },
            .init(delay: 0.06) { [self] in
                let opacity = layer?.presentation()?.opacity ?? 0
                try check(opacity > 0 && opacity < 1, "exit opacity changes over time")
                if !CommandLine.arguments.contains("--windowed") {
                    try check(controller.menuTransition.panel.isVisible && controller.menuTransition.opacity > 0 && controller.menuTransition.opacity < 1, "menu strip fades during exit")
                    try checkMenuSurface("exit")
                }
                try capture("exit-animation")
                controller.show()
            },
            .init(delay: visibilityWait) { [self] in
                try check(controller.isShown && window.isVisible && layer?.opacity == 1, "quick reopen survives old exit completion")
                if !CommandLine.arguments.contains("--windowed") {
                    try check(controller.menuTransition.panel.isVisible && controller.menuTransition.opacity == 1
                              && !controller.menuTransition.panel.ignoresMouseEvents,
                        "quick reopen keeps the menu covered without a stale exit callback")
                }
                controller.dismiss(restoreFocus:false)
            },
            .init(delay: visibilityWait) {
                try check(!window.isVisible, "window hides after exit completes")
                controller.show()
            },
            .init(delay: Motion.reduced ? 0.03 : 0.07) { [self] in
                let opacity = layer?.presentation()?.opacity ?? 1
                try check(opacity > 0 && opacity < 1, "entry opacity changes over time")
                if !CommandLine.arguments.contains("--windowed") {
                    try check(controller.menuTransition.panel.isVisible && controller.menuTransition.opacity > 0 && controller.menuTransition.opacity < 1, "menu strip fades during entry")
                    try checkMenuSurface("entry")
                }
                if !Motion.reduced { try check((grid.layer?.presentation()?.transform.m11 ?? 1) > 1, "entry grid scales towards rest") }
                try capture("entry-animation")
            },
            .init(delay: visibilityWait+0.15) { [self] in
                try check(layer?.opacity == 1 && grid.layer?.transform.m11 == 1 && controller.isShown, "entry settles at full opacity and natural size")
                try check(CommandLine.arguments.contains("--windowed") ? !controller.menuTransition.panel.isVisible
                          : controller.menuTransition.panel.isVisible && controller.menuTransition.opacity == 1,
                          "menu cover remains only while the fullscreen launcher is shown")
                if !CommandLine.arguments.contains("--windowed") {
                    try check(menuSamples.count >= 8, "menu transition sampled across multiple display frames")
                    try check(misplacedMenuSurface == nil, "menu surface never leaves the screen top, including presentation handoff: \(misplacedMenuSurface ?? "none")")
                }
                print("PASS: \(checks) pointer and animation checks")
            }
        ]
        InteractionCheckSequence(steps) { result in
            menuTimer?.invalidate()
            colorTile?.removeFromSuperview()
            if menuTimer != nil {
                do {
                    let report = menuSamples.joined(separator:"\n")
                        + "\nSamples: \(menuSamples.count); misplaced surface: \(misplacedMenuSurface ?? "none")\n"
                    try report.write(to:outputDirectory.appendingPathComponent("menu-handoff-frames.txt"), atomically:true, encoding:.utf8)
                } catch { completion(.failure(error)); return }
            }
            completion(result)
        }.run()
    }
}
