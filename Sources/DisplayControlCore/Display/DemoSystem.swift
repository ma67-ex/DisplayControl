import Foundation
import CoreGraphics

/// A pretend set of displays backed by `MockDDCMonitor`. Used by `displaycontrol selftest --mock`
/// and `DisplayControlApp --demo` so the whole pipeline can run without hardware.
public final class DemoDisplaySystem: DisplaySystem, @unchecked Sendable {
    private let builtInBackend = DemoBuiltInBackend()
    private let infos: [DisplayInfo] = [
        DisplayInfo(id: 1001, identity: .init(vendorID: 0x610, productID: 0xA050, serial: 0, isBuiltIn: true), name: "Built-in Display (demo)", isMain: true),
        DisplayInfo(id: 1002, identity: .init(vendorID: 0xFFFF, productID: 0x0001, serial: 1, isBuiltIn: false), name: "Demo Monitor 27\""),
    ]
    private let monitor = MockDDCMonitor.typical()

    public init() {}

    public func currentDisplays() -> [DisplayInfo] { infos }

    public func makeBackend(for info: DisplayInfo, preferred: ControlMode?, timing: DDCTiming) async -> DisplayBackend {
        if info.identity.isBuiltIn { return builtInBackend }
        if preferred == .software { return SoftwareBackend(displayID: info.id) }
        return DDCBackend(device: DDCDevice(transport: monitor, timing: timing))
    }

    public func setResolution(displayID: CGDirectDisplayID, _ spec: ResolutionSpec) throws {}
    public func currentResolution(displayID: CGDirectDisplayID) -> ResolutionSpec? { .init(width: 2560, height: 1440, refreshRate: 60, hiDPI: false) }
    public func listResolutions(displayID: CGDirectDisplayID) -> [ResolutionSpec] { [currentResolution(displayID: displayID)!] }
    public func setOrigin(displayID: CGDirectDisplayID, x: Int, y: Int) throws {}
    public func origin(displayID: CGDirectDisplayID) -> ArrangementSpec { .init(x: 0, y: 0) }
}

final class DemoBuiltInBackend: DisplayBackend, @unchecked Sendable {
    let mode: ControlMode = .apple
    private let lock = NSLock()
    private var brightness = 60
    func supported() async -> Set<DisplayProperty> { [.brightness] }
    func get(_ p: DisplayProperty) async throws -> Int {
        guard p == .brightness else { throw BackendError.unsupported(p) }
        return lock.withLock { brightness }
    }
    func set(_ p: DisplayProperty, to value: Int) async throws {
        guard p == .brightness else { throw BackendError.unsupported(p) }
        lock.withLock { brightness = value }
    }
    func shutdown() async {}
}
