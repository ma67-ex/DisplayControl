import Foundation

/// A small MCP (Model Context Protocol) server over stdio: newline-delimited JSON-RPC 2.0.
/// It forwards tool calls to the same command router the CLI uses, through `backend`.
public final class MCPServer: @unchecked Sendable {
    public typealias Backend = @Sendable (IPCRequest) async -> IPCResponse
    private let backend: Backend
    public static let protocolVersion = "2024-11-05"

    public init(backend: @escaping Backend) { self.backend = backend }

    // MARK: Tool catalogue

    static func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) }),
                 "additionalProperties": .bool(false)])
    }
    static func prop(_ type: String, _ desc: String, min: Int? = nil, max: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string(type), "description": .string(desc)]
        if let min { o["minimum"] = .int(min) }
        if let max { o["maximum"] = .int(max) }
        return .object(o)
    }

    static let tools: [(name: String, description: String, schema: JSONValue)] = {
        let display = prop("string", "Display name (case-insensitive, partial match allowed). Optional when only one display is connected.")
        return [
            ("list_displays", "List connected displays with their control mode, supported controls and current values.", schema([:])),
            ("get_display", "Read current settings of one display.", schema(["display": display])),
            ("set_display", "Change settings of one display, or all displays with all=true. Values are percentages 0-100 except input, rotation and power.",
             schema([
                "display": display,
                "all": prop("boolean", "Apply to every display."),
                "brightness": prop("integer", "Brightness percent.", min: 0, max: 100),
                "contrast": prop("integer", "Contrast percent.", min: 0, max: 100),
                "volume": prop("integer", "Speaker volume percent.", min: 0, max: 100),
                "boost": prop("integer", "Extra brightness from 100 (normal) to 200, by scaling the monitor's color gains. 100 restores them.", min: 100, max: 200),
                "mute": prop("boolean", "Mute the speakers."),
                "input": prop("string", "Input source: hdmi1, hdmi2, displayport1, displayport2, usbc, or a DDC code."),
                "rotation": prop("integer", "Rotation in degrees: 0, 90, 180 or 270."),
                "power": prop("string", "on or off. Turning a display off needs confirm=true."),
                "confirm": prop("boolean", "Must be true to power a display off."),
             ])),
            ("list_presets", "List saved presets.", schema([:])),
            ("activate_preset", "Apply a saved preset by name.", schema(["name": prop("string", "Preset name.")], required: ["name"])),
            ("set_sync", "Turn brightness sync on (with a host display) or off.",
             schema(["enabled": prop("boolean", "Sync on or off."), "display": prop("string", "Host display when enabling.")], required: ["enabled"])),
            ("list_schedules", "List schedules and whether they are enabled.", schema([:])),
            ("set_schedule_enabled", "Enable or disable a schedule.",
             schema(["id": prop("string", "Schedule id, unique id prefix, or name."), "enabled": prop("boolean", "On or off.")], required: ["id", "enabled"])),
        ]
    }()

    // MARK: JSON-RPC

    /// Handles one line. Returns the reply line, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return encode(error: nil, code: -32700, message: "Parse error")
        }
        let id = obj["id"]
        guard case .string(let method)? = obj["method"] else {
            return encode(error: id, code: -32600, message: "Invalid request")
        }
        let params: [String: JSONValue]
        if case .object(let p)? = obj["params"] { params = p } else { params = [:] }

        switch method {
        case "initialize":
            return encode(result: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("displaycontrol"), "version": .string("1.0.0")]),
            ]), id: id)
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return encode(result: .object([:]), id: id)
        case "tools/list":
            let list = Self.tools.map { JSONValue.object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema]) }
            return encode(result: .object(["tools": .array(list)]), id: id)
        case "tools/call":
            guard case .string(let name)? = params["name"], Self.tools.contains(where: { $0.name == name }) else {
                return encode(error: id, code: -32602, message: "Unknown tool")
            }
            var args: [String: JSONValue] = [:]
            if case .object(let a)? = params["arguments"] { args = a }
            return encode(result: await call(name, args), id: id)
        default:
            if id == nil { return nil }                         // unknown notification
            return encode(error: id, code: -32601, message: "Method not found")
        }
    }

    private func call(_ name: String, _ args: [String: JSONValue]) async -> JSONValue {
        func text(_ s: String, error: Bool = false) -> JSONValue {
            .object(["content": .array([.object(["type": .string("text"), "text": .string(s)])]), "isError": .bool(error)])
        }
        func render(_ r: IPCResponse) -> JSONValue {
            if !r.ok { return text(r.error ?? "Failed", error: true) }
            var out = "OK"
            if let d = r.data, d != .null, let json = try? JSONEncoder().encode(d) { out = String(decoding: json, as: UTF8.self) }
            if let e = r.error { out += "\n(\(e))" }
            return text(out)
        }
        var base: [String: JSONValue] = [:]
        if let d = args["display"] { base["display"] = d }

        switch name {
        case "list_displays": return render(await backend(IPCRequest(cmd: "list")))
        case "get_display": return render(await backend(IPCRequest(cmd: "get", args: base)))
        case "set_display":
            var props: [String: JSONValue] = [:]
            for k in ["brightness", "contrast", "volume", "boost", "mute", "input", "rotation", "power"] { if let v = args[k] { props[k] = v } }
            if let p = props["power"], p.boolValue == false, args["confirm"]?.boolValue != true {
                return text("Turning a display off needs confirm=true. Some monitors cannot be woken over DDC once off.", error: true)
            }
            for k in ["brightness", "contrast", "volume"] {                    // clamp 0-100
                if let v = props[k]?.intValue { props[k] = .int(min(100, max(0, v))) }
            }
            if let b = props["boost"]?.intValue { props["boost"] = .int(min(200, max(100, b))) }
            if props.isEmpty { return text("Nothing to set. Provide at least one of brightness, contrast, volume, boost, mute, input, rotation, power.", error: true) }
            base["props"] = .object(props)
            if let all = args["all"] { base["all"] = all }
            return render(await backend(IPCRequest(cmd: "set", args: base)))
        case "list_presets": return render(await backend(IPCRequest(cmd: "preset.list")))
        case "activate_preset": return render(await backend(IPCRequest(cmd: "preset.activate", args: ["name": args["name"] ?? .null])))
        case "set_sync":
            if args["enabled"]?.boolValue == true { return render(await backend(IPCRequest(cmd: "sync.enable", args: base))) }
            return render(await backend(IPCRequest(cmd: "sync.disable")))
        case "list_schedules": return render(await backend(IPCRequest(cmd: "schedule.list")))
        case "set_schedule_enabled":
            let cmd = args["enabled"]?.boolValue == true ? "schedule.enable" : "schedule.disable"
            return render(await backend(IPCRequest(cmd: cmd, args: ["id": args["id"] ?? .null])))
        default: return text("Unknown tool", error: true)
        }
    }

    private func encode(result: JSONValue, id: JSONValue?) -> String {
        line(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
    }
    private func encode(error id: JSONValue?, code: Int, message: String) -> String {
        line(["jsonrpc": .string("2.0"), "id": id ?? .null, "error": .object(["code": .int(code), "message": .string(message)])])
    }
    private func line(_ obj: [String: JSONValue]) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(JSONValue.object(obj))) ?? Data(), as: UTF8.self)
    }

    /// Reads stdin until EOF, answering each line on stdout.
    public func run() async {
        while let l = readLine(strippingNewline: true) {
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let reply = await handle(line: trimmed) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }
}
