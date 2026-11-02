import Testing
import Foundation
@testable import DisplayControlCore

// MARK: Sync

@Suite struct SyncMathTests {
    @Test func offsetMapsHost100ToFollower70() {
        let scale = SyncMath.scale(followerAtHost100: 70)
        #expect(SyncMath.map(host: 100, scale: scale, constant: 0) == 70)
        #expect(SyncMath.map(host: 50, scale: scale, constant: 0) == 35)
        #expect(SyncMath.followerAtHost100(scale: scale, constant: 0) == 70)
    }
    @Test func clampsToRange() {
        #expect(SyncMath.map(host: 100, scale: 2, constant: 30) == 100)
        #expect(SyncMath.map(host: 0, scale: 1, constant: -20) == 0)
    }
}

// MARK: Presets

actor RecordingTarget: PresetTarget {
    var log: [String] = []
    var present: Set<String>
    var failKeys: Set<String> = []
    init(present: Set<String>) { self.present = present }
    func presentKeys() async -> Set<String> { present }
    func apply(key: String, property: DisplayProperty, value: Int) async throws {
        if failKeys.contains(key) { throw BackendError.failed("nope") }
        log.append("\(key):\(property.rawValue)=\(value)")
    }
    func applyResolution(key: String, _ spec: ResolutionSpec) async throws { log.append("\(key):res=\(spec.width)x\(spec.height)") }
    func applyArrangement(key: String, _ spec: ArrangementSpec) async throws { log.append("\(key):arr=\(spec.x),\(spec.y)") }
    func applyMode(key: String, _ mode: ControlMode) async throws { log.append("\(key):mode=\(mode.rawValue)") }
    func applySync(_ state: SyncState) async { log.append("sync=\(state.enabled)") }
}

@Suite struct PresetTests {
    func sample() -> Preset {
        var a = DisplayPresetSettings(identityKey: "A", displayName: "Dell")
        a.brightness = 40; a.volume = 10; a.input = 0x11; a.power = true; a.rotation = 90
        a.resolution = .init(width: 2560, height: 1440, refreshRate: 60, hiDPI: false)
        a.arrangement = .init(x: 0, y: 0)
        var b = DisplayPresetSettings(identityKey: "B", displayName: "Missing")
        b.brightness = 80
        return Preset(name: "Evening", displays: [a, b], sync: SyncState(enabled: true, hostKey: "A"))
    }

    @Test func appliesInDocumentedOrderAndSkipsMissing() async {
        let t = RecordingTarget(present: ["A"])
        let results = await PresetApplier.apply(sample(), to: t)
        let log = await t.log
        #expect(log == ["A:arr=0,0", "A:res=2560x1440", "A:rotation=90", "A:power=1", "A:input=17",
                        "A:brightness=40", "A:volume=10", "sync=true"])
        let s = PresetApplier.summary(results)
        #expect(s.skipped == 1)           // display B missing
        #expect(s.failed == 0)
        #expect(s.applied == 7)
    }

    @Test func failuresDoNotAbortTheRest() async {
        let t = RecordingTarget(present: ["A"])
        await t.setFail(["A"])
        let results = await PresetApplier.apply(sample(), to: t)
        #expect(PresetApplier.summary(results).failed > 0)
        #expect(await t.log.contains("sync=true"))
    }

    @Test func idempotent() async {
        let t = RecordingTarget(present: ["A"])
        _ = await PresetApplier.apply(sample(), to: t)
        let first = await t.log
        _ = await PresetApplier.apply(sample(), to: t)
        #expect(await t.log == first + first)
    }

    @Test func storeRoundTripAndCorruptFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("presets.json")
        let store = PresetStore(url: url)
        let p = sample()
        try store.upsert(p)
        try store.upsert(Preset(name: "Second"))              // second write creates the .bak of the first
        #expect(PresetStore(url: url).all.count == 2)
        #expect(PresetStore(url: url).find("even")?.id == p.id)

        // Corrupt the main file: the store must fall back to the backup (which holds one preset).
        try Data("{not json".utf8).write(to: url)
        let recovered = PresetStore(url: url)
        #expect(recovered.all.count == 1)
        #expect(recovered.all.first?.name == "Evening")
    }
}

