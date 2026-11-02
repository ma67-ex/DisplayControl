import Testing
import Foundation
@testable import DisplayControlCore

@Suite struct DDCPacketTests {
    @Test func setBrightnessVector() {
        // Known vector: set brightness (0x10) to 50 (0x0032).
        // checksum = 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32
        let p = DDC.setVCP(0x10, value: 50)
        #expect(Array(p.dropLast()) == [0x84, 0x03, 0x10, 0x00, 0x32])
        let expected: UInt8 = [0x6E, 0x51, 0x84, 0x03, 0x10, 0x00, 0x32].reduce(0, ^)
        #expect(p.last == expected)
    }

    @Test func getBrightnessVector() {
        let p = DDC.getVCP(0x10)
        let expected: UInt8 = [0x6E, 0x51, 0x82, 0x01, 0x10].reduce(0, ^)
        #expect(p == [0x82, 0x01, 0x10, expected])
        #expect(expected == 0xAC)   // 0x6E^0x51=0x3F; ^0x82=0xBD; ^0x01=0xBC; ^0x10=0xAC
    }

    @Test func checksumOfRandomPayloadsRoundTrips() {
        for _ in 0..<200 {
            let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
            let c = DDC.checksum(seed: 0x6E, bytes)
            #expect(DDC.checksum(seed: 0x6E, bytes + [c]) == 0)
        }
    }

    @Test func parsesValidReply() throws {
        var r: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        r.append(DDC.checksum(seed: 0x50, r))
        let reply = try DDC.parseGetReply(r, expecting: 0x10)
        #expect(reply == .init(code: 0x10, type: 0, max: 100, current: 50))
    }

    @Test func parsesReplyCapturedFromRealMonitor() throws {
        // Captured from an Acer ED270R S3 on an Apple Silicon Mac through IOAVService (brightness 100 of 100).
        let real: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4]
        let reply = try DDC.parseGetReply(real, expecting: 0x10)
        #expect(reply == .init(code: 0x10, type: 0, max: 100, current: 100))
        // The 12-byte buffer the transport returns (one trailing zero) parses too.
        #expect(try DDC.parseGetReply(real + [0x00]).current == 100)
    }

    @Test func rejectsBadReplies() {
        var good: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
        good.append(DDC.checksum(seed: 0x50, good))

        var badSum = good; badSum[10] ^= 0xFF
        #expect(throws: DDCError.badChecksum) { try DDC.parseGetReply(badSum) }

        #expect(throws: DDCError.badLength(5)) { try DDC.parseGetReply(Array(good.prefix(5))) }

        var badOp = good; badOp[2] = 0x09
        #expect(throws: DDCError.badOpcode(0x09)) { try DDC.parseGetReply(badOp) }

        var unsupported: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x62, 0, 0, 0, 0, 0]
        unsupported.append(DDC.checksum(seed: 0x50, unsupported))
        #expect(throws: DDCError.unsupported(0x62)) { try DDC.parseGetReply(unsupported) }

        #expect(throws: DDCError.unexpectedCode(got: 0x10, wanted: 0x12)) {
            try DDC.parseGetReply(good, expecting: 0x12)
        }
    }

    @Test func capabilityFragmentParses() throws {
        let data = Array("(prot(monitor)".utf8)
        var r: [UInt8] = [0x6E, UInt8(0x80 | (data.count + 3)), 0xE3, 0x00, 0x00] + data
        r.append(DDC.checksum(seed: 0x50, r))
        let f = try DDC.parseCapabilitiesFragment(r + [0, 0, 0])
        #expect(f.offset == 0)
        #expect(f.data == data)
    }
}

@Suite struct ValueMapperTests {
    @Test func mapsAcrossMaxima() {
        for max in [100, 255, 75] {
            #expect(ValueMapper.raw(fromPercent: 0, max: max) == 0)
            #expect(ValueMapper.raw(fromPercent: 100, max: max) == max)
            #expect(ValueMapper.raw(fromPercent: 150, max: max) == max)
            #expect(ValueMapper.raw(fromPercent: -5, max: max) == 0)
            for p in [1, 50, 99] {
                let raw = ValueMapper.raw(fromPercent: p, max: max)
                #expect(raw <= max)
                #expect(abs(ValueMapper.percent(fromRaw: raw, max: max) - p) <= 1 + 50 / max)
            }
        }
        #expect(ValueMapper.raw(fromPercent: 50, max: 0) == 0)
    }
}

