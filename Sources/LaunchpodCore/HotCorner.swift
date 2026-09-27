import Foundation
import CoreGraphics

public enum HotCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    private func point(in screen: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x:screen.minX,y:screen.maxY)
        case .topRight: return CGPoint(x:screen.maxX,y:screen.maxY)
        case .bottomLeft: return CGPoint(x:screen.minX,y:screen.minY)
        case .bottomRight: return CGPoint(x:screen.maxX,y:screen.minY)
        }
    }

    fileprivate func contains(_ point: CGPoint, in screen: CGRect, distance: CGFloat) -> Bool {
        let corner = self.point(in:screen)
        // AppKit can report the exact top edge (maxY), which CGRect.contains excludes.
        return point.x >= screen.minX && point.x <= screen.maxX
            && point.y >= screen.minY && point.y <= screen.maxY
            && abs(point.x-corner.x) <= distance && abs(point.y-corner.y) <= distance
    }
}

/// Screen coordinates are AppKit points, including negative display origins.
/// A visit is consumed even when opening is blocked (for example during a drag).
public struct HotCornerTrigger {
    public struct Hit: Equatable {
        public let screenIndex: Int
        public let corner: HotCorner
    }
    private var occupied: Hit?
    public init() {}

    public mutating func reset(at point: CGPoint, screens: [CGRect], enabled: Set<HotCorner>) {
        occupied = hit(at:point,screens:screens,enabled:enabled)
    }

    public mutating func update(at point: CGPoint, screens: [CGRect], enabled: Set<HotCorner>, canOpen: Bool) -> Hit? {
        if let occupied = occupied, screens.indices.contains(occupied.screenIndex),
           screenIndex(at:point,screens:screens) == occupied.screenIndex,
           enabled.contains(occupied.corner),
           occupied.corner.contains(point,in:screens[occupied.screenIndex],distance:12) {
            return nil
        }
        occupied = hit(at:point,screens:screens,enabled:enabled)
        return canOpen ? occupied : nil
    }

    private func hit(at point: CGPoint, screens: [CGRect], enabled: Set<HotCorner>) -> Hit? {
        // Resolve the display before looking at enabled corners. Otherwise a
        // disabled corner could accidentally activate its neighbour's corner.
        guard let index = screenIndex(at:point,screens:screens) else { return nil }
        for corner in HotCorner.allCases where enabled.contains(corner) {
            if corner.contains(point,in:screens[index],distance:2) { return Hit(screenIndex:index,corner:corner) }
        }
        return nil
    }

    private func screenIndex(at point: CGPoint, screens: [CGRect]) -> Int? {
        // AppKit's Y axis is inverted relative to display pixels: the top edge
        // is included, the bottom edge excluded. Shared edges have one owner.
        screens.firstIndex {
            point.x >= $0.minX && point.x < $0.maxX && point.y > $0.minY && point.y <= $0.maxY
        } ?? screens.firstIndex {
            point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY
        }
    }
}
