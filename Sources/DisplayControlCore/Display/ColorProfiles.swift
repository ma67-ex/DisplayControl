import Foundation
import CoreGraphics
import ColorSync

public struct ColorProfileInfo: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    /// The profile the display shipped with, which "Reset" returns to.
    public var isFactory: Bool
    public init(name: String, path: String, isFactory: Bool = false) { self.name = name; self.path = path; self.isFactory = isFactory }
}

public struct ColorProfileState: Codable, Equatable, Sendable {
    public var current: ColorProfileInfo?
    public var available: [ColorProfileInfo] = []
    public init(current: ColorProfileInfo? = nil, available: [ColorProfileInfo] = []) { self.current = current; self.available = available }
}

/// Lists and switches the ColorSync profile of a display, through the public ColorSync API.
public enum ColorProfiles {
    private static func deviceInfo(_ id: CGDirectDisplayID) -> (uuid: CFUUID, info: [String: Any])? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return (uuid, info)
    }

    private static func name(of url: URL) -> String? {
        var err: Unmanaged<CFError>?
        guard let p = ColorSyncProfileCreateWithURL(url as CFURL, &err)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?
    }

    /// RGB profiles suitable for a screen: monitor, color space or scanner class, RGB data. Read from the file itself,
    /// since ColorSync returns its header with the bytes of each field reversed.
    static func isDisplayProfile(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 20), head.count == 20 else { return false }
        return isDisplayHeader(head)
    }

    static func isDisplayHeader(_ head: Data) -> Bool {
        guard head.count >= 20 else { return false }
        let cls = String(decoding: head[head.startIndex + 12 ..< head.startIndex + 16], as: UTF8.self)
        let space = String(decoding: head[head.startIndex + 16 ..< head.startIndex + 20], as: UTF8.self)
        return space == "RGB " && ["mntr", "spac", "scnr"].contains(cls)
    }

    private static let folders = ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles",
                                  NSHomeDirectory() + "/Library/ColorSync/Profiles"]

    public static func state(for id: CGDirectDisplayID) -> ColorProfileState {
        var st = ColorProfileState()
        guard let (_, info) = deviceInfo(id) else { return st }

        var factoryURL: URL?
        if let f = info["FactoryProfiles"] as? [String: Any], let first = f["1"] as? [String: Any], let u = first["DeviceProfileURL"] as? URL ?? (first["DeviceProfileURL"] as? String).flatMap(URL.init(string:)) {
            factoryURL = u
        }
        if let url = factoryURL {
            st.available.append(ColorProfileInfo(name: name(of: url) ?? "Built-in profile", path: url.path, isFactory: true))
        }
        for dir in folders {
            for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where f.hasSuffix(".icc") || f.hasSuffix(".icm") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
                guard isDisplayProfile(url), let n = name(of: url) else { continue }
                st.available.append(ColorProfileInfo(name: n, path: url.path))
            }
        }
        // Current: a custom profile if one is set, otherwise the factory one.
        var currentPath = factoryURL?.path
        if let custom = info["CustomProfiles"] as? [String: Any], let first = custom["1"] {
            if let u = first as? URL { currentPath = u.path } else if let s = first as? String, let u = URL(string: s) { currentPath = u.path }
        }
        st.current = st.available.first { $0.path == currentPath }
        return st
    }

    /// Sets a profile by file path, or returns to the display's own profile when `path` is nil.
    @discardableResult
    public static func set(_ path: String?, for id: CGDirectDisplayID) -> Bool {
        guard let (uuid, _) = deviceInfo(id) else { return false }
        let key = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        let value: Any = path.map { URL(fileURLWithPath: $0) as Any } ?? kCFNull as Any
        return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, [key: value] as CFDictionary)
    }
}
