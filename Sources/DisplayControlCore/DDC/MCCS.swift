import Foundation

/// Parsed MCCS capabilities string, e.g.
/// `(prot(monitor)type(LCD)model(X)cmds(01 02 03)vcp(10 12 60(0F 11 12) 62)mccs_ver(2.2))`.
public struct Capabilities: Equatable, Sendable, Codable {
    public var model: String?
    public var type: String?
    public var mccsVersion: String?
    /// VCP code to its allowed discrete values (empty array means continuous or unspecified).
    public var vcp: [UInt8: [UInt8]] = [:]

    public init() {}

    public func supports(_ code: UInt8) -> Bool { vcp[code] != nil }
    public func allowedValues(_ code: UInt8) -> [UInt8] { vcp[code] ?? [] }
}

public enum MCCSParser {
    /// Never crashes on malformed input: returns what could be parsed, or throws if nothing sensible was found.
    public static func parse(_ text: String) throws -> Capabilities {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        // Some monitors append a NUL or trailing garbage.
        s = s.prefix { $0 != "\0" }
        // Strip one level of outer parentheses if present.
        if s.first == "(", let close = matchingParen(in: s, from: s.startIndex), close == s.index(before: s.endIndex) {
            s = s[s.index(after: s.startIndex)..<close]
        }

        var caps = Capabilities()
        var i = s.startIndex
        var sawAny = false
        while i < s.endIndex {
            // identifier
            while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
            let nameStart = i
            while i < s.endIndex, s[i] != "(", s[i] != " " { i = s.index(after: i) }
            let name = String(s[nameStart..<i]).lowercased()
            while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
            guard i < s.endIndex, s[i] == "(" else { if i < s.endIndex { i = s.index(after: i) }; continue }
            guard let close = matchingParen(in: s, from: i) else { break }
            let body = s[s.index(after: i)..<close]
            i = s.index(after: close)

            switch name {
            case "model": caps.model = String(body); sawAny = true
            case "type": caps.type = String(body); sawAny = true
            case "mccs_ver": caps.mccsVersion = String(body); sawAny = true
            case "vcp":
                caps.vcp.merge(parseVCPList(body)) { a, _ in a }
                sawAny = true
            default: break
            }
        }
        guard sawAny else { throw DDCError.malformedCapabilities }
        return caps
    }

    /// `10 12 60(0F 11 12) 62` to `[0x10: [], 0x12: [], 0x60: [0x0F,0x11,0x12], 0x62: []]`.
    static func parseVCPList(_ body: Substring) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = body.startIndex
        while i < body.endIndex {
            while i < body.endIndex, body[i] == " " { i = body.index(after: i) }
            let start = i
            while i < body.endIndex, isHex(body[i]) { i = body.index(after: i) }
            guard start != i, let code = UInt8(body[start..<i], radix: 16) else {
                if i < body.endIndex { i = body.index(after: i) }
                continue
            }
            var j = i
            while j < body.endIndex, body[j] == " " { j = body.index(after: j) }
            if j < body.endIndex, body[j] == "(", let close = matchingParen(in: body, from: j) {
                let inner = body[body.index(after: j)..<close]
                out[code] = inner.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                i = body.index(after: close)
            } else {
                out[code] = []
            }
        }
        return out
    }

    private static func isHex(_ c: Character) -> Bool { c.isHexDigit }

    private static func matchingParen(in s: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var i = open
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 }
            else if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }
}
