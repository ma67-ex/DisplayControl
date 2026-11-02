import Foundation
import IOKit
import CoreGraphics

/// Apple Silicon DDC transport over the private `IOAVService` API, resolved with `dlsym`.
///
/// UNVERIFIED ON HARDWARE. Offsets, data address and the registry keys used to pair a
/// service with a display are taken from public knowledge of the API and may differ by
/// macOS release. They are named constants so they can be tuned, and everything degrades
/// to software dimming when a symbol or service is missing.
public final class AVServiceAPI: @unchecked Sendable {
    public static let shared = AVServiceAPI()

    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    let create: CreateFn?
    let writeI2C: WriteFn?
    let readI2C: ReadFn?
    public var isAvailable: Bool { create != nil && writeI2C != nil && readI2C != nil }

    private init() {
        // IOKit is already linked, so the default handle finds its symbols.
        let h = dlopen(nil, RTLD_NOW)
        create = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
        writeI2C = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) }
        readI2C = dlsym(h, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: ReadFn.self) }
    }
}

public final class AVServiceTransport: DDCTransport, @unchecked Sendable {
    /// I2C chip address (7-bit) and the data address used for writes. Tunable.
    public static var chipAddress: UInt32 = UInt32(DDC.chipAddress)
    public static var writeDataAddress: UInt32 = UInt32(DDC.hostAddress)
    public static var readOffset: UInt32 = 0

    private let service: CFTypeRef
    public init(service: CFTypeRef) { self.service = service }

    public func write(_ payload: [UInt8]) throws {
        guard let fn = AVServiceAPI.shared.writeI2C else { throw DDCError.noTransport }
        var buf = payload
        let r = buf.withUnsafeMutableBytes { fn(service, Self.chipAddress, Self.writeDataAddress, $0.baseAddress!, UInt32($0.count)) }
        if r != KERN_SUCCESS { throw DDCError.transport(r) }
    }

    public func read(length: Int) throws -> [UInt8] {
        guard let fn = AVServiceAPI.shared.readI2C else { throw DDCError.noTransport }
        var buf = [UInt8](repeating: 0, count: length)
        let r = buf.withUnsafeMutableBytes { fn(service, Self.chipAddress, Self.readOffset, $0.baseAddress!, UInt32($0.count)) }
        if r != KERN_SUCCESS { throw DDCError.transport(r) }
        return buf
    }
}

/// A registry-discovered DDC service plus whatever identifying attributes sat next to it.
public struct AVCandidate: Equatable, Sendable {
    public var handle: Int                 // index into the resolver's service array
    public var vendorID: UInt32?
    public var productID: UInt32?
    public var alphanumericSerial: String?
    public var edidUUID: String?
    public var registryPath: String
}

/// Pairing is a pure function so it can be tested against recorded fixtures.
public enum AVServicePairing {
    /// Returns display ID to candidate index. Each candidate is used at most once.
    /// When two identical monitors are attached, registry order breaks the tie.
    public static func pair(displays: [DisplayInfo], candidates: [AVCandidate]) -> [CGDirectDisplayID: Int] {
        var used = Set<Int>()
        var result: [CGDirectDisplayID: Int] = [:]
        // External displays only, in a stable order (by display ID).
        let ordered = displays.filter { !$0.identity.isBuiltIn }.sorted { $0.id < $1.id }
        for d in ordered {
            var best: (index: Int, score: Int)?
            for (i, c) in candidates.enumerated() where !used.contains(i) {
                var score = 0
                if let v = c.vendorID { score += v == d.identity.vendorID ? 4 : -100 }
                if let p = c.productID { score += p == d.identity.productID ? 4 : -100 }
                if let s = c.alphanumericSerial, let ds = d.identity.alphanumericSerial, !s.isEmpty {
                    score += s == ds ? 8 : -2
                }
                if c.vendorID == nil && c.productID == nil { score += 1 }   // unlabeled: weak fallback
                if score > 0, best == nil || score > best!.score { best = (i, score) }
            }
            if let b = best { used.insert(b.index); result[d.id] = b.index }
        }
        return result
    }

    /// EDID manufacturer letters ("DEL") to the numeric vendor ID CoreGraphics reports.
    public static func vendorID(fromPnP code: String) -> UInt32? {
        let u = Array(code.uppercased().utf8)
        guard u.count == 3, u.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return nil }
        return (UInt32(u[0] - 64) << 10) | (UInt32(u[1] - 64) << 5) | UInt32(u[2] - 64)
    }
}

/// Walks the IORegistry for external `DCPAVServiceProxy` services (spec 5.2).
public final class AVServiceResolver: @unchecked Sendable {
    private var services: [CFTypeRef] = []

    public init() {}

    /// Discovers candidates. Cheap enough to call on every display reconfiguration.
    public func discover() -> [AVCandidate] {
        services = []
        guard AVServiceAPI.shared.isAvailable, let create = AVServiceAPI.shared.create else { return [] }

        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [AVCandidate] = []
        var lastAttrs: (vendor: UInt32?, product: UInt32?, serial: String?, uuid: String?)?

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            let name = String(cString: nameBuf)

            if let attrs = Self.productAttributes(entry) {
                lastAttrs = attrs
            }

            guard name == "DCPAVServiceProxy" else { continue }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }
            guard let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }

            var pathBuf = [CChar](repeating: 0, count: 512)
            IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuf)
            services.append(svc)
            candidates.append(AVCandidate(handle: services.count - 1,
                                          vendorID: lastAttrs?.vendor, productID: lastAttrs?.product,
                                          alphanumericSerial: lastAttrs?.serial, edidUUID: lastAttrs?.uuid,
                                          registryPath: String(cString: pathBuf)))
            Log.registry.debug("AV candidate #\(self.services.count - 1) vendor=\(lastAttrs?.vendor ?? 0) product=\(lastAttrs?.product ?? 0)")
        }
        return candidates
    }

    public func transport(for candidate: AVCandidate) -> DDCTransport? {
        guard candidate.handle >= 0, candidate.handle < services.count else { return nil }
        return AVServiceTransport(service: services[candidate.handle])
    }

    /// Reads `DisplayAttributes.ProductAttributes` from a framebuffer node, if the entry has them.
    private static func productAttributes(_ entry: io_registry_entry_t) -> (vendor: UInt32?, product: UInt32?, serial: String?, uuid: String?)? {
        guard let dict = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
              let prod = dict["ProductAttributes"] as? [String: Any] else { return nil }
        let vendor = (prod["ManufacturerID"] as? String).flatMap { AVServicePairing.vendorID(fromPnP: $0) }
        let product = (prod["ProductID"] as? NSNumber)?.uint32Value
        let serial = prod["AlphanumericSerialNumber"] as? String
        let uuid = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return (vendor, product, serial, uuid)
    }
}
