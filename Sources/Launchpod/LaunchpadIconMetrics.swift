import AppKit

/// Logical icon bounds, independent of the centered presentation grid and of
/// Retina image storage. See docs/app-grid-icon-size.ko.md for the Dock evidence.
enum LaunchpadIconMetrics {
    static func preferredSize(screen: NSSize, reserved: NSSize, rows: Int, columns: Int) -> CGFloat {
        guard rows > 0, columns > 0 else { return 20 }
        // Springboard.layout: estimate a cell, then distribute unused height.
        // Dock uses internal Dock extents; our public AppKit adaptation uses the
        // screen's menu/Dock reservation, including the cached menu height.
        let width = max(0,screen.width-reserved.width)
        let height = max(0,screen.height-reserved.height-30)
        let seed = floor(width/CGFloat(2*columns+1))
        let remaining = floor(height-(seed+40)*CGFloat(rows))
        let side = max(90,floor(seed/2))
        let top = max(35,floor(remaining*0.15))
        let bottom = max(35,floor(remaining*0.25))
        let zoom: CGFloat = screen.width > 1920 ? 0.6 : (screen.width > 1680 ? 0.3 : (screen.width > 1440 ? 0.2 : 0))
        // ECSBLayer.calculateIconSize, neutral zoom style: horizontal zoom
        // margins, 30 pt search reservation, and a 15 pt bottom adjustment.
        let gridWidth = max(0,width-2*floor(side+width*0.2*zoom))
        let gridHeight = max(0,height-15-top-bottom)
        // Preserve the public sizing approximation verified in 0.1.16. The
        // original displayed label also wraps its text with margins/shadow
        // (7 pt); LaunchpadPageMetrics accounts for that when placing artwork.
        // Cache dimensions alone do not specify displayed image bounds.
        let cell = min(floor(gridWidth/CGFloat(columns)),floor(gridHeight/CGFloat(rows)))
        let font = NSFont.systemFont(ofSize:13)
        let labelHeight = ceil(font.ascender-font.descender+font.leading)
        return quantized(cell-labelHeight-24)
    }

    static func fittedSize(preferred: CGFloat, cell: NSSize) -> CGFloat {
        // AppTile reserves 8 pt above the image, 7 pt before its 20 pt label.
        // Fit those actual bounds, without subtracting the reference-layout
        // padding a second time. Keep separate horizontal click gutters.
        min(preferred,quantized(min(cell.width-24,cell.height-35)))
    }

    private static func quantized(_ size: CGFloat) -> CGFloat {
        max(20,min(128,floor(max(0,size)/8)*8))
    }
}
