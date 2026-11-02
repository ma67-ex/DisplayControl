import Foundation
import DisplayControlCore

// displaycontrol: command line client for the DisplayControl menu bar app (spec 6.8).

let usageText = """
Usage: displaycontrol <command> [options]

Commands:
  status                              compact table of displays
  list                                every display with its id, control mode and controls
  get <display> [--brightness] [--contrast] [--volume] [--input]
  set <display> [--brightness N] [--contrast N] [--volume N] [--boost 100-200] [--mute on|off]
                [--input NAME|CODE] [--rotation 0|90|180|270] [--power on|off]
  set --all --brightness N            apply to every display
  preset list
  preset activate <name> [--delay SECONDS] [--fade SECONDS]
  panic                               undo dimming, extra brightness and a switched color profile
  schedule list | enable <id> | disable <id>
  sync [enable <display> | disable]
  caps <display>                      list the controls a DDC monitor reports
  vcp <display> <code>                read one raw DDC control (code in hex like DC, or 0xDC)
  vcp-set <display> <code> <value>    write one raw DDC control the monitor advertises, and read it back
  nudge <display> <brightness|contrast|volume> <up|down>   one key press worth of change (uses the step size)
  extras                              show Dark Mode, Night Shift, True Tone and HDR
  extra <darkmode|nightshift|truetone|hdr> <on|off> [display]   switch one; nightshift-strength <0-100>
  profiles <display>                  list color profiles and the current one
  profile <display> <name|reset>      switch a display's color profile
  keys                                show whether the keyboard keys are enabled, permitted and running
  mode <display> auto|ddc|apple|software   choose how a display is controlled
  reset-gamma                         undo software dimming
  selftest [<display>] [--mock]       check a display (--mock runs against a simulated monitor)
  probe                               check DDC support without the app (for bug reports)
  mcp                                 run an MCP server on stdio
  version

Options:
  --json | --human      force output format (JSON when piped, human in a terminal)
  --index N | --uuid ID pick a display by index or identity key
  --launch              start the app first if it is not running

Exit codes: 0 ok, 1 usage, 2 app not running, 3 not found, 4 refused, 5 partial.
"""

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// MARK: Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
var forceJSON = false, forceHuman = false, launch = false, useMock = false, all = false
var index: Int?, uuid: String?, delay: Int?, fade: Int?
var props: [String: JSONValue] = [:]
var wantedProps: [String] = []
var positional: [String] = []

func takeValue(_ i: inout Int, _ flag: String) -> String {
    i += 1
    guard i < args.count else { fail("Missing value for \(flag)\n\n\(usageText)", ExitCode.usage) }
    return args[i]
}

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--json": forceJSON = true
    case "--human": forceHuman = true
    case "--launch": launch = true
    case "--mock": useMock = true
    case "--all": all = true
    case "--help", "-h": print(usageText); exit(0)
    case "--index": index = Int(takeValue(&i, a)) ?? { fail("--index needs a number", ExitCode.usage) }()
    case "--uuid": uuid = takeValue(&i, a)
    case "--fade": fade = Int(takeValue(&i, a)) ?? { fail("--fade needs a number of seconds", ExitCode.usage) }()
    case "--delay": delay = Int(takeValue(&i, a)) ?? { fail("--delay needs a number of seconds", ExitCode.usage) }()
    case "--brightness", "--contrast", "--volume", "--rotation", "--boost":
        let key = String(a.dropFirst(2))
        // For `get`, these flags select which values to print; for `set`, they carry a number.
        if args.first == "get" { wantedProps.append(key) }
        else {
            let raw = takeValue(&i, a)
            guard let n = Int(raw) else { fail("\(a) needs a number, got \"\(raw)\"", ExitCode.usage) }
            props[key] = .int(n)
        }
    case "--input":
        if args.first == "get" { wantedProps.append("input") }
        else { props["input"] = .string(takeValue(&i, a)) }
    case "--mute", "--power":
        props[String(a.dropFirst(2))] = .string(takeValue(&i, a))
    default:
        if a.hasPrefix("--") { fail("Unknown option \(a)\n\n\(usageText)", ExitCode.usage) }
        positional.append(a)
    }
    i += 1
}

