import Foundation

/// Value mapping between a sync host and its followers (spec 5.6).
public enum SyncMath {
    /// `follower = clamp(scale * host + constant)`, rounded to the nearest percent.
    public static func map(host: Int, scale: Double, constant: Double) -> Int {
        ValueMapper.clampPercent(Int((scale * Double(host) + constant).rounded()))
    }

    /// Builds the simple user-facing offset: "follower brightness when host is at 100%".
    public static func scale(followerAtHost100 value: Int) -> Double {
        Double(ValueMapper.clampPercent(value)) / 100.0
    }

    public static func followerAtHost100(scale: Double, constant: Double) -> Int {
        map(host: 100, scale: scale, constant: constant)
    }
}

public struct SyncState: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var hostKey: String?
    public init(enabled: Bool = false, hostKey: String? = nil) { self.enabled = enabled; self.hostKey = hostKey }
}
