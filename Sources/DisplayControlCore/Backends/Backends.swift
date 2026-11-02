import Foundation
import CoreGraphics

public enum BackendError: Error, CustomStringConvertible, Equatable {
    case unsupported(DisplayProperty)
    case failed(String)
    case unavailable

    public var description: String {
        switch self {
        case .unsupported(let p): return "This display does not support \(p.rawValue)"
        case .failed(let m): return m
        case .unavailable: return "Control is not available for this display"
        }
    }
}

/// One way of talking to a display. All values are in user units:
/// percent for brightness/contrast/volume, raw code for input, degrees for rotation,
/// 1/0 for power-on/mute.
public protocol DisplayBackend: Sendable {
    var mode: ControlMode { get }
    func supported() async -> Set<DisplayProperty>
    func get(_ property: DisplayProperty) async throws -> Int
    func set(_ property: DisplayProperty, to value: Int) async throws
    /// Called when the backend is replaced or the app quits.
    func shutdown() async
}

// MARK: - Software dimming (gamma)

/// Dims with a gamma formula. Does not touch the real backlight.
/// macOS resets gamma on wake and reconfiguration, so the owner must call `reapply()` then.
public final class SoftwareBackend: DisplayBackend, @unchecked Sendable {
    public let mode: ControlMode = .software
    private let displayID: CGDirectDisplayID
    private let lock = NSLock()
    private var percent: Int = 100
    /// Never go fully black unless the caller explicitly allows it.
    public static let floor: Double = 0.1

    public init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    public func supported() async -> Set<DisplayProperty> { [.brightness] }

    public func get(_ property: DisplayProperty) async throws -> Int {
        guard property == .brightness else { throw BackendError.unsupported(property) }
        return lock.withLock { percent }
    }

    public func set(_ property: DisplayProperty, to value: Int) async throws {
        guard property == .brightness else { throw BackendError.unsupported(property) }
        let p = ValueMapper.clampPercent(value)
        lock.withLock { percent = p }
        try apply(p)
    }

    /// Re-applies the last value (after wake or display reconfiguration).
    public func reapply() { let p = lock.withLock { percent }; try? apply(p) }

    public static func multiplier(forPercent p: Int) -> Double {
        floor + (1.0 - floor) * Double(ValueMapper.clampPercent(p)) / 100.0
    }

    private func apply(_ p: Int) throws {
        if p >= 100 {
            // At full brightness hand control back to ColorSync instead of holding a gamma table.
            CGDisplayRestoreColorSyncSettings()
            return
        }
        let m = Float(Self.multiplier(forPercent: p))
        let err = CGSetDisplayTransferByFormula(displayID, 0, m, 1, 0, m, 1, 0, m, 1)
        if err != .success { throw BackendError.failed("Could not change the display's gamma (\(err.rawValue))") }
    }

    public func shutdown() async {
        // Restores every display's ColorSync settings, which is the documented way to undo gamma changes.
        CGDisplayRestoreColorSyncSettings()
    }
}

// MARK: - Apple displays via DisplayServices (private, loaded at runtime)

public final class DisplayServicesAPI: @unchecked Sendable {
    public static let shared = DisplayServicesAPI()

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private let getFn: GetFn?
    private let setFn: SetFn?
    private let canFn: CanFn?

    public var isAvailable: Bool { getFn != nil && setFn != nil }

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let h = dlopen(path, RTLD_LAZY) else { getFn = nil; setFn = nil; canFn = nil; return }
        getFn = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(h, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        canFn = dlsym(h, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanFn.self) }
    }

    public func canChangeBrightness(_ id: CGDirectDisplayID) -> Bool {
        guard isAvailable else { return false }
        if let canFn { return canFn(id) }
        return brightness(id) != nil
    }

    /// 0...1, or nil when the display does not answer.
    public func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var v: Float = 0
        return getFn(id, &v) == 0 ? v : nil
    }

    @discardableResult
    public func setBrightness(_ id: CGDirectDisplayID, _ v: Float) -> Bool {
        guard let setFn else { return false }
        return setFn(id, max(0, min(1, v))) == 0
    }
}

public final class AppleBackend: DisplayBackend, @unchecked Sendable {
    public let mode: ControlMode = .apple
    private let displayID: CGDirectDisplayID
    public init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    public func supported() async -> Set<DisplayProperty> {
        DisplayServicesAPI.shared.canChangeBrightness(displayID) ? [.brightness] : []
    }

    public func get(_ property: DisplayProperty) async throws -> Int {
        guard property == .brightness else { throw BackendError.unsupported(property) }
        guard let v = DisplayServicesAPI.shared.brightness(displayID) else { throw BackendError.unavailable }
        return ValueMapper.clampPercent(Int((v * 100).rounded()))
    }

