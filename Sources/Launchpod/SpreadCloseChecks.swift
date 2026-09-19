import AppKit
import LaunchpodCore

/// In-memory touch/CGEvent sequences only; no global listener or event posting.
enum SpreadCloseChecks {
    static func run(outputDirectory: URL) throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain:"SpreadCloseChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
            checks += 1
        }
        func hand(_ count: Int, radius: Double = 0.16, dx: Double = 0, rotation: Double = 0) -> [LauncherTouch] {
            (0..<count).map { i in
                let angle = Double(i)*2*Double.pi/Double(count)+rotation
                return LauncherTouch(id:i,x:0.5+dx+radius*cos(angle),y:0.5+radius*sin(angle))
            }
        }
        for choice in LauncherGestureChoice.allCases {
            for count in 1...5 {
                var sequence = LauncherGestureSequence(choice:choice)
                try check(sequence.consume(hand(count),time:0,launcherShown:true) == nil,"first contact does not close")
                try check(sequence.consume(hand(count,radius:0.24),time:0.1,launcherShown:true) == (choice.accepts(count) ? .close : nil),"only selected finger counts close")
                try check(sequence.consume(hand(count,radius:0.28),time:0.2,launcherShown:false) == nil,"closing does not repeat after visibility changes")
                try check(sequence.consume(hand(count,radius:0.1),time:0.3,launcherShown:false) == nil,"reversal cannot reopen within the same contact sequence")
                _ = sequence.consume([],time:0.4,launcherShown:false)
                _ = sequence.consume(hand(count,radius:0.25),time:0.5,launcherShown:false)
                try check(sequence.consume(hand(count),time:0.6,launcherShown:false) == (choice.accepts(count) ? .open : nil),"lifting rearms inward opening")
                try check(sequence.consume(hand(count,radius:0.3),time:0.7,launcherShown:true) == nil,"opening cannot immediately close from the same hand")
            }
        }
        for count in [3,4,5] {
            let choice: LauncherGestureChoice = count == 3 ? .three : .fourOrFive
            var oneMoving = hand(count)
            oneMoving[0] = LauncherTouch(id:0,x:0.98,y:0.5)
            for sample in [hand(count,radius:0.10),hand(count,radius:0.17),hand(count,dx:0.14),hand(count,rotation:0.4),oneMoving] {
                var sequence = LauncherGestureSequence(choice:choice)
                _ = sequence.consume(hand(count),time:0,launcherShown:true)
                try check(sequence.consume(sample,time:0.1,launcherShown:true) == nil,"inward, jitter, translation, rotation and single finger do not close")
            }
            var sequence = LauncherGestureSequence(choice:choice)
            _ = sequence.consume(hand(count),time:0,launcherShown:true)
            try check(sequence.consume(Array(hand(count,radius:0.25).reversed()),time:0.1,launcherShown:true) == .close,"touch ordering does not affect spread")
            sequence.reset()
            _ = sequence.consume(hand(count),time:0,launcherShown:true)
            try check(sequence.consume(hand(count,radius:0.25),time:0.1,launcherShown:true,cancelled:true) == nil,"cancel cannot close")
            try check(sequence.consume(hand(count,radius:0.3),time:0.2,launcherShown:true) == nil,"cancel stays latched")
            sequence.reset()
            _ = sequence.consume(hand(count),time:0,launcherShown:true)
            try check(sequence.consume(hand(count,radius:0.25),time:1,launcherShown:true) == nil,"stale frame starts a fresh baseline")
            sequence.reset()
            _ = sequence.consume(hand(count),time:0,launcherShown:false)
            try check(sequence.consume(hand(count,radius:0.25),time:0.1,launcherShown:false) == nil,"hidden outward gesture leaves launcher alone")
        }
        func event(phase: Int64 = 1, progress: Double = 0, inverted: Bool = false, axis: Int64 = 3) -> CGEvent {
            let event = CGEvent(source:nil)!
            event.type = CGEventType(rawValue:30)!
            for (field,value) in [(110,Int64(23)),(123,axis),(132,phase),(136,inverted ? Int64(1) : 0)] {
                event.setIntegerValueField(CGEventField(rawValue:UInt32(field))!,value:value)
            }
            event.setDoubleValueField(CGEventField(rawValue:124)!,value:progress)
            return event
        }
        for inverted in [false,true] {
            let outward = inverted ? -0.2 : 0.2
            let filter = SystemAppsGestureFilter()
            try check(filter.filter(event(inverted:inverted),enabled:true,launcherShown:true).suppress,"visible neutral begin is held")
            // Visibility may already be false before the first directional frame.
            for (phase,progress) in [(Int64(2),outward),(2,outward*2),(2,-outward),(4,0),(4,0),(8,0)] {
                let result = filter.filter(event(phase:phase,progress:progress,inverted:inverted),enabled:true,launcherShown:false)
                try check(result.suppress && result.replayBegin == nil,"close owns direction, reversal and tail after hiding")
            }
            _ = filter.filter(event(inverted:inverted),enabled:true,launcherShown:false)
            let hidden = filter.filter(event(phase:2,progress:outward,inverted:inverted),enabled:true,launcherShown:true)
            try check(!hidden.suppress && hidden.replayBegin != nil,"a new hidden gesture stays with Show Desktop even if visibility changes")
            try check(!filter.filter(event(phase:4,inverted:inverted),enabled:true,launcherShown:true).suppress,"system outward end passes")
            try check(filter.filter(event(progress:outward,inverted:inverted),enabled:true,launcherShown:true).suppress,"direct outward begin closes without replay")
            try check(filter.filter(event(progress:-outward,inverted:inverted),enabled:true,launcherShown:false).suppress,"inward Apps interception preserved")
            filter.reset()
            try check(!filter.filter(event(phase:2,progress:outward,inverted:inverted),enabled:true,launcherShown:true).suppress,"midstream install does not steal end")
            _ = filter.filter(event(inverted:inverted),enabled:true,launcherShown:true)
            let cancel = filter.filter(event(phase:8,inverted:inverted),enabled:true,launcherShown:true)
            try check(!cancel.suppress && cancel.replayBegin != nil,"neutral cancellation releases held begin")
            try check(!filter.filter(event(progress:outward,inverted:inverted),enabled:false,launcherShown:true).suppress,"disabled gestures do not intercept")
            for axis: Int64 in [1,2,4] {
                try check(!filter.filter(event(progress:outward,inverted:inverted,axis:axis),enabled:true,launcherShown:true).suppress,"other system axes unaffected while visible")
            }
            // Raw touches can deliver close before the Dock stream begins.
            var sequence = LauncherGestureSequence()
            _ = sequence.consume(hand(4),time:0,launcherShown:true)
            _ = sequence.consume(hand(4,radius:0.25),time:0.1,launcherShown:true)
            try check(filter.filter(event(progress:outward,inverted:inverted),enabled:true,launcherShown:sequence.closesLauncher).suppress,"active raw close retains ownership when Dock begin arrives after hiding")
        }
        let report = "PASS: \(checks) spread-to-close checks\nTouch recognition, visibility ownership, open/close rearming, and system gesture filtering only.\nNo test events posted; physical trackpad close still requires a hardware check.\n"
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        print(report)
    }
}
