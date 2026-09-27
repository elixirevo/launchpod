import AppKit
import LaunchpodCore

extension HotCorner {
    var title: String {
        switch self {
        case .topLeft: return L10n.text("Top left", "왼쪽 위")
        case .topRight: return L10n.text("Top right", "오른쪽 위")
        case .bottomLeft: return L10n.text("Bottom left", "왼쪽 아래")
        case .bottomRight: return L10n.text("Bottom right", "오른쪽 아래")
        }
    }
}

final class HotCornerMonitor {
    private let defaults: UserDefaults
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fallbackTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screens: [NSScreen] = []
    private var screenFrames: [CGRect] = []
    private var trigger = HotCornerTrigger()
    private var started = false
    private var awake = true
    private var sessionActive = true
    private var generation = 0
    private(set) var enabledCorners: Set<HotCorner>
    var canOpen: () -> Bool = { true }
    var onOpen: ((NSScreen) -> Void)?
    var isListening: Bool { globalMonitor != nil || fallbackTimer != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledCorners = Set((defaults.stringArray(forKey:"hotCorners") ?? []).compactMap(HotCorner.init(rawValue:)))
    }

    func configure(corners: Set<HotCorner>) {
        enabledCorners = corners
        defaults.set(HotCorner.allCases.filter { corners.contains($0) }.map(\.rawValue),forKey:"hotCorners")
        refresh()
    }

    func start() {
        guard !started else { return }
        started = true
        screenObserver = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,
            object:nil,queue:.main) { [weak self] _ in self?.resetPosition() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
                guard let self = self else { return }
                switch note.name {
                case NSWorkspace.willSleepNotification: self.awake = false
                case NSWorkspace.didWakeNotification: self.awake = true
                case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive = false
                case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionActive = true
                default: break
                }
                self.refresh()
            })
        }
        refresh()
    }

    private func refresh() {
        stopListening()
        guard started, awake, sessionActive, !enabledCorners.isEmpty else { return }
        resetPosition()
        let mask: NSEvent.EventTypeMask = [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching:mask) { [weak self] _ in self?.samplePosition() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:mask) { [weak self] event in
            self?.samplePosition()
            return event
        }
        // Position sampling also works if AppKit cannot create an event monitor.
        // No keyboard monitoring or Accessibility permission request is needed here.
        if globalMonitor == nil || localMonitor == nil {
            let timer = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in self?.samplePosition() }
            timer.tolerance = 0.02
            RunLoop.main.add(timer,forMode:.common)
            fallbackTimer = timer
        }
    }

    private func resetPosition() {
        generation += 1
        screens = NSScreen.screens
        screenFrames = screens.map(\.frame)
        trigger.reset(at:NSEvent.mouseLocation,screens:screenFrames,enabled:enabledCorners)
    }

    private func samplePosition() {
        let allowed = NSEvent.pressedMouseButtons == 0 && NSApp.modalWindow == nil && canOpen()
        guard let hit = trigger.update(at:NSEvent.mouseLocation,screens:screenFrames,
                                       enabled:enabledCorners,canOpen:allowed) else { return }
        let screen = screens[hit.screenIndex]
        let expected = generation
        // Finish dispatching the current mouse event before changing the key window.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.generation == expected,
                  NSEvent.pressedMouseButtons == 0, NSApp.modalWindow == nil, self.canOpen() else { return }
            self.onOpen?(screen)
        }
    }

    private func stopListening() {
        generation += 1
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        fallbackTimer?.invalidate(); fallbackTimer = nil
        screens = []; screenFrames = []
        trigger = HotCornerTrigger()
    }

    func stop() {
        started = false
        stopListening()
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer); screenObserver = nil }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        awake = true; sessionActive = true
    }
    deinit { stop() }
}
