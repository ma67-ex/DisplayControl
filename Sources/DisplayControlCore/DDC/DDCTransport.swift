import Foundation

/// A blocking I2C connection to one display's DDC/CI endpoint.
/// Implementations must be safe to call from one serial queue at a time.
public protocol DDCTransport: Sendable {
    /// Writes `payload` (everything after the 0x51 data address).
    func write(_ payload: [UInt8]) throws
    /// Reads `length` bytes of a reply.
    func read(length: Int) throws -> [UInt8]
}

/// An in-memory monitor used by tests, the selftest dry run and development.
/// It validates checksums like a real display and can inject faults.
public final class MockDDCMonitor: DDCTransport, @unchecked Sendable {
    public struct VCPState: Sendable { public var current: UInt16; public var max: UInt16 }

    public struct WriteRecord: Sendable {
        public let time: ContinuousClock.Instant
        public let payload: [UInt8]
    }

    private let lock = NSLock()
    private var table: [UInt8: VCPState]
    private var pendingReply: [UInt8] = []
    private var capsString: [UInt8]
    private var writes: [WriteRecord] = []
    private var reads = 0

    // Fault injection (read under lock).
    private var failWrites = 0
    private var corruptReplies = 0
    private var hang = false
    private var latency: TimeInterval = 0

    public init(vcp: [UInt8: VCPState], capabilities: String = "") {
        self.table = vcp
        self.capsString = Array(capabilities.utf8)
    }

    /// A typical monitor: brightness, contrast, volume, input.
    public static func typical() -> MockDDCMonitor {
        MockDDCMonitor(
            vcp: [
                DDC.VCP.brightness: .init(current: 50, max: 100),
                DDC.VCP.contrast: .init(current: 70, max: 100),
                DDC.VCP.volume: .init(current: 20, max: 100),
                DDC.VCP.inputSource: .init(current: 0x0F, max: 0x1B),
            ],
            capabilities: "(prot(monitor)type(LCD)model(MockView 27)cmds(01 02 03 07 0C E3 F3)vcp(10 12 60(0F 11 12 1B) 62 D6(01 04 05))mccs_ver(2.2))"
        )
    }

    // MARK: Test controls

    public func failNextWrites(_ n: Int) { lock.lock(); failWrites = n; lock.unlock() }
    public func corruptNextReplies(_ n: Int) { lock.lock(); corruptReplies = n; lock.unlock() }
    public func setHang(_ h: Bool) { lock.lock(); hang = h; lock.unlock() }
    public func setLatency(_ s: TimeInterval) { lock.lock(); latency = s; lock.unlock() }
    public func value(_ code: UInt8) -> UInt16? { lock.lock(); defer { lock.unlock() }; return table[code]?.current }
    public func setValue(_ code: UInt8, _ v: UInt16) {
        lock.lock(); table[code]?.current = v; lock.unlock()
    }
    public var writeLog: [WriteRecord] { lock.lock(); defer { lock.unlock() }; return writes }
    public var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    /// Number of Set VCP commands received.
    public var setCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writes.filter { $0.payload.count > 2 && $0.payload[1] == DDC.Opcode.setVCP }.count
    }

    // MARK: DDCTransport

    public func write(_ payload: [UInt8]) throws {
        lock.lock()
        let hanging = hang, lat = latency
        lock.unlock()
        if hanging { Thread.sleep(forTimeInterval: 30) }
        if lat > 0 { Thread.sleep(forTimeInterval: lat) }

        lock.lock(); defer { lock.unlock() }
        writes.append(WriteRecord(time: .now, payload: payload))
        if failWrites > 0 { failWrites -= 1; throw DDCError.transport(-1) }

        // Validate like a real display.
        guard payload.count >= 4, payload.last == DDC.checksum(seed: DDC.destinationWire ^ DDC.hostAddress,
                                                              Array(payload.dropLast())) else { return }
        switch payload[1] {
        case DDC.Opcode.setVCP where payload.count == 6:
            let code = payload[2]
            let v = UInt16(payload[3]) << 8 | UInt16(payload[4])
            if table[code] != nil { table[code]!.current = min(v, table[code]!.max) }
        case DDC.Opcode.getVCP where payload.count == 4:
            pendingReply = vcpReply(for: payload[2])
        case DDC.Opcode.capsRequest where payload.count == 5:
            let off = Int(payload[2]) << 8 | Int(payload[3])
            pendingReply = capsFragment(at: off)
        default: break
        }
    }

    public func read(length: Int) throws -> [UInt8] {
        lock.lock()
        let hanging = hang, lat = latency
        lock.unlock()
        if hanging { Thread.sleep(forTimeInterval: 30) }
        if lat > 0 { Thread.sleep(forTimeInterval: lat) }

        lock.lock(); defer { lock.unlock() }
        reads += 1
        var r = pendingReply
        if corruptReplies > 0, !r.isEmpty { corruptReplies -= 1; r[r.count - 1] ^= 0xFF }
        if r.count < length { r += [UInt8](repeating: 0, count: length - r.count) }
        return Array(r.prefix(length))
    }

    // MARK: Reply builders

    private func vcpReply(for code: UInt8) -> [UInt8] {
        var r: [UInt8]
        if let s = table[code] {
            r = [0x6E, 0x88, 0x02, 0x00, code, 0x00,
                 UInt8(s.max >> 8), UInt8(s.max & 0xFF), UInt8(s.current >> 8), UInt8(s.current & 0xFF)]
        } else {
            r = [0x6E, 0x88, 0x02, 0x01, code, 0x00, 0, 0, 0, 0]
        }
        r.append(DDC.checksum(seed: DDC.replySeed, r))
        return r
    }

    private func capsFragment(at offset: Int) -> [UInt8] {
        let chunk = 32
        let start = min(offset, capsString.count)
        let data = Array(capsString[start..<min(start + chunk, capsString.count)])
        var r: [UInt8] = [0x6E, UInt8(0x80 | (data.count + 3)), DDC.Opcode.capsReply,
                          UInt8(offset >> 8), UInt8(offset & 0xFF)] + data
        r.append(DDC.checksum(seed: DDC.replySeed, r))
        return r
    }
}
