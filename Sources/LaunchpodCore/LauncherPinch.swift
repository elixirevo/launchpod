import Foundation

public enum LauncherGestureChoice: String, CaseIterable {
    case fourOrFive, three, five
    public func accepts(_ count: Int) -> Bool {
        switch self {
        case .fourOrFive: return count == 4 || count == 5
        case .three: return count == 3
        case .five: return count == 5
        }
    }
}

public struct LauncherTouch {
    public let id: Int
    public let x: Double
    public let y: Double
    public init(id: Int, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// Track pairwise distance changes and latch until every finger lifts.
public struct LauncherPinch {
    public enum Direction { case inward, outward }
    public var choice: LauncherGestureChoice
    private let direction: Direction
    private var baseline: [LauncherTouch] = []
    private var baselineSpread = 0.0
    private var blocked = false
    private var lastTime: Double?
    public init(choice: LauncherGestureChoice = .fourOrFive, direction: Direction = .inward) {
        self.choice = choice; self.direction = direction
    }
    public mutating func reset() { baseline = []; baselineSpread = 0; blocked = false; lastTime = nil }

    public mutating func consume(_ touches: [LauncherTouch], time: Double, cancelled: Bool = false) -> Bool {
        guard time.isFinite else { reset(); return false }
        if cancelled { baseline = []; blocked = true; lastTime = time; return false }
        if touches.isEmpty { reset(); return false }
        if let lastTime = lastTime, time < lastTime || time-lastTime > 0.8 { reset() }
        lastTime = time
        guard !blocked else { return false }
        guard touches.count <= 5, touches.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(touches.map(\.id)).count == touches.count else { blocked = true; return false }
        guard choice.accepts(touches.count) else {
            // Adding fingers before recognition is normal; losing fingers after
            // tracking starts ends this attempt until the hand leaves the pad.
            if !baseline.isEmpty { blocked = true }
            return false
        }
        let current = touches.sorted { $0.id < $1.id }
        guard current.map(\.id) == baseline.map(\.id) else {
            baseline = current; baselineSpread = Self.spread(current); return false
        }
        let before = Self.center(baseline), after = Self.center(current)
        guard hypot(after.x-before.x,after.y-before.y) < 0.12 else { blocked = true; return false }
        guard baselineSpread > 0.06 else { return false }
        let spread = Self.spread(current)
        let sign = direction == .inward ? 1.0 : -1.0
        guard (baselineSpread-spread)*sign >= max(0.025,baselineSpread*0.20) else { return false }
        // Require a majority to move in the requested radial direction relative
        // to the original centroid; one moving finger must not trigger it.
        let approaching = zip(baseline,current).filter { original, moved in
            (hypot(original.x-before.x,original.y-before.y)-hypot(moved.x-before.x,moved.y-before.y))*sign > 0.01
        }.count
        guard approaching >= max(3,(current.count+1)/2) else { return false }
        blocked = true
        return true
    }
    private static func center(_ touches: [LauncherTouch]) -> (x: Double,y: Double) {
        (touches.reduce(0) { $0+$1.x }/Double(touches.count),touches.reduce(0) { $0+$1.y }/Double(touches.count))
    }
    private static func spread(_ touches: [LauncherTouch]) -> Double {
        var total = 0.0, pairs = 0
        for i in touches.indices {
            for j in touches.indices where j > i {
                total += hypot(touches[i].x-touches[j].x,touches[i].y-touches[j].y); pairs += 1
            }
        }
        return pairs > 0 ? total/Double(pairs) : 0
    }
}

/// Snapshot visibility at first contact so showing/hiding during recognition
/// cannot change the action or retrigger its opposite before the hand lifts.
public struct LauncherGestureSequence {
    public enum Action { case open, close }
    private let choice: LauncherGestureChoice
    private var recognizer: LauncherPinch
    private var action: Action?
    public var closesLauncher: Bool { action == .close }
    public init(choice: LauncherGestureChoice = .fourOrFive) {
        self.choice = choice; recognizer = LauncherPinch(choice:choice)
    }
    public mutating func reset() { action = nil; recognizer.reset() }
    public mutating func consume(_ touches: [LauncherTouch], time: Double, launcherShown: Bool, cancelled: Bool = false) -> Action? {
        if action == nil && !touches.isEmpty {
            action = launcherShown ? .close : .open
            recognizer = LauncherPinch(choice:choice,direction:launcherShown ? .outward : .inward)
        }
        let completed = recognizer.consume(touches,time:time,cancelled:cancelled)
        let result = completed ? action : nil
        if touches.isEmpty { reset() }
        return result
    }
}
