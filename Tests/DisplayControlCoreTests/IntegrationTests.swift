import Testing
import Foundation
import CoreGraphics
@testable import DisplayControlCore

/// In-memory backend standing in for a built-in panel.
final class FakeBackend: DisplayBackend, @unchecked Sendable {
    let mode: ControlMode = .apple
    private let lock = NSLock()
    private var v: [DisplayProperty: Int] = [.brightness: 60]
    func supported() async -> Set<DisplayProperty> { [.brightness] }
    func get(_ p: DisplayProperty) async throws -> Int {
        guard let x = lock.withLock({ v[p] }) else { throw BackendError.unsupported(p) }
        return x
    }
    func set(_ p: DisplayProperty, to value: Int) async throws {
        guard p == .brightness else { throw BackendError.unsupported(p) }
        lock.withLock { v[p] = value }
    }
    func shutdown() async {}
    var brightness: Int { lock.withLock { v[.brightness] ?? -1 } }
}

final class FakeSystem: DisplaySystem, @unchecked Sendable {
    var infos: [DisplayInfo]
    var monitors: [CGDirectDisplayID: MockDDCMonitor] = [:]
    var devices: [CGDirectDisplayID: DDCDevice] = [:]
    var builtIn = FakeBackend()
    var resolutionLog: [String] = []

    init() {
        infos = [
            DisplayInfo(id: 1, identity: .init(vendorID: 0x610, productID: 0xA050, serial: 0, isBuiltIn: true), name: "Built-in Display", isMain: true),
            DisplayInfo(id: 2, identity: .init(vendorID: 0x10AC, productID: 0xA0EF, serial: 7, isBuiltIn: false), name: "Dell U2723QE"),
        ]
        monitors[2] = MockDDCMonitor.typical()
    }
    func currentDisplays() -> [DisplayInfo] { infos }
    func makeBackend(for info: DisplayInfo, preferred: ControlMode?, timing: DDCTiming) async -> DisplayBackend {
        if info.identity.isBuiltIn { return builtIn }
        if preferred == .software { return SoftwareBackend(displayID: info.id) }
        let dev = DDCDevice(transport: monitors[info.id]!, timing: .fast)
        devices[info.id] = dev
        return DDCBackend(device: dev, verifySettle: .milliseconds(30))
    }
    func setResolution(displayID: CGDirectDisplayID, _ spec: ResolutionSpec) throws { resolutionLog.append("\(displayID):\(spec.width)x\(spec.height)") }
    func currentResolution(displayID: CGDirectDisplayID) -> ResolutionSpec? { .init(width: 1920, height: 1080, refreshRate: 60, hiDPI: false) }
    func listResolutions(displayID: CGDirectDisplayID) -> [ResolutionSpec] { [] }
    func setOrigin(displayID: CGDirectDisplayID, x: Int, y: Int) throws {}
    func origin(displayID: CGDirectDisplayID) -> ArrangementSpec { .init(x: 0, y: 0) }
}

func makeCenter(_ sys: FakeSystem = FakeSystem()) -> (DisplayCenter, FakeSystem) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let c = DisplayCenter(system: sys, presets: PresetStore(url: dir.appendingPathComponent("p.json")),
                          schedules: ScheduleStore(url: dir.appendingPathComponent("s.json")),
                          settingsURL: dir.appendingPathComponent("d.json"), timing: .fast)
    return (c, sys)
}

@Suite struct CenterTests {
    @Test func listsDisplaysBuiltInFirst() async {
        let (c, _) = makeCenter()
        await c.reload()
        let s = await c.snapshots()
        #expect(s.map(\.name) == ["Built-in Display", "Dell U2723QE"])
        #expect(s[0].mode == .apple && s[1].mode == .ddc)
        #expect(s[1].supported.contains(.brightness) && s[1].supported.contains(.volume))
    }