guard let command = positional.first else { print(usageText); exit(ExitCode.usage) }
let rest = Array(positional.dropFirst())

// MARK: Build the request

func displayArgs(_ name: String?) -> [String: JSONValue] {
    var a: [String: JSONValue] = [:]
    if let name { a["display"] = .string(name) }
    if let index { a["index"] = .int(index) }
    if let uuid { a["uuid"] = .string(uuid) }
    return a
}

var request: IPCRequest
switch command {
case "status", "list", "version", "reset-gamma", "panic":
    request = IPCRequest(cmd: command)
case "keys":
    request = IPCRequest(cmd: "keys.status")
case "profiles":
    request = IPCRequest(cmd: "profiles.get", args: displayArgs(rest.first))
case "profile":
    guard rest.count >= 2 else { fail("Usage: displaycontrol profile <display> <name|reset>", ExitCode.usage) }
    var a = displayArgs(rest[0]); a["profile"] = .string(rest.dropFirst().joined(separator: " "))
    request = IPCRequest(cmd: "profile.set", args: a)
case "extras":
    request = IPCRequest(cmd: "extras.get")
case "extra":
    guard rest.count >= 2 else { fail("Usage: displaycontrol extra <darkmode|nightshift|truetone|hdr|nightshift-strength> <on|off|0-100> [display]", ExitCode.usage) }
    var a = displayArgs(rest.count > 2 ? rest[2] : nil); a["name"] = .string(rest[0]); a["value"] = .string(rest[1])
    if let n = Int(rest[1]) { a["value"] = .int(n) }
    request = IPCRequest(cmd: "extras.set", args: a)
case "nudge":
    guard rest.count == 3 else { fail("Usage: displaycontrol nudge <display> <brightness|contrast|volume> <up|down>", ExitCode.usage) }
    var a = displayArgs(rest[0]); a["property"] = .string(rest[1]); a["direction"] = .string(rest[2])
    request = IPCRequest(cmd: "nudge", args: a)
case "caps":
    request = IPCRequest(cmd: "caps", args: displayArgs(rest.first))
case "vcp-set":
    guard rest.count == 3, let value = Int(rest[2]) else { fail("Usage: displaycontrol vcp-set <display> <code in hex> <value>", ExitCode.usage) }
    let hexc = rest[1].lowercased().replacingOccurrences(of: "0x", with: "")
    guard let code = Int(hexc, radix: 16), (0...255).contains(code) else { fail("The code must be hexadecimal, like 14", ExitCode.usage) }
    var a = displayArgs(rest[0]); a["code"] = .int(code); a["value"] = .int(value)
    request = IPCRequest(cmd: "vcp.set", args: a)
case "vcp":
    guard rest.count == 2 else { fail("Usage: displaycontrol vcp <display> <code>", ExitCode.usage) }
    let hex = rest[1].lowercased().replacingOccurrences(of: "0x", with: "")
    guard let code = Int(hex, radix: 16), (0...255).contains(code) else { fail("The code must be hexadecimal, like DC or 0xDC", ExitCode.usage) }
    var a = displayArgs(rest[0]); a["code"] = .int(code)
    request = IPCRequest(cmd: "vcp.get", args: a)
case "get":
    var a = displayArgs(rest.first)
    if !wantedProps.isEmpty { a["props"] = .array(wantedProps.map { .string($0) }) }
    request = IPCRequest(cmd: "get", args: a)
case "set":
    guard !props.isEmpty else { fail("Nothing to set. Example: displaycontrol set \"Dell\" --brightness 70", ExitCode.usage) }
    var a = displayArgs(all ? nil : rest.first)
    a["props"] = .object(props)
    if all { a["all"] = .bool(true) }
    else if rest.isEmpty && index == nil && uuid == nil { /* the app picks the only display */ }
    request = IPCRequest(cmd: "set", args: a)
case "preset":
    switch rest.first {
    case "list": request = IPCRequest(cmd: "preset.list")
    case "activate":
        guard rest.count >= 2 else { fail("Usage: displaycontrol preset activate <name> [--delay SECONDS]", ExitCode.usage) }
        var a: [String: JSONValue] = ["name": .string(rest.dropFirst().joined(separator: " "))]
        if let delay { a["delay"] = .int(delay) }
        if let fade { a["fade"] = .int(fade) }
        request = IPCRequest(cmd: "preset.activate", args: a)
    default: fail("Usage: displaycontrol preset list | activate <name>", ExitCode.usage)
    }
case "schedule":
    switch rest.first {
    case "list": request = IPCRequest(cmd: "schedule.list")
    case "enable", "disable":
        guard rest.count >= 2 else { fail("Usage: displaycontrol schedule \(rest[0]) <id>", ExitCode.usage) }
        request = IPCRequest(cmd: "schedule.\(rest[0])", args: ["id": .string(rest[1])])
    default: fail("Usage: displaycontrol schedule list | enable <id> | disable <id>", ExitCode.usage)
    }
case "sync":
    switch rest.first {
    case nil: request = IPCRequest(cmd: "sync.status")
    case "enable": request = IPCRequest(cmd: "sync.enable", args: displayArgs(rest.dropFirst().first))
    case "disable": request = IPCRequest(cmd: "sync.disable")
    default: fail("Usage: displaycontrol sync [enable <display> | disable]", ExitCode.usage)
    }
case "mode":
    guard rest.count == 2 else { fail("Usage: displaycontrol mode <display> auto|ddc|apple|software", ExitCode.usage) }
    var a = displayArgs(rest[0]); a["mode"] = .string(rest[1])
    request = IPCRequest(cmd: "mode", args: a)
case "selftest":
    request = IPCRequest(cmd: "selftest", args: displayArgs(rest.first))
case "mcp", "probe":
    request = IPCRequest(cmd: "status")           // unused; handled below
default:
    fail("Unknown command \"\(command)\"\n\n\(usageText)", ExitCode.usage)
}

