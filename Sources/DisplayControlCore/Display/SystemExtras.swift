import Foundation
import CoreGraphics

/// System-wide display settings that sit beside brightness: Dark Mode, Night Shift, True Tone, and the HDR switch of
/// displays that offer one. Behind a protocol so tests and the demo mode do not touch the real system.
public protocol SystemExtras: Sendable {
    func state() async -> ExtrasState
    func setDarkMode(_ on: Bool) async -> Bool
    func setNightShift(_ on: Bool) async -> Bool
    func setNightShiftStrength(_ percent: Int) async -> Bool
    func setTrueTone(_ on: Bool) async -> Bool
    func setHDR(displayID: CGDirectDisplayID, _ on: Bool) async -> Bool
    func colorProfiles(displayID: CGDirectDisplayID) async -> ColorProfileState
    /// Path of a profile file, or nil to return to the display's own profile.
    func setColorProfile(displayID: CGDirectDisplayID, path: String?) async -> Bool
}

public struct ExtrasState: Codable, Equatable, Sendable {
    public var darkMode: Bool?
    public var nightShift: Bool?
    /// Warmth of Night Shift, 0 to 100. Nil when it cannot be read.
    public var nightShiftStrength: Int?
    public var trueTone: Bool?
    /// True Tone is offered only on some Macs.
    public var trueToneSupported = false
    /// Display ID (as text) to whether HDR is on, for displays that offer the switch.
    public var hdr: [String: Bool] = [:]
    public init() {}
}

/// Presets can include these system-wide switches too.
public struct ExtrasPreset: Codable, Equatable, Sendable {
    public var darkMode: Bool?
    public var nightShift: Bool?
    public var nightShiftStrength: Int?
    public var trueTone: Bool?
    public init(darkMode: Bool? = nil, nightShift: Bool? = nil, nightShiftStrength: Int? = nil, trueTone: Bool? = nil) {
        self.darkMode = darkMode; self.nightShift = nightShift; self.nightShiftStrength = nightShiftStrength; self.trueTone = trueTone
    }
    public var isEmpty: Bool { darkMode == nil && nightShift == nil && nightShiftStrength == nil && trueTone == nil }
}

/// The real thing. Every symbol and class is found at run time. When one is missing the matching switch reads as
/// unavailable and writes return false, so nothing here can stop the app from launching.
public final class LiveSystemExtras: SystemExtras, @unchecked Sendable {
    private typealias GetBool = @convention(c) () -> Bool
    private typealias SetBool = @convention(c) (Bool) -> Int32
    private typealias DisplayBool = @convention(c) (UInt32) -> Bool
    private typealias SetDisplayBool = @convention(c) (UInt32, Bool) -> Int32

    private let darkGet: GetBool?
    private let darkSet: SetBool?
    private let hdrSupports: DisplayBool?
    private let hdrIsOn: DisplayBool?
    private let hdrSet: SetDisplayBool?
    private let blueLight: NSObject?
    private let trueTone: NSObject?
    private let lock = NSLock()