    public func set(_ property: DisplayProperty, to value: Int) async throws {
        guard property == .brightness else { throw BackendError.unsupported(property) }
        let ok = DisplayServicesAPI.shared.setBrightness(displayID, Float(ValueMapper.clampPercent(value)) / 100)
        if !ok { throw BackendError.failed("The display refused the brightness change") }
    }

    public func shutdown() async {}
}

// MARK: - DDC

public final class DDCBackend: DisplayBackend, @unchecked Sendable {
    public let mode: ControlMode = .ddc
    public let device: DDCDevice
    private let lock = NSLock()
    private var caps: Capabilities?
    private var probed: Set<DisplayProperty>?
    private let verify: Debouncer
    private var lastTarget: [UInt8: Int] = [:]
    /// Invoked when read-back disagrees with what we wrote.
    public var onUnreliable: (@Sendable () -> Void)?
    public var verifyReadback = true

    static let codes: [DisplayProperty: UInt8] = [
        .brightness: DDC.VCP.brightness, .contrast: DDC.VCP.contrast, .volume: DDC.VCP.volume,
        .mute: DDC.VCP.mute, .input: DDC.VCP.inputSource, .power: DDC.VCP.power, .rotation: DDC.VCP.orientation,
    ]

    public init(device: DDCDevice, verifySettle: Duration = .milliseconds(250)) {
        self.device = device
        self.verify = Debouncer(delay: verifySettle)
    }

    public var capabilities: Capabilities? { lock.withLock { caps } }

    public func supported() async -> Set<DisplayProperty> {
        let cached = lock.withLock { probed }
        if let cached { return cached }

        var result: Set<DisplayProperty> = []
        if let c = try? await device.readCapabilities() {
            lock.withLock { caps = c }
            for (p, code) in Self.codes where c.supports(code) { result.insert(p) }
        }
        // Many monitors return an empty or broken capability string; probe the essentials individually.
        if result.isEmpty {
            for p in [DisplayProperty.brightness, .contrast, .volume, .input] {
                if let code = Self.codes[p], (try? await device.read(code)) != nil { result.insert(p) }
            }
        }
        lock.withLock { probed = result }
        return result
    }

    private func maxFor(_ code: UInt8) async throws -> Int {
        if let m = await device.maxValues[code], m > 0 { return Int(m) }
        return Int(try await device.read(code).max)
    }

    public func get(_ property: DisplayProperty) async throws -> Int {
        guard let code = Self.codes[property] else { throw BackendError.unsupported(property) }
        let r = try await device.read(code)
        switch property {
        case .brightness, .contrast, .volume: return ValueMapper.percent(fromRaw: Int(r.current), max: Int(r.max))
        case .mute: return r.current == 1 ? 1 : 0
        case .power: return r.current == 1 ? 1 : 0
        case .rotation: return Self.degrees(fromOrientationCode: Int(r.current))
        case .input: return Int(r.current)
        }
    }

    public func set(_ property: DisplayProperty, to value: Int) async throws {
        guard let code = Self.codes[property] else { throw BackendError.unsupported(property) }
        let raw: Int
        switch property {
        case .brightness, .contrast, .volume:
            raw = ValueMapper.raw(fromPercent: value, max: try await maxFor(code))
        case .mute: raw = value != 0 ? 1 : 2
        case .power: raw = value != 0 ? 1 : 5
        case .rotation: raw = Self.orientationCode(forDegrees: value)
        case .input: raw = max(0, min(0xFFFF, value))
        }
        Log.ddc.info("backend set code \(code, privacy: .public) raw \(raw, privacy: .public)")
        await device.set(code, raw: UInt16(raw))
        if verifyReadback, property.isPercent || property == .input {
            lock.withLock { lastTarget[code] = raw }
            scheduleVerify(code)
        }
    }

    private func scheduleVerify(_ code: UInt8) {
        verify.call { [weak self] in
            guard let self else { return }
            let target = self.lock.withLock { self.lastTarget[code] }
            guard let target, let r = try? await self.device.read(code) else { return }
            Log.ddc.info("verify code \(code, privacy: .public): wrote raw \(target, privacy: .public), monitor reports \(r.current, privacy: .public)")
            if abs(Int(r.current) - target) > 1 {
                await self.device.setUnreliable(true)
                self.onUnreliable?()
            }
        }
    }

    public func shutdown() async { verify.cancel() }

    // DDC orientation values: 1 = 0 degrees, 2 = 90, 3 = 180, 4 = 270.
    static func orientationCode(forDegrees d: Int) -> Int {
        switch ((d % 360) + 360) % 360 { case 90: return 2; case 180: return 3; case 270: return 4; default: return 1 }
    }
    static func degrees(fromOrientationCode c: Int) -> Int {
        switch c { case 2: return 90; case 3: return 180; case 4: return 270; default: return 0 }
    }
}
