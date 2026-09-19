import AppKit

/// Root-page coordinates translated from Dock's bottom-up CALayer layout to
/// our top-down AppKit views. See docs/app-grid-alignment.ko.md.
struct LaunchpadPageMetrics {
    let grid: NSRect
    let dotsCenterY: CGFloat

    init(size: NSSize, rows: Int, columns: Int, dockExtent: CGFloat,
         sideDockExtent: CGFloat, safeTop: CGFloat, searchBottom: CGFloat) {
        let rowCount = CGFloat(max(1,rows))
        let rootHeight = max(0,size.height-dockExtent-30)
        let seed = floor(max(0,size.width-sideDockExtent)/CGFloat(2*max(1,columns)+1))
        let remaining = floor(rootHeight-(seed+40)*rowCount)
        let top = max(35,floor(remaining*0.15))
        let bottom = max(35,floor(remaining*0.25))
        // ECSBLayer's root pager: 30 pt header, base margins, and integer row
        // heights. Use all configured rows even on a sparse last page.
        let origin = max(searchBottom+20,30+top+safeTop)
        let available = max(0,size.height-dockExtent-30-bottom-origin)
        let height = floor(available/rowCount)*rowCount
        grid = NSRect(x:0,y:origin,width:size.width,height:height)
        // ECPagerControlLayer is 15 pt high and sits halfway into the base
        // bottom margin. Its surrounding 28 pt click area remains usable.
        dotsCenterY = min(size.height-14,max(origin,
            size.height-dockExtent-30-max(0,floor(bottom/2-7.5))-7.5))
    }

    static func iconTop(cellHeight: CGFloat, iconSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize:13)
        // ECSBLabelLayer adds top/bottom margins 2 + 2 and shadow 2 - (-1).
        let labelHeight = ceil(font.ascender-font.descender+font.leading)+7
        let belowLabel = min(20,ceil(cellHeight*0.125))
        let original = cellHeight-iconSize-labelHeight-belowLabel
        // Preserve the public AppKit label's actual 7 + 20 pt bounds when a
        // dense custom grid is shorter than the original reference layout.
        return max(0,min(original,cellHeight-iconSize-27))
    }
}