// MARK: Transport

func send(_ req: IPCRequest) -> IPCResponse {
    func attempt() throws -> IPCResponse { try IPCClient.send(req) }
    do { return try attempt() }
    catch IPCError.notRunning where launch {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", "app.displaycontrol.DisplayControl"]
        try? p.run(); p.waitUntilExit()
        for _ in 0..<25 {                                           // up to 5 seconds
            Thread.sleep(forTimeInterval: 0.2)
            if let r = try? attempt() { return r }
        }
        fail("DisplayControl did not start. Open it from Applications and try again.", ExitCode.notRunning)
    }
    catch IPCError.notRunning { fail("DisplayControl is not running. Open the app, or add --launch.", ExitCode.notRunning) }
    catch { fail(String(describing: error), ExitCode.refused) }
}

if command == "probe" {
    // Keep the main thread free: screen names are read through the main queue.
    Task { print(await DDCProbe.run()); exit(0) }
    dispatchMain()
}

if command == "mcp" {
    let server = MCPServer { req in
        do { return try IPCClient.send(req) }
        catch { return .failure(String(describing: error), code: ExitCode.notRunning) }
    }
    let sem = DispatchSemaphore(value: 0)
    Task { await server.run(); sem.signal() }
    sem.wait()
    exit(0)
}

