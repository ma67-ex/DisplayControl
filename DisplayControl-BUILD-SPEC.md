# DisplayControl: Build Specification

Hand this whole file to the building agent (Opus 5.5). It is self-contained. Read all of it before writing code.

DisplayControl is an original macOS menu bar app, command line tool and marketing website that lets a user control external monitors the way a MacBook controls its built-in screen: real hardware brightness, contrast, volume, input source, rotation and power, plus sync, presets, schedules and automation. It is modelled on the feature set of an existing commercial product, DisplayBuddy, which was studied from its public website only.

---

## 0. Ground rules (read first)

### 0.1 What "same thing" means here

Build the same capabilities. Do not copy the product.

- Write all code from scratch. Do not decompile, disassemble or otherwise inspect the DisplayBuddy application binary, its DMG or its CLI. Do not download it.
- Do not copy any of its website text, FAQ answers, documentation prose, release notes, testimonials, press quotes, screenshots, icons, logos, brand names, fonts or image assets.
- Do not use the names DisplayBuddy or "Buddy" anywhere. The product name is **DisplayControl**. Bundle identifier: `app.displaycontrol.DisplayControl`. CLI binary name: `displaycontrol`.
- Do not invent testimonials, user counts, review scores, press coverage or "as seen in" logos. The website must contain only claims that are true of this codebase.
- Feature ideas, protocols (DDC/CI, VESA MCCS) and general behaviour are not proprietary and are fair to implement. Wording, design and code must be original.
- License the repository under MIT. First commit includes a `LICENSE` file: `Copyright (c) 2026 Muhammad Abdullah`.
- No AI or Claude attribution anywhere: not in commits, not in files, not in the website footer. Do not add `Co-Authored-By` lines.

### 0.2 Quality bar: "every feature is efficient and works"

This is a hard requirement. "Works" means demonstrably working, not "compiles". For each feature the agent must:

1. Implement it behind a testable seam (see section 5.3, the transport protocols).
2. Unit test the logic with mocks.
3. State in the final report exactly what was verified on real hardware, what was verified only against mocks, and what could not be verified. Never claim a DDC feature works on a real monitor unless it was actually exercised on one.

"Efficient" means all of the following hold (acceptance numbers are in section 9):

- Idle CPU is effectively zero. No timers or polling loops when nothing is happening. Everything is event-driven.
- No more DDC I2C traffic than needed: writes are coalesced and rate-limited, reads are cached, no per-frame or per-second polling of monitors.
- Idle memory stays small (target under 40 MB resident).
- Main thread never blocks on I2C. All monitor I/O runs off the main thread on a per-display serial queue.
- Event taps, location services and observers are installed only when the feature that needs them is turned on.

### 0.3 Honesty about environment

Facts about the machine the agent will run on (as of 2026-11-02, may change):

- Apple Silicon (arm64), macOS 27.2, Swift 6.4 from Command Line Tools only. `xcodebuild` is not available (only `swift build` / SwiftPM). Do not depend on Xcode project features. See section 5.1 for how to cope.
- Display hardware seen: a built-in Liquid Retina XDR panel and one 1920x1080 external display whose connection type is unknown (it might be a virtual or headless display). Assume DDC cannot be proven on this machine. Build a mock-first design and a hardware self-test command (section 6.11) that the user runs once with a real monitor attached.

---

## 1. Product overview

**Problem.** macOS exposes no brightness, volume or input controls for most third-party monitors. The buttons are hidden on the monitor, one display can be much brighter than another, and macOS Night Shift does not reach many external panels.