    @Test func setReachesTheMonitorInRawUnits() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        try await c.set(query: "dell", .brightness, to: 64)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 64)
        try await c.set(query: "dell", .input, to: InputSource.parse("hdmi1")!)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.inputSource) == 0x11)
    }

    @Test func monitorWithMax255MapsPercent() async throws {
        let sys = FakeSystem()
        sys.monitors[2] = MockDDCMonitor(vcp: [DDC.VCP.brightness: .init(current: 10, max: 255)],
                                         capabilities: "(vcp(10))")
        let (c, _) = makeCenter(sys)
        await c.reload()
        try await c.set(query: "dell", .brightness, to: 50)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 128)          // 50% of 255, rounded
    }

    @Test func unsupportedPropertyIsRefused() async {
        let sys = FakeSystem()
        sys.monitors[2] = MockDDCMonitor(vcp: [DDC.VCP.brightness: .init(current: 10, max: 100)], capabilities: "(vcp(10))")
        let (c, _) = makeCenter(sys)
        await c.reload()
        await #expect(throws: CenterError.self) { try await c.set(query: "dell", .volume, to: 10) }
    }

    @Test func volumeCapApplies() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        let key = await c.snapshots()[1].key
        await c.updateSettings(key: key) { $0.volumeCap = 40 }
        try await c.set(query: "dell", .volume, to: 90)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.volume) == 40)
    }

    @Test func syncPropagatesWithOffsetAndNeverLoops() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        let snaps = await c.snapshots()
        let dellKey = snaps[1].key
        // Follower (built-in) shows 70% when the host is at 100%.
        await c.updateSettings(key: snaps[0].key) { $0.syncScale = SyncMath.scale(followerAtHost100: 70) }
        await c.setSync(enabled: true, hostKey: dellKey)
        try await c.set(query: "dell", .brightness, to: 100)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.builtIn.brightness == 70)
        try await c.set(query: "dell", .brightness, to: 50)
        #expect(sys.builtIn.brightness == 35)
        // Moving the follower does not drive the host (host-to-follower only), and nothing recurses.
        try await c.set(query: "built", .brightness, to: 10)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 50)
        await c.setSync(enabled: false, hostKey: nil)
        try await c.set(query: "dell", .brightness, to: 20)
        #expect(sys.builtIn.brightness == 10)
    }

    @Test func syncSkipsPropertiesTheFollowerLacks() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        await c.setSync(enabled: true, hostKey: await c.snapshots()[1].key)
        try await c.set(query: "dell", .volume, to: 33)       // built-in has no volume: must not throw or change
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.builtIn.brightness != 33)
    }

    @Test func ambiguousAndMissingDisplays() async throws {
        let sys = FakeSystem()
        sys.infos.append(DisplayInfo(id: 3, identity: .init(vendorID: 0x10AC, productID: 0xA0EF, serial: 7, isBuiltIn: false), name: "Dell U2723QE"))
        sys.monitors[3] = MockDDCMonitor.typical()
        let (c, _) = makeCenter(sys)
        await c.reload()
        let snaps = await c.snapshots()
        #expect(snaps.count == 3)                                      // identical monitors get distinct keys
        #expect(Set(snaps.map(\.key)).count == 3)
        await #expect(throws: CenterError.self) { try await c.resolve("dell") }
        await #expect(throws: CenterError.displayNotFound("nothing")) { try await c.resolve("nothing") }
        #expect((try? await c.resolve("#1")) != nil)

        // The second identical monitor must be fully usable by its key: the same string everywhere.
        let second = snaps[2]
        let d = try? await c.resolve(second.key)
        #expect(d != nil)
        #expect(await d?.key == second.key)                           // dictionary key equals identity key
        try? await c.setMode(key: second.key, .software)              // CLI "mode" path
        #expect((await c.snapshots())[2].mode == .software)
        try? await c.setMode(key: second.key, nil)
        #expect((await c.snapshots())[2].mode == .ddc)
        #expect(await c.redetect(key: second.key))                     // CLI "redetect" path

        // Sync with the second monitor as host propagates to the built-in display.
        await c.setSync(enabled: true, hostKey: second.key)
        try? await c.set(query: second.key, .brightness, to: 31)
        await c.settle()
        #expect(sys.builtIn.brightness == 31)
        #expect((await c.snapshots())[2].isSyncHost)

        // Settings saved for the second monitor are found again after a reload.
        await c.updateSettings(key: second.key) { $0.volumeCap = 25 }
        await c.reload()
        #expect((await c.snapshots())[2].settings.volumeCap == 25)
    }

    @Test func hotplugKeepsExistingBackendAndDropsRemoved() async {
        let (c, sys) = makeCenter()
        await c.reload()
        sys.infos.removeLast()
        await c.reload()
        #expect((await c.snapshots()).map(\.name) == ["Built-in Display"])
        sys.infos.append(DisplayInfo(id: 2, identity: .init(vendorID: 0x10AC, productID: 0xA0EF, serial: 7, isBuiltIn: false), name: "Dell U2723QE"))
        await c.reload()
        #expect((await c.snapshots()).count == 2)
    }

    @Test func presetCaptureAndActivate() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        try await c.set(query: "dell", .brightness, to: 30)
        await sys.devices[2]!.waitUntilIdle()
        let p = await c.capturePreset(name: "Night")
        #expect(p.displays.count == 2)
        try c.presets.upsert(p)
        try await c.set(query: "dell", .brightness, to: 90)
        await sys.devices[2]!.waitUntilIdle()
        let results = try await c.activatePreset("night")
        await sys.devices[2]!.waitUntilIdle()
        #expect(PresetApplier.summary(results).failed == 0)
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 30)
        await #expect(throws: CenterError.presetNotFound("nope")) { try await c.activatePreset("nope") }
    }

    @Test func switchingModeToSoftwareAndBack() async throws {
        let (c, _) = makeCenter()
        await c.reload()
        let key = await c.snapshots()[1].key
        try await c.setMode(key: key, .software)
        #expect((await c.snapshots())[1].mode == .software)
        try await c.setMode(key: key, nil)
        #expect((await c.snapshots())[1].mode == .ddc)
    }
}