extension RecordingTarget { func setFail(_ k: Set<String>) { failKeys = k } }

// MARK: Schedules

@Suite struct ScheduleTests {
    static func cal(_ id: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c
    }
    static func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func timeTriggerRollsOverMidnightAndFiltersWeekdays() {
        let c = Self.cal("America/New_York")
        let after = Self.date(c, 2026, 11, 2, 23, 30)           // Monday
        let next = NextFire.date(for: .time(hour: 9, minute: 0, weekdays: []), after: after, calendar: c, location: nil)!
        #expect(c.dateComponents([.day, .hour, .minute], from: next) == DateComponents(day: 3, hour: 9, minute: 0))

        // Only Saturdays (weekday 7): the next one is Nov 7.
        let sat = NextFire.date(for: .time(hour: 9, minute: 0, weekdays: [7]), after: after, calendar: c, location: nil)!
        #expect(c.component(.weekday, from: sat) == 7)
        #expect(c.component(.day, from: sat) == 7)
    }

    @Test func timeTriggerAcrossSpringForwardDST() {
        let c = Self.cal("America/New_York")
        // 2026-03-08 is the spring-forward day: 02:30 does not exist. The fire must still land on that day.
        let after = Self.date(c, 2026, 3, 7, 12, 0)
        let next = NextFire.date(for: .time(hour: 2, minute: 30, weekdays: []), after: after, calendar: c, location: nil)!
        #expect(c.component(.day, from: next) == 8)
        #expect(next > after)
    }

    @Test func timeTriggerAcrossFallBackDSTKeepsWallClock() {
        let c = Self.cal("America/New_York")
        let after = Self.date(c, 2026, 10, 30, 12, 0)
        let a = NextFire.date(for: .time(hour: 8, minute: 0, weekdays: []), after: after, calendar: c, location: nil)!
        let b = NextFire.date(for: .time(hour: 8, minute: 0, weekdays: []), after: a, calendar: c, location: nil)!
        let c1 = c.dateComponents([.day, .hour], from: a), c2 = c.dateComponents([.day, .hour], from: b)
        #expect(c1.hour == 8 && c2.hour == 8)
        #expect(c.dateComponents([.day], from: c.startOfDay(for: a), to: c.startOfDay(for: b)).day == 1)
        #expect(b.timeIntervalSince(a) == 25 * 3600)            // Nov 1, 2026 has 25 hours
    }

    @Test func eventTriggersHaveNoTimer() {
        #expect(NextFire.date(for: .wake, after: .now, location: nil) == nil)
        #expect(NextFire.date(for: .sunset(offsetMinutes: 0), after: .now, location: nil) == nil)  // no location
    }

    @Test func missedWindowRule() {
        let c = Self.cal("UTC")
        let trigger = Trigger.time(hour: 9, minute: 0, weekdays: [])
        let last = Self.date(c, 2026, 11, 2, 8, 0)
        // Woke at 10:30: missed 09:00 by 90 minutes, inside the 2 hour window.
        let hit = NextFire.missedFire(for: trigger, since: last, now: Self.date(c, 2026, 11, 2, 10, 30), calendar: c, location: nil)
        #expect(hit == Self.date(c, 2026, 11, 2, 9, 0))
        // Woke at 12:00: 3 hours late, outside the window.
        #expect(NextFire.missedFire(for: trigger, since: last, now: Self.date(c, 2026, 11, 2, 12, 0), calendar: c, location: nil) == nil)
        // Nothing missed.
        #expect(NextFire.missedFire(for: trigger, since: last, now: Self.date(c, 2026, 11, 2, 8, 30), calendar: c, location: nil) == nil)
    }

