import Foundation
import AppKit
import Carbon.HIToolbox
import CoreLocation

// MARK: - Settings

public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case brightnessUp, brightnessDown, contrastUp, contrastDown, volumeUp, volumeDown, mute, cycleInput, toggleSync

    public var title: String {
        switch self {
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .contrastUp: return "Contrast up"
        case .contrastDown: return "Contrast down"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .cycleInput: return "Cycle input source"
        case .toggleSync: return "Toggle sync"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var mediaKeysEnabled = false
    public var controlAllDisplays = false
    public var hotkeys: [HotkeyAction: HotKeySpec] = [:]
    public var showOnboarding = true
    public var menuBarSymbol = "display"
    public init() {}
}

public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var value: AppSettings

    public init(url: URL = Paths.settingsFile) {
        self.url = url
        value = AtomicJSON.read(AppSettings.self, from: url) ?? AppSettings()
    }
    public var current: AppSettings { lock.withLock { value } }
    public func update(_ change: (inout AppSettings) -> Void) {
        lock.withLock { change(&value); try? AtomicJSON.write(value, to: url) }
    }
}

// MARK: - Media keys

public enum MediaKey: Int, Sendable {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

/// Intercepts brightness and volume keys. Needs Accessibility permission. The callback must be quick:
/// it returns whether to swallow the event, and any real work happens on a task.
public final class MediaKeyTap: @unchecked Sendable {
    /// Return true to swallow the event. `isDown` is false for the key-up that follows a key-down.
    public typealias Handler = @Sendable (_ key: MediaKey, _ isDown: Bool, _ isRepeat: Bool) -> Bool

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler
    private var box: Unmanaged<MediaKeyTap>?

    public init(handler: @escaping Handler) { self.handler = handler }

    public static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt when `prompt` is true. Returns the current trust state.
    @discardableResult
    public static func requestPermission(prompt: Bool = true) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil, Self.hasPermission else { return tap != nil }
        let mask = CGEventMask(1 << 14)                       // NSSystemDefined
        let me = Unmanaged.passRetained(self)
        box = me
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tapObj = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tapObj.process(type: type, event: event)
        }, userInfo: me.toOpaque()) else {
            me.release(); box = nil
            return false
        }
        tap = t
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    public func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); source = nil }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
        box?.release(); box = nil
    }

    public var isRunning: Bool { tap != nil }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a slow or interrupted tap; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let code = (data1 & 0xFFFF0000) >> 16
        let flags = data1 & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = (flags & 0x1) != 0
        guard let key = MediaKey(rawValue: code) else { return Unmanaged.passUnretained(event) }
        return handler(key, isDown, isRepeat) ? nil : Unmanaged.passUnretained(event)
    }
}

// MARK: - Global hotkeys (Carbon, no Accessibility permission needed)

public final class HotKeyCenter: @unchecked Sendable {
    public static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private let lock = NSLock()

