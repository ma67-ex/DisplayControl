import Foundation
import CoreGraphics

public enum DisplayProperty: String, Codable, CaseIterable, Sendable {
    case brightness, contrast, volume, mute, input, power, rotation

    /// Properties expressed as 0...100 percentages (these are the ones sync follows).
    public var isPercent: Bool { self == .brightness || self == .contrast || self == .volume }
}

public enum ControlMode: String, Codable, CaseIterable, Sendable {
    case ddc, apple, software

    public var title: String {
        switch self {
        case .ddc: return "Hardware (DDC)"
        case .apple: return "Apple display"
        case .software: return "Software dimming"
        }
    }
}

/// Stable identity that survives reboots and reconnects (spec 5.4).
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public var vendorID: UInt32
    public var productID: UInt32
    public var serial: UInt32
    public var alphanumericSerial: String?
    public var isBuiltIn: Bool
    public var locationHint: String?

    public init(vendorID: UInt32, productID: UInt32, serial: UInt32, alphanumericSerial: String? = nil,
                isBuiltIn: Bool, locationHint: String? = nil) {
        self.vendorID = vendorID; self.productID = productID; self.serial = serial
        self.alphanumericSerial = alphanumericSerial; self.isBuiltIn = isBuiltIn; self.locationHint = locationHint
    }

    /// String form used as a dictionary key in JSON files.
    public var key: String {
        let base = String(format: "%04X-%04X-%08X", vendorID, productID, serial)
        return isBuiltIn ? "builtin-" + base : base + (locationHint.map { "@" + $0 } ?? "")
    }
}

/// A snapshot of one connected display as macOS reports it.
public struct DisplayInfo: Sendable, Equatable {
    public var id: CGDirectDisplayID
    public var identity: DisplayIdentity
    public var name: String
    public var isMain: Bool

    public init(id: CGDirectDisplayID, identity: DisplayIdentity, name: String, isMain: Bool = false) {
        self.id = id; self.identity = identity; self.name = name; self.isMain = isMain
    }
}

/// A DDC input source choice shown to the user.
public struct InputSource: Sendable, Equatable {
    public let name: String
    public let code: Int
    public static let common: [InputSource] = [
        .init(name: "DisplayPort 1", code: 0x0F), .init(name: "DisplayPort 2", code: 0x10),
        .init(name: "HDMI 1", code: 0x11), .init(name: "HDMI 2", code: 0x12),
        .init(name: "USB-C", code: 0x1B),
    ]
    /// Resolves names like `hdmi1`, `displayport2`, `usbc` or a raw code like `17` / `0x11`.
    public static func parse(_ text: String) -> Int? {
        let t = text.lowercased().replacingOccurrences(of: "[ _-]", with: "", options: .regularExpression)
        switch t {
        case "dp1", "displayport1", "displayport": return 0x0F
        case "dp2", "displayport2": return 0x10
        case "hdmi1", "hdmi": return 0x11
        case "hdmi2": return 0x12
        case "usbc", "usb-c", "thunderbolt": return 0x1B
        default:
            if t.hasPrefix("0x"), let v = Int(t.dropFirst(2), radix: 16) { return v }
            return Int(t)
        }
    }
}

public struct DisplayChange: Sendable {
    public enum Origin: Sendable { case user, sync, preset, schedule, keyboard, external }
    public let identity: DisplayIdentity
    public let property: DisplayProperty
    public let value: Int
    public let origin: Origin
}

/// Per-display user settings persisted by identity key.
public struct DisplaySettings: Codable, Sendable, Equatable {
    public var friendlyName: String?
    public var preferredMode: ControlMode?
    public var stepSize: Int = 5
    public var volumeCap: Int = 100
    public var hidden: Bool = false
    /// Sync map: `follower = clamp(scale * host + constant)`.
    public var syncScale: Double = 1.0
    public var syncConstant: Double = 0.0
    public var doubleWrite: Bool = false
    public init() {}
}