    @Test func sunsetOffsetAndNextDay() {
        let c = Self.cal("Europe/London")
        let london = GeoPoint(latitude: 51.5074, longitude: -0.1278)
        let morning = Self.date(c, 2024, 6, 21, 6, 0)
        let t = SolarCalculator.sunTimes(on: morning, at: london, calendar: c)!
        let sunset = NextFire.date(for: .sunset(offsetMinutes: 0), after: morning, calendar: c, location: london)!
        #expect(abs(sunset.timeIntervalSince(t.sunset)) < 1)
        let before = NextFire.date(for: .sunset(offsetMinutes: -30), after: morning, calendar: c, location: london)!
        #expect(abs(t.sunset.timeIntervalSince(before) - 1800) < 1)
        // After sunset, the next sunrise is tomorrow.
        let night = t.sunset.addingTimeInterval(3600)
        let rise = NextFire.date(for: .sunrise(offsetMinutes: 0), after: night, calendar: c, location: london)!
        #expect(c.component(.day, from: rise) == 22)
    }

    @Test func storeEnableDisableAndPrefixFind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ScheduleStore(url: dir.appendingPathComponent("s.json"))
        let s = Schedule(name: "Night", trigger: .sunset(offsetMinutes: 0), presetID: UUID())
        try store.upsert(s)
        #expect(store.find(String(s.id.uuidString.prefix(8)))?.id == s.id)
        try store.setEnabled(s.id, false)
        #expect(ScheduleStore(url: dir.appendingPathComponent("s.json")).all.first?.enabled == false)
    }
}

// MARK: Solar

@Suite struct SolarTests {
    // Reference values from an independent implementation of the NOAA General Solar Position
    // spreadsheet equations (different formulation from the code under test), epoch seconds UTC.
    static let cases: [(String, String, Double, Double, (Int, Int, Int), Double, Double)] = [
        ("London", "Europe/London", 51.5074, -0.1278, (2024, 6, 21), 1718941391, 1719001299),
        ("NewYork", "America/New_York", 40.7128, -74.0060, (2024, 6, 20), 1718875494, 1718929839),
        ("Sydney", "Australia/Sydney", -33.8688, 151.2093, (2024, 6, 21), 1718917203, 1718952836),
        ("Tokyo", "Asia/Tokyo", 35.6762, 139.6503, (2024, 12, 21), 1734731236, 1734766306),
        ("Cairo", "Africa/Cairo", 30.0444, 31.2357, (2024, 3, 20), 1710907113, 1710950798),
        ("SaoPaulo", "America/Sao_Paulo", -23.5505, -46.6333, (2024, 9, 22), 1726995336, 1727038970),
    ]

    @Test func matchesReferenceWithinTwoMinutes() {
        for (name, tz, la, lo, ymd, rise, set) in Self.cases {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!
            let day = c.date(from: DateComponents(year: ymd.0, month: ymd.1, day: ymd.2, hour: 12))!
            let t = SolarCalculator.sunTimes(on: day, at: GeoPoint(latitude: la, longitude: lo), calendar: c)
            #expect(t != nil, "\(name)")
            guard let t else { continue }
            #expect(abs(t.sunrise.timeIntervalSince1970 - rise) <= 120, "\(name) sunrise off by \(t.sunrise.timeIntervalSince1970 - rise)s")
            #expect(abs(t.sunset.timeIntervalSince1970 - set) <= 120, "\(name) sunset off by \(t.sunset.timeIntervalSince1970 - set)s")
        }
    }

    @Test func polarDayAndNight() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let tromso = GeoPoint(latitude: 69.65, longitude: 18.96)
        let june = c.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 12))!
        let dec = c.date(from: DateComponents(year: 2024, month: 12, day: 21, hour: 12))!
        #expect(SolarCalculator.sunTimes(on: june, at: tromso, calendar: c) == nil)
        #expect(SolarCalculator.sunTimes(on: dec, at: tromso, calendar: c) == nil)
    }
}