**Solution.** A menu bar app that talks to monitors over DDC/CI (the same protocol the monitor's own buttons use), with a software-dimming fallback for monitors that refuse DDC, and native control of Apple displays.

**Platforms.** macOS 13 or later (arm64 and x86_64, universal build if the toolchain allows; arm64 required). No Windows version in scope.

**Distribution.** Direct download of a signed-if-possible `.app` zipped, plus a Homebrew cask definition file in the repo (not published).

---

## 2. Feature list

Each feature below has an ID. Section 9 maps IDs to acceptance tests.

### 2.1 Display control

| ID | Feature | Detail |
|----|---------|--------|
| F1 | Real hardware brightness | DDC/CI VCP 0x10, 0-100 mapped to the monitor's reported maximum. |
| F2 | Contrast | VCP 0x12. |
| F3 | Speaker volume | VCP 0x62, plus mute (VCP 0x8D, 1 = mute, 2 = unmute). Only shown if the monitor reports the code. |
| F4 | Input source | VCP 0x60. Offer common values (DisplayPort 1/2, HDMI 1/2, USB-C) and a custom raw-code entry. |
| F5 | Power on / off | VCP 0xD6 (1 = on, 4 = standby, 5 = off). Warn that some monitors cannot be woken over DDC once off. |
| F6 | Rotation | Display rotation through CoreGraphics private display config (`CGSConfigureDisplayOrientation` style) or the DDC orientation code where supported. Values 0, 90, 180, 270. If unsupported, hide the control, do not fake it. |
| F7 | Resolution and refresh rate | List modes with `CGDisplayCopyAllDisplayModes` (include HiDPI modes with the `kCGDisplayShouldListAllModes` option) and switch with `CGConfigureDisplayWithDisplayMode`. |
| F8 | Apple and built-in displays | Built-in panel and Apple Studio Display / Pro Display XDR brightness via the DisplayServices private framework loaded with `dlopen` (symbols `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness`, `DisplayServicesCanChangeBrightness`). Everything optional-symbol guarded: if the symbols are missing the feature degrades, it must never crash. |
| F9 | Software dimming fallback | For a monitor that does not answer DDC: dim with `CGSetDisplayTransferByFormula` (gamma). Always restore with `CGDisplayRestoreColorSyncSettings` on quit, on crash handler where possible, on disable and on display removal. Also usable for Sidecar and AirPlay displays. |
| F10 | Control mode per display | Modes: `ddc`, `apple` (DisplayServices), `software`. Auto-detect the best mode on first sight and let the user override per display. Remember the choice by stable display identity (section 5.4). |
| F11 | Capability detection | Read the monitor's MCCS capabilities string (VCP 0xF3 sequence, assembled across fragments) once at first connection and cache it. Show only the controls that appear in `vcp(...)`. If the capabilities read fails, probe individual codes with a single read each and cache the result. |
| F12 | Picture mode warning | If brightness writes do not change the read-back value, show a hint: "Your monitor may be in a preset picture mode or DDC/CI may be off in its menu." |

### 2.2 Multi-display

| ID | Feature | Detail |
|----|---------|--------|
| F20 | Sync | Pick a host display. Changes to brightness, contrast or volume on the host propagate to followers. Only properties both sides support are synced. |
| F21 | Sync offsets | Per-follower offset or scale so that host 100% can map to follower 70%. Store as a linear map `follower = clamp(offsetScale * host + offsetConstant)`. Provide a simple UI: one slider "Follower brightness at host 100%". |
| F22 | Independent control | Every display always has its own sliders even while sync is on (moving a follower slider breaks sync for that display until re-sync, or adjusts its offset, user's choice in settings). |
| F23 | Active-display keyboard control | Keyboard actions target the display under the mouse pointer by default, or all displays (setting). |

### 2.3 Presets

| ID | Feature | Detail |
|----|---------|--------|
| F30 | Create, edit, delete, reorder presets | A preset has a name, an SF Symbol icon name, and a list of per-display settings chosen by the user via checkboxes. |
| F31 | What a preset can store | Brightness, contrast, volume, mute, input source, power state, rotation, resolution, sync on/off and host, display arrangement (positions), control mode. Each item is optional. |
| F32 | Apply preset | Apply in a deterministic order: arrangement, resolution, rotation, power, input, then brightness/contrast/volume last (so values land on a display that is awake and on the right input). Displays missing at apply time are skipped and reported, not treated as failures. |
| F33 | Delayed apply | `--delay N` on the CLI and a per-preset optional delay, to allow a monitor to wake. |
| F34 | Global hotkey per preset | Via the shortcut recorder (F50). |

### 2.4 Schedules

| ID | Feature | Detail |
|----|---------|--------|
| F40 | Triggers: time | Specific time of day on chosen weekdays. |
| F41 | Triggers: sunrise and sunset | Computed locally with the NOAA solar position algorithm from latitude and longitude. Location comes from CoreLocation if the user allows it, otherwise manual latitude/longitude entry or a city search offline list is NOT required, manual coordinates are enough. Support an offset in minutes (e.g. 30 min before sunset). Recompute at local midnight and on wake / timezone change. |
| F42 | Triggers: system events | Mac wake, screen lock, screen unlock, app launch, macOS appearance change (light/dark), power source change (plugged in / on battery), a specific monitor connected or disconnected. |
| F43 | Action | Activate one preset. Optionally a fallback preset when the trigger condition ends (e.g. unplugged vs plugged in). |
| F44 | Enable and disable | Per schedule toggle, without deleting. |
| F45 | Missed-time handling | If the Mac was asleep at the scheduled time, run the most recent missed time-based schedule once at wake, only if it is within a configurable window (default 2 hours). |
| F46 | Reconnect restore | A schedule with trigger "monitor connected" re-applies a preset because many monitors reset brightness when reconnected. |

Scheduling must use one-shot timers computed to the next fire time (not a polling tick). On wake, system clock change or timezone change, recompute all timers.

### 2.5 Input and automation

| ID | Feature | Detail |
|----|---------|--------|
| F50 | Brightness and volume keys | Optional. When on, F1/F2 (brightness) and F10/F11/F12 (mute, volume) media keys control external displays. Implemented with a `CGEventTap` on `NSSystemDefined` events (subtype 8, key codes from `NX_KEYTYPE_BRIGHTNESS_UP` etc.). Requires Accessibility permission: prompt only when the user turns the feature on, explain why, and show a status row if permission is missing. Consume the event only when it was applied to an external display, otherwise pass it through so the built-in screen still works. |
| F51 | Custom shortcuts | A shortcut recorder for: brightness up/down, contrast up/down, volume up/down, mute, activate preset N, cycle inputs, toggle sync. Use a lightweight Carbon `RegisterEventHotKey` wrapper (no Accessibility permission needed for plain hotkeys). |
| F52 | Step size | Per-property increment (default 5, also support 1). Hold-to-repeat speeds up gently but stays inside the I2C rate limit (section 5.5). |
| F53 | URL scheme | `displaycontrol://preset/<name>`, `displaycontrol://set?display=<name>&brightness=60`. Works from Shortcuts "Open URL", AppleScript, and Terminal `open`. |
| F54 | macOS Shortcuts / Siri / Spotlight | Via App Intents. IMPORTANT LIMITATION: App Intents need Xcode's metadata extraction at build time. With Command Line Tools only this may not work. Implement the intents in a separate file group behind a compile flag (`DC_APPINTENTS`), keep the URL scheme and CLI as the guaranteed automation paths, and document in the README that Shortcuts/Siri support needs an Xcode build. Do not claim Siri works unless the agent verified it. |
| F55 | Command line tool | See section 6.8. |
| F56 | MCP server | `displaycontrol mcp` speaks JSON-RPC over stdio (MCP) and exposes tools for list, get, set, preset list/activate, sync, schedule list/enable/disable. Same code path as the CLI. |

### 2.6 App chrome

| ID | Feature | Detail |
|----|---------|--------|
| F60 | Menu bar app, no Dock icon | `LSUIElement = true`. SwiftUI `MenuBarExtra` with window style, or an `NSStatusItem` plus `NSPopover` if `MenuBarExtra` limitations bite (see 5.1). |
| F61 | Simple and expanded display cards | Simple: brightness, contrast, volume sliders. Expanded: input, power, rotation, resolution, control mode, offsets. |
| F62 | Launch at login | `SMAppService.mainApp`. |
| F63 | Settings window | Tabs: General, Displays, Presets, Schedules, Keyboard, Command Line, About. |
| F64 | Onboarding | First launch: permission explanations, control mode auto-detect result per display, "test" button that nudges brightness by 1 step and reads it back. |
| F65 | Auto-update | Out of scope for v1. Provide an "Check for updates" menu item that opens the releases page URL from a single constant. Do not embed a third-party updater. |
| F66 | Localization-ready | All user strings in `Localizable.xcstrings` or `.strings` via `String(localized:)`. Ship English only. |
| F67 | Privacy | No network access at all in the app. No analytics, no crash reporting service, no license server. State this in the About tab. (The product is free and open source, so there is no license activation.) |
| F68 | Accessibility | All sliders have accessibility labels and values, full keyboard navigation in settings, honour Reduce Motion. |

### 2.7 Explicitly out of scope for v1

- Samsung Tizen and LG webOS Wi-Fi control. Document as a possible v2 (separate module `SmartMonitors`, WebSocket remote protocols).
- HDR toggle, True Tone, Night Shift and Dark Mode control through private frameworks. May be added later behind the same `DisplayServices` seam.
- UltraBright / XDR brightness beyond the nominal maximum. Risky (EDR overlay tricks) and not required. Leave a `TODO` and a design note only.
- Windows.
- A licensing, payment or activation system.

---

## 3. Features from the reference product's public docs worth matching in behaviour

These are behaviours, not wording. Match the behaviour in your own words.

- Control modes per monitor: DDC, Apple protocol, software, (Wi-Fi smart, not in v1).
- Sync follows only properties the host supports.
- Apple Silicon DDC over HDMI on the original M1 Mac mini and early MacBooks can fail; USB-C/Thunderbolt/DisplayPort alt-mode works. Surface this in the troubleshooting doc and in the "no response" hint (F12).
- Monitors with preset picture modes (Game, Movie) can ignore brightness writes; switching the monitor to a Custom mode fixes it. Docks, hubs, KVMs and cheap adapters can block DDC.
- Menu bar icon can be hidden by menu bar managers when there are too many icons.
- Multiple macOS user accounts: settings are per user.
- CLI: `status`, `list`, `get`, `set`, `preset list/activate`, `schedule list/enable/disable`, `sync`, `version`, JSON output when piped.
- Keyboard brightness keys are off by default because they need Accessibility permission.

---

## 4. Repository layout

```
DisplayControl/
  LICENSE                         MIT, Copyright (c) 2026 Muhammad Abdullah
  README.md
  Package.swift
  Sources/
    DisplayControlCore/           library: no UI, fully unit-testable
      Display/                    Display model, identity, registry, hotplug
      DDC/                        transports, MCCS parser, VCP, command queue
      Backends/                   DDCBackend, AppleBackend, SoftwareBackend
      Sync/                       SyncEngine
      Presets/                    Preset model, PresetStore, PresetApplier
      Schedules/                  Schedule model, solar calc, Scheduler
      Input/                      HotKeyCenter, MediaKeyTap
      IPC/                        control socket server and client, JSON schema
      MCP/                        MCP stdio server
      Support/                    Logger, Rate limiter, Debouncer, Paths
    DisplayControlApp/            executable: SwiftUI menu bar app
    displaycontrol/               executable: CLI (thin client of IPC, also hosts `mcp`)
  Tests/
    DisplayControlCoreTests/
  Packaging/
    Info.plist                    LSUIElement, usage strings
    DisplayControl.entitlements
    build-app.sh                  builds, assembles .app, ad-hoc codesigns
    homebrew/displaycontrol.rb    cask draft
  site/                           the marketing website (section 7)
  docs/                           user docs source (also rendered on the site)
```

Keep the core library free of AppKit where possible so it can run in the CLI process for the offline commands.

---

## 5. Architecture and technical detail

### 5.1 Build system and toolchain constraints

- Use Swift Package Manager only. Platforms: `.macOS(.v13)`. Swift tools version 5.9 or newer. Prefer Swift 5 language mode if Swift 6 strict concurrency causes friction with C interop; do not fight the compiler.
- Add `-Xlinker -framework` entries through `linkerSettings: [.linkedFramework("IOKit"), ...]`. Needed: IOKit, CoreGraphics, AppKit, SwiftUI, ServiceManagement, CoreLocation, Carbon (for hotkeys), IOKit.ps (power source), Network is NOT needed.
- Private symbols are reached with `dlopen` and `dlsym` at runtime, never linked directly, so the app still launches when a symbol vanishes in a new macOS.
- `MenuBarExtra` in SwiftUI is fine for the popup. If it cannot open Settings reliably or loses focus, use `NSStatusItem` + `NSPopover` hosting the SwiftUI view. Decide early with a 30 minute spike and record the decision.
- Assemble the `.app` bundle by script (`Packaging/build-app.sh`): copy the SwiftPM binary to `DisplayControl.app/Contents/MacOS/DisplayControl`, write `Info.plist`, copy the `displaycontrol` CLI into `Contents/Resources/bin/`, then ad-hoc sign with `codesign --force --deep --sign -`. Hardened runtime and notarization are optional and need a Developer ID, so document them rather than automating.
- Info.plist keys: `LSUIElement=true`, `CFBundleIdentifier=app.displaycontrol.DisplayControl`, `LSMinimumSystemVersion=13.0`, `NSLocationWhenInUseUsageDescription` (sunrise/sunset), `NSAppleEventsUsageDescription` not needed, URL type for scheme `displaycontrol`.
- The app must not be sandboxed (it needs IOKit service access and an event tap). Do not add App Sandbox entitlements.

### 5.2 DDC/CI implementation details (the core risk)

#### Wire format

DDC/CI uses I2C with these constants:

- Display DDC chip address: `0x37` (7-bit). Host sub-address (the "source address" byte in the payload): `0x51`.
- Set VCP feature, host to display, payload bytes:
  `[0x51, 0x84, 0x03, vcp, valueHigh, valueLow, checksum]`
  where checksum = XOR of the destination address byte (`0x6E`, which is `0x37 << 1`) and every payload byte before the checksum.
- Get VCP feature request: `[0x51, 0x82, 0x01, vcp, checksum]` with checksum = `0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ vcp`.
- Get VCP reply (read after a delay, typically 40 ms): 11 bytes: `[0x6E(dst echo, may be omitted by the transport), 0x88, 0x02, resultCode, vcp, type, maxHigh, maxLow, curHigh, curLow, checksum]`. Result code 0 = no error, 1 = unsupported VCP. Reply checksum: `0x50` XOR all reply bytes from the leading `0x6E` (see the correction below). Validate length and checksum; on mismatch retry up to 2 times.
  **CORRECTION, verified on real hardware (Acer ED270R S3, Apple Silicon, HDMI, 2026-11-02):** the reply checksum is `0x50` XOR *every preceding byte of the reply including the leading `0x6E`*, not just the bytes after it. Captured reply: `6E 88 02 00 10 00 00 64 00 64 A4` (brightness current 100, max 100). Use it as a test vector. The same rule applies to capability fragments.
- Capabilities request: `[0x51, 0x83, 0xF3, offsetHigh, offsetLow, checksum]`. Reply: `[0x6E, length(0x80|n), 0xE3, offsetHigh, offsetLow, ...ASCII fragment..., checksum]`. Concatenate fragments until a fragment has zero data bytes. Parse the string with a small recursive-descent MCCS parser: `(prot(monitor)type(LCD)model(X)cmds(...)vcp(10 12 60(0F 10 11) 62 ...)mccs_ver(2.2))`. `vcp(...)` entries can carry a nested allowed-values list in parentheses.
- Write spacing: the DDC/CI spec asks for at least 50 ms between commands to the same display. Enforce a minimum gap per display in the command queue (default 50 ms, adaptive up to 100 ms after any error, down again after 20 clean commands).

#### Apple Silicon transport (primary target)

Apple Silicon Macs do not expose `IOFBCopyI2CInterface`. Use the private `IOAVService` API, loaded via `dlsym` from `IOKit`:

- `IOAVServiceCreateWithService(CFAllocatorRef, io_service_t) -> IOAVServiceRef?`
- `IOAVServiceReadI2C(service, chipAddress: UInt32, offset: UInt32, outputBuffer: UnsafeMutableRawPointer, outputBufferSize: UInt32) -> IOReturn`
- `IOAVServiceWriteI2C(service, chipAddress: UInt32, dataAddress: UInt32, inputBuffer: UnsafeRawPointer, inputBufferSize: UInt32) -> IOReturn`

Typical call: `chipAddress = 0x37`, `dataAddress = 0x51` for writes, and the write buffer is the payload after the `0x51` byte (so `[0x84, 0x03, vcp, hi, lo, checksum]` with checksum seeded as `0x6E ^ 0x51 ^ ...`). Reads use `offset = 0` and a 12-byte buffer. Write twice if the monitor shows flaky acceptance (many implementations send each write twice with a short delay; make it a per-display tunable defaulting to once, with an automatic switch to twice after a failed read-back).

Finding the right `IOAVService` for each display (this is the hard part):

1. Enumerate `CGGetActiveDisplayList`. For each display, read EDID from the IORegistry (`IODisplayConnect` / `DCPAVServiceProxy` / `AppleCLCD2` properties vary by macOS version). Take vendor ID, product ID, serial and the manufacturing week/year.
2. Walk the IORegistry for services of class `DCPAVServiceProxy` (these have a `Location` property of `External` for external displays; the built-in is `Embedded`). Create an `IOAVService` from each external proxy.
3. Match proxy to `CGDirectDisplayID` by walking the registry path: the `AppleCLCD2` / `IOMobileFramebufferShim` node's `EDID UUID` or `DisplayAttributes` / `ProductAttributes` (`ManufacturerID`, `ProductID`, `AlphanumericSerialNumber`) against the CG display's `CGDisplayVendorNumber`, `CGDisplayModelNumber`, `CGDisplaySerialNumber`. If two identical monitors are attached, break ties by registry path order and the `UnitNumber`/ location index, and expose a "swap" control in Displays settings so the user can fix a wrong pairing.
4. Treat the pairing as a cache keyed by display identity (5.4) and re-resolve on every reconfiguration callback.

Because this matching logic relies on undocumented registry keys that change between macOS releases, isolate it in one file (`AVServiceResolver.swift`) with tests that run against recorded IORegistry JSON fixtures, and log (at debug level) every key it reads.

#### Intel transport (secondary, behind `#if arch(x86_64)` or runtime check)

Use the public-but-deprecated `IOFBCopyI2CInterface` / `IOI2CSendRequest` through the framebuffer service found with `CGDisplayIOServicePort` (deprecated, use `IOServiceMatching("IOFramebuffer")` and match by EDID). Support is best-effort. Keep it compile-guarded so arm64 builds do not need it.

#### Transport protocol seam

```swift
public protocol DDCTransport: Sendable {
    func write(_ payload: [UInt8]) throws                       // chip 0x37, data address 0x51
    func read(length: Int) throws -> [UInt8]
}
```

Everything above this (checksums, retries, spacing, VCP parsing, capability cache) is pure Swift and unit-tested with a `MockDDCTransport` that simulates a monitor: an in-memory VCP table, configurable error injection (NACK, bad checksum, timeouts), configurable latency, and a record of timestamps so tests can assert spacing and coalescing.

#### Command queue behaviour (this is where efficiency lives)

One `DisplayCommandQueue` actor per physical display:

- Serial execution, minimum inter-command gap as above.
- **Coalescing**: while a write for a given VCP code is pending or in flight, a newer write to the same code replaces the pending one. A slider drag that produces 200 value changes must result in at most about `dragSeconds / gap` writes and always ends on the final value.
- **Trailing-edge guarantee**: the last value requested is always sent.
- **Priority**: user-initiated writes beat reads; reads for refresh are low priority and dropped if a write is queued.
- **Read-back verification**: after a write batch settles (200 ms with no new writes), read the code once; if the value differs from the target by more than 1 step, retry once, then mark the display `ddcUnreliable` and show F12's hint. Make this verification toggleable because some monitors ignore reads but accept writes.
- **Timeouts and cancellation**: a hung I2C call must not wedge the queue. Run the blocking call on a dedicated serial `DispatchQueue` per display and apply a timeout wrapper (default 1 s). On timeout, mark the transport suspect, continue with the next command.
- **No wake-ups when idle**: the queue is a plain actor plus one-shot `DispatchSourceTimer` for the gap, cancelled when empty.

#### Value mapping

- Read `maxValue` for each VCP code once (from the Get VCP reply) and cache it. Brightness 0-100 in the UI maps linearly to `0...max`. Monitors with max not equal to 100 (e.g. 255 or 75) must map correctly.
- Never send values above `max`. Clamp and log.
- Volume: some monitors report volume max 100, others 255 or less. Same mapping rule. Keep a per-display "volume cap" setting for loud monitors (default 100%).

### 5.3 Backends

```swift
public protocol DisplayBackend: Sendable {
    var mode: ControlMode { get }
    func supports(_ property: DisplayProperty) -> Bool
    func get(_ property: DisplayProperty) async throws -> Int
    func set(_ property: DisplayProperty, to value: Int) async throws
}
```

`DDCBackend`, `AppleBackend` (DisplayServices, built-in and Apple displays), `SoftwareBackend` (gamma). A `Display` owns exactly one active backend and can switch. The sync engine, presets and keyboard layer only talk to `Display`, never to a backend directly.

**SoftwareBackend details**

- Brightness 0-100 maps to a gamma multiplier in `[0.1 ... 1.0]` (never fully black, otherwise users lock themselves out). Allow "dim to black" only behind an explicit setting and always keep the menu bar reachable.
- Use `CGSetDisplayTransferByFormula(display, 0, mult, 1, 0, mult, 1, 0, mult, 1)` for the red, green and blue channels.
- Re-apply after wake, after display reconfiguration and after the user changes the macOS color profile, since macOS resets gamma on those events. Subscribe to `NSApplication.didChangeScreenParametersNotification` and `NSWorkspace.didWakeNotification`.
- Always call `CGDisplayRestoreColorSyncSettings()` on app termination (`applicationWillTerminate`), on `SIGTERM`/`SIGINT` via `DispatchSource` signal handlers, and when switching a display away from software mode. Document that a hard crash can leave a display dimmed until relaunch or logout, and add a CLI command `displaycontrol reset-gamma`.
- Does not affect the screen's real backlight. Label it "Software dimming" in the UI.

**AppleBackend details**

- `dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)`; resolve symbols with `dlsym`; if any are missing, `supports(...)` returns false for everything and the display falls back to software mode.
- Brightness is a `Float` 0.0 to 1.0. Map to 0-100.
- Subscribe to brightness changes if a notification is available, otherwise read on popup open only (never poll).

### 5.4 Display identity and persistence

`CGDirectDisplayID` is not stable across reboots or reconnects. Define:

```swift
struct DisplayIdentity: Codable, Hashable {
    let vendorID: UInt32
    let productID: UInt32
    let serial: UInt32          // 0 if absent
    let alphanumericSerial: String?   // from EDID descriptor if present
    let isBuiltIn: Bool
    let locationHint: String?   // connection port path, only to disambiguate identical monitors
}
```

All saved state (control mode, offsets, step sizes, caps, presets, schedules) is keyed by `DisplayIdentity`, never by display ID. Presets keep a human-readable display name as a secondary hint for the UI.

### 5.5 Hotplug and reconfiguration

- Register `CGDisplayRegisterReconfigurationCallback`. Debounce the burst of callbacks (macOS fires several per change) by 500 ms, then rebuild the registry once.
- On rebuild: diff by identity, create backends only for new displays, tear down only removed ones, keep caches for displays that stay.
- Fire a `displayConnected(identity)` event for schedules (F42, F46). Delay the first DDC command to a newly connected monitor by about 2 seconds, since monitors often ignore DDC while negotiating the link, and retry with backoff (2 s, 4 s, 8 s) up to 3 times.

### 5.6 Sync engine

- Single `SyncEngine` actor. State: `hostIdentity`, `followers`, per-follower `Offset(scale, constant)`.
- Input: a `propertyChanged(display, property, value, origin)` event. If `origin == .sync`, ignore it (prevents loops). If the display is the host and the property is in `{brightness, contrast, volume}`, compute each follower's mapped value and enqueue it on that follower's command queue (which coalesces).
- Ensure follower writes happen concurrently across displays (each has its own queue), so syncing three monitors takes about the time of one.
- Sync is allowed to include the built-in display (Apple backend) as host or follower. Built-in updates are cheap and not rate limited.
- Persist sync state in presets and in settings.

### 5.7 Presets storage and apply

- JSON file `~/Library/Application Support/DisplayControl/presets.json`, versioned (`"version": 1`), written atomically (write to temp, `rename`). Back up the previous file as `presets.json.bak` before overwrite.
- `PresetApplier` returns a per-display, per-property result list (applied, skipped because missing, failed with reason). The UI and CLI show a concise summary. Never throw away partial success.
- Applying a preset must be idempotent and safe to repeat.

### 5.8 Scheduler

- `Scheduler` actor holds `[Schedule]`. For time-based and sun-based triggers it computes the next fire date and sets a single `DispatchSourceTimer` for the earliest one. After firing, recompute.
- Observers (installed only if at least one enabled schedule needs them):
  - Wake: `NSWorkspace.didWakeNotification`.
  - Lock/unlock: `DistributedNotificationCenter` names `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked`.
  - Appearance: `DistributedNotificationCenter` name `AppleInterfaceThemeChangedNotification`.
  - Power source: `IOPSNotificationCreateRunLoopSource` with `IOPSCopyPowerSourcesInfo` to read AC vs battery.
  - Display connect/disconnect: from the registry rebuild events (5.5).
  - Clock change: `NSSystemClockDidChange` and `NSSystemTimeZoneDidChange`.
- Solar calculation: implement the NOAA sunrise/sunset equations in `SolarCalculator.swift` (pure function `(date, lat, lon) -> (sunrise, sunset)?`, returns nil for polar day/night). Unit test against known values for at least 5 cities and dates with a tolerance of 2 minutes.
- Persist schedules in `schedules.json` with the same atomic-write scheme.

### 5.9 Media keys and hotkeys

- `MediaKeyTap`: `CGEvent.tapCreate` at `.cgSessionEventTap`, `.headInsertEventTap`, mask for `NSSystemDefined` (type 14). Decode `data1`: key code in bits 16-23, key state in bits 8-15 (`0xA` down, `0xB` up), repeat flag bit 0. Handle `NX_KEYTYPE_BRIGHTNESS_UP = 2`, `BRIGHTNESS_DOWN = 3`, `SOUND_UP = 0`, `SOUND_DOWN = 1`, `MUTE = 7`.
- The tap callback must return fast: decode, hand off to a Swift concurrency task, return. Re-enable the tap if macOS disables it (`kCGEventTapDisabledByTimeout` / `ByUserInput`).
- Install the tap only when F50 is on and Accessibility is granted; check with `AXIsProcessTrustedWithOptions`. Poll permission only while the permission prompt UI is visible (a short-lived 1 s timer), never otherwise.
- Target display: display under the pointer by default (`NSEvent.mouseLocation` mapped to a screen), or all displays.
- Brightness key steps follow the per-display step setting. When the targeted display is the built-in one, do not consume the event (let macOS handle it).
- Custom hotkeys: Carbon `RegisterEventHotKey` for each recorded key combination, unregistered on removal or app quit.

### 5.10 Local control channel (CLI and automation)

- Unix domain socket at `~/Library/Application Support/DisplayControl/control.sock`, mode `0600`, created by the app at launch, removed at quit. Protocol: newline-delimited JSON requests and responses, e.g. `{"id":1,"cmd":"set","display":"Dell U2723QE","props":{"brightness":70}}`.
- The CLI connects, sends one request, prints the reply, exits. If the socket is missing, the CLI prints "DisplayControl is not running" and exits with code 2, or (flag `--launch`) opens the app and retries for up to 5 seconds.
- Only the owning user can connect (filesystem permission). No TCP listener, ever.
- Versioned: every request carries `"v":1`. The server rejects unknown versions with a clear error.
- Commands: `status`, `list`, `get`, `set`, `preset.list`, `preset.activate`, `schedule.list`, `schedule.enable`, `schedule.disable`, `sync.status`, `sync.enable`, `sync.disable`, `reset-gamma`, `selftest`, `version`.

### 5.11 Logging

- `os.Logger` with subsystem `app.displaycontrol` and categories `ddc`, `registry`, `sync`, `schedule`, `keys`, `ipc`. Debug level only emits DDC byte dumps. Never log anything user-identifying. Provide "Copy diagnostics" in About which gathers: macOS version, chip, display list with vendor/product IDs, control modes, last 200 log lines for the `ddc` category, capability strings.

---

## 6. UI specification

Original look. Use native macOS controls and a clean, dense menu bar popover. Do not imitate DisplayBuddy's visuals; follow Apple's Human Interface Guidelines.

### 6.1 Menu bar popover

- Width about 320 pt. Vertically scrolls if many displays.
- Header row: app title, a sync toggle, a gear button for Settings.
- One card per display: name, a small connection badge (built-in, DDC, Apple, software), brightness slider (always), contrast and volume sliders (when supported), a disclosure chevron for the expanded view.
- Footer: preset chips (horizontal scroll, up to 6 visible), "Edit presets".
- Sliders: continuous update while dragging (coalesced by the queue), keyboard arrows adjust by the step, Option-click resets. Show the numeric value on hover or while dragging.
- Empty states: "No external displays found" with a one-line explanation and a link to Troubleshooting.

### 6.2 Expanded display card

Input source picker, power button, rotation picker, resolution list, control mode picker with a short explanation of each mode, sync offset slider (only for followers), "Test this display" (runs the self-test for this monitor), picture-mode hint banner when F12 triggers.

### 6.3 Settings

- General: launch at login, show or hide the icon text, menu bar icon style, step size, "Control all displays vs the one under the pointer".
- Displays: reorderable list, per-display friendly name, control mode, volume cap, "re-detect", "swap pairing", hide this display.
- Presets: list with drag reorder, editor sheet with per-property checkboxes per display, icon picker, hotkey recorder, delay field.
- Schedules: list with enable toggles, editor sheet (trigger kind, time or sun offset, weekdays, preset, optional end preset), location section for sunrise and sunset.
- Keyboard: toggle media keys (with permission status), shortcut recorders.
- Command Line: shows whether the `displaycontrol` command is installed on PATH. "Install" symlinks `/usr/local/bin/displaycontrol` to the bundled binary (use `NSAppleScript` "with administrator privileges" only if the plain symlink fails; or offer a one-line copy-paste `sudo ln -sf` instead of elevating).
- About: version, licence (MIT), privacy statement (no network), "Copy diagnostics".

### 6.4 States and errors

Every control has loading, success and failure states. A failed DDC write shows a subtle inline warning on that display card (not a modal alert). Only one non-blocking banner at a time. Never show raw error codes without a plain-language line.

### 6.5 Accessibility and appearance

Light and dark mode, increased contrast, reduced motion, VoiceOver labels, Dynamic Type is not applicable on macOS but respect the system font. No custom colour palettes that break in dark mode.

### 6.6 Onboarding

Three short steps: what it does, optional permissions (Accessibility for media keys, Location for sun schedules, each skippable), per-display detection result with a "test" button.

### 6.7 Menu bar behaviour

Left click toggles the popover. Right click shows a small menu: preset list, "Reset software dimming", Settings, Quit. Escape closes the popover.

### 6.8 CLI specification

```
displaycontrol status                       compact table of displays
displaycontrol list                         name, index, id, control mode, capabilities
displaycontrol get <display> [--brightness|--contrast|--volume|--input]
displaycontrol set <display> [--brightness N] [--contrast N] [--volume N]
                             [--input NAME|CODE] [--rotation 0|90|180|270] [--power on|off]
displaycontrol set --all --brightness N
displaycontrol preset list
displaycontrol preset activate <name> [--delay SECONDS]
displaycontrol schedule list|enable <id>|disable <id>
displaycontrol sync [enable <display>|disable]
displaycontrol reset-gamma
displaycontrol selftest [<display>]
displaycontrol mcp                          start MCP stdio server
displaycontrol version
Global flags: --json, --human, --index N, --uuid ID, --launch
```

Display lookup: case-insensitive name, `--index`, or `--uuid`. Default output is human when stdout is a TTY and JSON when piped. Exit codes: 0 ok, 1 usage error, 2 app not running, 3 display not found, 4 display refused the command, 5 partial success (preset). Provide shell completions for zsh and bash under `Packaging/completions/`.

### 6.9 MCP server

Implement MCP over stdio (JSON-RPC 2.0, `initialize`, `tools/list`, `tools/call`). Tools: `list_displays`, `get_display`, `set_display`, `list_presets`, `activate_preset`, `set_sync`, `list_schedules`, `set_schedule_enabled`. Tool inputs are validated against JSON Schema and brightness/contrast/volume are clamped to 0-100. Destructive power-off requires an explicit `"confirm": true` argument. Write a short README section showing how to register it with an MCP client.

### 6.10 Auto-detect of the best control mode

On first sight of a display:

1. If it is built-in or an Apple display and DisplayServices answers a brightness read: `apple`.
2. Else if a DDC transport exists and a Get VCP 0x10 returns a valid reply (try up to 3 times with growing gaps): `ddc`.
3. Else: `software`.

Re-run detection when the user presses "re-detect" or after a monitor reconnect when the previous mode was `software`.

### 6.11 Hardware self-test (`displaycontrol selftest`)

A guided check the user can run once per monitor. It must be safe: it changes brightness by at most 5 steps and always restores. Steps: resolve transport, read capabilities, read brightness, write brightness +3 then read back, write original, read back, test contrast and volume if advertised, report timings (median round-trip), report whether the monitor needs double writes. Output a plain pass/fail table and an optional anonymous diagnostics blob the user can paste into a GitHub issue. This is the authoritative proof that the DDC path works on a given monitor.

---

## 7. Marketing website (`site/`)

Original design and original copy. Static HTML, CSS and a little vanilla JS. No frameworks required, no build step required. It must work when opened from the file system and when hosted on any static host (Cloudflare Pages, Vercel, GitHub Pages).

### 7.1 Pages

- `index.html`: hero, problem, how it works, features grid, sync, presets, schedules, compatibility, automation (CLI and MCP), privacy, download, FAQ summary.
- `features.html`: each feature with a short description.
- `docs/`: getting-started, keyboard, sync, presets, schedules, automation and CLI, troubleshooting. Written fresh from section 2, 3 and 5 of this spec.
- `faq.html`: write at least 20 original questions and answers covering compatibility, docks/hubs/KVMs, HDMI on Apple Silicon, picture modes, privacy, multiple accounts, uninstalling, reporting bugs. Wording must be original.
- `download.html`: a button pointing at one constant URL, plus checksum display and install steps (drag to Applications, first-launch Gatekeeper note for an ad-hoc signed build, permissions).
- `compatibility.html`: an honest table of tested monitor/connection combinations. Start with "none verified yet" rows and a call to submit results via GitHub issue template. Do not fabricate numbers or a success rate.
- `privacy.html`, `license.html` (MIT).
- `404.html`.

### 7.2 Design requirements

Choose an original visual identity: its own colour palette, type scale and layout, a simple original logo (a rounded square with a sun-over-horizon or slider motif, drawn as inline SVG, no third-party artwork). Dark and light mode through `prefers-color-scheme`. Mobile first, no horizontal scroll at 360 px. Fast: no web fonts (system font stack), no third-party scripts, total transfer under 200 KB per page, Lighthouse performance 95 or higher.

Use real UI that can be drawn with HTML and CSS to illustrate the product (a fake popover built from divs) instead of screenshots of anyone else's app. If real screenshots of DisplayControl are captured later, they replace the HTML mockups.

### 7.3 SEO and metadata

Per-page `<title>` and meta description, canonical URLs, Open Graph and Twitter cards, a generated `sitemap.xml`, `robots.txt`, JSON-LD `SoftwareApplication` markup that contains only true facts (name, operating system, price 0, license MIT). No fake ratings.

### 7.4 Content rules

Everything on the site must be true of the code in this repo. If a feature is partially done (for example Siri via App Intents requiring Xcode), say so on the site.

---

## 8. Phased build plan

Work in this order. Each phase ends with passing tests and a short commit message in plain English. Stop and report at the end of each phase before starting the next only if a blocker appears; otherwise keep going.

1. **Scaffold.** Repo, `LICENSE`, `Package.swift`, targets, empty modules, CI script `Scripts/check.sh` that runs `swift build` and `swift test`.
2. **Pure logic first.** DDC packet builder and checksum, reply parser, MCCS capabilities parser, value mapper, rate limiter, debouncer, command queue with coalescing, `MockDDCTransport`, solar calculator, schedule next-fire computation, sync mapping math. Full unit tests. No hardware.
3. **Display model.** `Display`, identity, registry rebuild, hotplug debounce, persistence store.
4. **Backends.** Software (gamma) with guaranteed restore, Apple (DisplayServices via dlsym with graceful absence), DDC with the Apple Silicon IOAVService transport and resolver, Intel transport guarded. Run what can run on this machine (built-in panel brightness read, gamma dim and restore on the external display).
5. **Engines.** Sync, presets store and applier, scheduler with all triggers.
6. **IPC and CLI.** Socket server, CLI client, JSON output, exit codes, MCP server. Integration test that starts the server in-process against mock displays and drives it through the CLI client library.
7. **App UI.** Menu bar, cards, settings tabs, onboarding, media keys, hotkeys, launch at login, URL scheme, packaging script producing `DisplayControl.app`.
8. **Selftest and diagnostics.**
9. **Website.**
10. **Docs, README, polish, final verification report.**

---

## 9. Acceptance criteria and test plan

### 9.1 Unit and integration tests (must pass in `swift test`)

| Area | What is asserted |
|------|------------------|
| DDC packets | Known-good byte vectors for set and get brightness match published examples; checksum functions correct for random payloads. |
| DDC parser | Valid reply parsed; wrong length, wrong checksum, result code 1 (unsupported) each produce the right error. |
| MCCS parser | At least 6 real-world capability strings (with nested lists, `mccs_ver`, `cmds`, `vcp` with `60(0F 11 12)` style values) parse to the expected structure; malformed strings do not crash. |
| Command queue | 200 rapid writes to one VCP produce at most `ceil(duration/gap)+1` actual writes and the final write equals the last requested value; spacing between any two transport calls is at least the configured gap; error injection triggers retry then marks display unreliable; a hung transport times out and the next command still runs. |
| Value mapping | Max 100, 255, 75 map correctly at 0, 1, 50, 99, 100; never exceeds max. |
| Sync | Host change propagates to followers with offsets; no feedback loop (origin tagging); properties unsupported by a follower are skipped. |
| Presets | Apply order is deterministic; missing displays skipped; persist and reload round-trip; corrupt file falls back to the `.bak`. |
| Scheduler | Next fire computed correctly across DST changes, weekday filters, midnight rollover; wake recompute; missed-schedule window rule; sun triggers with offset. |
| Solar | Within 2 minutes of reference values for 5 cities and 3 dates, nil in polar regions. |
| IPC | Round-trip every command against mock displays; wrong version rejected; socket permission mode is 0600. |
| MCP | `initialize`, `tools/list`, `tools/call` conformance; invalid arguments return JSON-RPC errors, not crashes. |
| AVService resolver | Recorded IORegistry fixtures (at least one MacBook with one external, one with two identical externals) resolve to the right pairing. |

### 9.2 Efficiency measurements (record numbers in the final report)

Measure on the build machine and report: idle CPU (Activity Monitor or `top -pid`, sampled for 60 s with the popover closed, target under 0.1 percent average), resident memory with popover closed (target under 40 MB) and open (under 80 MB), launch-to-menu-bar time (target under 1 s), CLI round-trip for `get` (target under 50 ms excluding the DDC call itself), number of DDC writes generated by a simulated 3 second slider drag (target at most 3 seconds divided by the gap plus one), zero wake-ups per second when idle as shown by `sudo powermetrics --samplers tasks` or Instruments if available. If a measurement cannot be taken, say so.

### 9.3 Manual verification checklist (user runs once with a real monitor)

Document this list in `docs/verification.md` for the user:

1. `displaycontrol list` shows the monitor and a DDC mode.
2. `displaycontrol selftest` passes.
3. Brightness slider changes the real backlight and the monitor's own OSD agrees.
4. Volume, contrast and input work or are correctly hidden.
5. Sync with the built-in display, offsets behave.
6. Preset round-trip, including input switching.
7. Schedule fires on wake, on a time trigger and on monitor connect.
8. Media keys steer the display under the pointer; the built-in screen still works with the keys.
9. Unplug and replug the monitor: settings restored, no crash.
10. Quit the app while software dimming is on: the screen returns to normal brightness.

---

## 10. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| IOAVService and registry keys change in new macOS versions | Single resolver file, `dlsym` only, graceful degradation to software mode, fixture tests, version-tagged log lines. |
| DDC is unreliable behind docks, hubs, KVMs and HDMI on some Apple Silicon Macs | Detect, explain in-app (F12) and in the docs; never hang; software fallback. |
| Monitors with picture modes ignore writes | Read-back verification plus hint. |
| A crash leaves gamma dimmed | Restore on every exit path, signal handlers, `reset-gamma` command. |
| Event tap disabled by the system | Detect disabled events and re-enable; fall back to hotkeys. |
| Apple Intents need Xcode | Compile flag, documented limitation, URL scheme and CLI as guaranteed paths. |
| No hardware to test DDC on the build machine | Mock-first design, `selftest`, honest report of what was and was not verified. |
| Legal exposure from copying the reference product | Section 0.1 is binding. No binary inspection, no copied text or assets. |

---

## 11. Definition of done

The work is done only when all of these are true:

- `swift build -c release` and `swift test` pass with zero failures and no warnings that indicate real problems.
- `Packaging/build-app.sh` produces a launchable `DisplayControl.app` that shows a menu bar icon and lists the built-in display with a working brightness slider on this machine.
- The `displaycontrol` CLI works against the running app for every command in 6.8, tested.
- The software dimming fallback dims and restores the external display on this machine, verified.
- Every feature F1 to F68 is either implemented and tested, or listed in the final report with its exact status ("implemented, mock-tested only", "implemented, hardware-verified", "not implemented, reason"). No silent omissions.
- The website builds as static files, every page is complete, passes an automated check for broken internal links and missing alt text, and contains no copied DisplayBuddy text or assets and no fabricated claims.
- `LICENSE` is MIT with the required copyright line. No AI attribution anywhere.
- The final report includes the efficiency numbers from 9.2 and the manual checklist from 9.3.

---

## 12. Reference facts gathered from the DisplayBuddy public site (for orientation only)

Do not copy wording. These are facts about what a competing product claims to do, useful for scoping:

- Mac and Windows app; controls brightness, contrast, volume, input, rotation, power and resolution; sync with offsets; presets; schedules with triggers (time, sunrise/sunset, lock/unlock/wake, dark mode, monitor connected, power source, app launch); keyboard keys and custom shortcuts; Siri, Shortcuts, AppleScript and Spotlight; widgets and Control Center controls; CLI and an MCP server; software-gamma fallback; LG webOS and Samsung Tizen Wi-Fi control; Apple Studio Display and Pro Display XDR support; UltraBright on MacBook Pro; color profile and display preset selection; True Tone, Night Shift and Dark Mode toggles; HDR toggle.
- Technical claims: DDC/CI over cable, Apple native APIs for Apple displays, under 30 MB memory when idle, license activation needs internet and everything else runs offline.
- Known limitation cited by that product: DDC over HDMI on early M1 Macs does not work; USB-C/Thunderbolt works.
- Pricing model of that product (not relevant here): paid lifetime license. DisplayControl is free and open source (MIT).

---

## 13. Instructions to the building agent

1. Read this whole document, then write a one-page plan that lists any ambiguity you resolved and how.
2. Use the phases in section 8. Run `swift build` and `swift test` after each phase.
3. Prefer small, well-named files. Match the surrounding code style once it exists. Comments only where behaviour is non-obvious (especially around private API usage and I2C timing).
4. Do not skip tests to save time. Do not weaken an acceptance threshold to make a test pass; report the real number instead.
5. Use `dlsym` for every private symbol. Never import or link private headers or frameworks directly.
6. Keep the app offline: no networking code, no third-party SDKs, no telemetry. No third-party dependencies at all unless unavoidable; if you add one, justify it in the README.
7. At the end produce `FINAL-REPORT.md` containing: feature status table (F1 to F68), test results, efficiency numbers, the manual checklist results you could not perform, known issues, and a list of every private API used with the fallback behaviour when it is missing.
8. If something in this spec is impossible or unsafe, say so in the report and implement the safest reasonable alternative. Do not pretend.
