import SwiftUI
import AppKit
import DisplayControlCore
import ServiceManagement

/// Bridges the display core to SwiftUI. All state here is a cache of what the core reports;
/// the core stays the source of truth.
@MainActor
final class AppModel: ObservableObject {
    @Published var displays: [DisplaySnapshot] = []
    @Published var presets: [Preset] = []
    @Published var schedules: [Schedule] = []
    @Published var sync = SyncState()
    @Published var banner: String?
    @Published var lastPresetSummary: String?
    @Published var settings = AppSettings()
    @Published var accessibilityGranted = MediaKeyTap.hasPermission
    @Published var keyTapRunning = false
    @Published var selfTest: SelfTestReport?
    @Published var runningSelfTest = false

    let center: DisplayCenter
    let settingsStore: SettingsStore
    var onSettingsChanged: (() -> Void)?
    var onSchedulesChanged: (() -> Void)?
    var onPresetsChanged: (() -> Void)?
    private var reloadTask: Task<Void, Never>?

    init(center: DisplayCenter, settings: SettingsStore) {
        self.center = center
        self.settingsStore = settings
        self.settings = settings.current
    }

    // MARK: Loading

    func reload() async {
        displays = await center.snapshots()
        presets = center.presets.all
        schedules = center.schedules.all
        sync = await center.sync
        settings = settingsStore.current
        accessibilityGranted = MediaKeyTap.hasPermission
    }

    /// Reads live values from the monitors. Called when the popover opens, never on a timer.
    func refreshLive() async {
        await center.refreshAll()
        await reload()
    }

    /// Coalesces bursts of change events into one reload.
    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            await self?.reload()
        }
    }

    // MARK: Values

    func value(_ key: String, _ property: DisplayProperty) -> Int {
        displays.first { $0.key == key }?.values[property.rawValue] ?? 0
    }

    /// Slider changes: update the UI immediately, send to the monitor through the coalescing queue.
    func setValue(_ key: String, _ property: DisplayProperty, _ value: Int) {
        if let i = displays.firstIndex(where: { $0.key == key }) { displays[i].values[property.rawValue] = value }
        center.submit(key: key, property, to: value)        // synchronous, ordered, newest value wins
    }

    func setMode(_ key: String, _ mode: ControlMode?) {
        Task {
            do { try await center.setMode(key: key, mode); banner = nil }
            catch { banner = String(describing: error) }
            await reload()
        }
    }

    func toggleSync(host key: String) {
        Task {
            if sync.enabled { await center.setSync(enabled: false, hostKey: nil) }
            else { await center.setSync(enabled: true, hostKey: key) }
            await reload()
        }
    }

    func setSyncOffset(_ key: String, followerAtHost100 v: Int) {
        Task {
            await center.updateSettings(key: key) { $0.syncScale = SyncMath.scale(followerAtHost100: v); $0.syncConstant = 0 }
            await reload()
        }
    }

    func updateSettings(_ key: String, _ change: @escaping @Sendable (inout DisplaySettings) -> Void) {
        Task { await center.updateSettings(key: key, change); await reload() }
    }

    func run(selfTestFor key: String) {
        runningSelfTest = true
        Task {
            if let d = try? await center.resolve(key) { selfTest = await SelfTest.run(d) }
            runningSelfTest = false
            await reload()
        }
    }

    // MARK: Presets

    func activate(_ preset: Preset) {
        Task {
            do {
                let results = try await center.activatePreset(id: preset.id)
                let s = PresetApplier.summary(results)
                lastPresetSummary = s.failed > 0 ? "\(preset.name): \(s.failed) item(s) failed" :
                    s.skipped > 0 ? "\(preset.name): applied, \(s.skipped) skipped (display not connected)" : nil
            } catch { banner = String(describing: error) }
            await reload()
        }
    }

    func savePreset(_ p: Preset) {
        try? center.presets.upsert(p)
        onPresetsChanged?()
        Task { await reload() }
    }

    func deletePreset(_ p: Preset) {
        try? center.presets.delete(id: p.id)
        onPresetsChanged?()
        Task { await reload() }
    }

    func captureNewPreset(named name: String) {
        Task {
            let p = await center.capturePreset(name: name)
            savePreset(p)
        }
    }

    // MARK: Schedules

    func saveSchedule(_ s: Schedule) {
        try? center.schedules.upsert(s)
        onSchedulesChanged?()
        Task { await reload() }
    }

    func deleteSchedule(_ s: Schedule) {
        try? center.schedules.delete(id: s.id)
        onSchedulesChanged?()
        Task { await reload() }
    }

    // MARK: Settings

    func updateAppSettings(_ change: (inout AppSettings) -> Void) {
        settingsStore.update(change)
        settings = settingsStore.current
        onSettingsChanged?()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { banner = "Launch at login needs the app to be in Applications: \(error.localizedDescription)" }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    // MARK: Diagnostics

    func diagnostics() async -> String {
        var lines: [String] = []
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chip = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)
        lines.append("DisplayControl 1.0.0")
        lines.append("macOS \(v), \(String(cString: chip))")
        lines.append("AVService API available: \(AVServiceAPI.shared.isAvailable), DisplayServices available: \(DisplayServicesAPI.shared.isAvailable)")
        for s in await center.snapshots() {
            lines.append("- \(s.name) key=\(s.key) mode=\(s.mode.rawValue) controls=\(s.supported.map(\.rawValue).joined(separator: ",")) model=\(s.capabilitiesModel ?? "?") unreliable=\(s.ddcUnreliable)")
        }
        // Last 200 DDC log lines from this process (no personal data is logged).
        if let store = try? OSLogStore(scope: .currentProcessIdentifier) {
            let pos = store.position(timeIntervalSinceLatestBoot: 0)
            if let entries = try? store.getEntries(at: pos) {
                let ddc = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.subsystem == Log.subsystem && $0.category == "ddc" }
                lines.append("--- ddc log (last 200) ---")
                lines += ddc.suffix(200).map { "\($0.date.formatted(date: .omitted, time: .standard)) \($0.composedMessage)" }
            }
        }
        return lines.joined(separator: "\n")
    }
}

import OSLog
