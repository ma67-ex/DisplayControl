import Foundation

/// The motion of the background stars, as pure functions of time so it can be tested and drawn anywhere.
/// Positions are in unit space (0 to 1 across and down) and wrap around the edges.
public struct Star: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var size: Double          // points
    public var speed: Double         // unit-space distance per second
    public var phase: Double
    public var twinkleRate: Double   // radians per second
    public var layer: Int            // 0 far, 1 middle, 2 near
    public var warm: Bool            // a warm amber star instead of a cool white one
}

public enum StarMath {
    /// Deterministic generator so every launch draws the same sky.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Far stars are small and slow, near stars bigger and quicker, which gives a sense of depth.
    public static let layerSize: [Double] = [0.7, 1.1, 1.7]
    public static let layerSpeed: [Double] = [0.0035, 0.0075, 0.0135]

    public static func generate(count: Int = 70, seed: UInt64 = 2026) -> [Star] {
        var rng = SplitMix(state: seed)
        return (0..<count).map { i in
            let layer = i % 7 == 0 ? 2 : (i % 3 == 0 ? 1 : 0)
            return Star(x: .random(in: 0..<1, using: &rng), y: .random(in: 0..<1, using: &rng),
                        size: layerSize[layer] * .random(in: 0.85...1.2, using: &rng),
                        speed: layerSpeed[layer] * .random(in: 0.8...1.25, using: &rng),
                        phase: .random(in: 0..<(2 * .pi), using: &rng),
                        twinkleRate: .random(in: 0.6...1.8, using: &rng),
                        layer: layer, warm: Double.random(in: 0..<1, using: &rng) < 0.22)
        }
    }

    /// Drift to the upper right at a shallow angle, wrapping at the edges.
    public static func position(_ s: Star, at t: Double) -> (x: Double, y: Double) {
        func wrap(_ v: Double) -> Double { let r = v.truncatingRemainder(dividingBy: 1); return r < 0 ? r + 1 : r }
        return (wrap(s.x + s.speed * t * 0.94), wrap(s.y - s.speed * t * 0.34))
    }

    /// Brightness multiplier, always between `low` and 1, so a star dims and returns but never vanishes.
    public static func twinkle(_ s: Star, at t: Double, low: Double = 0.35) -> Double {
        let wave = 0.5 + 0.5 * sin(t * s.twinkleRate + s.phase)
        return low + (1 - low) * wave
    }

    /// An occasional shooting star. Nil between appearances; otherwise progress 0 to 1 plus where it starts.
    public static func shootingStar(at t: Double, every period: Double = 11, lasting: Double = 1.1) -> (progress: Double, x: Double, y: Double)? {
        guard t >= 0 else { return nil }
        let cycle = Int(t / period)
        let local = t - Double(cycle) * period
        guard local < lasting else { return nil }
        var rng = SplitMix(state: UInt64(truncatingIfNeeded: cycle) &* 7919 &+ 17)
        return (local / lasting, .random(in: 0.35...1.0, using: &rng), .random(in: 0.0...0.4, using: &rng))
    }
}
