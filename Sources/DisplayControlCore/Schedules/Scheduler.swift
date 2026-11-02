import Foundation
import AppKit
import IOKit.ps

public enum SystemEvent: Equatable, Sendable {
    case wake, willSleep, lock, unlock, appLaunch
    case appearance(dark: Bool)
    case power(plugged: Bool)
    case monitor(key: String, connected: Bool)
    case clockChanged
}

extension Trigger {
    /// The trigger that marks the end of this one's condition, if the pair is meaningful.
    func ends(on event: SystemEvent) -> Bool {
        switch (self, event) {
        case (.appearanceDark, .appearance(let dark)): return !dark
        case (.appearanceLight, .appearance(let dark)): return dark
        case (.powerPlugged, .power(let plugged)): return !plugged
        case (.powerBattery, .power(let plugged)): return plugged
        case (.lock, .unlock): return true
        case (.unlock, .lock): return true
        case (.monitorConnected(let k), .monitor(let key, let connected)): return !connected && (k == nil || k == key)
        default: return false
        }
    }

    func starts(on event: SystemEvent) -> Bool {
        switch (self, event) {
        case (.wake, .wake), (.lock, .lock), (.unlock, .unlock), (.appLaunch, .appLaunch): return true
        case (.appearanceDark, .appearance(let dark)): return dark
        case (.appearanceLight, .appearance(let dark)): return !dark
        case (.powerPlugged, .power(let plugged)): return plugged
        case (.powerBattery, .power(let plugged)): return !plugged
        case (.monitorConnected(let k), .monitor(let key, let connected)): return connected && (k == nil || k == key)
        case (.monitorDisconnected(let k), .monitor(let key, let connected)): return !connected && (k == nil || k == key)
        default: return false
        }
    }
}

/// Runs schedules. Timed triggers use one one-shot timer for the earliest fire time; event triggers
/// use system notifications that are installed only while at least one enabled schedule needs them.
public actor Scheduler {
    private let center: DisplayCenter
    private var calendar: Calendar
    private var timerTask: Task<Void, Never>?
    private var lastActive = Date()
    private var armed = false
    private var eventSource: SystemEventSource?
    private var connectionToken: UUID?
    private var lastPower: Bool?
    private var lastDark: Bool?
    public var missedWindow: TimeInterval = 7200
    /// Called on the main actor path when the scheduler wants a location lookup (no coordinates stored).
    public var onNeedLocation: (@Sendable () -> Void)?

    public init(center: DisplayCenter, calendar: Calendar = .current) {
        self.center = center; self.calendar = calendar
    }

    public func setNeedLocationHandler(_ h: (@Sendable () -> Void)?) { onNeedLocation = h }

    /// Begins listening. Call after the first `DisplayCenter.reload()` so startup does not look like a hotplug.
    public func start() async {
        armed = true
        connectionToken = await center.observeConnections { [weak self] key, connected in
            guard let self else { return }
            Task { await self.handle(.monitor(key: key, connected: connected)) }
        }
        await reconfigure()
        await handle(.appLaunch)
    }

    public func stop() async {
        timerTask?.cancel(); timerTask = nil
        eventSource?.stop(); eventSource = nil
        if let t = connectionToken { await center.removeObserver(t); connectionToken = nil }
        armed = false
    }

    /// Call whenever schedules change (add, edit, enable, disable) or the location changes.
    public func reconfigure() async {
        let enabled = center.schedules.all.filter(\.enabled)
        // Event sources only when something needs them.
        let needsEvents = !enabled.isEmpty                       // timers also need wake and clock-change events
        if needsEvents, eventSource == nil {
            let src = SystemEventSource { [weak self] e in
                guard let self else { return }
                Task { await self.handle(e) }
            }
            src.start()
            eventSource = src
            lastPower = SystemEventSource.currentlyPlugged()
        } else if !needsEvents { eventSource?.stop(); eventSource = nil }
        scheduleNextTimer()
    }

    // MARK: Timers

    private func scheduleNextTimer() {
        timerTask?.cancel(); timerTask = nil
        let loc = center.schedules.location
        let now = Date()
        var best: (Date, [Schedule])?
        for s in center.schedules.all where s.enabled && s.trigger.isTimed {
            if (s.trigger.needsLocation) && loc == nil { onNeedLocation?(); continue }
            guard let d = NextFire.date(for: s.trigger, after: now, calendar: calendar, location: loc) else { continue }
            if best == nil || d < best!.0 { best = (d, [s]) }
            else if let b = best, abs(d.timeIntervalSince(b.0)) < 1 { best = (b.0, b.1 + [s]) }
        }
        guard let (fire, due) = best else { return }
        let delay = max(0, fire.timeIntervalSinceNow)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.fire(due)
        }
    }

    private func fire(_ due: [Schedule]) async {
        lastActive = Date()
        for s in due where s.enabled { await run(presetID: s.presetID, why: s.name) }
        scheduleNextTimer()
    }

    private func run(presetID: UUID, why: String) async {
        Log.schedule.info("running preset for schedule \(why)")
        _ = try? await center.activatePreset(id: presetID)
    }

    // MARK: Events

    public func handle(_ event: SystemEvent) async {
        guard armed else { return }
        switch event {
        case .willSleep:
            lastActive = Date(); return
        case .clockChanged:
            scheduleNextTimer(); return
        case .wake:
            await runMissed()
            scheduleNextTimer()
        case .power(let plugged):
            if lastPower == plugged { return }
            lastPower = plugged
        case .appearance(let dark):
            if lastDark == dark { return }
            lastDark = dark
        default: break
        }
        for s in center.schedules.all where s.enabled {
            if s.trigger.starts(on: event) { await run(presetID: s.presetID, why: s.name) }
            else if let end = s.endPresetID, s.trigger.ends(on: event) { await run(presetID: end, why: s.name + " (end)") }
        }
    }

    /// Spec F45: run the most recent missed timed schedule once, if it is within the window.
    private func runMissed() async {
        let now = Date()
        let loc = center.schedules.location
        var latest: (Date, Schedule)?
        for s in center.schedules.all where s.enabled && s.trigger.isTimed {
            if let d = NextFire.missedFire(for: s.trigger, since: lastActive, now: now, window: missedWindow, calendar: calendar, location: loc),
               latest == nil || d > latest!.0 { latest = (d, s) }
        }
        lastActive = now
        if let (_, s) = latest { await run(presetID: s.presetID, why: s.name + " (missed)") }
    }
}