@Suite struct MCCSTests {
    static let samples: [(String, Set<UInt8>, UInt8?, [UInt8])] = [
        ("(prot(monitor)type(LCD)model(U2723QE)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B) 16 18 1A 52 60(0F 11 12) 62 AC AE B2 B6 C6 C8 C9 CA CC(01 02 03 04) D6(01 04 05) DC DF)mccs_ver(2.2))",
         [0x02, 0x04, 0x05, 0x08, 0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x52, 0x60, 0x62, 0xAC, 0xAE, 0xB2, 0xB6, 0xC6, 0xC8, 0xC9, 0xCA, 0xCC, 0xD6, 0xDC, 0xDF], 0x60, [0x0F, 0x11, 0x12]),
        ("prot(monitor)type(lcd)vcp(10 12 62)mccs_ver(2.1)", [0x10, 0x12, 0x62], nil, []),
        ("(vcp(10 12 60(11 12 0F) 62 D6(01 04))model(LG ULTRAFINE))", [0x10, 0x12, 0x60, 0x62, 0xD6], 0x60, [0x11, 0x12, 0x0F]),
        ("(prot(monitor)type(LCD)vcp(10 60(01 03)))\0\0\0", [0x10, 0x60], 0x60, [0x01, 0x03]),
        ("(model(Odd Model)vcp(10 12  60( 0F  11 ) 62)mccs_ver(3.0))", [0x10, 0x12, 0x60, 0x62], 0x60, [0x0F, 0x11]),
        ("(vcp(10 12 14(01 02 03 04 05 06 07 08 09 0A 0B) 60(0F 10 11 12 1B) 62)type(LCD))", [0x10, 0x12, 0x14, 0x60, 0x62], 0x14, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),
    ]

    @Test func parsesRealWorldStrings() throws {
        for (text, codes, nested, values) in Self.samples {
            let caps = try MCCSParser.parse(text)
            #expect(Set(caps.vcp.keys) == codes, "\(text)")
            if let n = nested { #expect(caps.allowedValues(n) == values) }
        }
        let first = try MCCSParser.parse(Self.samples[0].0)
        #expect(first.model == "U2723QE")
        #expect(first.mccsVersion == "2.2")
    }

    @Test func malformedNeverCrashes() {
        for junk in ["", "(", ")", "((((", "vcp(", "vcp(10 12", "(vcp())", "\u{0}", "garbage text with no structure", "(vcp(zz yy))"] {
            _ = try? MCCSParser.parse(junk)
        }
    }
}

@Suite struct DDCDeviceTests {
    @Test func coalescesBurstAndSendsFinalValue() async {
        let mon = MockDDCMonitor.typical()
        let dev = DDCDevice(transport: mon, timing: .fast)
        for v in 1...200 { await dev.set(DDC.VCP.brightness, raw: UInt16(v % 100)) }
        await dev.set(DDC.VCP.brightness, raw: 77)
        await dev.waitUntilIdle()
        #expect(mon.value(DDC.VCP.brightness) == 77)
        #expect(mon.setCount <= 5)          // 201 requests collapse to a handful of writes
        #expect(mon.setCount >= 1)
    }

    @Test func respectsMinimumGap() async {
        let mon = MockDDCMonitor.typical()
        var t = DDCTiming.fast
        t.minGap = .milliseconds(20); t.maxGap = .milliseconds(40)
        let dev = DDCDevice(transport: mon, timing: t)
        await dev.set(DDC.VCP.brightness, raw: 10)
        await dev.set(DDC.VCP.contrast, raw: 20)
        await dev.set(DDC.VCP.volume, raw: 30)
        await dev.waitUntilIdle()
        let times = mon.writeLog.map(\.time)
        #expect(times.count == 3)
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(b - a >= .milliseconds(18))
        }
    }

    @Test func readsValueAndMax() async throws {
        let mon = MockDDCMonitor.typical()
        let dev = DDCDevice(transport: mon, timing: .fast)
        let r = try await dev.read(DDC.VCP.brightness)
        #expect(r.current == 50 && r.max == 100)
        #expect(await dev.maxValues[DDC.VCP.brightness] == 100)
    }

    @Test func unsupportedControlIsDefinitive() async {
        let mon = MockDDCMonitor.typical()
        let dev = DDCDevice(transport: mon, timing: .fast)
        await #expect(throws: DDCError.unsupported(0x99)) { try await dev.read(0x99) }
    }

    @Test func retriesCorruptReply() async throws {
        let mon = MockDDCMonitor.typical()
        mon.corruptNextReplies(2)
        let dev = DDCDevice(transport: mon, timing: .fast)
        let r = try await dev.read(DDC.VCP.contrast)
        #expect(r.current == 70)
        #expect(await dev.stats.errors >= 2)
    }

    @Test func writeFailureRetriesOnce() async {
        let mon = MockDDCMonitor.typical()
        mon.failNextWrites(1)
        let dev = DDCDevice(transport: mon, timing: .fast)
        await dev.set(DDC.VCP.brightness, raw: 33)
        await dev.waitUntilIdle()
        #expect(mon.value(DDC.VCP.brightness) == 33)
    }

    @Test func hungTransportTimesOutAndQueueContinues() async {
        let mon = MockDDCMonitor.typical()
        mon.setHang(true)
        let dev = DDCDevice(transport: mon, timing: .fast)
        await #expect(throws: DDCError.timeout) { try await dev.read(DDC.VCP.brightness) }
        #expect(await dev.stats.timeouts >= 1)
    }

    @Test func readsCapabilitiesAcrossFragments() async throws {
        let mon = MockDDCMonitor.typical()
        let dev = DDCDevice(transport: mon, timing: .fast)
        let caps = try await dev.readCapabilities()
        #expect(caps.supports(DDC.VCP.brightness))
        #expect(caps.allowedValues(DDC.VCP.inputSource) == [0x0F, 0x11, 0x12, 0x1B])
        #expect(caps.model == "MockView 27")
    }
}
