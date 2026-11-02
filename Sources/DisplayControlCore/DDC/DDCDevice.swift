import Foundation

public struct DDCTiming: Sendable {
    /// Minimum gap between commands to the same display (spec: at least 50 ms).
    public var minGap: Duration = .milliseconds(50)
    /// The gap grows toward this after errors.
    public var maxGap: Duration = .milliseconds(100)
    /// Wait between a Get request and reading its reply.
    public var readDelay: Duration = .milliseconds(40)
    /// A hung I2C call is abandoned after this long.
    public var timeout: Duration = .seconds(1)
    /// Extra attempts for a read that fails its checksum or length check.
    public var readRetries = 2
    /// Send every write twice (some monitors drop the first).
    public var doubleWrite = false

    public init() {}

    /// Short timings for unit tests.
    public static var fast: DDCTiming {
        var t = DDCTiming()
        t.minGap = .milliseconds(5); t.maxGap = .milliseconds(10)
        t.readDelay = .milliseconds(2); t.timeout = .milliseconds(150)
        return t
    }
}

public struct DDCStats: Sendable, Equatable {
    public var writesSent = 0
    public var readsDone = 0
    public var errors = 0
    public var timeouts = 0
    public var coalesced = 0
}

/// Owns one display's DDC conversation. Serial, rate limited and coalescing:
/// a burst of writes to the same control collapses to the latest value, and
/// the final value is always sent (trailing edge). Nothing runs when idle.
public actor DDCDevice {
    public enum ReadResult: Sendable { case vcp(DDC.VCPReply), caps(Capabilities) }

    private enum ReadKind: Hashable { case vcp(UInt8), caps }

    private let transport: DDCTransport
    public private(set) var timing: DDCTiming
    private let ioQueue = DispatchQueue(label: "app.displaycontrol.ddc.io")

    private var pending: [UInt8: UInt16] = [:]
    private var order: [UInt8] = []
    private var readOrder: [ReadKind] = []
    private var readWaiters: [ReadKind: [CheckedContinuation<ReadResult, Error>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var draining = false

    private var lastCall: ContinuousClock.Instant?
    private var currentGap: Duration
    private var cleanStreak = 0

    public private(set) var stats = DDCStats()
    /// Highest raw value reported by the monitor per control (learned from reads).
    public private(set) var maxValues: [UInt8: UInt16] = [:]
    /// Set when commands keep failing; the UI shows a hint.
    public private(set) var isUnreliable = false

    public init(transport: DDCTransport, timing: DDCTiming = DDCTiming()) {
        self.transport = transport
        self.timing = timing
        self.currentGap = timing.minGap
    }

    public func setDoubleWrite(_ on: Bool) { timing.doubleWrite = on }
    public func setUnreliable(_ v: Bool) { isUnreliable = v }

    // MARK: Public API

    /// Queues a raw Set VCP. Returns immediately. A newer value for the same
    /// control replaces one that has not been sent yet.
    public func set(_ code: UInt8, raw value: UInt16) {
        if pending[code] != nil { stats.coalesced += 1 } else { order.append(code) }
        pending[code] = value
        startDrain()
    }

    /// Reads a control. Concurrent reads of the same control share one transaction.
    public func read(_ code: UInt8) async throws -> DDC.VCPReply {
        let r = try await enqueueRead(.vcp(code))
        if case .vcp(let reply) = r { return reply }
        throw DDCError.badOpcode(0)
    }

    /// Reads and parses the MCCS capability string.
    public func readCapabilities() async throws -> Capabilities {
        let r = try await enqueueRead(.caps)
        if case .caps(let c) = r { return c }
        throw DDCError.malformedCapabilities
    }

    /// Suspends until every queued write and read has been processed.
    public func waitUntilIdle() async {
        if !draining && pending.isEmpty && readOrder.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Drain loop

    private func enqueueRead(_ kind: ReadKind) async throws -> ReadResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ReadResult, Error>) in
            if readWaiters[kind] == nil { readWaiters[kind] = []; readOrder.append(kind) }
            readWaiters[kind]!.append(cont)
            startDrain()
        }
    }

    private func startDrain() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while true {
            if let code = order.first {
                order.removeFirst()
                if let value = pending.removeValue(forKey: code) { await sendWrite(code, value) }
            } else if let kind = readOrder.first {
                readOrder.removeFirst()
                let waiters = readWaiters.removeValue(forKey: kind) ?? []
                do {
                    let result = try await performRead(kind)
                    for w in waiters { w.resume(returning: result) }
                } catch {
                    for w in waiters { w.resume(throwing: error) }
                }
            } else {
                break
            }
        }
        draining = false
        let waiters = idleWaiters
        idleWaiters = []
        for w in waiters { w.resume() }
    }

    // MARK: Transport work

    private func spacing() async {
        if let last = lastCall {
            let elapsed = ContinuousClock.now - last
            if elapsed < currentGap { try? await Task.sleep(for: currentGap - elapsed) }
        }
    }

    private func noteSuccess() {
        cleanStreak += 1
        if cleanStreak >= 20 { currentGap = timing.minGap; cleanStreak = 0 }
    }

    private func noteFailure(_ error: Error) {
        stats.errors += 1
        cleanStreak = 0
        if case DDCError.timeout = error { stats.timeouts += 1 }
        currentGap = min(timing.maxGap, currentGap + .milliseconds(25))
    }

    private func sendWrite(_ code: UInt8, _ value: UInt16) async {
        let payload = DDC.setVCP(code, value: value)
        let repeats = timing.doubleWrite ? 2 : 1
        for _ in 0..<repeats {
            var attempt = 0
            while true {
                await spacing()
                do {
                    try await blocking { [transport] in try transport.write(payload) }
                    lastCall = .now
                    stats.writesSent += 1
                    noteSuccess()
                    break
                } catch {
                    lastCall = .now
                    noteFailure(error)
                    attempt += 1
                    if attempt >= 2 { Log.ddc.error("write 0x\(String(code, radix: 16)) failed: \(String(describing: error))"); return }
                }
            }
        }
    }

    private func performRead(_ kind: ReadKind) async throws -> ReadResult {
        switch kind {
        case .vcp(let code): return .vcp(try await readVCP(code))
        case .caps: return .caps(try await readCaps())
        }
    }

    private func readVCP(_ code: UInt8) async throws -> DDC.VCPReply {
        var lastError: Error = DDCError.badLength(0)
        for _ in 0...timing.readRetries {
            await spacing()
            do {
                try await blocking { [transport] in try transport.write(DDC.getVCP(code)) }
                try? await Task.sleep(for: timing.readDelay)
                let bytes = try await blocking { [transport] in try transport.read(length: DDC.getReplyLength) }
                lastCall = .now
                let reply = try DDC.parseGetReply(bytes, expecting: code)
                maxValues[code] = reply.max
                stats.readsDone += 1
                noteSuccess()
                return reply
            } catch let e as DDCError {
                lastCall = .now
                lastError = e
                // An unsupported control is a definitive answer, not a fault.
                if case .unsupported = e { stats.readsDone += 1; throw e }
                noteFailure(e)
            } catch {
                lastCall = .now
                lastError = error
                noteFailure(error)
            }
        }
        throw lastError
    }

    private func readCaps() async throws -> Capabilities {
        var assembled: [UInt8] = []
        var offset = 0
        var guardCount = 0
        while guardCount < 64 {                         // 64 fragments is far beyond any real string
            guardCount += 1
            var fragment: (offset: Int, data: [UInt8])?
            var lastError: Error = DDCError.badLength(0)
            for _ in 0...timing.readRetries {
                await spacing()
                do {
                    let req = DDC.capabilitiesRequest(offset: UInt16(offset))
                    try await blocking { [transport] in try transport.write(req) }
                    try? await Task.sleep(for: timing.readDelay)
                    let bytes = try await blocking { [transport] in try transport.read(length: DDC.capsReplyLength) }
                    lastCall = .now
                    fragment = try DDC.parseCapabilitiesFragment(bytes)
                    noteSuccess()
                    break
                } catch {
                    lastCall = .now
                    lastError = error
                    noteFailure(error)
                }
            }
            guard let f = fragment else { throw lastError }
            if f.data.isEmpty { break }
            assembled += f.data
            offset += f.data.count
        }
        let text = String(decoding: assembled, as: UTF8.self)
        stats.readsDone += 1
        return try MCCSParser.parse(text)
    }

    /// Runs a blocking call off the actor with a hard deadline. If the deadline
    /// wins, the caller moves on and the stuck call finishes (or not) in the background.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let seconds = timing.timeout.seconds
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = OnceBox(cont)
            ioQueue.async {
                do { once.resume(.success(try work())) } catch { once.resume(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.resume(.failure(DDCError.timeout))
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side gets there first.
private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { cont = c }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = cont; cont = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
