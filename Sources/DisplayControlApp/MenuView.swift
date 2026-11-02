import SwiftUI
import DisplayControlCore

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    let openSettings: (SettingsTab) -> Void
    @Environment(\.colorScheme) private var scheme
    /// A ScrollView has no natural height, so inside the self-sizing menu bar window it collapses
    /// to nothing. Measure the cards and give the ScrollView exactly that height, up to a cap.
    @State private var cardsHeight: CGFloat = 0

    private var cards: some View {
        VStack(spacing: 10) {
            ForEach(model.displays, id: \.key) { d in DisplayCard(model: model, display: d) }
        }
        .padding(.vertical, 4)
        .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            header
            if let banner = model.banner {
                Banner(text: banner, symbol: "exclamationmark.triangle.fill", tint: .orange) { model.banner = nil }
            }
            if model.displays.isEmpty {
                EmptyState(openSettings: openSettings)
            } else {
                ScrollView(showsIndicators: false) { cards }
                    .frame(height: min(max(cardsHeight, 80), 540))
                    .onPreferenceChange(ContentHeightKey.self) { cardsHeight = $0 }
            }
            if !model.presets.isEmpty { presetRow }
            if let s = model.lastPresetSummary {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(14)
        .frame(width: 344)
        .background(AppBackdrop(stars: model.settings.animatedStars))
        .task { await model.refreshLive() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            AppMark()
            Text("DisplayControl").font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            if model.displays.count > 1 {
                IconButton(symbol: model.sync.enabled ? "link.circle.fill" : "link.circle",
                           label: model.sync.enabled ? "Sync is on. Click to turn it off." : "Make every display follow the one you adjust.",
                           tint: model.sync.enabled ? Theme.amber : nil) {
                    if let host = model.displays.first(where: { !$0.isBuiltIn }) ?? model.displays.first {
                        model.toggleSync(host: model.sync.hostKey ?? host.key)
                    }
                }
            }
            IconButton(symbol: model.settings.appearance.symbol,
                       label: "Appearance: \(model.settings.appearance.title). Click to change.") {
                model.updateAppSettings { $0.appearance = $0.appearance.next }
            }
            IconButton(symbol: "gearshape", label: "Settings") { openSettings(.general) }
        }
    }

    // MARK: Presets

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRESETS").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(0.8).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.presets) { p in
                        PresetChip(preset: p) { model.activate(p) }
                    }
                    IconButton(symbol: "pencil", label: "Edit presets") { openSettings(.presets) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Reset dimming") {
                Task { _ = await CommandRouter(center: model.center).handle(IPCRequest(cmd: "reset-gamma")) }
            }
            .help("Undo software dimming on every display")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

struct PresetChip: View {
    let preset: Preset
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Label(preset.name, systemImage: preset.icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(hover ? Theme.amber.opacity(0.22) : Theme.chip(scheme)))
                .overlay(Capsule().strokeBorder(Theme.hairline(scheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.settle, value: hover)
    }
}

struct EmptyState: View {
    let openSettings: (SettingsTab) -> Void
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No displays found").font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("Connect a monitor and it will show up here. If it is connected but missing, check the cable or dock.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Troubleshooting") { NSWorkspace.shared.open(Links.troubleshooting) }.buttonStyle(.link).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .card()
    }
}

/// One place for outbound links. Replace `site` and `repository` once the project has a home.
enum Links {
    static let site = "https://displaycontrol.example"
    static let repository = "https://github.com/OWNER/DisplayControl"
    static let troubleshooting = URL(string: site + "/docs/troubleshooting.html")!
    static let releases = URL(string: repository + "/releases")!
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss") }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.14)))
    }
}

// MARK: - Display card

struct DisplayCard: View {
    @ObservedObject var model: AppModel
    let display: DisplaySnapshot
    @State private var expanded = false

    private func has(_ p: DisplayProperty) -> Bool { display.supported.contains(p) }

    /// How lit the card is: follows brightness, and past 100% the boost pushes it further.
    private var glow: Double {
        let b = GlowMath.intensity(GlowMath.normalized(model.value(display.key, .brightness), range: 0...100))
        guard has(.boost) else { return b }
        return min(1, b + 0.25 * GlowMath.normalized(model.value(display.key, .boost), range: 100...200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GlowIcon(symbol: display.isBuiltIn ? "laptopcomputer" : "display", strength: has(.brightness) ? glow : 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    ModeBadge(mode: display.mode)
                }
                Spacer()
                IconButton(symbol: "chevron.down", label: expanded ? "Show fewer controls" : "Show more controls") {
                    withAnimation(Theme.settle) { expanded.toggle() }
                }
                .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            if display.ddcUnreliable {
                Banner(text: "This monitor is not confirming changes. It may be in a preset picture mode, or DDC/CI may be off in its menu.",
                       symbol: "questionmark.circle.fill", tint: .yellow)
            }
            if has(.brightness) {
                SliderRow(model: model, display: display, property: .brightness, symbol: "sun.max.fill", label: "Brightness", tint: Theme.amber, glows: true)
            }
            if has(.contrast) {
                SliderRow(model: model, display: display, property: .contrast, symbol: "circle.lefthalf.filled", label: "Contrast", tint: Theme.cool, glows: false)
            }
            if has(.volume) {
                SliderRow(model: model, display: display, property: .volume, symbol: "speaker.wave.2.fill", label: "Volume", tint: Theme.mint, glows: false)
            }
            if !has(.brightness) && !has(.contrast) && !has(.volume) {
                Text("No controls available in this mode.").font(.caption).foregroundStyle(.secondary)
            }
            if expanded { ExpandedControls(model: model, display: display) }
        }
        .card(glow: has(.brightness) ? glow : 0)
        .animation(Theme.settle, value: glow)
    }
}

struct ModeBadge: View {
    let mode: ControlMode
    var body: some View {
        Pill(text: mode == .ddc ? "Hardware" : mode == .apple ? "Apple" : "Software",
             dot: mode == .ddc ? Theme.mint : mode == .apple ? Theme.cool : Theme.amber)
            .help(mode.title)
    }
}

struct SliderRow: View {
    @ObservedObject var model: AppModel
    let display: DisplaySnapshot
    let property: DisplayProperty
    let symbol: String
    let label: String
    var tint: Color
    var glows: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 16).foregroundStyle(glows ? tint : Color.secondary).accessibilityHidden(true)
            GlowSlider(value: Binding(get: { model.value(display.key, property) },
                                      set: { model.setValue(display.key, property, $0) }),
                       range: 0...100, tint: tint, glows: glows, label: label, step: max(1, display.settings.stepSize))
            Text("\(model.value(display.key, property))")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - Expanded controls

struct ExpandedControls: View {
    @ObservedObject var model: AppModel
    let display: DisplaySnapshot
    @State private var resolutions: [ResolutionSpec] = []
    @State private var currentResolution: ResolutionSpec?
    @Environment(\.colorScheme) private var scheme

