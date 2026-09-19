import AppKit

/// Real CGEvent objects are passed directly into the filter, never posted to
/// the system. Captured replay events are inspected without synthesizing input.
enum SystemGestureFilterChecks {
    static func run(outputDirectory: URL) throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain:"SystemGestureFilterChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
            checks += 1
        }
        func event(type: UInt32 = 30, subtype: Int64 = 23, axis: Int64 = 3, phase: Int64 = 1,
                   progress: Double = 0, inverted: Bool = false) -> CGEvent {
            let e = CGEvent(source:nil)!
            e.type = CGEventType(rawValue:type)!
            for (field,value) in [(110,subtype),(123,axis),(132,phase),(136,inverted ? Int64(1) : 0)] {
                e.setIntegerValueField(CGEventField(rawValue:UInt32(field))!,value:value)
            }
            e.setDoubleValueField(CGEventField(rawValue:124)!,value:progress)
            return e
        }
        for inverted in [false,true] {
            let inward = inverted ? 0.2 : -0.2
            let filter = SystemAppsGestureFilter()
            try check(filter.filter(event(inverted:inverted),enabled:true).suppress,"neutral begin never flashes system Apps")
            for (phase,value) in [(Int64(2),inward),(2,inward*2),(2,-inward),(4,0),(4,0),(8,0)] {
                let result = filter.filter(event(phase:phase,progress:value,inverted:inverted),enabled:true)
                try check(result.suppress && result.replayBegin == nil,"claimed inward gesture consumes changes, reversal, end and duplicate end")
            }
            filter.reset()
            let direct = filter.filter(event(progress:inward,inverted:inverted),enabled:true)
            try check(direct.suppress && direct.replayBegin == nil,"nonzero inward begin is consumed immediately")
            filter.reset()
            _ = filter.filter(event(inverted:inverted),enabled:true)
            let outward = filter.filter(event(phase:2,progress:-inward,inverted:inverted),enabled:true)
            try check(!outward.suppress && outward.replayBegin != nil,"Show Desktop receives its held begin before changed")
            try check(outward.replayBegin?.getIntegerValueField(CGEventField(rawValue:132)!) == 1
                      && outward.replayBegin?.getDoubleValueField(CGEventField(rawValue:124)!) == 0,"replayed begin preserves original phase and progress")
            for phase: Int64 in [2,4,4] {
                let next = filter.filter(event(phase:phase,progress:0,inverted:inverted),enabled:true)
                try check(!next.suppress && next.replayBegin == nil,"outward stream and duplicate end pass without duplicate replay")
            }
            try check(filter.filter(event(progress:inward,inverted:inverted),enabled:true).suppress,"next inward begin starts a fresh decision")
        }
        let filter = SystemAppsGestureFilter()
        for axis: Int64 in [1,2,4] {
            for phase: Int64 in [1,2,4,8] {
                try check(!filter.filter(event(axis:axis,phase:phase,progress:-1),enabled:true).suppress,"Spaces, Mission Control and other axes pass")
            }
        }
        for type: UInt32 in [1,5,10,22,29] {
            try check(!filter.filter(event(type:type,progress:-1),enabled:true).suppress,"mouse, keyboard, scroll and raw touch input pass")
        }
        try check(!filter.filter(event(subtype:8,progress:-1),enabled:true).suppress,"ordinary magnification passes")
        try check(!filter.filter(event(phase:2,progress:-1),enabled:true).suppress,"listener starting mid-gesture leaves the active system sequence intact")
        _ = filter.filter(event(),enabled:true)
        let cancel = filter.filter(event(phase:8),enabled:true)
        try check(!cancel.suppress && cancel.replayBegin != nil,"cancel before direction releases a balanced system sequence")
        _ = filter.filter(event(),enabled:true)
        let invalid = filter.filter(event(phase:2,progress:.nan),enabled:true)
        try check(!invalid.suppress && invalid.replayBegin != nil,"unknown values release held input")
        _ = filter.filter(event(progress:-1),enabled:true)
        try check(!filter.filter(event(phase:4),enabled:false).suppress,"disabled feature does not consume input")
        filter.reset()
        try check(!filter.filter(event(phase:2,progress:-1),enabled:true).suppress,"teardown removes the previous route")
        try check(TrackpadGesture.eventTapOptions == .defaultTap,"active tap can actually suppress events")
        try check(TrackpadGesture.eventMask == (CGEventMask(1) << 29) | (CGEventMask(1) << 30),"only raw and system gestures are registered")
        let domain = "app.launchpod.SystemGestureChecks."+UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let monitor = TrackpadGesture(defaults:defaults)
        monitor.start()
        let runtime = String(describing:monitor.status)
        if TrackpadGesture.hasPermission { try check(monitor.isFilteringSystemApps,"authorized native filtering tap starts") }
        else { try check(!monitor.isFilteringSystemApps && monitor.status == .permissionRequired,"missing permission cannot leave a blocking tap") }
        monitor.configure(enabled:false,choice:.fourOrFive)
        try check(!monitor.isFilteringSystemApps && monitor.status == .off,"turning gestures off removes system interception")
        monitor.stop()
        try check(!monitor.isFilteringSystemApps,"app termination removes interception")
        let report = "PASS: \(checks) system gesture interception checks\nNative tap: \(runtime)\nNo system gesture settings changed; no test events were posted. Physical simultaneous Spotlight opening requires a hardware pinch check.\n"
        try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true)
        try report.write(to:outputDirectory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        print(report)
    }
}