    @discardableResult
    public func register(_ spec: HotKeySpec, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = lock.withLock { () -> UInt32 in defer { nextID += 1 }; return nextID }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x44434B59), id: id)      // 'DCKY'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        lock.withLock { handlers[id] = handler; refs[id] = ref }
        return id
    }

    public func unregisterAll() {
        lock.withLock {
            for r in refs.values { UnregisterEventHotKey(r) }
            refs = [:]; handlers = [:]
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let h = HotKeyCenter.shared.lock.withLock { HotKeyCenter.shared.handlers[hk.id] }
            h?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Human-readable form like "⌃⌥B" for the shortcut recorder.
    public static func describe(_ spec: HotKeySpec) -> String {
        var s = ""
        if spec.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if spec.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if spec.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if spec.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(spec.keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 41: ";", 45: "N", 46: "M", 43: ",", 47: ".",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[code] ?? "Key \(code)"
    }

    /// Converts NSEvent modifier flags into the Carbon modifier mask.
    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

// MARK: - Keyboard actions on displays

public struct KeyboardController: Sendable {
    public let center: DisplayCenter
    public let settings: SettingsStore

    public init(center: DisplayCenter, settings: SettingsStore) { self.center = center; self.settings = settings }

    /// Targets: the display under the pointer, or all, per settings.
    private func targets(pointer: CGPoint) async -> [ManagedDisplay] {
        if settings.current.controlAllDisplays { return await center.allDisplays }
        if let d = await center.displayUnderPointer(pointer) { return [d] }
        return []
    }

    public func perform(_ action: HotkeyAction, pointer: CGPoint) async {
        let list = await targets(pointer: pointer)
        for d in list {
            switch action {
            case .brightnessUp: try? await center.adjust(d, .brightness, steps: 1)
            case .brightnessDown: try? await center.adjust(d, .brightness, steps: -1)
            case .contrastUp: try? await center.adjust(d, .contrast, steps: 1)
            case .contrastDown: try? await center.adjust(d, .contrast, steps: -1)
            case .volumeUp: try? await center.adjust(d, .volume, steps: 1)
            case .volumeDown: try? await center.adjust(d, .volume, steps: -1)
            case .mute:
                let muted = (await d.values[.mute]) ?? 0
                try? await center.set(d, .mute, to: muted == 0 ? 1 : 0, origin: .keyboard)
            case .cycleInput:
                let all = InputSource.common.map(\.code)
                let cur = await d.refresh(.input) ?? all[0]
                let next = all[((all.firstIndex(of: cur) ?? -1) + 1) % all.count]
                try? await center.set(d, .input, to: next, origin: .keyboard)
            case .toggleSync:
                let s = await center.sync
                if s.enabled { await center.setSync(enabled: false, hostKey: nil) }
                else { await center.setSync(enabled: true, hostKey: await d.key) }
            }
        }
    }

    /// Maps a media key to an action.
    public static func action(for key: MediaKey) -> HotkeyAction {
        switch key {
        case .brightnessUp: return .brightnessUp
        case .brightnessDown: return .brightnessDown
        case .soundUp: return .volumeUp
        case .soundDown: return .volumeDown
        case .mute: return .mute
        }
    }
}

// MARK: - Location (sunrise and sunset)

public final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var completion: (@Sendable (GeoPoint?) -> Void)?

    public override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }

    /// Asks once for an approximate location. Calls back with nil if the user declines.
    public func requestOnce(_ done: @escaping @Sendable (GeoPoint?) -> Void) {
        completion = done
        switch manager.authorizationStatus {
        case .denied, .restricted: finish(nil)
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
    }

    private func finish(_ p: GeoPoint?) { completion?(p); completion = nil }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard completion != nil else { return }
        switch manager.authorizationStatus {
        case .denied, .restricted: finish(nil)
        case .notDetermined: break
        default: manager.requestLocation()
        }
    }
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
    }
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
}

// MARK: - URL scheme

public enum URLCommand {
    /// `displaycontrol://preset/<name>` and `displaycontrol://set?display=<name>&brightness=60&contrast=50...`
    public static func parse(_ url: URL) -> IPCRequest? {
        guard url.scheme?.lowercased() == "displaycontrol", let host = url.host?.lowercased() else { return nil }
        switch host {
        case "preset":
            let name = url.pathComponents.dropFirst().joined(separator: "/")
            guard !name.isEmpty else { return nil }
            return IPCRequest(cmd: "preset.activate", args: ["name": .string(name)])
        case "set":
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            var args: [String: JSONValue] = [:]
            var props: [String: JSONValue] = [:]
            for i in items {
                guard let v = i.value else { continue }
                switch i.name {
                case "display": args["display"] = .string(v)
                case "all": args["all"] = .bool(v == "1" || v.lowercased() == "true")
                case "brightness", "contrast", "volume", "rotation": if let n = Int(v) { props[i.name] = .int(n) }
                case "input", "power", "mute": props[i.name] = .string(v)
                default: break
                }
            }
            guard !props.isEmpty else { return nil }
            args["props"] = .object(props)
            return IPCRequest(cmd: "set", args: args)
        default:
            return nil
        }
    }
}