    private func row<Trailing: View>(_ title: String, _ symbol: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if display.supported.contains(.boost) { boost }
            if display.supported.contains(.input) {
                row("Input", "cable.connector") {
                    Menu("Switch") {
                        ForEach(InputSource.common, id: \.code) { src in Button(src.name) { send(.input, src.code) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if display.supported.contains(.power) {
                row("Power", "power") {
                    Button("Turn off") { send(.power, 0) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.amber)
                        .help("Some monitors cannot be woken over DDC once off. Use the monitor's own button or switch its input from the Mac.")
                }
            }
            if display.supported.contains(.mute) {
                row("Mute speakers", "speaker.slash") {
                    Toggle("", isOn: Binding(get: { (display.values["mute"] ?? 0) != 0 }, set: { send(.mute, $0 ? 1 : 0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            if display.supported.contains(.rotation) {
                row("Rotation", "rotate.right") {
                    Picker("", selection: Binding(get: { display.values["rotation"] ?? 0 }, set: { send(.rotation, $0) })) {
                        ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            if !resolutions.isEmpty {
                row("Resolution", "rectangle.expand.vertical") {
                    Menu(currentResolution.map(format) ?? "Choose") {
                        ForEach(resolutions.prefix(24), id: \.self) { r in Button(format(r)) { choose(r) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            row("Control", "slider.horizontal.3") {
                Menu(display.settings.preferredMode?.title ?? "Automatic") {
                    Button("Automatic") { model.setMode(display.key, nil) }
                    ForEach(ControlMode.allCases, id: \.self) { m in Button(m.title) { model.setMode(display.key, m) } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if display.isSyncFollower {
                HStack(spacing: 8) {
                    Label("At host 100%", systemImage: "link").font(.system(size: 12)).foregroundStyle(.secondary)
                    GlowSlider(value: Binding(
                        get: { SyncMath.followerAtHost100(scale: display.settings.syncScale, constant: display.settings.syncConstant) },
                        set: { model.setSyncOffset(display.key, followerAtHost100: $0) }),
                               range: 20...100, tint: Theme.cool, glows: false, label: "Follower brightness when the host is at 100 percent")
                    Text("\(SyncMath.followerAtHost100(scale: display.settings.syncScale, constant: display.settings.syncConstant))%")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
            HStack {
                Button(model.runningSelfTest ? "Testing…" : "Test this display") { model.run(selfTestFor: display.key) }
                    .disabled(model.runningSelfTest)
                Spacer()
                Button("Re-detect") { Task { _ = try? await model.center.setMode(key: display.key, nil); await model.reload() } }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.amber)
            if let r = model.selfTest, r.display == display.name {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(r.steps, id: \.name) { s in
                        Label("\(s.name): \(s.detail)", systemImage: s.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption2).foregroundStyle(s.passed ? Color.green : Color.red)
                    }
                }
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline(scheme)).frame(height: 1) }
        .task {
            let r = await model.center.resolutions(key: display.key)
            resolutions = r.all; currentResolution = r.current
        }
    }

    private var boost: some View {
        let v = max(100, model.value(display.key, .boost))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Extra brightness", systemImage: "sun.max.trianglebadge.exclamationmark").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(v)%").font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(v > 100 ? Theme.amber : Color.secondary).contentTransition(.numericText())
            }
            GlowSlider(value: Binding(get: { max(100, model.value(display.key, .boost)) },
                                      set: { model.setValue(display.key, .boost, $0) }),
                       range: 100...200, tint: Theme.hot, glows: true, label: "Extra brightness")
            Text("Raises the monitor's color gains together. Past a point, bright detail can clip. 100% puts your original settings back exactly.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func send(_ p: DisplayProperty, _ v: Int) {
        Task {
            guard let d = try? await model.center.resolve(display.key) else { return }
            do { try await model.center.set(d, p, to: v) } catch { model.banner = String(describing: error) }
            await model.reload()
        }
    }

    private func choose(_ r: ResolutionSpec) {
        Task {
            do { try await model.center.applyResolution(key: display.key, r); currentResolution = r }
            catch { model.banner = String(describing: error) }
        }
    }

    private func format(_ r: ResolutionSpec) -> String {
        "\(r.width)×\(r.height)\(r.hiDPI ? " HiDPI" : "") @ \(Int(r.refreshRate.rounded())) Hz"
    }
}
