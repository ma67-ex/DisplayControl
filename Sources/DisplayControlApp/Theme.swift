import SwiftUI
import AppKit
import DisplayControlCore

/// The look of the app: one adaptive palette for light and night, soft glass cards, and the brightness glow.
enum Theme {
    // MARK: Palette

    /// The warm light that brightness glows with.
    static let amber = Color(red: 1.00, green: 0.70, blue: 0.22)
    /// Where the glow ends up when boosted past 100%: nearly white.
    static let hot = Color(red: 1.00, green: 0.94, blue: 0.80)
    static let cool = Color(red: 0.45, green: 0.62, blue: 1.00)
    static let mint = Color(red: 0.36, green: 0.82, blue: 0.62)

    static func backdrop(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.055, green: 0.063, blue: 0.098), Color(red: 0.086, green: 0.098, blue: 0.157)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.992, green: 0.980, blue: 0.957), Color(red: 0.945, green: 0.929, blue: 0.894)], startPoint: .top, endPoint: .bottom)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.78)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }

    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    static func chip(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    // MARK: Shape

    static let radius: CGFloat = 16
    static let gap: CGFloat = 12

    /// A spring that settles smoothly with no overshoot. Used for everything the user does not throw.
    static let settle = Animation.interpolatingSpring(stiffness: 260, damping: 26)
    /// A hint of bounce for the glow when brightness is raised, since the gesture carried momentum.
    static let flare = Animation.interpolatingSpring(stiffness: 190, damping: 15)
}

// MARK: - Card

struct CardStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    /// 0 to 1: a soft wash of warm light inside the card, following the display's brightness.
    var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card(scheme))
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(RadialGradient(colors: [Theme.amber.opacity(0.22 * glow * (scheme == .dark ? 1 : 0.7)), .clear],
                                             center: .topLeading, startRadius: 2, endRadius: 190))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.07), radius: 8, y: 3)
    }
}

extension View {
    func card(glow: Double = 0) -> some View { modifier(CardStyle(glow: glow)) }
}

// MARK: - The glow slider

/// A slider whose halo follows its value: it brightens and widens as the value rises, and dims as it falls.
/// A brief flare marks each rise and a brief dip marks each fall, so the direction is felt, not just the level.
struct GlowSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var tint: Color = Theme.amber
    var glows: Bool = true
    let label: String
    var unit: String = "percent"
    /// How far one arrow key or VoiceOver adjustment moves the value.
    var step: Int = 1

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false
    @State private var pulse: Double = 0
    @State private var lastValue: Int? = nil

    private var t: Double { GlowMath.normalized(value, range: range) }
    private var strength: Double { glows ? min(1, max(0, GlowMath.intensity(t) + 0.28 * pulse)) : 0 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = dragging ? 22 : 18
            let x = max(0, min(width, CGFloat(t) * width))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track(scheme)).frame(height: 6)

                // The lit part of the track, with its halo.
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, x), height: 6)
                    .shadow(color: tint.opacity(glows ? GlowMath.opacity(strength) * 0.9 : 0), radius: GlowMath.radius(strength) * 0.7)

                // The knob: a lamp that shines with the value.
                ZStack {
                    // A radial gradient fades smoothly to nothing, with no blur filter to depend on.
                    Circle().fill(RadialGradient(colors: [tint.opacity(glows ? 0.75 * strength : 0), tint.opacity(glows ? 0.30 * strength : 0), .clear],
                                                 center: .center, startRadius: 0, endRadius: (knob + 22 + 34 * CGFloat(strength)) / 2))
                        .frame(width: knob + 22 + 34 * CGFloat(strength), height: knob + 22 + 34 * CGFloat(strength))
                    Circle().fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .shadow(color: tint.opacity(glows ? GlowMath.opacity(strength) : 0), radius: GlowMath.radius(strength))
                    Circle().strokeBorder(tint.opacity(0.9), lineWidth: 2).frame(width: knob - 4, height: knob - 4)
                }
                .frame(width: knob, height: knob)
                .offset(x: x - knob / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { withAnimation(reduceMotion ? nil : Theme.settle) { dragging = true } }
                        let f = min(1, max(0, g.location.x / max(1, width)))
                        value = range.lowerBound + Int((f * Double(range.upperBound - range.lowerBound)).rounded())
                    }
                    .onEnded { _ in withAnimation(reduceMotion ? nil : Theme.settle) { dragging = false } }
            )
        }
        .frame(height: 30)
        .animation(reduceMotion ? nil : Theme.settle, value: value)
        .onChange(of: value) { new in
            defer { lastValue = new }
            guard let old = lastValue, old != new, !reduceMotion, glows else { return }
            // Flare on the way up, dip on the way down, then settle back to the steady level.
            pulse = GlowMath.pulse(delta: new - old)
            withAnimation(Theme.flare) { pulse = 0 }
        }
        .onAppear { lastValue = value }
        // Keyboard and VoiceOver.
        .focusable()
        .onMoveCommand { dir in
            switch dir {
            case .left, .down: value = max(range.lowerBound, value - step)
            case .right, .up: value = min(range.upperBound, value + step)
            @unknown default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Glowing icon

/// The sun on a display card: its halo is the same glow, so the whole card reads as lit.
struct GlowIcon: View {
    let symbol: String
    let strength: Double          // 0 to 1
    var tint: Color = Theme.amber
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.15 + 0.6 * strength), tint.opacity(0.05 + 0.2 * strength), .clear],
                                         center: .center, startRadius: 0, endRadius: 17 + 6 * strength))
                .frame(width: 34 + 8 * strength, height: 34 + 8 * strength)
            Circle().fill(scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Theme.hairline(scheme), lineWidth: 1))
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(strength > 0.04 ? tint : Color.secondary)
                .shadow(color: tint.opacity(0.9 * strength), radius: 2 + 7 * strength)
        }
        .frame(width: 34, height: 34)
        .animation(reduceMotion ? nil : Theme.settle, value: strength)
        .accessibilityHidden(true)
    }
}