// `selftest --mock` runs the full pipeline against a simulated monitor, no app or hardware needed.
var response: IPCResponse
if command == "selftest" && useMock {
    let sem = DispatchSemaphore(value: 0)
    var r = IPCResponse.failure("mock failed", code: ExitCode.refused)
    Task {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dc-mock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var timing = DDCTiming(); timing.minGap = .milliseconds(10); timing.maxGap = .milliseconds(20); timing.readDelay = .milliseconds(5)
        let center = DisplayCenter(system: DemoDisplaySystem(), presets: PresetStore(url: tmp.appendingPathComponent("p.json")),
                                   schedules: ScheduleStore(url: tmp.appendingPathComponent("s.json")),
                                   settingsURL: tmp.appendingPathComponent("d.json"), timing: timing, extras: FakeSystemExtras())
        await center.reload()
        var a = displayArgs(rest.first ?? "Demo Monitor")
        a["display"] = .string(rest.first ?? "Demo Monitor")
        r = await CommandRouter(center: center).handle(IPCRequest(cmd: "selftest", args: a))
        sem.signal()
    }
    sem.wait()
    response = r
} else {
    response = send(request)
}

// MARK: Output

let humanOutput = forceHuman || (!forceJSON && isatty(STDOUT_FILENO) != 0)

func render(_ r: IPCResponse) {
    if !humanOutput {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) { print(String(decoding: d, as: UTF8.self)) }
        return
    }
    guard r.ok else { FileHandle.standardError.write(Data(("Error: " + (r.error ?? "failed") + "\n").utf8)); return }
    guard let data = r.data else { print("OK"); return }

    func decode<T: Decodable>(_ t: T.Type) -> T? {
        (try? JSONEncoder().encode(data)).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }
    switch command {
    case "status", "list":
        guard let snaps = decode([DisplaySnapshot].self) else { break }
        if snaps.isEmpty { print("No displays found."); break }
        let rows = snaps.map { s -> [String] in
            func v(_ k: String) -> String { s.values[k].map { "\($0)%" } ?? "-" }
            var flags = ""
            if s.isSyncHost { flags += " [sync host]" }
            if s.isSyncFollower { flags += " [sync]" }
            if s.ddcUnreliable { flags += " [check monitor settings]" }
            return ["\(s.index)", s.name + flags, s.mode.title, v("brightness"), v("contrast"), v("volume")]
        }
        let head = ["#", "Display", "Control", "Bright", "Contrast", "Volume"]
        let widths = (0..<head.count).map { c in max(head[c].count, rows.map { $0[c].count }.max() ?? 0) }
        func line(_ cols: [String]) -> String { zip(cols, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ") }
        print(line(head)); for row in rows { print(line(row)) }
        if command == "list" {
            print()
            for s in snaps { print("\(s.index): \(s.name)  id=\(s.id)  key=\(s.key)  controls=\(s.supported.map(\.rawValue).joined(separator: ","))") }
        }
        return
    case "selftest":
        guard let rep = decode(SelfTestReport.self) else { break }
        print("\(rep.display)  (\(rep.mode.title))")
        for s in rep.steps { print("  \(s.passed ? "PASS" : "FAIL")  \(s.name): \(s.detail)") }
        print(rep.passed ? "\nAll checks passed." : "\nSome checks failed.")
        return
    default: break
    }
    switch data {
    case .null: print("OK")
    case .string(let s): print(s)
    case .array(let items): for it in items { print(it.stringValue ?? "\(it)") }
    case .object(let o): for k in o.keys.sorted() { print("\(k) = \(o[k]?.stringValue ?? "\(o[k]!)")") }
    default: print("\(data)")
    }
    if let e = r.error { FileHandle.standardError.write(Data(("Note: " + e + "\n").utf8)) }
}

render(response)
var code = response.code ?? (response.ok ? ExitCode.ok : ExitCode.refused)
if command == "selftest", response.ok,
   let rep = (try? JSONEncoder().encode(response.data)).flatMap({ try? JSONDecoder().decode(SelfTestReport.self, from: $0) }), !rep.passed {
    code = ExitCode.refused
}
exit(code)
