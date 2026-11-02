# DisplayControl: final report

Date: 2026-11-02. Built from `DisplayControl-BUILD-SPEC.md` on an Apple Silicon MacBook (macOS 27.2, Swift 6.4 from the Command Line Tools, no Xcode).

## Summary

A working macOS menu bar app, command line tool, MCP server and static website, about 6,400 lines of Swift plus the site generator. 106 automated tests pass. Real DDC/CI control was verified on one external monitor (Acer ED270R S3 over HDMI). Media keys and the real menu bar popover were later confirmed by the user. Global hotkeys, live system-event triggers and URL scheme launch from LaunchServices remain implemented but not exercised, and are listed as such below.

Run `./Scripts/check.sh` to rebuild and re-run everything, and `./Packaging/build-app.sh` for `dist/DisplayControl.app` and the zip.

## Status legend

- **Hardware**: exercised on a real monitor or display on this Mac.
- **Tested**: covered by automated tests with a simulated monitor or fake display system, and driven end to end through the real binary in demo mode.
- **Compiled only**: implemented and builds, not run.
- **Not built**: not implemented.

## Feature status

| ID | Feature | Status | Notes |
|---|---|---|---|
| F1 | Hardware brightness | **Hardware** | Acer ED270R S3, HDMI, Apple Silicon. 100 to 90 to 100 verified with read-back. |
| F2 | Contrast | Hardware (partial) | Capability and read work. Writes did not change the value on this monitor, which the app flagged with its hint. Probably a locked picture mode. |
| F3 | Volume and mute | Tested | The test monitor reports no volume. |
| F4 | Input source | Hardware (read), Tested (write) | Read returned HDMI 1 (17). Switching was not tried on the real monitor. |
| F5 | Power | Hardware (read), Tested (write) | Read returned on. Power off was deliberately not sent. |
| F6 | Rotation | Tested | DDC orientation code only. The CoreGraphics private route in the spec was not built. |
| F7 | Resolution and refresh rate | Compiled only | Uses CGDisplayMode APIs. Ordering in presets is tested with a fake system. Not run on a real display. |
| F8 | Apple and built-in displays | **Hardware** | Built-in panel read and write through DisplayServices passed the self-test. Studio Display and Pro Display XDR not available. |
| F9 | Software dimming | **Hardware** | Set 50% gave gamma 0.55 on the external display. SIGTERM restored 1.0, and the app exited. |
| F10 | Control modes and auto-detect | **Hardware** | Auto picked DDC for the Acer and Apple for the built-in. Forcing software and back worked. |
| F11 | Capability detection | **Hardware** | MCCS 2.2, model ACER, 33 controls parsed. |
| F12 | Picture-mode hint | **Hardware** | The failed contrast write produced "[check monitor settings]". |
| F20 | Sync | Tested | Host to follower, loop-free, skips unsupported controls. Run through the real binary in demo mode. |
| F21 | Sync offsets | Tested | 70% at host 100% verified in tests. |
| F22 | Independent control | Tested | Followers keep their own sliders. Sync is one way. |
| F23 | Keyboard targets the display under the pointer | **Hardware** | Confirmed by the user: with the all-displays option off, keys change only the display under the pointer. |
| F30 to F33 | Presets: create, edit, store, apply, delay | Tested | Store round trip, corrupt-file fallback, apply order, missing displays, idempotency. The editor UI renders (snapshots) but was not clicked through. |
| F34 | Preset hotkey | Compiled only | |
| F40 | Time trigger | Tested | Weekdays, midnight, daylight saving both ways. |
| F41 | Sunrise and sunset | Tested | Within two minutes of an independent NOAA implementation for six cities. Polar nil. Location lookup compiled only. |
| F42 | System-event triggers | Tested (logic), Compiled only (OS observers) | Trigger matching and pairing tested. Wake, lock, appearance and power observers were not exercised live. |
| F43 | Action and end preset | Tested | |
| F44 | Enable and disable | Tested | |
| F45 | Missed-time catch-up | Tested | Two hour window. |
| F46 | Reconnect restore | Tested | Connection events are emitted; the scheduler ignores startup. |
| F50 | Media keys | **Hardware** | Confirmed on the external Acer display after the permission was granted. Needed a stable signing certificate and a system-wide permission reset (see Known issues). |
| F51 | Custom shortcuts | Compiled only | Carbon hotkeys. The recorder renders but was not used. |
| F52 | Step size | Tested | Hold-to-repeat relies on the coalescing queue. |
| F53 | URL scheme | Tested (parsing), Compiled only (AppleEvent handler) | The bundle declares the scheme; launching through LaunchServices was not tried. |
| F54 | App Intents, Siri, Spotlight, Shortcuts | **Not built** | Needs an Xcode build. Use the URL scheme or CLI. The `DC_APPINTENTS` flag from the spec was not created. |
| F55 | Command line tool | **Hardware** | Run against the live app on real displays. Exit codes verified. |
| F56 | MCP server | Tested | Handshake, tool list, clamping, power-off guard, JSON-RPC errors. Smoke tested over stdio. |
| F60 | Menu bar app without a Dock icon | **Hardware** | The user opened the real popover. It exposed a collapsed-list bug, now fixed. |
| F61 | Simple and expanded cards | Compiled only | Rendered in snapshots, expanded state not captured. |
| F62 | Launch at login | Compiled only | `SMAppService`, needs the app in Applications. |
| F63 | Settings window | Compiled only | All seven sections render in snapshots. |
| F64 | Onboarding and test button | Compiled only | |
| F65 | Updates | Done as specified | A menu item opens the releases page. The URL is a placeholder. |
| F66 | Localization-ready | **Not built** | Strings are inline English. |
| F67 | Privacy | Done | No networking code anywhere. |
| F68 | Accessibility | Partial | Labels on sliders and icon buttons, keyboard-reachable controls. Not audited with VoiceOver. |
| Boost | Extra brightness (100 to 200 percent) by scaling the RGB gains | **Hardware** | Added after the first release. On the Acer: 120% gave gains 60/56/50 and 100% restored 50/47/42 and preset 5 exactly. 8 tests. Whether 200% looks right (clipping) is for the user to judge. |
| Design | Redesigned window, Light / Night / system appearance, brightness glow | Tested (logic), snapshot-checked (look) | Glow math and appearance setting have 7 tests. The look was checked in rendered images of both modes; the user has not yet seen it live. |
| Extras | Dark Mode, Night Shift (+ warmth), True Tone toggles, also in presets | **Hardware** | Each switched and restored on this MacBook through the CLI and read back. Private CoreBrightness and SkyLight interfaces, loaded at run time. |
| Extras | HDR switch | Compiled only | Shown only where macOS reports support. This Mac's built-in panel reported none, and no HDR monitor was available. |
| Extras | Color profile picker (per display, in presets) | **Hardware** | Built-in display switched to sRGB and reset to its own profile, read back each time. Public ColorSync API. |
| Comfort | Preset fade, brightness floor and ceiling, reset-everything (button, command, shortcut) | Tested | 7 tests, including that a fade ends on the exact values and that panic undoes boost and a color profile. Panic and the on-screen bar path were run on the built-in display; the Acer was unplugged at the time, so boost-then-panic was not repeated on real hardware. |
| Comfort | On-screen bar when keys change a value, menu bar number | Snapshot-checked | Bar rendered in both modes. Not seen live: it needs a real key press. |
| Tooling | Hardware self-test, probe, diagnostics | **Hardware** | `selftest` and `probe` ran on this Mac. `selftest --mock` runs without hardware. |

