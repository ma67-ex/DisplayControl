import Foundation

/// DDC/CI wire format helpers. All constants are named so they can be tuned
/// per display if a monitor needs different behaviour.
///
/// UNVERIFIED ON HARDWARE: these follow the VESA DDC/CI description and common
/// open implementations. They are unit-tested against known byte vectors, but
/// they have not been exercised against a real monitor on this machine.
public enum DDC {
    /// 7-bit I2C address of the display's DDC/CI endpoint.
    public static let chipAddress: UInt8 = 0x37
    /// Source ("host") address byte used as the I2C data address.
    public static let hostAddress: UInt8 = 0x51
    /// Destination address on the wire (chip address shifted left).
    public static let destinationWire: UInt8 = 0x6E
    /// Seed for checksums on replies from the display. HARDWARE-VERIFIED (Acer ED270R S3, Apple Silicon):
    /// the reply checksum is this seed XOR every preceding byte of the reply, including the leading 0x6E.
    public static let replySeed: UInt8 = 0x50
    /// Length in bytes of a Get VCP reply (including the leading source byte).
    public static let getReplyLength = 11
    /// Maximum bytes of a capabilities reply fragment.
    public static let capsReplyLength = 38

    public enum Opcode {
        public static let setVCP: UInt8 = 0x03
        public static let getVCP: UInt8 = 0x01
        public static let getVCPReply: UInt8 = 0x02
        public static let capsRequest: UInt8 = 0xF3
        public static let capsReply: UInt8 = 0xE3
    }

    /// Well-known MCCS VCP codes.
    public enum VCP {
        public static let brightness: UInt8 = 0x10
        public static let contrast: UInt8 = 0x12
        public static let colorPreset: UInt8 = 0x14
        public static let gainRed: UInt8 = 0x16
        public static let gainGreen: UInt8 = 0x18
        public static let gainBlue: UInt8 = 0x1A
        public static let inputSource: UInt8 = 0x60
        public static let volume: UInt8 = 0x62
        public static let orientation: UInt8 = 0xAA
        public static let mute: UInt8 = 0x8D
        public static let power: UInt8 = 0xD6
        public static let capabilities: UInt8 = 0xF3
    }

    /// XOR of `bytes` onto `seed`.
    public static func checksum(seed: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Payload for Set VCP, to be written at data address 0x51.
    /// Layout: `[0x84, 0x03, vcp, hi, lo, checksum]`.
    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x84, Opcode.setVCP, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        p.append(checksum(seed: destinationWire ^ hostAddress, p))
        return p
    }

    /// Payload for Get VCP. Layout: `[0x82, 0x01, vcp, checksum]`.
    public static func getVCP(_ code: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x82, Opcode.getVCP, code]
        p.append(checksum(seed: destinationWire ^ hostAddress, p))
        return p
    }

    /// Payload for a capabilities fragment request at `offset`.
    public static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x83, Opcode.capsRequest, UInt8(offset >> 8), UInt8(offset & 0xFF)]
        p.append(checksum(seed: destinationWire ^ hostAddress, p))
        return p
    }

    // MARK: Parsing

    public struct VCPReply: Equatable, Sendable {
        public let code: UInt8
        public let type: UInt8
        public let max: UInt16
        public let current: UInt16
        public init(code: UInt8, type: UInt8, max: UInt16, current: UInt16) {
            self.code = code; self.type = type; self.max = max; self.current = current
        }
    }

    /// Parses a Get VCP reply. `bytes[0]` is the display's source byte (0x6E).
    public static func parseGetReply(_ bytes: [UInt8], expecting code: UInt8? = nil) throws -> VCPReply {
        guard bytes.count >= getReplyLength else { throw DDCError.badLength(bytes.count) }
        let b = Array(bytes.prefix(getReplyLength))
        guard b[1] == 0x88, b[2] == Opcode.getVCPReply else { throw DDCError.badOpcode(b[2]) }
        let expected = checksum(seed: replySeed, Array(b[0..<10]))
        guard expected == b[10] else { throw DDCError.badChecksum }
        guard b[3] == 0x00 else { throw DDCError.unsupported(b[4]) }
        if let code, b[4] != code { throw DDCError.unexpectedCode(got: b[4], wanted: code) }
        return VCPReply(code: b[4], type: b[5],
                        max: UInt16(b[6]) << 8 | UInt16(b[7]),
                        current: UInt16(b[8]) << 8 | UInt16(b[9]))
    }

    /// Parses one capabilities reply fragment into its offset and data bytes.
    public static func parseCapabilitiesFragment(_ bytes: [UInt8]) throws -> (offset: Int, data: [UInt8]) {
        guard bytes.count >= 6 else { throw DDCError.badLength(bytes.count) }
        let length = Int(bytes[1] & 0x7F)          // opcode + offset(2) + data
        guard length >= 3, bytes.count >= length + 3 else { throw DDCError.badLength(bytes.count) }
        guard bytes[2] == Opcode.capsReply else { throw DDCError.badOpcode(bytes[2]) }
        let end = 2 + length                        // index of checksum byte
        let expected = checksum(seed: replySeed, Array(bytes[0..<end]))
        guard expected == bytes[end] else { throw DDCError.badChecksum }
        let offset = Int(bytes[3]) << 8 | Int(bytes[4])
        return (offset, Array(bytes[5..<end]))
    }
}

public enum DDCError: Error, Equatable, CustomStringConvertible {
    case badLength(Int)
    case badOpcode(UInt8)
    case badChecksum
    case unsupported(UInt8)
    case unexpectedCode(got: UInt8, wanted: UInt8)
    case timeout
    case transport(Int32)
    case noTransport
    case malformedCapabilities

    public var description: String {
        switch self {
        case .badLength(let n): return "Unexpected reply length (\(n) bytes)"
        case .badOpcode(let o): return String(format: "Unexpected reply opcode 0x%02X", o)
        case .badChecksum: return "Reply failed its checksum"
        case .unsupported(let c): return String(format: "Monitor does not support control 0x%02X", c)
        case .unexpectedCode(let g, let w): return String(format: "Got control 0x%02X, wanted 0x%02X", g, w)
        case .timeout: return "The monitor did not answer in time"
        case .transport(let c): return "I2C transport error (\(c))"
        case .noTransport: return "No DDC connection available for this display"
        case .malformedCapabilities: return "Could not read the monitor's capability list"
        }
    }
}
