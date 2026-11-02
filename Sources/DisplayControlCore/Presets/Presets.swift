import Foundation

public struct HotKeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
}

public struct ResolutionSpec: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    public var hiDPI: Bool
    public init(width: Int, height: Int, refreshRate: Double, hiDPI: Bool) {
        self.width = width; self.height = height; self.refreshRate = refreshRate; self.hiDPI = hiDPI
    }
}

public struct ArrangementSpec: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// Everything optional: a preset only stores what the user ticked.
public struct DisplayPresetSettings: Codable, Equatable, Sendable {
    public var identityKey: String
    public var displayName: String
    public var brightness: Int?
    public var contrast: Int?
    public var volume: Int?
    public var mute: Bool?
    public var input: Int?
    public var power: Bool?
    public var rotation: Int?
    public var resolution: ResolutionSpec?
    public var arrangement: ArrangementSpec?
    public var mode: ControlMode?
    /// File path of a ColorSync profile, or the empty string for the display's own profile.
    public var colorProfile: String?

    public init(identityKey: String, displayName: String) {
        self.identityKey = identityKey; self.displayName = displayName
    }
}

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var displays: [DisplayPresetSettings]
    public var sync: SyncState?
    /// Dark Mode, Night Shift and True Tone, applied after the display values.
    public var extras: ExtrasPreset?
    public var delaySeconds: Double?
    /// Ease brightness, contrast and volume over this many seconds instead of jumping.
    public var fadeSeconds: Double?
    public var hotkey: HotKeySpec?

    public init(id: UUID = UUID(), name: String, icon: String = "sun.max", displays: [DisplayPresetSettings] = [],
                sync: SyncState? = nil, extras: ExtrasPreset? = nil, delaySeconds: Double? = nil, fadeSeconds: Double? = nil, hotkey: HotKeySpec? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.displays = displays
        self.sync = sync; self.extras = extras; self.delaySeconds = delaySeconds; self.fadeSeconds = fadeSeconds; self.hotkey = hotkey
    }
}

struct PresetFile: Codable { var version: Int = 1; var presets: [Preset] }

/// JSON-backed preset list. Safe to call from any thread.
public final class PresetStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var items: [Preset]

    public init(url: URL = Paths.presetsFile) {
        self.url = url
        self.items = AtomicJSON.read(PresetFile.self, from: url)?.presets ?? []
    }

    public var all: [Preset] { lock.withLock { items } }

    public func find(_ query: String) -> Preset? {
        let q = query.lowercased()
        return lock.withLock {
            items.first { $0.id.uuidString.lowercased() == q } ?? items.first { $0.name.lowercased() == q }
                ?? items.first { $0.name.lowercased().hasPrefix(q) }
        }
    }

    public func upsert(_ preset: Preset) throws {
        try lock.withLock {
            if let i = items.firstIndex(where: { $0.id == preset.id }) { items[i] = preset } else { items.append(preset) }
            try persist()
        }
    }

    public func delete(id: UUID) throws {
        try lock.withLock { items.removeAll { $0.id == id }; try persist() }
    }

    public func move(from: Int, to: Int) throws {
        try lock.withLock {
            guard items.indices.contains(from), items.indices.contains(to) else { return }
            items.insert(items.remove(at: from), at: to)
            try persist()
        }
    }

    private func persist() throws { try AtomicJSON.write(PresetFile(presets: items), to: url) }
}

// MARK: - Applying

public enum ApplyStatus: Equatable, Sendable {
    case applied
    case skippedMissing
    case failed(String)
}

public struct ApplyResult: Equatable, Sendable {
    public var displayKey: String
    public var item: String
    public var status: ApplyStatus
}

/// What the preset applier needs from the display layer.
public protocol PresetTarget: Sendable {
    func presentKeys() async -> Set<String>
    func apply(key: String, property: DisplayProperty, value: Int) async throws
    func applyResolution(key: String, _ spec: ResolutionSpec) async throws
    func applyArrangement(key: String, _ spec: ArrangementSpec) async throws
    func applyMode(key: String, _ mode: ControlMode) async throws
    func applyColorProfile(key: String, path: String?) async throws
    func applySync(_ state: SyncState) async
    func applyExtras(_ extras: ExtrasPreset) async -> [String]
}

public enum PresetApplier {
    /// Applies in the order the spec requires: arrangement, resolution, rotation, power, input,
    /// then brightness/contrast/volume last so values land on an awake display on the right input.
    /// Missing displays are skipped, never fatal. Partial success is reported per item.
    public static func apply(_ preset: Preset, to target: PresetTarget) async -> [ApplyResult] {
        var results: [ApplyResult] = []
        let present = await target.presentKeys()

        func run(_ key: String, _ item: String, _ work: () async throws -> Void) async {
            guard present.contains(key) else {
                results.append(.init(displayKey: key, item: item, status: .skippedMissing)); return
            }
            do { try await work(); results.append(.init(displayKey: key, item: item, status: .applied)) }
            catch { results.append(.init(displayKey: key, item: item, status: .failed(String(describing: error)))) }
        }

        for d in preset.displays { if let a = d.arrangement { await run(d.identityKey, "arrangement") { try await target.applyArrangement(key: d.identityKey, a) } } }
        for d in preset.displays { if let m = d.mode { await run(d.identityKey, "mode") { try await target.applyMode(key: d.identityKey, m) } } }
        for d in preset.displays { if let r = d.resolution { await run(d.identityKey, "resolution") { try await target.applyResolution(key: d.identityKey, r) } } }
        for d in preset.displays { if let c = d.colorProfile { await run(d.identityKey, "color profile") { try await target.applyColorProfile(key: d.identityKey, path: c.isEmpty ? nil : c) } } }
        for d in preset.displays { if let r = d.rotation { await run(d.identityKey, "rotation") { try await target.apply(key: d.identityKey, property: .rotation, value: r) } } }
        for d in preset.displays { if let p = d.power { await run(d.identityKey, "power") { try await target.apply(key: d.identityKey, property: .power, value: p ? 1 : 0) } } }
        for d in preset.displays { if let i = d.input { await run(d.identityKey, "input") { try await target.apply(key: d.identityKey, property: .input, value: i) } } }
        if let s = preset.sync, s.enabled == false { await target.applySync(s) }       // turn sync off before changing values
        for d in preset.displays {
            if let m = d.mute { await run(d.identityKey, "mute") { try await target.apply(key: d.identityKey, property: .mute, value: m ? 1 : 0) } }
            if let v = d.brightness { await run(d.identityKey, "brightness") { try await target.apply(key: d.identityKey, property: .brightness, value: v) } }
            if let v = d.contrast { await run(d.identityKey, "contrast") { try await target.apply(key: d.identityKey, property: .contrast, value: v) } }
            if let v = d.volume { await run(d.identityKey, "volume") { try await target.apply(key: d.identityKey, property: .volume, value: v) } }
        }
        if let s = preset.sync, s.enabled { await target.applySync(s) }                // turn sync on after values are set
        if let e = preset.extras, !e.isEmpty {
            for failed in await target.applyExtras(e) { results.append(.init(displayKey: "system", item: failed, status: .failed("not available on this Mac"))) }
        }
        return results
    }

    public static func summary(_ results: [ApplyResult]) -> (applied: Int, skipped: Int, failed: Int) {
        var a = 0, s = 0, f = 0
        for r in results {
            switch r.status { case .applied: a += 1; case .skippedMissing: s += 1; case .failed: f += 1 }
        }
        return (a, s, f)
    }
}
