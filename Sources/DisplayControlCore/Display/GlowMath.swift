import Foundation

/// How strongly the brightness glow should shine for a value. Pure, so it can be tested.
/// The glow rises and falls with brightness: more brightness, a brighter and wider halo.
public enum GlowMath {
    /// Position of `value` within `range`, 0 to 1.
    public static func normalized(_ value: Int, range: ClosedRange<Int>) -> Double {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        return min(1, max(0, Double(value - range.lowerBound) / span))
    }

    /// Glow strength 0 to 1. A gentle curve keeps low brightness dim but visible, and lets the top end blaze.
    public static func intensity(_ t: Double) -> Double {
        pow(min(1, max(0, t)), 1.35)
    }

    /// Halo radius in points: tight at low brightness, wide at high.
    public static func radius(_ t: Double, smallest: Double = 3, largest: Double = 24) -> Double {
        smallest + (largest - smallest) * intensity(t)
    }

    /// Glow opacity, never fully dark so the control stays readable.
    public static func opacity(_ t: Double, floor: Double = 0.08) -> Double {
        floor + (1 - floor) * intensity(t)
    }

    /// A brief extra flare when brightness is rising (+) or a brief dip when it is falling (-).
    /// `delta` is the change in value; the result is -1 to 1 and the view lets it settle back to zero.
    public static func pulse(delta: Int) -> Double {
        guard delta != 0 else { return 0 }
        return delta > 0 ? 1 : -1
    }
}
