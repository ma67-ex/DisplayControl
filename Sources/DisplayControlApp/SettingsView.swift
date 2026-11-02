import SwiftUI
import AppKit
import Carbon.HIToolbox
import DisplayControlCore

enum SettingsTab: Hashable { case general, displays, presets, schedules, keyboard, commandLine, about }

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State var tab: SettingsTab

    private static let titles: [(SettingsTab, String)] = [
        (.general, "General"), (.displays, "Displays"), (.presets, "Presets"), (.schedules, "Schedules"),
        (.keyboard, "Keyboard"), (.commandLine, "Command Line"), (.about, "About")]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Self.titles, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)
            Group {
                switch tab {
                case .general: GeneralTab(model: model)
                case .displays: DisplaysTab(model: model)
                case .presets: PresetsTab(model: model)
                case .schedules: SchedulesTab(model: model)
                case .keyboard: KeyboardTab(model: model)
                case .commandLine: CommandLineTab(model: model)
                case .about: AboutTab(model: model)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 520)
        .background(AppBackdrop(stars: model.settings.animatedStars))
        .task { await model.reload() }
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Appearance", systemImage: "paintbrush").foregroundStyle(.primary)
                    Text(model.settings.appearance.title).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    // One small icon on the right: shows the current mode, opens the three choices.
                    Menu {
                        ForEach(AppearanceMode.allCases, id: \.self) { m in
                            Button { model.updateAppSettings { $0.appearance = m } } label: {
                                Label(m.title, systemImage: model.settings.appearance == m ? "checkmark" : m.symbol)
                            }
                        }
                    } label: {
                        Image(systemName: model.settings.appearance.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Appearance: \(model.settings.appearance.title)")
                    .accessibilityLabel("Appearance: \(model.settings.appearance.title)")
                }
                Toggle("Moving stars in the background", isOn: Binding(get: { model.settings.animatedStars }, set: { v in model.updateAppSettings { $0.animatedStars = v } }))
                Text("Night is a dark theme for evenings. The stars drift only while a window is open, and stop if Reduce Motion is on.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Open DisplayControl at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { model.setLaunchAtLogin($0) }
            Toggle("Keyboard shortcuts control every display, not just the one under the pointer",
                   isOn: Binding(get: { model.settings.controlAllDisplays }, set: { v in model.updateAppSettings { $0.controlAllDisplays = v } }))
            Section("Step size") {
                ForEach(model.displays, id: \.key) { d in
                    Picker(d.name, selection: Binding(get: { d.settings.stepSize }, set: { v in model.updateSettings(d.key) { $0.stepSize = v } })) {
                        Text("1").tag(1); Text("2").tag(2); Text("5").tag(5); Text("10").tag(10)
                    }
                    .pickerStyle(.segmented)
                }
            }
            if let b = model.banner { Banner(text: b, symbol: "exclamationmark.triangle.fill", tint: .orange) { model.banner = nil } }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}

// MARK: - Displays

struct DisplaysTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        List {
            if model.displays.isEmpty { Text("No displays found").foregroundStyle(.secondary) }
            ForEach(model.displays, id: \.key) { d in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: d.isBuiltIn ? "laptopcomputer" : "display")
                        TextField("Name", text: Binding(get: { d.settings.friendlyName ?? d.name },
                                                        set: { v in model.updateSettings(d.key) { $0.friendlyName = v.isEmpty ? nil : v } }))
                            .textFieldStyle(.roundedBorder)
                        ModeBadge(mode: d.mode)
                    }
                    Picker("Control mode", selection: Binding(get: { d.settings.preferredMode }, set: { model.setMode(d.key, $0) })) {
                        Text("Automatic").tag(ControlMode?.none)
                        ForEach(ControlMode.allCases, id: \.self) { Text($0.title).tag(ControlMode?.some($0)) }
                    }
                    if d.supported.contains(.volume) {
                        Stepper("Volume cap: \(d.settings.volumeCap)%", value: Binding(get: { d.settings.volumeCap }, set: { v in model.updateSettings(d.key) { $0.volumeCap = v } }), in: 10...100, step: 5)
                    }
                    if d.mode == .ddc {
                        Toggle("Send every command twice (for monitors that drop the first)",
                               isOn: Binding(get: { d.settings.doubleWrite }, set: { v in model.updateSettings(d.key) { $0.doubleWrite = v } }))
                    }
                    Text("Identity: \(d.key)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Presets

struct PresetsTab: View {
    @ObservedObject var model: AppModel
    @State private var editing: Preset?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading) {
            if model.presets.isEmpty {
                Text("No presets yet. Set your displays up the way you like, then choose “Save current setup” below.")
                    .foregroundStyle(.secondary).padding([.horizontal, .top])
            }
            List {
                ForEach(model.presets) { p in
                    HStack {
                        Image(systemName: p.icon).frame(width: 22)
                        Text(p.name)
                        Spacer()
                        Button("Apply") { model.activate(p) }.buttonStyle(.borderless)
                        Button("Edit") { editing = p }.buttonStyle(.borderless)
                        Button { model.deletePreset(p) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(p.name)")
                    }
                }
                .onMove { from, to in
                    var list = model.presets
                    list.move(fromOffsets: from, toOffset: to)
                    for p in list { try? model.center.presets.delete(id: p.id) }
                    for p in list { try? model.center.presets.upsert(p) }
                    Task { await model.reload() }
                }
            }
            HStack {
                TextField("New preset name", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Save current setup") {
                    model.captureNewPreset(named: newName.isEmpty ? "Preset \(model.presets.count + 1)" : newName)
                    newName = ""
                }
                Spacer()
                Text("Saves the present brightness, contrast, volume, resolution and arrangement. Edit it to pick what is included.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .bottom])
        }
        .sheet(item: $editing) { p in PresetEditor(model: model, preset: p) { editing = nil } }
    }
}

struct PresetEditor: View {
    @ObservedObject var model: AppModel
    @State var preset: Preset
    let done: () -> Void
    static let icons = ["sun.max", "moon", "moon.stars", "gamecontroller", "film", "briefcase", "laptopcomputer", "tv", "book", "paintpalette", "bolt", "leaf"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $preset.name).textFieldStyle(.roundedBorder)
                Picker("Icon", selection: $preset.icon) { ForEach(Self.icons, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) } }.frame(width: 90)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(preset.displays.indices, id: \.self) { i in displayEditor(i) }
                    GroupBox("Sync") {
                        Toggle("Include sync state", isOn: Binding(get: { preset.sync != nil }, set: { preset.sync = $0 ? model.sync : nil }))
                        if preset.sync != nil {
                            Toggle("Sync on", isOn: Binding(get: { preset.sync?.enabled ?? false }, set: { preset.sync?.enabled = $0 }))
                        }
                    }
                    GroupBox("Options") {
                        Stepper("Delay before applying: \(Int(preset.delaySeconds ?? 0)) s", value: Binding(get: { preset.delaySeconds ?? 0 }, set: { preset.delaySeconds = $0 > 0 ? $0 : nil }), in: 0...30)
                        HStack { Text("Shortcut"); ShortcutRecorder(spec: $preset.hotkey) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.savePreset(preset); done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 540, height: 520)
    }

    @ViewBuilder func displayEditor(_ i: Int) -> some View {
        GroupBox(preset.displays[i].displayName) {
            VStack(alignment: .leading, spacing: 6) {
                optionalSlider("Brightness", $preset.displays[i].brightness)
                optionalSlider("Contrast", $preset.displays[i].contrast)
                optionalSlider("Volume", $preset.displays[i].volume)
                HStack {
                    Toggle("Input", isOn: Binding(get: { preset.displays[i].input != nil }, set: { preset.displays[i].input = $0 ? 0x11 : nil }))
                    if preset.displays[i].input != nil {
                        Picker("", selection: Binding(get: { preset.displays[i].input ?? 0x11 }, set: { preset.displays[i].input = $0 })) {
                            ForEach(InputSource.common, id: \.code) { Text($0.name).tag($0.code) }
                        }.labelsHidden().fixedSize()
                    }
                }
                Toggle("Power on", isOn: Binding(get: { preset.displays[i].power ?? false }, set: { preset.displays[i].power = $0 ? true : nil }))
                HStack {
                    Toggle("Rotation", isOn: Binding(get: { preset.displays[i].rotation != nil }, set: { preset.displays[i].rotation = $0 ? 0 : nil }))
                    if preset.displays[i].rotation != nil {
                        Picker("", selection: Binding(get: { preset.displays[i].rotation ?? 0 }, set: { preset.displays[i].rotation = $0 })) {
                            ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                Toggle(preset.displays[i].resolution.map { "Resolution \($0.width)×\($0.height)" } ?? "Resolution (not included)", isOn: Binding(
                    get: { preset.displays[i].resolution != nil },
                    set: { on in
                        if on {
                            Task { preset.displays[i].resolution = await model.center.resolutions(key: preset.displays[i].identityKey).current }
                        } else { preset.displays[i].resolution = nil }
                    }))
                Toggle(preset.displays[i].arrangement.map { "Position \($0.x), \($0.y)" } ?? "Position (not included)", isOn: Binding(
                    get: { preset.displays[i].arrangement != nil },
                    set: { preset.displays[i].arrangement = $0 ? (preset.displays[i].arrangement ?? ArrangementSpec(x: 0, y: 0)) : nil }))
                Button("Remove this display") { preset.displays.remove(at: i) }.buttonStyle(.borderless).font(.caption)
            }
        }
    }

    func optionalSlider(_ title: String, _ value: Binding<Int?>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? 50 : nil })).frame(width: 130, alignment: .leading)
            if value.wrappedValue != nil {
                Slider(value: Binding(get: { Double(value.wrappedValue ?? 50) }, set: { value.wrappedValue = Int($0.rounded()) }), in: 0...100)
                Text("\(value.wrappedValue ?? 0)%").font(.caption.monospacedDigit()).frame(width: 36)
            }
        }
    }
}

// MARK: - Schedules

struct SchedulesTab: View {
    @ObservedObject var model: AppModel
    @State private var editing: Schedule?

    var body: some View {
        VStack(alignment: .leading) {
            if model.presets.isEmpty {
                Banner(text: "Create at least one preset first. A schedule switches to a preset when its trigger happens.", symbol: "info.circle.fill", tint: .blue)
                    .padding()
            }
            if model.schedules.isEmpty && !model.presets.isEmpty {
                Text("No schedules yet. A schedule applies a preset at a time, at sunrise or sunset, or when something happens on your Mac.")
                    .foregroundStyle(.secondary).padding(.horizontal)
            }
            List {
                ForEach(model.schedules) { s in
                    HStack {
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { on in var c = s; c.enabled = on; model.saveSchedule(c) })).labelsHidden().toggleStyle(.switch)
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text("\(Describe.trigger(s.trigger)) → \(model.presets.first { $0.id == s.presetID }?.name ?? "missing preset")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = s }.buttonStyle(.borderless)
                        Button { model.deleteSchedule(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(s.name)")
                    }
                }
            }
            HStack {
                Button("New schedule") {
                    if let p = model.presets.first { editing = Schedule(name: "New schedule", trigger: .time(hour: 9, minute: 0, weekdays: []), presetID: p.id) }
                }.disabled(model.presets.isEmpty)
                Spacer()
                LocationSection(model: model)
            }
            .padding([.horizontal, .bottom])
        }
        .sheet(item: $editing) { s in ScheduleEditor(model: model, schedule: s) { editing = nil } }
    }
}

enum Describe {
    static func trigger(_ t: Trigger) -> String {
        switch t {
        case .time(let h, let m, let wd):
            let days = wd.isEmpty ? "every day" : wd.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
            return String(format: "%02d:%02d, %@", h, m, days)
        case .sunrise(let o): return o == 0 ? "at sunrise" : "\(abs(o)) min \(o < 0 ? "before" : "after") sunrise"
        case .sunset(let o): return o == 0 ? "at sunset" : "\(abs(o)) min \(o < 0 ? "before" : "after") sunset"
        case .wake: return "when the Mac wakes"
        case .lock: return "when the screen locks"
        case .unlock: return "when the screen unlocks"
        case .appLaunch: return "when DisplayControl starts"
        case .appearanceDark: return "when Dark Mode turns on"
        case .appearanceLight: return "when Light Mode turns on"
        case .powerPlugged: return "when plugged in"
        case .powerBattery: return "when on battery"
        case .monitorConnected(let k): return k == nil ? "when any monitor connects" : "when a specific monitor connects"
        case .monitorDisconnected(let k): return k == nil ? "when any monitor disconnects" : "when a specific monitor disconnects"
        }
    }
}

struct ScheduleEditor: View {
    @ObservedObject var model: AppModel
    @State var schedule: Schedule
    let done: () -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case time = "Time of day", sunrise = "Sunrise", sunset = "Sunset", wake = "Mac wakes", lock = "Screen locks", unlock = "Screen unlocks",
             launch = "App starts", dark = "Dark Mode on", light = "Light Mode on", plugged = "Plugged in", battery = "On battery",
             connected = "Monitor connects", disconnected = "Monitor disconnects"
        var id: String { rawValue }
    }
    @State private var kind: Kind = .time
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var weekdays: Set<Int> = []
    @State private var offset = 0
    @State private var monitorKey = ""

    var body: some View {
        Form {
            TextField("Name", text: $schedule.name)
            Picker("When", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
            if kind == .time {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(Calendar.current.shortWeekdaySymbols[d - 1], isOn: Binding(get: { weekdays.contains(d) }, set: { if $0 { weekdays.insert(d) } else { weekdays.remove(d) } })).toggleStyle(.button)
                    }
                }
                Text("No days selected means every day.").font(.caption).foregroundStyle(.secondary)
            }
            if kind == .sunrise || kind == .sunset {
                Stepper("Offset: \(offset) min (negative is before)", value: $offset, in: -240...240, step: 5)
                if model.center.schedules.location == nil { Text("Set your location in the Schedules tab so sunrise and sunset can be calculated.").font(.caption).foregroundStyle(.orange) }
            }
            if kind == .connected || kind == .disconnected {
                Picker("Monitor", selection: $monitorKey) {
                    Text("Any monitor").tag("")
                    ForEach(model.displays.filter { !$0.isBuiltIn }, id: \.key) { Text($0.name).tag($0.key) }
                }
            }
            Picker("Apply preset", selection: $schedule.presetID) { ForEach(model.presets) { Text($0.name).tag($0.id) } }
            if [.plugged, .battery, .dark, .light, .lock, .unlock, .connected].contains(kind) {
                Picker("When it ends", selection: $schedule.endPresetID) {
                    Text("Do nothing").tag(UUID?.none)
                    ForEach(model.presets) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            HStack { Spacer(); Button("Cancel", action: done).keyboardShortcut(.cancelAction); Button("Save") { schedule.trigger = build(); model.saveSchedule(schedule); done() }.keyboardShortcut(.defaultAction) }
        }
        .formStyle(.grouped).padding().frame(width: 460, height: 460)
        .onAppear { load() }
    }

    private func load() {
        switch schedule.trigger {
        case .time(let h, let m, let wd): kind = .time; time = Calendar.current.date(from: DateComponents(hour: h, minute: m)) ?? time; weekdays = wd
        case .sunrise(let o): kind = .sunrise; offset = o
        case .sunset(let o): kind = .sunset; offset = o
        case .wake: kind = .wake
        case .lock: kind = .lock
        case .unlock: kind = .unlock
        case .appLaunch: kind = .launch
        case .appearanceDark: kind = .dark
        case .appearanceLight: kind = .light
        case .powerPlugged: kind = .plugged
        case .powerBattery: kind = .battery
        case .monitorConnected(let k): kind = .connected; monitorKey = k ?? ""
        case .monitorDisconnected(let k): kind = .disconnected; monitorKey = k ?? ""
        }
    }

    private func build() -> Trigger {
        switch kind {
        case .time:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .time(hour: c.hour ?? 9, minute: c.minute ?? 0, weekdays: weekdays)
        case .sunrise: return .sunrise(offsetMinutes: offset)
        case .sunset: return .sunset(offsetMinutes: offset)
        case .wake: return .wake
        case .lock: return .lock
        case .unlock: return .unlock
        case .launch: return .appLaunch
        case .dark: return .appearanceDark
        case .light: return .appearanceLight
        case .plugged: return .powerPlugged
        case .battery: return .powerBattery
        case .connected: return .monitorConnected(identityKey: monitorKey.isEmpty ? nil : monitorKey)
        case .disconnected: return .monitorDisconnected(identityKey: monitorKey.isEmpty ? nil : monitorKey)
        }
    }
}

struct LocationSection: View {
    @ObservedObject var model: AppModel
    @State private var lat = ""
    @State private var lon = ""
    @State private var status = ""

    var body: some View {
        HStack(spacing: 6) {
            Text("Location").font(.caption)
            TextField("Lat", text: $lat).frame(width: 64)
            TextField("Lon", text: $lon).frame(width: 64)
            Button("Save") {
                if let la = Double(lat), let lo = Double(lon), (-90...90).contains(la), (-180...180).contains(lo) {
                    try? model.center.schedules.setLocation(GeoPoint(latitude: la, longitude: lo)); status = "Saved"; model.onSchedulesChanged?()
                } else { status = "Invalid" }
            }
            Button("Use my location") {
                AppEnvironment.shared.locationProvider.requestOnce { g in
                    DispatchQueue.main.async {
                        if let g { try? model.center.schedules.setLocation(g); lat = String(format: "%.3f", g.latitude); lon = String(format: "%.3f", g.longitude); status = "Saved"; model.onSchedulesChanged?() }
                        else { status = "Not allowed" }
                    }
                }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            if let g = model.center.schedules.location { lat = String(format: "%.3f", g.latitude); lon = String(format: "%.3f", g.longitude) }
        }
    }
}

// MARK: - Keyboard

struct KeyboardTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Brightness and volume keys") {
                Toggle("Use the keyboard's brightness and volume keys for external displays",
                       isOn: Binding(get: { model.settings.mediaKeysEnabled }, set: { on in
                    if on { MediaKeyTap.requestPermission(prompt: true) }
                    model.updateAppSettings { $0.mediaKeysEnabled = on }
                    model.accessibilityGranted = MediaKeyTap.hasPermission
                }))
                if model.settings.mediaKeysEnabled && !model.accessibilityGranted {
                    Banner(text: "macOS needs your permission to read these keys. Open System Settings, Privacy & Security, Accessibility, and switch DisplayControl on. If you rebuilt the app, remove it from the list and add it again.",
                           symbol: "lock.trianglebadge.exclamationmark.fill", tint: .orange)
                    Button("Open Accessibility settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                if model.settings.mediaKeysEnabled {
                    Label(model.keyTapRunning ? "Keys are active" : "Keys are not active yet", systemImage: model.keyTapRunning ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(model.keyTapRunning ? Color.green : Color.secondary)
                }
                Text("The keys control the display under the mouse pointer, so move the pointer onto the external display first. With the pointer on the built-in screen, macOS handles the keys as usual.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Custom shortcuts") {
                ForEach(HotkeyAction.allCases, id: \.self) { a in
                    HStack {
                        Text(a.title)
                        Spacer()
                        ShortcutRecorder(spec: Binding(get: { model.settings.hotkeys[a] }, set: { v in model.updateAppSettings { $0.hotkeys[a] = v } }))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.accessibilityGranted = MediaKeyTap.hasPermission }
    }
}

/// Click, then press a key combination. Escape cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var spec: HotKeySpec?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press keys…" : (spec.map(HotKeyCenter.describe) ?? "Record")) { toggle() }
                .frame(minWidth: 96)
            if spec != nil { Button { spec = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Clear shortcut") }
        }
        .onDisappear { stop() }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if e.keyCode == UInt16(kVK_Delete) { spec = nil; stop(); return nil }
            let mods = HotKeyCenter.carbonModifiers(e.modifierFlags)
            guard mods != 0 else { return nil }                       // require a modifier so typing is never hijacked
            spec = HotKeySpec(keyCode: UInt32(e.keyCode), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Command line

struct CommandLineTab: View {
    @ObservedObject var model: AppModel
    @State private var message = ""
    private var bundled: String { Bundle.main.bundlePath + "/Contents/Resources/bin/displaycontrol" }
    private let target = "/usr/local/bin/displaycontrol"
    private var installed: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: target)) != nil || FileManager.default.fileExists(atPath: target)
    }

    var body: some View {
        Form {
            Section("displaycontrol command") {
                Label(installed ? "Installed at \(target)" : "Not installed", systemImage: installed ? "checkmark.circle.fill" : "circle.dashed")
                HStack {
                    Button("Install") { install() }
                    Button("Copy install command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("sudo ln -sf \"\(bundled)\" \(target)", forType: .string)
                        message = "Copied. Paste it in Terminal."
                    }
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
                Text("DisplayControl must be running for the command to work. Run `displaycontrol status` to try it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts, Siri and scripts") {
                Text("These always work: the `displaycontrol://` URL scheme, the command line, and AppleScript's `do shell script`. Examples:").font(.caption)
                Text("open \"displaycontrol://preset/Evening\"\nopen \"displaycontrol://set?display=Dell&brightness=60\"").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("AI assistants (MCP)") {
                Text("Add this to your MCP client configuration:").font(.caption)
                Text("{ \"mcpServers\": { \"displaycontrol\": { \"command\": \"\(target)\", \"args\": [\"mcp\"] } } }")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        guard FileManager.default.fileExists(atPath: bundled) else { message = "The command line tool is not inside this app bundle."; return }
        do {
            try? FileManager.default.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: target)
            try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: bundled)
            message = "Installed."
        } catch {
            message = "macOS needs administrator rights here. Use “Copy install command” and run it in Terminal."
        }
    }
}

// MARK: - About

struct AboutTab: View {
    @ObservedObject var model: AppModel
    @State private var copied = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "display").font(.system(size: 44)).foregroundStyle(.tint)
            Text("DisplayControl").font(.title2.bold())
            Text("Version 1.0.0").foregroundStyle(.secondary)
            Text("Free and open source under the MIT License.").font(.callout)
            GroupBox("Privacy") {
                Text("DisplayControl never connects to the internet. There is no analytics, no crash reporting service and no account. Everything stays on this Mac.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(copied ? "Copied" : "Copy diagnostics") {
                    Task {
                        let text = await model.diagnostics()
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    }
                }
                Button("Check for updates") { NSWorkspace.shared.open(Links.releases) }
            }
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let finish: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case 0:
                Image(systemName: "display.2").font(.system(size: 40)).foregroundStyle(.tint)
                Text("Welcome to DisplayControl").font(.title2.bold())
                Text("Control the brightness, contrast, volume and input of your external monitors from the menu bar, the keyboard or the command line.")
            case 1:
                Text("Optional permissions").font(.title2.bold())
                Text("Both are optional and you can change them later.").foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Accessibility lets the brightness and volume keys control external monitors.", systemImage: "keyboard")
                        Button("Allow keys…") { MediaKeyTap.requestPermission(prompt: true); model.updateAppSettings { $0.mediaKeysEnabled = true } }
                        Label("Location lets schedules follow your local sunrise and sunset.", systemImage: "location")
                        Text("Use the Schedules tab to allow it or type coordinates.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            default:
                Text("Your displays").font(.title2.bold())
                ForEach(model.displays, id: \.key) { d in
                    HStack {
                        Image(systemName: d.isBuiltIn ? "laptopcomputer" : "display")
                        Text(d.name)
                        Spacer()
                        ModeBadge(mode: d.mode)
                        Button("Test") { model.run(selfTestFor: d.key) }.disabled(model.runningSelfTest)
                    }
                }
                if let r = model.selfTest {
                    Label(r.passed ? "\(r.display) passed." : "\(r.display) has a problem: \(r.steps.first { !$0.passed }?.detail ?? "")",
                          systemImage: r.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.passed ? Color.green : Color.orange)
                }
                Text("A test nudges the brightness by a few steps and puts it back.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step < 2 ? "Continue" : "Done") { if step < 2 { step += 1 } else { finish() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480, height: 340)
        .background(AppBackdrop(stars: model.settings.animatedStars))
    }
}
