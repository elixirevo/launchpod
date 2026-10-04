import AppKit
import ApplicationServices
import LaunchpodCore

extension LauncherGestureChoice {
    var title: String {
        switch self {
        case .fourOrFive: return L10n.text("Four or five fingers", "네 손가락 또는 다섯 손가락")
        case .three: return L10n.text("Three fingers", "세 손가락")
        case .five: return L10n.text("Five fingers", "다섯 손가락")
        }
    }
}

/// LaunchOS also observes raw gesture events (29), converts them to NSEvent,
/// and reads touchesMatchingPhase:inView:nil. This event type is undocumented;
/// keep it confined here and fail without affecting normal app input.
final class TrackpadGesture {
    enum Status: Equatable { case off, permissionRequired, listening, unavailable }
    static let settingsChanged = Notification.Name("Launchpod.TrackpadGestureSettingsChanged")
    private let defaults: UserDefaults
    private let permissionAvailable: () -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var recognizer = LauncherGestureSequence()
    private let systemAppsFilter = SystemAppsGestureFilter()
    static let eventMask = (CGEventMask(1) << 29) | (CGEventMask(1) << 30)
    static let eventTapOptions = CGEventTapOptions.defaultTap
    var isFilteringSystemApps: Bool { tap != nil && status == .listening }
    private var touchIDs: [AnyHashable:Int] = [:]
    private var nextTouchID = 0
    private var device: AnyHashable?
    private var generation = 0
    private(set) var status: Status = .off
    var isLauncherShown: () -> Bool = { false }
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    var onStatusChanged: (() -> Void)?
    var enabled: Bool { defaults.object(forKey:"trackpadGestureEnabled") as? Bool ?? true }
    var choice: LauncherGestureChoice {
        LauncherGestureChoice(rawValue:defaults.string(forKey:"trackpadGestureChoice") ?? "") ?? .fourOrFive
    }
    // Match the permission LaunchOS checks before handling raw gestures.
    // Input Monitoring is a different TCC service and must not be advertised
    // as the destination for this Accessibility request.
    static var hasPermission: Bool { AXIsProcessTrusted() }
    init(defaults: UserDefaults = .standard, permissionAvailable: @escaping () -> Bool = { TrackpadGesture.hasPermission }) {
        self.defaults = defaults; self.permissionAvailable = permissionAvailable
    }

    func start() {
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.refresh() })
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in self?.stopListening() })
            workspaceObservers.append(center.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.stopListening() })
            for name in [NSWorkspace.didWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
                workspaceObservers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.refresh() })
            }
        }
        refresh()
    }
    func configure(enabled: Bool, choice: LauncherGestureChoice) {
        defaults.set(enabled,forKey:"trackpadGestureEnabled")
        defaults.set(choice.rawValue,forKey:"trackpadGestureChoice")
        stopListening(); refresh()
    }
    func refresh() {
        guard enabled else { stopListening(); updateStatus(.off); return }
        guard permissionAvailable() else { stopListening(); updateStatus(.permissionRequired); return }
        guard tap == nil else { return }
        recognizer = LauncherGestureSequence(choice:choice)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:Self.eventTapOptions,
                                         eventsOfInterest:Self.eventMask,callback:{ proxy,type,event,context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<TrackpadGesture>.fromOpaque(context).takeUnretainedValue()
            return owner.handleEvent(proxy:proxy,type:type,event:event)
        },userInfo:context), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0) else {
            updateStatus(.unavailable); return
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap:tap,enable:true)
        updateStatus(.listening)
    }
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type.rawValue == 30 {
            let result = systemAppsFilter.filter(event,enabled:enabled && isFilteringSystemApps,launcherShown:isLauncherShown() || recognizer.closesLauncher)
            if let begin = result.replayBegin {
                // Forward the original neutral begin downstream of this tap,
                // before the outward changed/end event. It cannot loop back.
                begin.tapPostEvent(proxy)
            }
            return result.suppress ? nil : Unmanaged.passUnretained(event)
        }
        receive(type:type,event:event)
        return Unmanaged.passUnretained(event)
    }
    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetContacts(); systemAppsFilter.reset(); generation += 1
            if permissionAvailable(), let tap = tap { CGEvent.tapEnable(tap:tap,enable:true) }
            else { stopListening(); updateStatus(.permissionRequired) }
            return
        }
        guard type.rawValue == 29, enabled, let native = NSEvent(cgEvent:event) else { return }
        let touches = native.touches(matching:.touching,in:nil).filter { $0.type == .indirect }
        // Ignore duplicate contacts from another physical trackpad; never
        // combine two devices into one multi-finger gesture.
        let devices = Set(touches.compactMap { $0.device as? AnyHashable })
        if devices.count > 1 { resetContacts(); return }
        if let current = devices.first, current != device { resetContacts(); device = current }
        var points: [LauncherTouch] = []
        for touch in touches {
            guard let identity = touch.identity as? AnyHashable else { resetContacts(); return }
            if touchIDs[identity] == nil { touchIDs[identity] = nextTouchID; nextTouchID += 1 }
            points.append(LauncherTouch(id:touchIDs[identity]!,x:touch.normalizedPosition.x,y:touch.normalizedPosition.y))
        }
        let completed = recognizer.consume(points,time:native.timestamp,launcherShown:isLauncherShown(),cancelled:native.phase.contains(.cancelled))
        if touches.isEmpty { resetContacts() }
        if let completed = completed {
            let expected = generation
            // Never activate a window inside the event tap callback.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == expected, self.enabled, self.status == .listening else { return }
                switch completed {
                case .open: self.onOpen?()
                case .close: self.onClose?()
                }
            }
        }
    }
    private func resetContacts() { recognizer.reset(); touchIDs.removeAll(keepingCapacity:true); nextTouchID = 0; device = nil }
    private func stopListening() {
        generation += 1
        systemAppsFilter.reset()
        if let tap = tap { CGEvent.tapEnable(tap:tap,enable:false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        source = nil; tap = nil; resetContacts()
    }
    func stop() {
        stopListening()
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceObservers = []
        updateStatus(.off)
    }
    private func updateStatus(_ next: Status) {
        guard next != status else { return }
        status = next; onStatusChanged?()
        NotificationCenter.default.post(name:Self.settingsChanged,object:self)
    }
    deinit { stopListening(); observers.forEach(NotificationCenter.default.removeObserver); workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }
}
