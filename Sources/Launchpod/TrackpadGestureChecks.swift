import AppKit
import LaunchpodCore

enum TrackpadGestureChecks {
    static func run(outputDirectory: URL) throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain:"TrackpadGestureChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
            checks += 1
        }
        func hand(_ count: Int, radius: Double = 0.25, dx: Double = 0, dy: Double = 0, rotation: Double = 0) -> [LauncherTouch] {
            (0..<count).map { index in
                let angle = Double(index)*2*Double.pi/Double(count)+rotation
                return LauncherTouch(id:index,x:0.5+dx+radius*cos(angle),y:0.5+dy+radius*sin(angle))
            }
        }
        for choice in LauncherGestureChoice.allCases {
            for fingers in 1...5 {
                var detector = LauncherPinch(choice:choice)
                try check(!detector.consume(hand(fingers),time:0),"initial contact must not open")
                let opened = detector.consume(hand(fingers,radius:0.16),time:0.12)
                try check(opened == choice.accepts(fingers),"only the selected finger count opens: \(choice), \(fingers)")
                try check(!detector.consume(hand(fingers,radius:0.10),time:0.2),"same gesture cannot open twice")
                try check(!detector.consume([],time:0.25),"lifting all fingers does not open")
                _ = detector.consume(hand(fingers),time:0.3)
                try check(detector.consume(hand(fingers,radius:0.16),time:0.4) == choice.accepts(fingers),"a new hand contact rearms detection")
            }
        }
        for count in [3,4,5] {
            let choice: LauncherGestureChoice = count == 3 ? .three : .fourOrFive
            for sample in [hand(count,radius:0.26),hand(count,radius:0.247),hand(count,dx:0.14),hand(count,dy:0.14),hand(count,rotation:0.4)] {
                var detector = LauncherPinch(choice:choice)
                _ = detector.consume(hand(count),time:0)
                try check(!detector.consume(sample,time:0.1),"outward pinch, small jitter, translation and rotation are ignored")
            }
            var detector = LauncherPinch(choice:choice)
            _ = detector.consume(hand(count),time:0)
            var single = hand(count); single[0] = LauncherTouch(id:0,x:0.50,y:0.50)
            try check(!detector.consume(single,time:0.1),"one finger moving toward resting fingers does not open")
            _ = detector.consume(hand(count),time:0.2,cancelled:true)
            try check(!detector.consume(hand(count,radius:0.1),time:0.3),"cancelled gesture stays blocked")
            detector.reset(); _ = detector.consume(hand(count),time:0)
            try check(!detector.consume(hand(count,radius:0.1),time:1),"stale touch frame does not trigger")
            try check(!detector.consume(hand(count,radius:0.09),time:0.8),"time reversal restarts baseline")
            detector.reset(); _ = detector.consume(hand(count),time:0)
            let replacement = hand(count,radius:0.1).map { LauncherTouch(id:$0.id+20,x:$0.x,y:$0.y) }
            try check(!detector.consume(replacement,time:0.1),"replaced contacts must establish a new baseline")
            detector.reset(); _ = detector.consume(hand(count),time:0)
            try check(detector.consume(Array(hand(count,radius:0.1).reversed()),time:0.1),"touch ordering does not affect recognition")
        }
        for invalid in [LauncherTouch(id:0,x:.nan,y:0.5),LauncherTouch(id:0,x:.infinity,y:0.5),LauncherTouch(id:0,x:2,y:0.5)] {
            var detector = LauncherPinch()
            var points = hand(4); points[0] = invalid
            try check(!detector.consume(points,time:0),"invalid touch coordinates fail closed")
            try check(!detector.consume(hand(4,radius:0.1),time:0.1),"invalid frame cannot leave an armed baseline")
        }
        var detector = LauncherPinch()
        _ = detector.consume(hand(4),time:0)
        try check(!detector.consume(hand(5,radius:0.17),time:0.1),"adding a fifth finger resets the distance baseline")
        try check(detector.consume(hand(5,radius:0.1),time:0.2),"five-finger contraction can then open")
        _ = detector.consume(hand(4),time:0.3)
        try check(!detector.consume(hand(4,radius:0.1),time:0.4),"lifting one finger after opening cannot rearm")
        _ = detector.consume([],time:0.5)
        _ = detector.consume(hand(4),time:0.6)
        _ = detector.consume(hand(4,dx:0.15),time:0.7)
        try check(!detector.consume(hand(4,radius:0.1),time:0.8),"swipe cannot become a pinch mid-contact")
        // Isolated preferences; this path never asks for or grants permissions.
        let domain = "app.launchpod.GestureChecks."+UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let monitor = TrackpadGesture(defaults:defaults)
        try check(monitor.enabled && monitor.choice == .fourOrFive,"default is four or five fingers")
        monitor.configure(enabled:false,choice:.three)
        try check(monitor.status == .off,"disabled gesture does not listen")
        let restored = TrackpadGesture(defaults:defaults)
        try check(!restored.enabled && restored.choice == .three,"enabled state and finger count persist")
        monitor.configure(enabled:true,choice:.five)
        let runtime = String(describing:monitor.status)
        if !TrackpadGesture.hasPermission { try check(monitor.status == .permissionRequired,"permission denial is reported without requesting access") }
        else { try check(monitor.status == .listening,"authorized native event tap starts") }
        monitor.start(); monitor.start()
        try check(monitor.status == (TrackpadGesture.hasPermission ? .listening : .permissionRequired),"repeated start remains stable")
        monitor.stop(); monitor.stop()
        try check(monitor.status == .off,"repeated stop removes the listener safely")
        monitor.configure(enabled:false,choice:.fourOrFive)
        try check(monitor.status == .off,"disabling remains effective after stop")
        let denied = TrackpadGesture(defaults:defaults,permissionAvailable:{ false })
        denied.configure(enabled:true,choice:.three)
        try check(denied.status == .permissionRequired,"missing permission never creates a tap")
        denied.start(); denied.start()
        try check(denied.status == .permissionRequired,"permission denial remains stable across refresh")
        denied.configure(enabled:false,choice:.three)
        try check(denied.status == .off,"gesture can be disabled before permission is granted")
        denied.stop()
        let report = "PASS: \(checks) gesture checks\nNative listener status: \(runtime)\nOnly pinch recognition, false-positive rejection, one-shot/rearm, saved settings and listener lifecycle were tested.\nPhysical trackpad pinch input must be checked on a permission-enabled installation. No gesture events were injected into the system.\n"
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        print(report)
    }
}
