# DisplayControl

A free, open source macOS menu bar app, command line tool and MCP server that controls external monitors: real hardware brightness, contrast, volume, input source, power and rotation over DDC/CI, with software dimming as a fallback, plus sync, presets, schedules, keyboard control and automation.

It is an original implementation. It shares a feature set with other monitor utilities but no code, text or assets.

- No network access, no analytics, no account.
- macOS 13 or later. Hardware (DDC) control of third-party monitors needs an Apple Silicon Mac. Intel Macs get Apple-display control and software dimming.
- MIT licensed.

## Build

You need the Swift toolchain (the Command Line Tools are enough).

```sh
./Packaging/build-app.sh      # builds dist/DisplayControl.app and dist/DisplayControl.zip
./Scripts/check.sh            # builds, runs all tests, builds and checks the website
open dist/DisplayControl.app
```

With only the Command Line Tools installed, the newest macOS SDK may be missing the SwiftUI macro plugin (`@State` fails to compile). Both scripts then fall back to an older SDK from `/Library/Developer/CommandLineTools/SDKs`. Plain `swift build` or `swift test` can fail for that reason, so use the scripts, or pass `--sdk` yourself.

`DisplayControlApp --demo` runs the app against simulated displays, so you can try the interface and the command line without hardware.

## Layout

```
Sources/DisplayControlCore   library: DDC protocol, backends, display center, sync, presets,
                             schedules, input, IPC, MCP. No UI.
Sources/DisplayControlApp    SwiftUI menu bar app
Sources/displaycontrol       command line client (also `mcp` and `probe`)
Tests/                       swift-testing suites (simulated monitor, fake display system)
Packaging/                   Info.plist, build-app.sh, completions, Homebrew cask draft
Scripts/                     check.sh, build-site.py, check-site.py
site/                        generated static website (edit Scripts/build-site.py, not the HTML)
docs/                        verification.md
DisplayControl-BUILD-SPEC.md the original build specification (with the hardware-verified checksum correction)
```

## How it works

- `DDCDevice` is one actor per display. It rate limits commands (50 ms minimum gap, growing after errors), coalesces a burst of writes to the same control into the latest value, always sends the final value, and abandons a hung I2C call after a timeout.
- `DDCBackend` reads the monitor's capability string, scales percentages to the monitor's own range and reads values back after a write to detect monitors that ignore them.
- On Apple Silicon the transport is the private `IOAVService` API, loaded with `dlsym`. Paired with displays by vendor, product and serial from the IORegistry (`AVServicePairing`, tested against fixtures).
- `SoftwareBackend` dims with gamma tables and restores them on every exit path. `AppleBackend` uses the private DisplayServices framework, also loaded at runtime.
- `DisplayCenter` owns all displays and is the only thing the UI, CLI, schedules and keyboard talk to.
- The CLI talks to the running app over a Unix socket (mode 0600) using newline-delimited JSON.

## Private APIs used

Every one is loaded with `dlsym` at runtime, and the app degrades if it is missing.

| API | Used for | If missing |
|---|---|---|
| `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C` | DDC on Apple Silicon | DDC unavailable, software dimming |
| `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness`, `DisplayServicesCanChangeBrightness` | Built-in and Apple displays | Software dimming |
| IORegistry keys `DisplayAttributes.ProductAttributes`, `DCPAVServiceProxy.Location` | Pairing monitors with DDC services | Software dimming |

## Known limits

- Siri, Spotlight and Shortcuts actions (App Intents) need a full Xcode build and are not included. Use the URL scheme or the command line.
- Samsung and LG Wi-Fi control, HDR toggles and extra-bright modes are not implemented.
- The macOS 27 SDK in the Command Line Tools lacks the SwiftUI macro plugin; see Build.
- Ad-hoc signing changes the code identity on every build, which resets the Accessibility grant for the keyboard keys.

## License

MIT. See `LICENSE`.
