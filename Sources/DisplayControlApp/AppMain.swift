import SwiftUI
import AppKit
import DisplayControlCore

/// Which displays the keyboard may steer. Read from the event tap callback, so it is lock-protected.
final class KeyTargets: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [CGDirectDisplayID: Set<DisplayProperty>] = [:]
    private var swallowed = Set<Int>()

    func update(_ snaps: [DisplaySnapshot]) {
        lock.withLock {
            byID = Dictionary(uniqueKeysWithValues: snaps.filter { !$0.isBuiltIn }.map { (CGDirectDisplayID($0.id), Set($0.supported)) })
        }
    }

    /// True when the event should be taken for an external display. Built-in displays are left to macOS.
    func shouldSwallow(_ key: MediaKey, isDown: Bool, controlAll: Bool) -> Bool {
        if !isDown { return lock.withLock { swallowed.remove(key.rawValue) != nil } }   // swallow the key-up of a swallowed key-down
        let needed: DisplayProperty = (key == .brightnessUp || key == .brightnessDown) ? .brightness : (key == .mute ? .mute : .volume)
        let hit: Bool = lock.withLock {
            if controlAll { return byID.values.contains { $0.contains(needed) } }
            let p = CGEvent(source: nil)?.location ?? .zero
            var count: UInt32 = 0
            var id: CGDirectDisplayID = 0
            guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return false }
            return byID[id]?.contains(needed) ?? false
        }
        if hit { lock.withLock { _ = swallowed.insert(key.rawValue) } }
        return hit
    }
}

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let isDemo = CommandLine.arguments.contains("--demo")
    let center: DisplayCenter
    let settings: SettingsStore
    let model: AppModel
    let router: CommandRouter
    let scheduler: Scheduler
    let keyboard: KeyboardController
    let keyTargets = KeyTargets()
    let locationProvider = LocationProvider()
    private var server: IPCServer?
    private var tap: MediaKeyTap?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var reconfigureTask: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []
    private var started = false

    private init() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("displaycontrol-demo")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let demo = isDemo
        settings = demo ? SettingsStore(url: temp.appendingPathComponent("settings.json")) : SettingsStore()
        let system: DisplaySystem = demo ? DemoDisplaySystem() : LiveDisplaySystem()
        center = demo
            ? DisplayCenter(system: system, presets: PresetStore(url: temp.appendingPathComponent("presets.json")),
                            schedules: ScheduleStore(url: temp.appendingPathComponent("schedules.json")),
                            settingsURL: temp.appendingPathComponent("displays.json"))
            : DisplayCenter(system: system)
        model = AppModel(center: center, settings: settings)
        router = CommandRouter(center: center)
        scheduler = Scheduler(center: center)
        keyboard = KeyboardController(center: center, settings: settings)
    }

    func start() {
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)                                  // no Dock icon, even outside the bundle

        model.onSettingsChanged = { [weak self] in self?.applyInputSettings() }
        model.onPresetsChanged = { [weak self] in self?.applyInputSettings() }
        model.onSchedulesChanged = { [weak self] in Task { await self?.scheduler.reconfigure() } }

        Task {
            await center.reload()
            await refreshModel()
            startServer()
            await center.observeTopology { [weak self] in Task { @MainActor in await self?.refreshModel() } }
            await center.observe { [weak self] change in
                if change.origin != .user { Task { @MainActor in self?.model.scheduleReload() } }
            }
            await scheduler.setNeedLocationHandler { [weak self] in
                Task { @MainActor in self?.requestLocationForSchedules() }
            }
            await scheduler.start()
            applyInputSettings()
            if settings.current.showOnboarding && !isDemo { showOnboarding() }
            if CommandLine.arguments.contains("--preview-windows") { showPreviewWindows() }
            if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
                try? await Task.sleep(for: .seconds(1))
                writeSnapshots(to: CommandLine.arguments[i + 1])
                exit(0)
            }
        }
        installSystemObservers()
        installSignalHandlers()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func refreshModel() async {
        await model.reload()
        keyTargets.update(model.displays)
    }

    // MARK: Server

    private func startServer() {
        let router = self.router
        let s = IPCServer { await router.handle($0) }
        do { try s.start(); server = s }
        catch { model.banner = "The command line tool cannot connect: \(error)" }
    }

    // MARK: Keys and hotkeys

    func applyInputSettings() {
        let current = settings.current
        // Media keys: only while enabled and permitted.
        if current.mediaKeysEnabled && MediaKeyTap.hasPermission {
            if tap == nil {
                let targets = keyTargets, kb = keyboard, stg = settings
                tap = MediaKeyTap { key, isDown, isRepeat in
                    let all = stg.current.controlAllDisplays
                    guard targets.shouldSwallow(key, isDown: isDown, controlAll: all) else { return false }
                    if isDown {
                        let p = CGEvent(source: nil)?.location ?? .zero
                        Task { await kb.perform(KeyboardController.action(for: key), pointer: p) }
                    }
                    return true
                }
            }
            tap?.start()
        } else {
            tap?.stop(); tap = nil
        }

        // Custom shortcuts.
        HotKeyCenter.shared.unregisterAll()
        for (action, spec) in current.hotkeys {
            HotKeyCenter.shared.register(spec) { [kb = keyboard] in
                let p = CGEvent(source: nil)?.location ?? .zero
                Task { await kb.perform(action, pointer: p) }
            }
        }
        for preset in center.presets.all {
            guard let spec = preset.hotkey else { continue }
            let id = preset.id
            HotKeyCenter.shared.register(spec) { [center] in Task { _ = try? await center.activatePreset(id: id) } }
        }
    }

    // MARK: System events

    private func installSystemObservers() {
        // Display topology: macOS fires several callbacks per change, so debounce.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconfigure(after: .milliseconds(500)) }
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async { Task { @MainActor in AppEnvironment.shared.scheduleReconfigure(after: .milliseconds(500)) } }
        }, nil)
        // Monitors need a moment after wake before they answer DDC; gamma is reset by macOS on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconfigure(after: .seconds(2)) }
        }
    }

    func scheduleReconfigure(after delay: Duration) {
        reconfigureTask?.cancel()
        reconfigureTask = Task { [center] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await center.reload()
            await center.reapplySoftwareDimming()
            await refreshModel()
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.restoreEverything()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Every exit path calls this so a display is never left dimmed.
    func restoreEverything() {
        CGDisplayRestoreColorSyncSettings()
        server?.stop()
    }

    // MARK: Location

    private func requestLocationForSchedules() {
        guard center.schedules.location == nil else { return }
        locationProvider.requestOnce { [weak self] g in
            guard let g else { return }
            try? self?.center.schedules.setLocation(g)
            Task { await self?.scheduler.reconfigure() }
        }
    }

    // MARK: Windows

    func openSettings(_ tab: SettingsTab) {
        let view = SettingsView(model: model, tab: tab)
        let w = settingsWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "DisplayControl Settings"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self, weak w] in
            self?.settings.update { $0.showOnboarding = false }
            w?.close()
        })
        w.center()
        onboardingWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Development aid: shows the menu bar window's contents and Settings as ordinary windows so they can be inspected.
    func showPreviewWindows() {
        let pop = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 330, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        pop.title = "Popover preview"
        pop.contentView = NSHostingView(rootView: MenuView(model: model) { [weak self] tab in self?.openSettings(tab) })
        pop.setFrameOrigin(NSPoint(x: 40, y: 200))
        pop.makeKeyAndOrderFront(nil)
        openSettings(.general)
        settingsWindow?.setFrameOrigin(NSPoint(x: 420, y: 200))
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Development aid: renders the main views to PNG files without needing screen recording permission.
    func writeSnapshots(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func render<V: View>(_ view: V, _ size: NSSize, _ name: String) {
            let host = NSHostingView(rootView: view)
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            win.orderBack(nil)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
        }
        render(MenuView(model: model) { _ in }.background(Color(nsColor: .windowBackgroundColor)), NSSize(width: 330, height: 560), "popover")
        for (tab, name) in [(SettingsTab.general, "settings-general"), (.displays, "settings-displays"), (.presets, "settings-presets"),
                            (.schedules, "settings-schedules"), (.keyboard, "settings-keyboard"), (.commandLine, "settings-cli"), (.about, "settings-about")] {
            render(SettingsView(model: model, tab: tab).background(Color(nsColor: .windowBackgroundColor)), NSSize(width: 640, height: 520), name)
        }
        render(OnboardingView(model: model) {}.background(Color(nsColor: .windowBackgroundColor)), NSSize(width: 480, height: 340), "onboarding")
    }

    // MARK: URL scheme

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s),
              let req = URLCommand.parse(url) else { return }
        let router = self.router
        Task { _ = await router.handle(req) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.shared.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppEnvironment.shared.restoreEverything() }
        return .terminateNow
    }
}

@main
struct DisplayControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppEnvironment.shared.model

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model) { tab in AppEnvironment.shared.openSettings(tab) }
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
