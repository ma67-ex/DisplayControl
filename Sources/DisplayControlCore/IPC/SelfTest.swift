import Foundation

/// The authoritative per-monitor check (spec 6.11). Safe: it nudges a value by a few steps
/// and always puts the original value back.
public enum SelfTest {
    public static func run(_ display: ManagedDisplay) async -> SelfTestReport {
        let name = await display.info.name
        let mode = await display.mode
        var steps: [SelfTestStep] = []
        var median: Double?
        var doubleWrite: Bool?

        func add(_ n: String, _ ok: Bool, _ d: String) { steps.append(SelfTestStep(name: n, passed: ok, detail: d)) }

        let supported = await display.supported
        add("Connection", true, "\(mode.title); controls: \(supported.map(\.rawValue).sorted().joined(separator: ", "))")
        guard supported.contains(.brightness) else {
            add("Brightness control", false, "This display reports no brightness control. Try another control mode.")
            return SelfTestReport(display: name, mode: mode, steps: steps, medianRoundTripMs: nil, needsDoubleWrite: nil)
        }

        if let ddc = await display.backend as? DDCBackend {
            if let caps = try? await ddc.device.readCapabilities() {
                add("Capabilities", true, "model \(caps.model ?? "unknown"), \(caps.vcp.count) controls, MCCS \(caps.mccsVersion ?? "?")")
            } else {
                add("Capabilities", false, "The monitor did not return a capability list (many do not). Controls were probed one by one.")
            }
            // Round-trip timing: five consecutive reads.
            var times: [Double] = []
            for _ in 0..<5 {
                let t0 = ContinuousClock.now
                if (try? await ddc.device.read(DDC.VCP.brightness)) != nil { times.append((ContinuousClock.now - t0).seconds * 1000) }
            }
            if !times.isEmpty { median = times.sorted()[times.count / 2] }
            add("Read round trip", !times.isEmpty, times.isEmpty ? "No reply" : String(format: "median %.0f ms over %d reads", median ?? 0, times.count))
        }

        // Brightness: nudge and restore, verifying by reading back.
        let original = await display.refresh(.brightness)
        if let original {
            add("Read brightness", true, "\(original)%")
            let target = original >= 95 ? original - 3 : original + 3
            do {
                try await display.set(.brightness, to: target)
                try? await Task.sleep(for: .milliseconds(300))
                let back = await display.refresh(.brightness)
                let ok = back.map { abs($0 - target) <= 1 } ?? false
                add("Write and read back", ok, ok ? "set \(target)%, read \(back!)%" : "set \(target)%, read \(back.map(String.init) ?? "nothing"). The monitor may be in a preset picture mode or have DDC/CI off.")
                if !ok, await display.mode == .ddc { doubleWrite = true }
            } catch {
                add("Write and read back", false, String(describing: error))
            }
            do {
                try await display.set(.brightness, to: original)
                try? await Task.sleep(for: .milliseconds(300))
                let restored = await display.refresh(.brightness)
                add("Restore original", restored.map { abs($0 - original) <= 1 } ?? false, "back to \(restored.map(String.init) ?? "?")%")
            } catch {
                add("Restore original", false, String(describing: error))
            }
        } else {
            add("Read brightness", false, "No reply from the display")
        }

        // Contrast and volume only if advertised.
        for p in [DisplayProperty.contrast, .volume] where supported.contains(p) {
            if let o = await display.refresh(p) {
                let t = o >= 95 ? o - 3 : o + 3
                try? await display.set(p, to: t)
                try? await Task.sleep(for: .milliseconds(300))
                let b = await display.refresh(p)
                try? await display.set(p, to: o)
                add(p.rawValue.capitalized, b.map { abs($0 - t) <= 1 } ?? false, "set \(t), read \(b.map(String.init) ?? "nothing"), restored \(o)")
            } else {
                add(p.rawValue.capitalized, false, "advertised but no reply")
            }
        }
        return SelfTestReport(display: name, mode: mode, steps: steps, medianRoundTripMs: median, needsDoubleWrite: doubleWrite)
    }
}