    public init() {
        let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func sym<T>(_ n: String, _ t: T.Type) -> T? { sl.flatMap { dlsym($0, n) }.map { unsafeBitCast($0, to: t) } }
        darkGet = sym("SLSGetAppearanceThemeLegacy", GetBool.self)
        darkSet = sym("SLSSetAppearanceThemeLegacy", SetBool.self)
        hdrSupports = sym("SLSDisplaySupportsHDRMode", DisplayBool.self)
        hdrIsOn = sym("SLSDisplayIsHDRModeEnabled", DisplayBool.self)
        hdrSet = sym("SLSDisplaySetHDRModeEnabled", SetDisplayBool.self)

        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        blueLight = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
        trueTone = (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
    }

    // MARK: Objective-C helpers

    private func callBool(_ o: NSObject?, _ name: String) -> Bool? {
        guard let o, o.responds(to: NSSelectorFromString(name)) else { return nil }
        let s = NSSelectorFromString(name)
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(o.method(for: s), to: F.self)(o, s)
    }

    private func callSetBool(_ o: NSObject?, _ name: String, _ value: Bool) -> Bool {
        guard let o, o.responds(to: NSSelectorFromString(name)) else { return false }
        let s = NSSelectorFromString(name)
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(o.method(for: s), to: F.self)(o, s, value)
        return true
    }

    /// `getBlueLightStatus:` fills a C struct. Offsets 0 and 1 are "active" and "enabled".
    private func nightShiftEnabled() -> Bool? {
        guard let o = blueLight, o.responds(to: NSSelectorFromString("getBlueLightStatus:")) else { return nil }
        var raw = [UInt8](repeating: 0, count: 64)
        let s = NSSelectorFromString("getBlueLightStatus:")
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let ok = raw.withUnsafeMutableBytes { unsafeBitCast(o.method(for: s), to: F.self)(o, s, $0.baseAddress!) }
        return ok ? raw[1] != 0 : nil
    }

    private func nightShiftStrength() -> Int? {
        guard let o = blueLight, o.responds(to: NSSelectorFromString("getStrength:")) else { return nil }
        var v: Float = -1
        let s = NSSelectorFromString("getStrength:")
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
        guard unsafeBitCast(o.method(for: s), to: F.self)(o, s, &v), v >= 0 else { return nil }
        return Int((min(1, v) * 100).rounded())
    }

    // MARK: SystemExtras

    public func state() async -> ExtrasState {
        var st = ExtrasState()
        st.darkMode = darkGet?()
        st.nightShift = nightShiftEnabled()
        st.nightShiftStrength = nightShiftStrength()
        st.trueToneSupported = callBool(trueTone, "supported") == true && callBool(trueTone, "available") != false
        st.trueTone = st.trueToneSupported ? callBool(trueTone, "enabled") : nil
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        if let supports = hdrSupports, let isOn = hdrIsOn {
            for id in ids.prefix(Int(count)) where supports(id) { st.hdr[String(id)] = isOn(id) }
        }
        return st
    }

    public func setDarkMode(_ on: Bool) async -> Bool {
        guard let darkSet else { return false }
        _ = darkSet(on)
        return true
    }

    public func setNightShift(_ on: Bool) async -> Bool { callSetBool(blueLight, "setEnabled:", on) }

    public func setNightShiftStrength(_ percent: Int) async -> Bool {
        guard let o = blueLight, o.responds(to: NSSelectorFromString("setStrength:commit:")) else { return false }
        let s = NSSelectorFromString("setStrength:commit:")
        typealias F = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
        _ = unsafeBitCast(o.method(for: s), to: F.self)(o, s, Float(max(0, min(100, percent))) / 100, true)
        return true
    }

    public func setTrueTone(_ on: Bool) async -> Bool { callSetBool(trueTone, "setEnabled:", on) }

    public func setHDR(displayID: CGDirectDisplayID, _ on: Bool) async -> Bool {
        guard let hdrSet, hdrSupports?(displayID) == true else { return false }
        _ = hdrSet(displayID, on)
        return true
    }

    public func colorProfiles(displayID: CGDirectDisplayID) async -> ColorProfileState { ColorProfiles.state(for: displayID) }
    public func setColorProfile(displayID: CGDirectDisplayID, path: String?) async -> Bool { ColorProfiles.set(path, for: displayID) }
}

/// In-memory stand-in for tests and demo mode.
public final class FakeSystemExtras: SystemExtras, @unchecked Sendable {
    private let lock = NSLock()
    private var s: ExtrasState

    public init(trueToneSupported: Bool = true, hdrDisplays: [CGDirectDisplayID] = []) {
        var st = ExtrasState()
        st.darkMode = false; st.nightShift = false; st.nightShiftStrength = 50
        st.trueToneSupported = trueToneSupported; st.trueTone = trueToneSupported ? true : nil
        for d in hdrDisplays { st.hdr[String(d)] = false }
        s = st
    }
    public func state() async -> ExtrasState { lock.withLock { s } }
    public func setDarkMode(_ on: Bool) async -> Bool { lock.withLock { s.darkMode = on }; return true }
    public func setNightShift(_ on: Bool) async -> Bool { lock.withLock { s.nightShift = on }; return true }
    public func setNightShiftStrength(_ p: Int) async -> Bool { lock.withLock { s.nightShiftStrength = max(0, min(100, p)) }; return true }
    public func setTrueTone(_ on: Bool) async -> Bool {
        lock.withLock { if s.trueToneSupported { s.trueTone = on } }
        return lock.withLock { s.trueToneSupported }
    }
    public func setHDR(displayID: CGDirectDisplayID, _ on: Bool) async -> Bool {
        lock.withLock { if s.hdr[String(displayID)] != nil { s.hdr[String(displayID)] = on } }
        return lock.withLock { s.hdr[String(displayID)] != nil }
    }

    private var profile: [CGDirectDisplayID: String] = [:]
    public static let fakeProfiles = [ColorProfileInfo(name: "Display own profile", path: "/fake/own.icc", isFactory: true),
                                      ColorProfileInfo(name: "sRGB", path: "/fake/srgb.icc"), ColorProfileInfo(name: "Display P3", path: "/fake/p3.icc")]
    public func colorProfiles(displayID: CGDirectDisplayID) async -> ColorProfileState {
        let cur = lock.withLock { profile[displayID] } ?? Self.fakeProfiles[0].path
        return ColorProfileState(current: Self.fakeProfiles.first { $0.path == cur }, available: Self.fakeProfiles)
    }
    public func setColorProfile(displayID: CGDirectDisplayID, path: String?) async -> Bool {
        guard path == nil || Self.fakeProfiles.contains(where: { $0.path == path }) else { return false }
        lock.withLock { profile[displayID] = path }
        return true
    }
}