// MARK: - Small parts

struct Pill: View {
    let text: String
    var dot: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Theme.chip(scheme)))
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hover ? Theme.chip(scheme) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The app mark: the app's own icon, so the window and the Dock agree.
struct AppMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high)
            .frame(width: 30, height: 30)
            .shadow(color: Theme.amber.opacity(0.35), radius: 6)        // lifts the dark icon off a dark window
            .accessibilityHidden(true)
    }
}

extension AppearanceMode {
    var symbol: String {
        switch self { case .system: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .night: return "moon.stars" }
    }
    var nsAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .night: return NSAppearance(named: .darkAqua) }
    }
}

// MARK: - Stars

/// Slowly drifting, twinkling stars with an occasional shooting star. It runs continuously while the window is
/// on screen. When the window is closed nothing draws, so the app still idles at zero CPU.
struct Starfield: View {
    var enabled: Bool = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stars = StarMath.generate()
    /// One clock for the whole app, so stars keep their place when a window closes and reopens.
    private static let epoch = Date()

    /// True only while this view's window is actually on screen. A hidden window must not animate.
    @State private var onScreen = false

    var body: some View {
        let animate = enabled && !reduceMotion && onScreen
        // The drift is a few points per second, so twelve frames a second looks smooth and costs little.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !animate)) { timeline in
            Canvas { ctx, size in
                guard enabled else { return }
                let t = animate ? timeline.date.timeIntervalSince(Self.epoch) : 0
                let dark = scheme == .dark
                let base: [Double] = dark ? [0.50, 0.70, 0.95] : [0.20, 0.28, 0.36]
                for s in Self.stars {
                    let p = StarMath.position(s, at: t)
                    let a = base[s.layer] * StarMath.twinkle(s, at: animate ? t : 0)
                    let color: Color = s.warm ? Theme.amber : (dark ? Color(red: 0.86, green: 0.91, blue: 1.0) : Color(red: 0.55, green: 0.48, blue: 0.40))
                    let cx = p.x * size.width, cy = p.y * size.height
                    if s.layer == 2 {
                        let h = s.size * 5
                        ctx.fill(Path(ellipseIn: CGRect(x: cx - h / 2, y: cy - h / 2, width: h, height: h)), with: .color(color.opacity(a * 0.14)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - s.size / 2, y: cy - s.size / 2, width: s.size, height: s.size)), with: .color(color.opacity(a)))
                }
                if animate, let m = StarMath.shootingStar(at: t) {
                    let headX = (m.x - 0.30 * m.progress) * size.width, headY = (m.y + 0.18 * m.progress) * size.height
                    let tailX = headX + 0.085 * size.width, tailY = headY - 0.05 * size.height
                    let fade = sin(m.progress * .pi) * (dark ? 0.85 : 0.35)
                    var line = Path(); line.move(to: CGPoint(x: tailX, y: tailY)); line.addLine(to: CGPoint(x: headX, y: headY))
                    ctx.stroke(line, with: .linearGradient(Gradient(colors: [.clear, (dark ? Color.white : Theme.amber).opacity(fade)]),
                                                           startPoint: CGPoint(x: tailX, y: tailY), endPoint: CGPoint(x: headX, y: headY)),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                }
            }
        }
        .background(WindowVisibility(visible: $onScreen))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reports whether the window this view lives in is on screen: shown, not minimized, not fully covered.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.onChange = { value in DispatchQueue.main.async { if visible != value { visible = value } } }
        return v
    }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            guard let w = window else { onChange?(false); return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                                              NSWindow.didChangeScreenNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.evaluate() })
            }
            evaluate()
        }

        private func evaluate() {
            guard let w = window else { onChange?(false); return }
            let on = w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
            onChange?(on)
        }

        deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }
    }
}

/// The gradient backdrop with the stars on top. Used behind the menu bar window and Settings.
struct AppBackdrop: View {
    var stars: Bool = true
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.backdrop(scheme))
            Starfield(enabled: stars)
        }
    }
}