Not in v1 by design: Samsung and LG Wi-Fi control, HDR and Night Shift toggles, extra-bright modes, Windows. Hardware DDC on Intel Macs is also not built (no `IOFBCopyI2CInterface` path), so Intel Macs get Apple-display control and software dimming only.

## Findings from real hardware

1. **My reply checksum was wrong, and the real monitor proved it.** The spec and my first implementation XORed `0x50` with the reply bytes after the leading `0x6E`. The real rule includes that `0x6E` byte. The captured reply `6E 88 02 00 10 00 00 64 00 64 A4` is now a test vector. Without a real monitor this bug would have shipped.
2. **Pairing a display to its I2C service works** through `ProductAttributes` (vendor 0x0472, product 0x0B39, serial) read from the IORegistry. One external monitor was tested, so the duplicate-monitor tie-break is only tested against fixtures.
3. **HDMI DDC worked** on this Apple Silicon MacBook.
4. The 24 MB and 0.0% figures below come from the release build.

## Test results

`swift test`: 72 tests in 14 suites, all passing. Areas: DDC packet vectors including the hardware capture, MCCS parsing of six realistic strings plus junk input, value mapping at three ranges, the command queue (200 requests collapse to at most 5 writes, minimum gap, retry, timeout of a hung transport, capabilities across fragments), sync, presets, schedules including both daylight saving transitions, solar accuracy, display pairing, the display center with fake systems, the socket protocol (mode 0600, versions, error codes), the self-test, and the MCP server.

Website: 16 pages generated, `check-site.py` reports no broken links, no images without alt text, no external requests, every page under 200 KB (total site 132 KB), and no copied competitor wording. Checked at 375 px: no horizontal scroll.

## Efficiency numbers (release build, this Mac)

| Measure | Result | Target | Verdict |
|---|---|---|---|
| Idle CPU, window closed | 0.0% over 10 samples of 3 s each | under 0.1% | Met |
| Memory footprint (`top` MEM) | 24 MB | under 40 MB | Met (footprint, not resident size) |
| Resident size (`ps` RSS) | 86 MB | under 40 MB | **Not met** by this reading. Most of it is shared SwiftUI and AppKit framework pages. |
| Launch to first CLI answer | 1.02 s | under 1 s | Narrowly missed. Measured in `--demo` mode, not with live displays. |
| CLI `version` round trip | median 5 ms | under 50 ms | Met |
| DDC writes for a slider drag | at most 5 for 201 requests (unit test) | at most drag time over gap, plus one | Met |
| DDC read round trip on the real monitor | about 105 ms median | n/a | Reported |
| Idle wake-ups per second | not measured | zero | Not measured (needs `powermetrics`). The design has no timers or polling when idle. |

