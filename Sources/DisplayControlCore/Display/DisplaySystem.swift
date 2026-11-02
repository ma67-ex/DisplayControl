import Foundation
import AppKit
import CoreGraphics

/// The boundary between the display logic and macOS. Tests supply a fake.
public protocol DisplaySystem: Sendable {
    func currentDisplays() -> [DisplayInfo]
    /// Builds the backend to use. `preferred` is a user override; nil means auto-detect.
    func makeBackend(for info: DisplayInfo, preferred: ControlMode?, timing: DDCTiming) async -> DisplayBackend
    func setResolution(displayID: CGDirectDisplayID, _ spec: ResolutionSpec) throws
    func currentResolution(displayID: CGDirectDisplayID) -> ResolutionSpec?
    func listResolutions(displayID: CGDirectDisplayID) -> [ResolutionSpec]
    func setOrigin(displayID: CGDirectDisplayID, x: Int, y: Int) throws
    func origin(displayID: CGDirectDisplayID) -> ArrangementSpec
}

public enum SystemError: Error, CustomStringConvertible {
    case noMatchingMode
    case configurationFailed(Int32)
    public var description: String {
        switch self {
        case .noMatchingMode: return "The display has no matching resolution"
        case .configurationFailed(let c): return "macOS refused the display change (\(c))"
        }
    }
}

public final class LiveDisplaySystem: DisplaySystem, @unchecked Sendable {
    private let resolver = AVServiceResolver()
    private let lock = NSLock()
    private var cachedCandidates: [AVCandidate] = []

    public init() {}

    // MARK: Listing

    public func currentDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = Self.screenNames()
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let identity = DisplayIdentity(vendorID: CGDisplayVendorNumber(id), productID: CGDisplayModelNumber(id),
                                           serial: CGDisplaySerialNumber(id), alphanumericSerial: nil, isBuiltIn: builtIn)
            return DisplayInfo(id: id, identity: identity, name: names[id] ?? (builtIn ? "Built-in Display" : "Display \(id)"), isMain: id == main)
        }
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        let work = {
            for s in NSScreen.screens {
                if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    out[CGDirectDisplayID(n.uint32Value)] = s.localizedName
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return out
    }

    // MARK: Backends

    public func makeBackend(for info: DisplayInfo, preferred: ControlMode?, timing: DDCTiming) async -> DisplayBackend {
        if let preferred {
            if let b = await build(preferred, info, timing) { return b }
        }
        // Auto-detect (spec 6.10).
        if info.identity.isBuiltIn || DisplayServicesAPI.shared.canChangeBrightness(info.id) && info.identity.isBuiltIn {
            if let b = await build(.apple, info, timing) { return b }
        }
        if !info.identity.isBuiltIn {
            if let b = await build(.ddc, info, timing) { return b }
            // Apple external displays (Studio Display, Pro Display XDR) answer DisplayServices.
            if let b = await build(.apple, info, timing) { return b }
        }
        return SoftwareBackend(displayID: info.id)
    }

    private func build(_ mode: ControlMode, _ info: DisplayInfo, _ timing: DDCTiming) async -> DisplayBackend? {
        switch mode {
        case .software:
            return SoftwareBackend(displayID: info.id)
        case .apple:
            let b = AppleBackend(displayID: info.id)
            return await b.supported().isEmpty ? nil : b
        case .ddc:
            guard AVServiceAPI.shared.isAvailable else { return nil }
            let candidates = resolver.discover()
            lock.withLock { cachedCandidates = candidates }
            let pairing = AVServicePairing.pair(displays: currentDisplays(), candidates: candidates)
            guard let index = pairing[info.id], let transport = resolver.transport(for: candidates[index]) else { return nil }
            let device = DDCDevice(transport: transport, timing: timing)
            // Detection: a valid brightness reply (the device retries internally).
            guard (try? await device.read(DDC.VCP.brightness)) != nil else { return nil }
            return DDCBackend(device: device)
        }
    }

    // MARK: Resolution and arrangement

    public func listResolutions(displayID: CGDirectDisplayID) -> [ResolutionSpec] {
        let opts = ["kCGDisplayShouldListAllModes": true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return [] }
        var seen = Set<String>()
        var out: [ResolutionSpec] = []
        for m in modes where m.isUsableForDesktopGUI() {
            let spec = Self.spec(m)
            let key = "\(spec.width)x\(spec.height)@\(spec.refreshRate)/\(spec.hiDPI)"
            if seen.insert(key).inserted { out.append(spec) }
        }
        return out.sorted { ($0.width * $0.height, $0.refreshRate) > ($1.width * $1.height, $1.refreshRate) }
    }

    public func currentResolution(displayID: CGDirectDisplayID) -> ResolutionSpec? {
        CGDisplayCopyDisplayMode(displayID).map(Self.spec)
    }

    private static func spec(_ m: CGDisplayMode) -> ResolutionSpec {
        ResolutionSpec(width: m.width, height: m.height, refreshRate: m.refreshRate, hiDPI: m.pixelWidth > m.width)
    }

    public func setResolution(displayID: CGDirectDisplayID, _ spec: ResolutionSpec) throws {
        let opts = ["kCGDisplayShouldListAllModes": true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { throw SystemError.noMatchingMode }
        func sameSize(_ m: CGDisplayMode) -> Bool {
            let scaled = m.pixelWidth > m.width
            return m.width == spec.width && m.height == spec.height && scaled == spec.hiDPI
        }
        let sized = modes.filter(sameSize)
        let match = sized.first { abs($0.refreshRate - spec.refreshRate) < 1 } ?? sized.first
        guard let mode = match else { throw SystemError.noMatchingMode }
        try configure { cfg in CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil) }
    }

    public func setOrigin(displayID: CGDirectDisplayID, x: Int, y: Int) throws {
        try configure { cfg in CGConfigureDisplayOrigin(cfg, displayID, Int32(x), Int32(y)) }
    }

    public func origin(displayID: CGDirectDisplayID) -> ArrangementSpec {
        let b = CGDisplayBounds(displayID)
        return ArrangementSpec(x: Int(b.origin.x), y: Int(b.origin.y))
    }

    private func configure(_ body: (CGDisplayConfigRef?) -> CGError) throws {
        var cfg: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&cfg)
        guard err == .success else { throw SystemError.configurationFailed(err.rawValue) }
        err = body(cfg)
        guard err == .success else { CGCancelDisplayConfiguration(cfg); throw SystemError.configurationFailed(err.rawValue) }
        err = CGCompleteDisplayConfiguration(cfg, .permanently)
        guard err == .success else { throw SystemError.configurationFailed(err.rawValue) }
    }
}
