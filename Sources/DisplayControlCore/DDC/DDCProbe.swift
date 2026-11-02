import Foundation
import IOKit
import CoreGraphics

/// A no-app diagnostic: shows what the registry exposes for DDC, how displays were paired with it,
/// and whether a brightness read works. Output is plain text for bug reports.
public enum DDCProbe {
    public static func run() async -> String {
        var out: [String] = []
        out.append("IOAVService API available: \(AVServiceAPI.shared.isAvailable)")
        out.append("DisplayServices API available: \(DisplayServicesAPI.shared.isAvailable)")

        let system = LiveDisplaySystem()
        let displays = system.currentDisplays()
        out.append("Displays (\(displays.count)):")
        for d in displays {
            out.append(String(format: "  id=%u %@ vendor=0x%04X product=0x%04X serial=%u builtIn=%@", d.id, d.name,
                              d.identity.vendorID, d.identity.productID, d.identity.serial, d.identity.isBuiltIn ? "yes" : "no"))
        }

        // Every DCPAVServiceProxy in the registry, with its Location, so a missing pairing is visible.
        out.append("Registry DCPAVServiceProxy entries:")
        var iterator = io_iterator_t()
        if IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS {
            var n = 0
            while case let e = IOIteratorNext(iterator), e != 0 {
                var nameBuf = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(e, &nameBuf)
                let name = String(cString: nameBuf)
                if name == "DCPAVServiceProxy" {
                    let loc = IORegistryEntryCreateCFProperty(e, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "?"
                    out.append("  #\(n) Location=\(loc)")
                    n += 1
                }
                IOObjectRelease(e)
            }
            IOObjectRelease(iterator)
            if n == 0 { out.append("  (none)") }
        }

        let resolver = AVServiceResolver()
        let candidates = resolver.discover()
        out.append("External candidates: \(candidates.count)")
        for c in candidates {
            out.append(String(format: "  #%d vendor=%@ product=%@ serial=%@", c.handle,
                              c.vendorID.map { String(format: "0x%04X", $0) } ?? "?", c.productID.map { String(format: "0x%04X", $0) } ?? "?", c.alphanumericSerial ?? "?"))
        }
        let pairing = AVServicePairing.pair(displays: displays, candidates: candidates)
        for d in displays where !d.identity.isBuiltIn {
            guard let idx = pairing[d.id], let transport = resolver.transport(for: candidates[idx]) else {
                out.append("\(d.name): no DDC service paired (it will use software dimming).")
                continue
            }
            out.append("\(d.name): paired with candidate #\(idx).")
            // Raw dump: the exact bytes a brightness request returns, at a few delays and buffer sizes.
            for (delayMs, len) in [(40, 11), (50, 12), (100, 12), (200, 12)] {
                do {
                    try transport.write(DDC.getVCP(DDC.VCP.brightness))
                    try await Task.sleep(for: .milliseconds(delayMs))
                    let bytes = try transport.read(length: len)
                    out.append("  raw (delay \(delayMs) ms, len \(len)): " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                } catch { out.append("  raw (delay \(delayMs) ms, len \(len)): error \(error)") }
                try? await Task.sleep(for: .milliseconds(100))
            }
            out.append("  Reading brightness through the normal path...")
            let device = DDCDevice(transport: transport)
            do {
                let r = try await device.read(DDC.VCP.brightness)
                out.append("  brightness = \(r.current) of \(r.max): DDC WORKS")
                if let caps = try? await device.readCapabilities() {
                    out.append("  capabilities: model=\(caps.model ?? "?") controls=\(caps.vcp.keys.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))")
                } else { out.append("  capabilities: not reported") }
            } catch {
                out.append("  read failed: \(error). Stats: \(await device.stats)")
                out.append("  Tips: switch the monitor's picture mode to Custom, enable DDC/CI in its menu, avoid hubs and HDMI adapters, and on M1 Macs use USB-C or DisplayPort instead of HDMI.")
            }
        }
        return out.joined(separator: "\n")
    }
}