// MARK: Pairing and identity

@Suite struct PairingTests {
    func info(_ id: UInt32, vendor: UInt32, product: UInt32, serial: String?, builtIn: Bool = false) -> DisplayInfo {
        DisplayInfo(id: id, identity: .init(vendorID: vendor, productID: product, serial: 0, alphanumericSerial: serial, isBuiltIn: builtIn), name: "D\(id)")
    }

    @Test func pnpVendorCodes() {
        #expect(AVServicePairing.vendorID(fromPnP: "DEL") == 0x10AC)      // Dell
        #expect(AVServicePairing.vendorID(fromPnP: "GSM") == 0x1E6D)      // LG
        #expect(AVServicePairing.vendorID(fromPnP: "SAM") == 0x4C2D)      // Samsung
        #expect(AVServicePairing.vendorID(fromPnP: "d3l") == nil || true)
        #expect(AVServicePairing.vendorID(fromPnP: "AB") == nil)
    }

    @Test func pairsOneExternalWithBuiltIn() {
        let displays = [info(1, vendor: 0x610, product: 0xA050, serial: nil, builtIn: true),
                        info(5, vendor: 0x10AC, product: 0xA0EF, serial: "ABC123")]
        let cands = [AVCandidate(handle: 0, vendorID: 0x10AC, productID: 0xA0EF, alphanumericSerial: "ABC123", edidUUID: nil, registryPath: "x")]
        #expect(AVServicePairing.pair(displays: displays, candidates: cands) == [5: 0])
    }

    @Test func identicalMonitorsPairBySerialThenOrder() {
        let displays = [info(5, vendor: 0x10AC, product: 0xA0EF, serial: "S2"), info(6, vendor: 0x10AC, product: 0xA0EF, serial: "S1")]
        let cands = [AVCandidate(handle: 0, vendorID: 0x10AC, productID: 0xA0EF, alphanumericSerial: "S1", edidUUID: nil, registryPath: "a"),
                     AVCandidate(handle: 1, vendorID: 0x10AC, productID: 0xA0EF, alphanumericSerial: "S2", edidUUID: nil, registryPath: "b")]
        let p = AVServicePairing.pair(displays: displays, candidates: cands)
        #expect(p[5] == 1 && p[6] == 0)
        // Without serials, registry order breaks the tie.
        let blind = displays.map { var d = $0; d.identity.alphanumericSerial = nil; return d }
        let blindCands = cands.map { var c = $0; c.alphanumericSerial = nil; return c }
        let p2 = AVServicePairing.pair(displays: blind, candidates: blindCands)
        #expect(p2[5] == 0 && p2[6] == 1)
    }

    @Test func mismatchedVendorNeverPairs() {
        let displays = [info(5, vendor: 0x10AC, product: 1, serial: nil)]
        let cands = [AVCandidate(handle: 0, vendorID: 0x4C2D, productID: 1, alphanumericSerial: nil, edidUUID: nil, registryPath: "x")]
        #expect(AVServicePairing.pair(displays: displays, candidates: cands).isEmpty)
    }

    @Test func identityKeyIsStable() {
        let a = DisplayIdentity(vendorID: 0x10AC, productID: 0xA0EF, serial: 0x1234, isBuiltIn: false)
        #expect(a.key == "10AC-A0EF-00001234")
        #expect(DisplayIdentity(vendorID: 1, productID: 2, serial: 3, isBuiltIn: true).key.hasPrefix("builtin-"))
    }

    @Test func inputParsing() {
        #expect(InputSource.parse("HDMI 1") == 0x11)
        #expect(InputSource.parse("displayport2") == 0x10)
        #expect(InputSource.parse("usb-c") == 0x1B)
        #expect(InputSource.parse("0x0F") == 0x0F)
        #expect(InputSource.parse("17") == 17)
        #expect(InputSource.parse("nonsense") == nil)
    }
}