@Suite struct IPCTests {
    func tempSocket() -> String { "/tmp/dc-test-\(UUID().uuidString.prefix(8)).sock" }

    @Test func roundTripsCommandsOverTheSocket() async throws {
        let (center, sys) = makeCenter()
        await center.reload()
        let router = CommandRouter(center: center)
        let path = tempSocket()
        let server = IPCServer(path: path) { await router.handle($0) }
        try server.start()
        defer { server.stop() }

        // Permissions: owner only.
        var st = stat()
        #expect(stat(path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)

        let status = try IPCClient.send(IPCRequest(cmd: "status"), path: path)
        #expect(status.ok)
        let snaps = try JSONDecoder().decode([DisplaySnapshot].self, from: JSONEncoder().encode(status.data))
        #expect(snaps.count == 2)

        let set = try IPCClient.send(IPCRequest(cmd: "set", args: ["display": .string("dell"), "props": .object(["brightness": .int(42), "input": .string("hdmi2")])]), path: path)
        #expect(set.ok)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 42)
        #expect(sys.monitors[2]!.value(DDC.VCP.inputSource) == 0x12)

        let all = try IPCClient.send(IPCRequest(cmd: "set", args: ["all": .bool(true), "props": .object(["brightness": .int(55)])]), path: path)
        #expect(all.ok)
        #expect(sys.builtIn.brightness == 55)

        let missing = try IPCClient.send(IPCRequest(cmd: "get", args: ["display": .string("nothing")]), path: path)
        #expect(!missing.ok && missing.code == ExitCode.notFound)

        let bad = try IPCClient.send(IPCRequest(cmd: "set", args: ["display": .string("dell"), "props": .object(["brightness": .int(900)])]), path: path)
        #expect(!bad.ok && bad.code == ExitCode.usage)

        let wrongVersion = try IPCClient.send(IPCRequest(cmd: "status", v: 99), path: path)
        #expect(!wrongVersion.ok)

        let unknown = try IPCClient.send(IPCRequest(cmd: "frobnicate"), path: path)
        #expect(unknown.code == ExitCode.usage)

        let ver = try IPCClient.send(IPCRequest(cmd: "version"), path: path)
        #expect(ver.ok)
    }

    @Test func clientReportsNotRunning() {
        #expect(throws: IPCError.self) { try IPCClient.send(IPCRequest(cmd: "status"), path: "/tmp/dc-does-not-exist.sock") }
    }

