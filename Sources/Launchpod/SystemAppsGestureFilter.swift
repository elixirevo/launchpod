import CoreGraphics

/// The Dock's pinch stream is distinct from raw touches (29) and ordinary
/// two-finger magnification. Field numbers are confined to this Tahoe adapter.
final class SystemAppsGestureFilter {
    struct Result {
        let suppress: Bool
        var replayBegin: CGEvent? = nil
    }
    private enum Route { case idle, waitingForDirection, system, launchpod }
    private var route: Route = .idle
    private var pendingBegin: CGEvent?
    private var claimOutward = false
    func reset() { route = .idle; pendingBegin = nil; claimOutward = false }

    func filter(_ event: CGEvent, enabled: Bool, launcherShown: Bool = false) -> Result {
        guard enabled else { reset(); return Result(suppress:false) }
        guard event.type.rawValue == 30,
              event.getIntegerValueField(CGEventField(rawValue:110)!) == 23,
              event.getIntegerValueField(CGEventField(rawValue:123)!) == 3 else { return Result(suppress:false) }
        // IOHID gesture phases: began=1, changed=2, ended=4, cancelled=8.
        let phase = event.getIntegerValueField(CGEventField(rawValue:132)!)
        let began = phase & 1 != 0, terminal = phase & 12 != 0
        if began {
            reset(); route = .waitingForDirection
            // Preserve ownership even after the close callback hides Launchpod.
            claimOutward = launcherShown
        }
        // Installing a listener midway through a gesture must not steal its end.
        if route == .idle || route == .system { return Result(suppress:false) }
        // Once claimed, consume the complete sequence, including reversal and
        // duplicate terminal frames; leaking the end can still launch Spotlight.
        if route == .launchpod { return Result(suppress:true) }
        let progress = event.getDoubleValueField(CGEventField(rawValue:124)!)
        let inverted = event.getIntegerValueField(CGEventField(rawValue:136)!) & 1 != 0
        // LaunchOS c2e60/c2e74/c3748: positive after inversion means pinch-in.
        let inward = inverted ? progress : -progress
        if inward.isFinite && (inward > 0 || (inward < 0 && claimOutward)) {
            pendingBegin = nil; route = .launchpod
            return Result(suppress:true)
        }
        if inward.isFinite && inward == 0 && !terminal {
            // A neutral begin can reveal the system UI before touch recognition.
            // Hold it until direction is known, with bounded storage.
            if began { pendingBegin = event.copy() }
            return Result(suppress:true)
        }
        // Outward pinch while hidden (Show Desktop), cancelled neutral input, or unknown
        // values keep the original system stream, including its held begin.
        let replay = pendingBegin
        pendingBegin = nil; route = .system
        return Result(suppress:false,replayBegin:replay)
    }
}
