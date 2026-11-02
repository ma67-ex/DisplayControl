import SwiftUI
import AppKit
import DisplayControlCore

/// The small bar that appears when a key changes brightness, contrast or volume, on the display that changed.
struct HUDView: View {
    let property: DisplayProperty
    let value: Int
    let displayName: String
    @Environment(\.colorScheme) private var scheme

    private var symbol: String {
        switch property { case .contrast: return "circle.lefthalf.filled"; case .volume: return value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        default: return "sun.max.fill" }
    }
    private var tint: Color { property == .contrast ? Theme.cool : property == .volume ? Theme.mint : Theme.amber }

    var body: some View {
        HStack(spacing: 12) {
            GlowIcon(symbol: symbol, strength: property == .brightness ? GlowMath.intensity(GlowMath.normalized(value, range: 0...100)) : 0.4, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                GlowSlider(value: .constant(value), range: 0...100, tint: tint, glows: property == .brightness, label: "\(property.rawValue.capitalized)")
                    .frame(width: 180).allowsHitTesting(false)
            }
            Text("\(value)").font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline(scheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .padding(24)
    }
}

/// Owns one borderless panel, moves it to the display that changed and fades it out. It never takes focus or clicks.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let model: HUDModel

    final class HUDModel: ObservableObject {
        @Published var property: DisplayProperty = .brightness
        @Published var value = 0
        @Published var name = ""
    }

    init() { model = HUDModel() }

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }

    func show(property: DisplayProperty, value: Int, name: String, displayID: UInt32, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        guard let screen = screen(for: displayID) else { return }
        model.property = property; model.value = value; model.name = name
        let p = panel ?? makePanel()
        panel = p
        let size = p.contentView?.fittingSize ?? NSSize(width: 360, height: 100)
        p.setContentSize(size)
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 40))
        hideTask?.cancel()
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = reduceMotion ? 0 : 0.12; p.animator().alphaValue = 1 }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            if Task.isCancelled { return }
            await MainActor.run {
                NSAnimationContext.runAnimationGroup({ $0.duration = reduceMotion ? 0 : 0.35; self?.panel?.animator().alphaValue = 0 },
                                                     completionHandler: { self?.panel?.orderOut(nil) })
            }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: HUDHost(model: model))
        return p
    }
}

struct HUDHost: View {
    @ObservedObject var model: HUDController.HUDModel
    var body: some View { HUDView(property: model.property, value: model.value, displayName: model.name) }
}