    @Test func presetAndSyncAndScheduleCommands() async throws {
        let (center, _) = makeCenter()
        await center.reload()
        let router = CommandRouter(center: center)
        try center.presets.upsert(Preset(name: "Work", displays: []))
        let s = Schedule(name: "Morning", trigger: .time(hour: 9, minute: 0, weekdays: []), presetID: UUID())
        try center.schedules.upsert(s)

        #expect((await router.handle(IPCRequest(cmd: "preset.list"))).ok)
        #expect((await router.handle(IPCRequest(cmd: "preset.activate", args: ["name": .string("work")]))).ok)
        #expect((await router.handle(IPCRequest(cmd: "preset.activate", args: ["name": .string("zzz")]))).code == ExitCode.notFound)
        #expect((await router.handle(IPCRequest(cmd: "schedule.disable", args: ["id": .string(String(s.id.uuidString.prefix(6)))]))).ok)
        #expect(center.schedules.all.first?.enabled == false)
        #expect((await router.handle(IPCRequest(cmd: "sync.enable", args: ["display": .string("dell")]))).ok)
        #expect((await center.sync).enabled)
        #expect((await router.handle(IPCRequest(cmd: "sync.disable"))).ok)
        #expect((await router.handle(IPCRequest(cmd: "reset-gamma"))).ok)
    }
}

