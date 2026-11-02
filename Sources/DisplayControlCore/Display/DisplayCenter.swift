import Foundation
import CoreGraphics

/// A serializable view of one display, used by the CLI, IPC and the UI.
public struct DisplaySnapshot: Codable, Equatable, Sendable {
    public var key: String
    public var id: UInt32
    public var index: Int
    public var name: String
    public var isBuiltIn: Bool
    public var mode: ControlMode
    public var supported: [DisplayProperty]
    public var values: [String: Int]
    public var settings: DisplaySettings
    public var isSyncHost: Bool
    public var isSyncFollower: Bool
    public var ddcUnreliable: Bool
    public var capabilitiesModel: String?
}

public enum CenterError: Error, CustomStringConvertible, Equatable {
    case displayNotFound(String)
    case ambiguous(String, [String])
    case unsupported(String, DisplayProperty)
    case presetNotFound(String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .displayNotFound(let q): return "No display matches \"\(q)\""
        case .ambiguous(let q, let names): return "\"\(q)\" matches more than one display: \(names.joined(separator: ", "))"
        case .unsupported(let n, let p): return "\(n) does not support \(p.rawValue)"
        case .presetNotFound(let q): return "No preset named \"\(q)\""
        case .invalidValue(let m): return m
        }
    }
}

/// One connected display and its live state.
public actor ManagedDisplay {
    public let info: DisplayInfo
    public private(set) var backend: DisplayBackend
    public private(set) var supported: Set<DisplayProperty> = []
    public private(set) var values: [DisplayProperty: Int] = [:]
    public var settings: DisplaySettings
    public private(set) var unreliable = false

    public init(info: DisplayInfo, backend: DisplayBackend, settings: DisplaySettings) {
        self.info = info; self.backend = backend; self.settings = settings
    }

    public var key: String { info.identity.key }
    public var mode: ControlMode { backend.mode }

    public func setSettings(_ s: DisplaySettings) { settings = s }
    public func markUnreliable(_ v: Bool) { unreliable = v }

    public func probe() async {
        supported = await backend.supported()
        // Read the sliders' starting values once so the window never opens showing zeros.
        for p in [DisplayProperty.brightness, .contrast, .volume] where supported.contains(p) && values[p] == nil {
            if let v = try? await backend.get(p) { values[p] = v }
        }
    }

    /// Reads the live value (used when the popover opens, never on a timer).
    public func refresh(_ property: DisplayProperty) async -> Int? {
        guard supported.contains(property), let v = try? await backend.get(property) else { return values[property] }
        values[property] = v
        return v
    }

    public func refreshCore() async {
        for p in [DisplayProperty.brightness, .contrast, .volume, .boost] where supported.contains(p) { _ = await refresh(p) }
    }

    public func set(_ property: DisplayProperty, to value: Int) async throws {
        guard supported.contains(property) else { throw CenterError.unsupported(info.name, property) }
        var v = value
        if property == .volume { v = min(v, settings.volumeCap) }
        if property.isPercent { v = ValueMapper.clampPercent(v) }
        try await backend.set(property, to: v)
        values[property] = v
    }

    public func replaceBackend(_ new: DisplayBackend) async {
        let old = backend
        backend = new
        values = [:]
        await old.shutdown()
        await probe()
    }

    public func shutdown() async { await backend.shutdown() }
}

