import SwiftUI
import DisplayControlCore

struct MenuView: View {
    @ObservedObject var model: AppModel
    let openSettings: (SettingsTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = model.banner {
                Banner(text: banner, symbol: "exclamationmark.triangle.fill", tint: .orange) { model.banner = nil }
            }
            if model.displays.isEmpty {
                EmptyState(openSettings: openSettings)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.displays, id: \.key) { d in
                            DisplayCard(model: model, display: d)
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
            if !model.presets.isEmpty { presetRow }
            if let s = model.lastPresetSummary {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .task { await model.refreshLive() }
    }

    private var header: some View {
        HStack {
            Text("DisplayControl").font(.headline)
            Spacer()
            if model.displays.count > 1 {
                Button {
                    if let host = model.displays.first(where: { !$0.isBuiltIn }) ?? model.displays.first { model.toggleSync(host: model.sync.hostKey ?? host.key) }
                } label: {
                    Label("Sync", systemImage: model.sync.enabled ? "link.circle.fill" : "link.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.sync.enabled ? Color.accentColor : .secondary)
                .help(model.sync.enabled ? "Sync is on. Click to turn it off." : "Make every display follow the one you adjust.")
                .accessibilityLabel(model.sync.enabled ? "Turn sync off" : "Turn sync on")
            }
            Button { openSettings(.general) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.presets) { p in
                        Button { model.activate(p) } label: {
                            Label(p.name, systemImage: p.icon).font(.callout)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button { openSettings(.presets) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit presets")
                        .accessibilityLabel("Edit presets")
                }
            }
        }
    }

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
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

struct EmptyState: View {
    let openSettings: (SettingsTab) -> Void
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text("No displays found").font(.headline)
            Text("Connect a monitor and it will show up here. If it is connected but missing, check the cable or dock.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Troubleshooting") { NSWorkspace.shared.open(Links.troubleshooting) }.buttonStyle(.link).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
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
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DisplayCard: View {
    @ObservedObject var model: AppModel
    let display: DisplaySnapshot
    @State private var expanded = false

    private func has(_ p: DisplayProperty) -> Bool { display.supported.contains(p) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                Text(display.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                ModeBadge(mode: display.mode)
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Show fewer controls" : "Show more controls")
            }
            if display.ddcUnreliable {
                Banner(text: "This monitor is not confirming changes. It may be in a preset picture mode, or DDC/CI may be off in its menu.",
                       symbol: "questionmark.circle.fill", tint: .yellow)
            }
            if has(.brightness) { SliderRow(model: model, display: display, property: .brightness, symbol: "sun.max", label: "Brightness") }
            if has(.contrast) { SliderRow(model: model, display: display, property: .contrast, symbol: "circle.lefthalf.filled", label: "Contrast") }
            if has(.volume) { SliderRow(model: model, display: display, property: .volume, symbol: "speaker.wave.2", label: "Volume") }
            if !has(.brightness) && !has(.contrast) && !has(.volume) {
                Text("No controls available in this mode.").font(.caption).foregroundStyle(.secondary)
            }
            if expanded { ExpandedControls(model: model, display: display) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ModeBadge: View {
    let mode: ControlMode
    var body: some View {
        Text(mode == .ddc ? "DDC" : mode == .apple ? "Apple" : "Software")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(mode.title)
    }
}

struct SliderRow: View {
    @ObservedObject var model: AppModel
    let display: DisplaySnapshot
    let property: DisplayProperty
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(model.value(display.key, property)) },
                set: { model.setValue(display.key, property, Int($0.rounded())) }
            ), in: 0...100)
            .accessibilityLabel(label)
            .accessibilityValue("\(model.value(display.key, property)) percent")
            Text("\(model.value(display.key, property))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
        }
    }
}

struct ExpandedControls: View {
    @ObservedObject var model: AppModel
    let display: DisplaySnapshot
    @State private var resolutions: [ResolutionSpec] = []
    @State private var currentResolution: ResolutionSpec?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if display.supported.contains(.input) {
                HStack {
                    Label("Input", systemImage: "cable.connector").font(.caption)
                    Spacer()
                    Menu("Switch") {
                        ForEach(InputSource.common, id: \.code) { src in
                            Button(src.name) { send(.input, src.code) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if display.supported.contains(.power) {
                HStack {
                    Label("Power", systemImage: "power").font(.caption)
                    Spacer()
                    Button("Turn off") { send(.power, 0) }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Some monitors cannot be woken over DDC once off. Use the monitor's own button or switch its input from the Mac.")
                }
            }
            if display.supported.contains(.mute) {
                HStack {
                    Label("Mute speakers", systemImage: "speaker.slash").font(.caption)
                    Spacer()
                    Toggle("", isOn: Binding(get: { (display.values["mute"] ?? 0) != 0 }, set: { send(.mute, $0 ? 1 : 0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            if display.supported.contains(.rotation) {
                HStack {
                    Label("Rotation", systemImage: "rotate.right").font(.caption)
                    Spacer()
                    Picker("", selection: Binding(get: { display.values["rotation"] ?? 0 }, set: { send(.rotation, $0) })) {
                        ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            if !resolutions.isEmpty {
                HStack {
                    Label("Resolution", systemImage: "rectangle.expand.vertical").font(.caption)
                    Spacer()
                    Menu(currentResolution.map(format) ?? "Choose") {
                        ForEach(resolutions.prefix(24), id: \.self) { r in
                            Button(format(r)) { choose(r) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            HStack {
                Label("Control", systemImage: "slider.horizontal.3").font(.caption)
                Spacer()
                Menu(display.settings.preferredMode?.title ?? "Automatic") {
                    Button("Automatic") { model.setMode(display.key, nil) }
                    ForEach(ControlMode.allCases, id: \.self) { m in Button(m.title) { model.setMode(display.key, m) } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if display.isSyncFollower {
                HStack {
                    Label("When host is 100%", systemImage: "link").font(.caption)
                    Slider(value: Binding(
                        get: { Double(SyncMath.followerAtHost100(scale: display.settings.syncScale, constant: display.settings.syncConstant)) },
                        set: { model.setSyncOffset(display.key, followerAtHost100: Int($0.rounded())) }), in: 20...100)
                    Text("\(SyncMath.followerAtHost100(scale: display.settings.syncScale, constant: display.settings.syncConstant))%")
                        .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            HStack {
                Button(model.runningSelfTest ? "Testing…" : "Test this display") { model.run(selfTestFor: display.key) }
                    .disabled(model.runningSelfTest)
                    .font(.caption).buttonStyle(.borderless)
                Spacer()
                Button("Re-detect") { Task { _ = try? await model.center.setMode(key: display.key, nil); await model.reload() } }
                    .font(.caption).buttonStyle(.borderless)
            }
            if let r = model.selfTest, r.display == display.name {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(r.steps, id: \.name) { s in
                        Label("\(s.name): \(s.detail)", systemImage: s.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.caption2).foregroundStyle(s.passed ? Color.green : Color.red)
                    }
                }
            }
        }
        .task {
            let r = await model.center.resolutions(key: display.key)
            resolutions = r.all; currentResolution = r.current
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