extension Trigger {
    var needsLocation: Bool {
        switch self { case .sunrise, .sunset: return true; default: return false }
    }
}

/// Installs system observers. Everything here is event driven; nothing polls.
public final class SystemEventSource: @unchecked Sendable {
    private let emit: @Sendable (SystemEvent) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var powerBox: Unmanaged<Box>?

    public init(emit: @escaping @Sendable (SystemEvent) -> Void) { self.emit = emit }

    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [emit] _ in emit(.wake) })
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [emit] _ in emit(.willSleep) })
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil) { [emit] _ in emit(.clockChanged) })
        tokens.append(nc.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { [emit] _ in emit(.clockChanged) })

        let dn = DistributedNotificationCenter.default()
        distributed.append(dn.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [emit] _ in emit(.lock) })
        distributed.append(dn.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [emit] _ in emit(.unlock) })
        distributed.append(dn.addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: nil) { [emit] _ in
            emit(.appearance(dark: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"))
        })

        // Power source changes (plugged in vs battery).
        let retained = Unmanaged.passRetained(Box(emit))
        powerBox = retained
        let ctx = retained.toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().emit(.power(plugged: SystemEventSource.currentlyPlugged()))
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
    }

    final class Box { let emit: @Sendable (SystemEvent) -> Void; init(_ e: @escaping @Sendable (SystemEvent) -> Void) { emit = e } }

    public func stop() {
        let ws = NSWorkspace.shared.notificationCenter
        for t in tokens { ws.removeObserver(t); NotificationCenter.default.removeObserver(t) }
        for t in distributed { DistributedNotificationCenter.default().removeObserver(t) }
        tokens = []; distributed = []
        if let s = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode); powerSource = nil }
        powerBox?.release(); powerBox = nil
    }

    /// True on AC power (or on a desktop with no battery).
    public static func currentlyPlugged() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type != kIOPMBatteryPowerKey
    }
}