/// Owns every display, sync, presets and the settings store. This is the single entry point
/// used by the CLI server, the menu bar UI, schedules and the keyboard layer.
public actor DisplayCenter: PresetTarget {
    private let system: DisplaySystem
    public nonisolated let presets: PresetStore
    public nonisolated let schedules: ScheduleStore
    private let settingsURL: URL
    private let timing: DDCTiming

    private var displays: [String: ManagedDisplay] = [:]
    private var order: [String] = []
    private var settingsByKey: [String: DisplaySettings]
    public private(set) var sync = SyncState()
    private var observers: [UUID: @Sendable (DisplayChange) -> Void] = [:]
    private var topologyObservers: [UUID: @Sendable () -> Void] = [:]
    private var connectionObservers: [UUID: @Sendable (_ key: String, _ connected: Bool) -> Void] = [:]
    private var redetectTasks: [String: Task<Void, Never>] = [:]
    private nonisolated let slots = LatestValueSlots()

    public init(system: DisplaySystem, presets: PresetStore = PresetStore(), schedules: ScheduleStore = ScheduleStore(),
                settingsURL: URL = Paths.displaysFile, timing: DDCTiming = DDCTiming()) {
        self.system = system; self.presets = presets; self.schedules = schedules
        self.settingsURL = settingsURL; self.timing = timing
        self.settingsByKey = AtomicJSON.read([String: DisplaySettings].self, from: settingsURL) ?? [:]
    }

    // MARK: Observation

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (DisplayChange) -> Void) -> UUID {
        let id = UUID(); observers[id] = handler; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil; topologyObservers[id] = nil; connectionObservers[id] = nil }

    /// Called with `connected == true` for a display that appeared and `false` for one that went away.
    @discardableResult
    public func observeConnections(_ handler: @escaping @Sendable (_ key: String, _ connected: Bool) -> Void) -> UUID {
        let id = UUID(); connectionObservers[id] = handler; return id
    }

    @discardableResult
    public func observeTopology(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID(); topologyObservers[id] = handler; return id
    }

    private func emit(_ c: DisplayChange) { for h in observers.values { h(c) } }

    // MARK: Topology

    /// Rebuilds the display list. Existing displays keep their backend and caches.
    public func reload() async {
        let infos = system.currentDisplays()
        var seen = Set<String>()
        var newKeys: [String] = []
        for info in infos {
            // Two identical monitors share a key. The second gets a location hint so that one string is
            // used everywhere: the dictionary key, the identity, saved settings, sync and presets.
            var identity = info.identity
            if seen.contains(identity.key) { identity.locationHint = "\(info.id)" }
            let key = identity.key
            seen.insert(key)
            var fixed = info; fixed.identity = identity
            let settings = settingsByKey[key] ?? DisplaySettings()

            if let existing = displays[key], await existing.info.id == info.id {
                await existing.setSettings(settings)
                continue
            }
            let backend = await system.makeBackend(for: fixed, preferred: settings.preferredMode, timing: timing)
            if let ddc = backend as? DDCBackend {
                await ddc.device.setDoubleWrite(settings.doubleWrite)
            }
            let managed = ManagedDisplay(info: fixed, backend: backend, settings: settings)
            wireUnreliable(backend, managed, key: key, settings: settings)
            await managed.probe()
            if let old = displays[key] { await old.shutdown() }
            displays[key] = managed
            newKeys.append(key)
            Log.registry.info("display \(fixed.name) mode=\(backend.mode.rawValue)")
        }
        for gone in displays.keys where !seen.contains(gone) {
            await displays[gone]?.shutdown()
            displays[gone] = nil
            redetectTasks[gone]?.cancel(); redetectTasks[gone] = nil
            for h in connectionObservers.values { h(gone, false) }
        }
        // Keep a stable order: built-in first, then by display ID.
        var withInfo: [(String, UInt32, Bool)] = []
        for (k, d) in displays { withInfo.append((k, await d.info.id, await d.info.identity.isBuiltIn)) }
        order = withInfo.sorted { ($0.2 ? 0 : 1, $0.1) < ($1.2 ? 0 : 1, $1.1) }.map(\.0)

        for k in newKeys {
            scheduleRedetectIfNeeded(k)
            for h in connectionObservers.values { h(k, true) }
        }
        for h in topologyObservers.values { h() }
    }

    private func wireUnreliable(_ backend: DisplayBackend, _ managed: ManagedDisplay, key: String, settings: DisplaySettings) {
        guard let ddc = backend as? DDCBackend else { return }
        ddc.onUnreliable = { Task { await managed.markUnreliable(true) } }
        // Keep the pre-boost gains in settings so the baseline survives a restart. Set synchronously, before the
        // first read, so a relaunched app already knows it is boosted.
        ddc.gainBaseline = settings.gainBaseline
        ddc.presetBaseline = settings.gainBaselinePreset
        ddc.onBaselineChange = { [weak self] gains, preset in
            Task { await self?.updateSettings(key: key) { $0.gainBaseline = gains; $0.gainBaselinePreset = preset } }
        }
    }

    /// A monitor that just connected often ignores DDC while the link comes up (spec 5.5).
    /// Retry detection at 2, 4 and 8 seconds, but only when it fell back to software on its own.
    private func scheduleRedetectIfNeeded(_ key: String) {
        guard let d = displays[key] else { return }
        redetectTasks[key]?.cancel()
        redetectTasks[key] = Task { [weak self] in
            guard let self else { return }
            guard await d.mode == .software, await d.settings.preferredMode == nil, await !d.info.identity.isBuiltIn else { return }
            for delay in [2, 4, 8] {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                if await self.redetect(key: key) { return }
            }
        }
    }

    /// Re-runs auto-detection. Returns true when it ended up on a hardware backend.
    @discardableResult
    public func redetect(key: String) async -> Bool {
        guard let d = displays[key] else { return false }
        let info = await d.info
        let backend = await system.makeBackend(for: info, preferred: nil, timing: timing)
        guard backend.mode != .software else { return false }
        let current = await d.settings
        wireUnreliable(backend, d, key: key, settings: current)
        await d.replaceBackend(backend)
        for h in topologyObservers.values { h() }
        return true
    }

    // MARK: Queries

    public func snapshots() async -> [DisplaySnapshot] {
        var out: [DisplaySnapshot] = []
        for (i, k) in order.enumerated() {
            guard let d = displays[k] else { continue }
            out.append(await snapshot(of: d, key: k, index: i))
        }
        return out
    }

    private func snapshot(of d: ManagedDisplay, key: String, index: Int) async -> DisplaySnapshot {
        let info = await d.info
        let values = await d.values
        var caps: String?
        if let ddc = await d.backend as? DDCBackend { caps = ddc.capabilities?.model }
        return DisplaySnapshot(
            key: key, id: info.id, index: index,
            name: await d.settings.friendlyName ?? info.name, isBuiltIn: info.identity.isBuiltIn,
            mode: await d.mode, supported: await d.supported.sorted { $0.rawValue < $1.rawValue },
            values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }),
            settings: await d.settings,
            isSyncHost: sync.enabled && sync.hostKey == key,
            isSyncFollower: sync.enabled && sync.hostKey != nil && sync.hostKey != key,
            ddcUnreliable: await d.unreliable, capabilitiesModel: caps)
    }

    public func refreshAll() async {
        for d in displays.values { await d.refreshCore() }
    }

    /// Finds a display by name (exact, then prefix, then substring), `#index`, or identity key.
    public func resolve(_ query: String) async throws -> ManagedDisplay {
        let q = query.lowercased()
        if let i = Int(q.hasPrefix("#") ? String(q.dropFirst()) : q), order.indices.contains(i), q.hasPrefix("#") || Int(q) != nil {
            if let d = displays[order[i]] { return d }
        }
        if let d = displays[query] ?? displays.first(where: { $0.key.lowercased() == q })?.value { return d }
        var names: [(String, ManagedDisplay)] = []
        for k in order { if let d = displays[k] { names.append((await d.settings.friendlyName ?? d.info.name, d)) } }
        for test in [{ (n: String) in n.lowercased() == q }, { $0.lowercased().hasPrefix(q) }, { $0.lowercased().contains(q) }] as [(String) -> Bool] {
            let m = names.filter { test($0.0) }
            if m.count == 1 { return m[0].1 }
            if m.count > 1 { throw CenterError.ambiguous(query, m.map(\.0)) }
        }
        throw CenterError.displayNotFound(query)
    }

    public func key(of d: ManagedDisplay) async -> String { await d.key }

    // MARK: Setting values

    /// Sets one property and, if sync is on and this is the host, propagates to followers.
    public func set(_ display: ManagedDisplay, _ property: DisplayProperty, to value: Int, origin: DisplayChange.Origin = .user) async throws {
        try await display.set(property, to: value)
        let identity = await display.info.identity
        let applied = await display.values[property] ?? value
        emit(DisplayChange(identity: identity, property: property, value: applied, origin: origin))

        guard origin != .sync, sync.enabled, property.isPercent, sync.hostKey == (await display.key) else { return }
        await propagate(property, hostValue: applied, hostKey: await display.key)
    }

    private func propagate(_ property: DisplayProperty, hostValue: Int, hostKey: String) async {
        await withTaskGroup(of: Void.self) { group in
            for (k, f) in displays where k != hostKey {
                group.addTask { [self] in
                    guard await f.supported.contains(property) else { return }
                    let s = await f.settings
                    let mapped = SyncMath.map(host: hostValue, scale: s.syncScale, constant: s.syncConstant)
                    try? await set(f, property, to: mapped, origin: .sync)
                }
            }
        }
    }

    /// Fire-and-forget set for sliders. Synchronous on purpose: values are recorded in call order, so the
    /// newest value for a control always wins, and at most one write per control is in flight.
    /// (Spawning one task per slider tick lets ticks finish out of order, and an old value can land last.)
    public nonisolated func submit(key: String, _ property: DisplayProperty, to value: Int, origin: DisplayChange.Origin = .user) {
        let slot = key + "/" + property.rawValue
        Log.ddc.info("slider submit \(property.rawValue, privacy: .public)=\(value, privacy: .public)")
        if slots.put(slot, Pending(key: key, property: property, value: value, origin: origin)) {
            Task { await self.runSlot(slot) }
        }
    }

    private func runSlot(_ slot: String) async {
        while let p = slots.take(slot) {
            Log.ddc.info("slider send \(p.property.rawValue, privacy: .public)=\(p.value, privacy: .public)")
            do { try await set(try await resolve(p.key), p.property, to: p.value, origin: p.origin) }
            catch { Log.ddc.error("set failed: \(String(describing: error))") }
        }
    }

    /// Waits for every pending slider write (used by tests and by quit).
    public func settle() async {
        while slots.isBusy { try? await Task.sleep(for: .milliseconds(5)) }
        for d in displays.values { if let ddc = await d.backend as? DDCBackend { await ddc.device.waitUntilIdle() } }
    }

    public func set(query: String, _ property: DisplayProperty, to value: Int, origin: DisplayChange.Origin = .user) async throws {
        try await set(try await resolve(query), property, to: value, origin: origin)
    }

    public func setAll(_ property: DisplayProperty, to value: Int, origin: DisplayChange.Origin = .user) async -> [String: String] {
        var errors: [String: String] = [:]
        for k in order {
            guard let d = displays[k], await d.supported.contains(property) else { continue }
            do { try await set(d, property, to: value, origin: origin) }
            catch { errors[k] = String(describing: error) }
        }
        return errors
    }

    /// Relative change in `steps` of the display's step size (used by keys and hotkeys).
    public func adjust(_ display: ManagedDisplay, _ property: DisplayProperty, steps: Int, origin: DisplayChange.Origin = .keyboard) async throws {
        var current = await display.values[property]
        if current == nil { current = await display.refresh(property) }
        let step = max(1, await display.settings.stepSize)
        try await set(display, property, to: (current ?? 50) + steps * step, origin: origin)
    }

    public func displayUnderPointer(_ pointer: CGPoint) async -> ManagedDisplay? {
        for k in order {
            guard let d = displays[k] else { continue }
            if CGDisplayBounds(await d.info.id).contains(pointer) { return d }
        }
        return nil
    }

    public var allDisplays: [ManagedDisplay] { order.compactMap { displays[$0] } }

    // MARK: Resolution helpers for the UI

    public func resolutions(key: String) async -> (current: ResolutionSpec?, all: [ResolutionSpec]) {
        guard let d = displays[key] else { return (nil, []) }
        let id = await d.info.id
        return (system.currentResolution(displayID: id), system.listResolutions(displayID: id))
    }

    // MARK: Settings

    public func updateSettings(key: String, _ change: (inout DisplaySettings) -> Void) async {
        var s = settingsByKey[key] ?? DisplaySettings()
        change(&s)
        settingsByKey[key] = s
        try? AtomicJSON.write(settingsByKey, to: settingsURL)
        if let d = displays[key] {
            await d.setSettings(s)
            if let ddc = await d.backend as? DDCBackend { await ddc.device.setDoubleWrite(s.doubleWrite) }
        }
    }

    public func setMode(key: String, _ mode: ControlMode?) async throws {
        guard let d = displays[key] else { throw CenterError.displayNotFound(key) }
        await updateSettings(key: key) { $0.preferredMode = mode }
        let info = await d.info
        let backend = await system.makeBackend(for: info, preferred: mode, timing: timing)
        if let mode, backend.mode != mode { throw CenterError.invalidValue("\(info.name) does not support \(mode.title)") }
        let current = await d.settings
        wireUnreliable(backend, d, key: key, settings: current)
        await d.replaceBackend(backend)
        for h in topologyObservers.values { h() }
    }

    // MARK: Sync

    public func setSync(enabled: Bool, hostKey: String?) async {
        sync = SyncState(enabled: enabled && hostKey != nil, hostKey: hostKey)
        for h in topologyObservers.values { h() }
        guard sync.enabled, let hk = hostKey, let host = displays[hk] else { return }
        // Align followers with the host immediately.
        if let b = await host.refresh(.brightness) { await propagate(.brightness, hostValue: b, hostKey: hk) }
    }

    public func applySync(_ state: SyncState) async { await setSync(enabled: state.enabled, hostKey: state.hostKey) }

    // MARK: PresetTarget

    public func presentKeys() async -> Set<String> { Set(displays.keys) }

    public func apply(key: String, property: DisplayProperty, value: Int) async throws {
        guard let d = displays[key] else { throw CenterError.displayNotFound(key) }
        try await set(d, property, to: value, origin: .preset)
    }

    public func applyResolution(key: String, _ spec: ResolutionSpec) async throws {
        guard let d = displays[key] else { throw CenterError.displayNotFound(key) }
        try system.setResolution(displayID: await d.info.id, spec)
    }

    public func applyArrangement(key: String, _ spec: ArrangementSpec) async throws {
        guard let d = displays[key] else { throw CenterError.displayNotFound(key) }
        try system.setOrigin(displayID: await d.info.id, x: spec.x, y: spec.y)
    }

    public func applyMode(key: String, _ mode: ControlMode) async throws { try await setMode(key: key, mode) }

    public func activatePreset(_ query: String, delay: Double? = nil) async throws -> [ApplyResult] {
        guard let p = presets.find(query) else { throw CenterError.presetNotFound(query) }
        let wait = delay ?? p.delaySeconds ?? 0
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        return await PresetApplier.apply(p, to: self)
    }

    public func activatePreset(id: UUID) async throws -> [ApplyResult] {
        guard let p = presets.all.first(where: { $0.id == id }) else { throw CenterError.presetNotFound(id.uuidString) }
        if let w = p.delaySeconds, w > 0 { try? await Task.sleep(for: .seconds(w)) }
        return await PresetApplier.apply(p, to: self)
    }

    /// Captures the current state of every display into a new preset (the UI then lets the user untick items).
    public func capturePreset(name: String, icon: String = "sun.max") async -> Preset {
        var items: [DisplayPresetSettings] = []
        for k in order {
            guard let d = displays[k] else { continue }
            var s = DisplayPresetSettings(identityKey: k, displayName: await d.info.name)
            await d.refreshCore()
            let v = await d.values
            s.brightness = v[.brightness]; s.contrast = v[.contrast]; s.volume = v[.volume]
            s.arrangement = system.origin(displayID: await d.info.id)
            s.resolution = system.currentResolution(displayID: await d.info.id)
            items.append(s)
        }
        return Preset(name: name, icon: icon, displays: items, sync: sync.enabled ? sync : nil)
    }

    // MARK: Lifecycle

    /// Restores gamma and releases backends. Safe to call more than once.
    public func shutdown() async {
        for t in redetectTasks.values { t.cancel() }
        for d in displays.values { await d.shutdown() }
        CGDisplayRestoreColorSyncSettings()
    }

    /// Re-applies software dimming after wake or reconfiguration (macOS resets gamma on those events).
    public func reapplySoftwareDimming() async {
        for d in displays.values { if let s = await d.backend as? SoftwareBackend { s.reapply() } }
    }
}


struct Pending: Sendable {
    let key: String
    let property: DisplayProperty
    let value: Int
    let origin: DisplayChange.Origin
}

/// Latest-value-wins slots with a single worker per slot. All state is behind one lock, so `put` is
/// ordered exactly as it is called.
final class LatestValueSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [String: Pending] = [:]
    private var working = Set<String>()

    /// Records the value. Returns true when the caller must start a worker for this slot.
    func put(_ slot: String, _ p: Pending) -> Bool {
        lock.withLock {
            latest[slot] = p
            return working.insert(slot).inserted
        }
    }

    /// Next value to send, or nil (and the worker is released) when none is waiting.
    func take(_ slot: String) -> Pending? {
        lock.withLock {
            if let p = latest.removeValue(forKey: slot) { return p }
            working.remove(slot)
            return nil
        }
    }

    var isBusy: Bool { lock.withLock { !working.isEmpty || !latest.isEmpty } }
}