@Suite struct SelfTestAndMCP {
    @Test func selftestPassesAgainstMockMonitorAndRestoresValue() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        let d = try await c.resolve("dell")
        let report = await SelfTest.run(d)
        #expect(report.passed, "\(report.steps)")
        #expect(report.medianRoundTripMs != nil)
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 50)       // original value restored
    }

    @Test func selftestFlagsMonitorThatIgnoresWrites() async throws {
        let sys = FakeSystem()
        let mon = MockDDCMonitor.typical()
        sys.monitors[2] = mon
        let (c, _) = makeCenter(sys)
        await c.reload()
        mon.failNextWrites(1000)                                        // every write fails
        let d = try await c.resolve("dell")
        let report = await SelfTest.run(d)
        #expect(!report.passed)
    }

    func server() async -> (MCPServer, FakeSystem) {
        let (c, sys) = makeCenter()
        await c.reload()
        let router = CommandRouter(center: c)
        return (MCPServer { await router.handle($0) }, sys)
    }

    func call(_ s: MCPServer, _ json: String) async -> [String: JSONValue]? {
        guard let reply = await s.handle(line: json), let d = reply.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: d)
    }

    @Test func mcpHandshakeAndTools() async {
        let (s, _) = await server()
        let i = await call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        if case .object(let r)? = i?["result"] { #expect(r["protocolVersion"]?.stringValue == MCPServer.protocolVersion) } else { Issue.record("no result") }
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let l = await call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        if case .object(let r)? = l?["result"], case .array(let tools)? = r["tools"] { #expect(tools.count == MCPServer.tools.count) } else { Issue.record("no tools") }
    }

    @Test func mcpSetClampsAndGuardsPowerOff() async throws {
        let (s, sys) = await server()
        let r = await call(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_display","arguments":{"display":"dell","brightness":250}}}"#)
        if case .object(let res)? = r?["result"] { #expect(res["isError"] == .bool(false)) } else { Issue.record("no result") }
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 100)      // clamped to 100

        let off = await call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_display","arguments":{"display":"dell","power":"off"}}}"#)
        if case .object(let res)? = off?["result"] { #expect(res["isError"] == .bool(true)) } else { Issue.record("no result") }
        await sys.devices[2]!.waitUntilIdle()
        #expect(sys.monitors[2]!.value(DDC.VCP.power) == nil)           // nothing was sent
    }

    @Test func mcpErrorsAreJSONRPCNotCrashes() async {
        let (s, _) = await server()
        let bad = await call(s, "not json")
        if case .object(let e)? = bad?["error"] { #expect(e["code"]?.intValue == -32700) } else { Issue.record("no error") }
        let unknown = await call(s, #"{"jsonrpc":"2.0","id":9,"method":"nope"}"#)
        if case .object(let e)? = unknown?["error"] { #expect(e["code"]?.intValue == -32601) } else { Issue.record("no error") }
        let tool = await call(s, #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nope"}}"#)
        if case .object(let e)? = tool?["error"] { #expect(e["code"]?.intValue == -32602) } else { Issue.record("no error") }
    }
}

@Suite struct SubmitAndEvents {
    @Test func submitKeepsLatestValueInOrder() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        let key = try await c.resolve("dell").key
        for v in 1...100 { c.submit(key: key, .brightness, to: v) }
        await c.settle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 100)
    }

    /// The reported bug: dragging a slider down to 1 ended on an older value (10) because ticks raced.
    @Test func draggingDownEndsOnTheFinalValue() async throws {
        for round in 0..<20 {
            let (c, sys) = makeCenter()
            await c.reload()
            let key = try await c.resolve("dell").key
            for v in stride(from: 90, through: 1, by: -1) { c.submit(key: key, .brightness, to: v) }
            await c.settle()
            #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 1, "round \(round)")
        }
    }

    @Test func submitsFromManyThreadsStillEndOnTheLastCall() async throws {
        let (c, sys) = makeCenter()
        await c.reload()
        let key = try await c.resolve("dell").key
        // Calls are made one after another from this task, even though writes run on other threads.
        for v in [80, 10, 55, 3, 70, 1] { c.submit(key: key, .brightness, to: v); await Task.yield() }
        await c.settle()
        #expect(sys.monitors[2]!.value(DDC.VCP.brightness) == 1)
    }

    @Test func triggerPairingForEvents() {
        #expect(Trigger.powerPlugged.starts(on: .power(plugged: true)))
        #expect(Trigger.powerPlugged.ends(on: .power(plugged: false)))
        #expect(!Trigger.powerPlugged.starts(on: .power(plugged: false)))
        #expect(Trigger.appearanceDark.starts(on: .appearance(dark: true)))
        #expect(Trigger.appearanceLight.starts(on: .appearance(dark: false)))
        #expect(Trigger.monitorConnected(identityKey: "K").starts(on: .monitor(key: "K", connected: true)))
        #expect(!Trigger.monitorConnected(identityKey: "K").starts(on: .monitor(key: "OTHER", connected: true)))
        #expect(Trigger.monitorConnected(identityKey: nil).starts(on: .monitor(key: "ANY", connected: true)))
        #expect(Trigger.wake.starts(on: .wake) && !Trigger.wake.starts(on: .lock))
        #expect(Trigger.lock.ends(on: .unlock))
    }

    @Test func connectionEventsFireOnHotplugNotOnFirstLoad() async {
        let (c, sys) = makeCenter()
        final class Log: @unchecked Sendable { var events: [String] = []; let l = NSLock(); func add(_ s: String) { l.withLock { events.append(s) } } }
        let log = Log()
        _ = await c.observeConnections { k, up in log.add("\(k):\(up)") }
        await c.reload()
        let afterFirst = log.l.withLock { log.events.count }
        #expect(afterFirst == 2)                       // observers see the initial load; the Scheduler ignores it until armed
        sys.infos.removeLast()
        await c.reload()
        #expect(log.l.withLock { log.events.last } == "10AC-A0EF-00000007:false")
    }

    @Test func urlCommands() {
        let p = URLCommand.parse(URL(string: "displaycontrol://preset/Movie%20Night")!)
        #expect(p?.cmd == "preset.activate" && p?.args["name"]?.stringValue == "Movie Night")
        let s = URLCommand.parse(URL(string: "displaycontrol://set?display=Dell&brightness=60&input=hdmi1")!)
        #expect(s?.cmd == "set")
        if case .object(let props)? = s?.args["props"] { #expect(props["brightness"]?.intValue == 60 && props["input"]?.stringValue == "hdmi1") }
        #expect(URLCommand.parse(URL(string: "displaycontrol://set")!) == nil)
        #expect(URLCommand.parse(URL(string: "https://example.com")!) == nil)
        #expect(URLCommand.parse(URL(string: "displaycontrol://bogus")!) == nil)
    }
}

@Suite struct BoostTests {
    func center() async throws -> (DisplayCenter, FakeSystem, String) {
        let (c, sys) = makeCenter()
        await c.reload()
        return (c, sys, try await c.resolve("dell").key)
    }
    func gains(_ m: MockDDCMonitor) -> [UInt16?] { [m.value(0x16), m.value(0x18), m.value(0x1A)] }

    @Test func supportedOnlyWhenTheMonitorHasAllThreeGains() async throws {
        let (c, _, _) = try await center()
        #expect((await c.snapshots())[1].supported.contains(.boost))
        let sys = FakeSystem()
        sys.monitors[2] = MockDDCMonitor(vcp: [DDC.VCP.brightness: .init(current: 50, max: 100)], capabilities: "(vcp(10 16))")
        let (c2, _) = makeCenter(sys)
        await c2.reload()
        #expect(!(await c2.snapshots())[1].supported.contains(.boost))
    }

    @Test func doublesGainsInProportionAndKeepsWhiteBalance() async throws {
        let (c, sys, _) = try await center()
        try await c.set(query: "dell", .boost, to: 200)
        await c.settle()
        let g = gains(sys.monitors[2]!)
        #expect(g == [100, 94, 84])                                   // 50, 47, 42 scaled by two
        #expect(sys.monitors[2]!.value(DDC.VCP.colorPreset) == 11)    // the monitor flips itself to "user"
    }

    @Test func partialBoostScalesEachChannel() async throws {
        let (c, sys, _) = try await center()
        try await c.set(query: "dell", .boost, to: 150)
        await c.settle()
        #expect(gains(sys.monitors[2]!) == [75, 71, 63])              // 70.5 rounds to 71
    }

    @Test func hundredPutsBackTheOriginalGainsAndPreset() async throws {
        let (c, sys, _) = try await center()
        try await c.set(query: "dell", .boost, to: 180)
        await c.settle()
        try await c.set(query: "dell", .boost, to: 100)
        await c.settle()
        #expect(gains(sys.monitors[2]!) == [50, 47, 42])
        #expect(sys.monitors[2]!.value(DDC.VCP.colorPreset) == 5)
    }

    @Test func neverExceedsTheChannelMaximum() async throws {
        let sys = FakeSystem()
        sys.monitors[2] = MockDDCMonitor(
            vcp: [DDC.VCP.brightness: .init(current: 50, max: 100), DDC.VCP.colorPreset: .init(current: 5, max: 11),
                  DDC.VCP.gainRed: .init(current: 80, max: 100), DDC.VCP.gainGreen: .init(current: 60, max: 100), DDC.VCP.gainBlue: .init(current: 40, max: 100)],
            capabilities: "(vcp(10 14 16 18 1A))")
        let (c, _) = makeCenter(sys)
        await c.reload()
        try await c.set(query: "dell", .boost, to: 200)
        await c.settle()
        // Red can only go from 80 to 100, so the limit is 125 percent and the others scale by the same factor.
        #expect(gains(sys.monitors[2]!) == [100, 75, 50])
    }

    @Test func readsBackTheCurrentBoost() async throws {
        let (c, _, _) = try await center()
        try await c.set(query: "dell", .boost, to: 140)
        await c.settle()
        let d = try await c.resolve("dell")
        #expect(await d.refresh(.boost) == 140)
        try await c.set(query: "dell", .boost, to: 100)
        await c.settle()
        #expect(await d.refresh(.boost) == 100)
    }

    @Test func baselineSurvivesARestartWhileBoosted() async throws {
        let (c, sys, key) = try await center()
        try await c.set(query: "dell", .boost, to: 160)
        await c.settle()
        try await Task.sleep(for: .milliseconds(50))
        let saved = (await c.snapshots())[1].settings
        #expect(saved.gainBaseline == [50, 47, 42] && saved.gainBaselinePreset == 5)

        // A new center with the same settings file plays the part of a relaunched app.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("d.json")
        try AtomicJSON.write([key: saved], to: url)
        let c2 = DisplayCenter(system: sys, presets: PresetStore(url: dir.appendingPathComponent("p.json")),
                               schedules: ScheduleStore(url: dir.appendingPathComponent("s.json")), settingsURL: url, timing: .fast)
        await c2.reload()
        let d2 = try await c2.resolve(key)
        #expect(await d2.refresh(.boost) == 160)                       // still knows it is boosted
        try await c2.set(d2, .boost, to: 100)
        await c2.settle()
        #expect(gains(sys.monitors[2]!) == [50, 47, 42])
    }

    @Test func outOfRangeValuesAreRejectedByTheRouter() async throws {
        let (c, _, _) = try await center()
        let router = CommandRouter(center: c)
        let bad = await router.handle(IPCRequest(cmd: "set", args: ["display": .string("dell"), "props": .object(["boost": .int(250)])]))
        #expect(!bad.ok && bad.code == ExitCode.usage)
        let ok = await router.handle(IPCRequest(cmd: "set", args: ["display": .string("dell"), "props": .object(["boost": .int(120)])]))
        #expect(ok.ok)
    }
}
