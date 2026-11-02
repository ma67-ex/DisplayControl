import Foundation

/// Minimal JSON value so requests can carry loosely typed arguments.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v.rounded())
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var stringValue: String? {
        switch self { case .string(let s): return s; case .int(let i): return String(i); default: return nil }
    }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["on", "true", "yes", "1"].contains(s.lowercased()) ? true : (["off", "false", "no", "0"].contains(s.lowercased()) ? false : nil)
        case .int(let i): return i != 0
        default: return nil
        }
    }

    /// Encodes any Encodable into a JSONValue.
    public static func from<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return v
    }
}

public enum IPC {
    public static let version = 1
}

public struct IPCRequest: Codable, Sendable {
    public var v: Int
    public var id: Int?
    public var cmd: String
    public var args: [String: JSONValue]

    public init(cmd: String, args: [String: JSONValue] = [:], id: Int? = nil, v: Int = IPC.version) {
        self.v = v; self.id = id; self.cmd = cmd; self.args = args
    }
}

/// Exit codes shared with the CLI (spec 6.8).
public enum ExitCode {
    public static let ok: Int32 = 0
    public static let usage: Int32 = 1
    public static let notRunning: Int32 = 2
    public static let notFound: Int32 = 3
    public static let refused: Int32 = 4
    public static let partial: Int32 = 5
}

public struct IPCResponse: Codable, Sendable {
    public var v: Int = IPC.version
    public var id: Int?
    public var ok: Bool
    public var data: JSONValue?
    public var error: String?
    public var code: Int32?

    public static func success(_ data: JSONValue = .null, id: Int? = nil) -> IPCResponse {
        IPCResponse(id: id, ok: true, data: data, error: nil, code: ExitCode.ok)
    }
    public static func failure(_ message: String, code: Int32, id: Int? = nil) -> IPCResponse {
        IPCResponse(id: id, ok: false, data: nil, error: message, code: code)
    }
}