## Manual checks still needed

See `docs/verification.md`. Not done: recording and using custom shortcuts, schedules firing on wake, lock, plug-in and monitor connect, hotplug, URL scheme through `open`, clicking the real menu bar item, input switching and power off on a real monitor, volume on a monitor with speakers, a dock or KVM, an Intel Mac, a second identical monitor.

## Known issues and limits

- With only the Command Line Tools, the macOS 27 SDK lacks the SwiftUI macro plugin, so `@State` does not compile. `Package.swift` is not enough: plain `swift build` fails. The scripts retry with older SDKs, which works. With Xcode installed this should not occur.
- `swift test` and `swift build` must not be mixed with `--build-tests` runs in the same `.build` folder, or the testing macro plugin goes missing. `swift package clean` fixes it. `Scripts/check.sh` runs `swift test` only.
- Ad-hoc signing changes the code identity every build, which resets the Accessibility grant. `Scripts/make-dev-cert.sh` creates a local certificate, and `build-app.sh` uses it automatically, so the grant survives rebuilds.
- On macOS 27 the Accessibility list is called **Device Control and Data Access**. A grant made against an earlier build can leave a stale system-wide record that blocks the new one. `sudo tccutil reset Accessibility app.displaycontrol.DisplayControl` clears it. Then reopen the app, allow its own prompt, and toggle the switch off and on once.
- `displaycontrol keys` shows whether the key listener is enabled, trusted and running.
- `check.sh` prints several failed SDK attempts before it succeeds. Harmless but noisy.
- The site and app link to placeholder addresses (`displaycontrol.example`, `github.com/OWNER/DisplayControl`). Set `SITE_URL` and `REPO_URL` when building the site, and edit `Links` in `MenuView.swift`.
- No right-click menu on the status item and no Escape-to-close, because `MenuBarExtra` does not expose them. The same actions are in the popover footer.
- The read-back check marks a display as unreliable on the first disagreement and never clears it until relaunch.
- Display settings are keyed by vendor, product and serial. Two identical monitors with no serial number share a key and are told apart only by display ID, which can change.
- Writing to `/usr/local/bin` can need administrator rights, so the Install button falls back to a copy-and-paste command.
- The Homebrew cask is a draft with placeholders.

## Private APIs used

Every symbol is loaded with `dlsym` at runtime. A missing symbol disables only the feature that needs it.

| API | Used for | If missing |
|---|---|---|
| `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C` | DDC on Apple Silicon | DDC unavailable, falls back to software dimming |
| `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness`, `DisplayServicesCanChangeBrightness` | Built-in and Apple display brightness | Falls back to software dimming |
| IORegistry: `DCPAVServiceProxy` `Location`, `DisplayAttributes.ProductAttributes` | Pairing a monitor with its DDC service | No pairing, software dimming |

Public APIs of note: `CGSetDisplayTransferByFormula`, `CGDisplayRestoreColorSyncSettings`, `CGEvent.tapCreate`, Carbon `RegisterEventHotKey`, `SMAppService`, `CLLocationManager`, `IOPSNotificationCreateRunLoopSource`.

## Legal and attribution

Original code and copy. DisplayBuddy's application binary was never downloaded or inspected, and none of its text, images or branding was used. The website's banned-phrase check includes its name and its press and review claims. MIT licence, copyright Muhammad Abdullah, 2026. No AI attribution in any file.

## Not committed

Nothing was committed. This folder sits inside a larger repository that has an unrelated modified file (`learnings/INDEX.md`), and the chosen branch was the current one. Stage only paths under `projects/DisplayManager/` when committing.


## Requested but not built (reasons)

| Item | Why not |
|---|---|
| Siri, Spotlight, Shortcuts actions, desktop widgets, Control Center controls | Need Xcode's App Intents and WidgetKit tooling. This Mac has only the Command Line Tools. |
| Samsung Tizen and LG webOS Wi-Fi control | No such monitor to test against. Untested network protocol code would be guesswork. |
| Windows version, DDC on Intel Macs | Need other hardware. |
| Brightness past the panel maximum on MacBook Pro and Studio Display XDR | Works by overdriving the panel with HDR content. Not attempted: no way to measure it here, and a mistake can run the panel hot. |
| macOS Display Presets and Reference Modes | Private CoreDisplay interface that is not present on this macOS (the library did not load). |
| Languages | English only. Needs a bundled resources setup and real translations. |
| Built-in update check, compatibility checker fed by user data | Both need the app to use the network, which it deliberately never does. |
| Notarization, SetApp, licenses, volume deals for business | Need a Developer ID and accounts. The project is free and open source. |
