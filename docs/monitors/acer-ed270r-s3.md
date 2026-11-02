# Acer ED270R S3: what its DDC/CI interface exposes

Measured on 2026-11-02 with DisplayControl on an Apple Silicon MacBook over HDMI. DDC/CI version 2.2. Controller type reported: 9. Firmware level: 1. Everything below was read from the monitor, and every write was read back and restored.

## Controls that answer (55 of 256 codes)

| Code | Control | Value / max | Writable | Notes |
|---|---|---|---|---|
| 10 | Brightness | 100 / 100 | Yes | Already at the backlight maximum. |
| 12 | Contrast | 50 / 100 | **Only outside picture mode 0** | Writes are silently ignored in mode 0. |
| 14 | Color preset | 5 / 11 | Yes | Advertised values: 5 (6500 K), 6 (7500 K), 8 (9300 K), 11 (user). |
| 16, 18, 1A | RGB gain | 50 / 47 / 42, max 100 | Yes | Editing gains makes the monitor switch itself to preset 11. |
| 6C, 6E, 70 | RGB black level | 50 each, max 100 | Yes | Same preset switch. Raises shadows. |
| 59 to 5E | Six-axis saturation | 50 each | Yes | |
| 9B to A0 | Six-axis hue | 50 each | Yes | |
| 60 | Input source | 17 (HDMI 1) | Yes | Advertised 15 (DP), 17 (HDMI 1), 18 (HDMI 2). |
| D6 | Power mode | 1 | Yes | 1 on, 2 standby, 4 suspend, 5 off. |
| CC | OSD language | 2 | Yes | |
| E2 | Picture mode (manufacturer) | 0 / 18 | Yes | See below. Advertised 0 to 7 and 16 to 18. Mode 4 is refused and falls back to 0. |
| 72 | Gamma | 120 / 160 | **Not advertised** | Readable only. 120 is gamma 2.2 in the usual encoding. |
| 87 | Sharpness | 4 / 4 | not tested | |
| 0B, 0C | Color temperature increment / request | 100, 35 | not tested | |
| E3 | Manufacturer | 452 / 4095 | not tested | Looks like a measured value, possibly a sensor or counter. |
| E4, E5, E6 | Manufacturer | 1/3, 6/10, 1 | not tested | Possibly response time, overdrive or adaptive sync. Left alone. |
| E0, E1, E7, E8, E9, EA | Manufacturer | 255 | not tested | 255 usually means write-only or unavailable. Left alone. |
| AC, AE, B2, B6, C6, C8, C9, CA, DF | Timing and identity | various | No | Read-only information. |
| **04, 05, 06, 08** | **Restore factory defaults** | 0 / 1 | **Never write** | DisplayControl refuses controls the monitor does not advertise, but do not send these by hand either. |

## Picture mode (E2) behavior

| Mode | Brightness it applied | Contrast writable |
|---|---|---|
| 0 (your original) | 100 | **No** |
| 1 | 80 | Yes |
| 2 | 44 | Yes |
| 3 | 97 | Yes |
| 4 | refused, stays 0 | n/a |
| 5 | 50 | Yes |
| 6 | 60 | Yes |
| 7 | 25 | Yes |

Switching mode changes the brightness to a stored value for that mode, and the brightness setting is shared afterwards. The mode names are not reported over DDC. Mode 2 and 7 are the darkest, so they are probably the eco or low-blue-light modes. Modes 16 to 18 were not tried because they may switch HDR or other video modes.

## Why you can't get 200 percent

- Brightness reports 100 of 100, so the backlight is already at its maximum. No setting multiplies the panel's peak luminance.
- Contrast is the one control that can raise the white level, and it is locked in mode 0.
- RGB gains sit at about 50 of 100. If the firmware scales them linearly, doubling them could raise peak white a lot, but I cannot measure luminance from here, and it may clip highlights instead.
- Black level and gamma lift shadows and midtones, so the picture looks brighter without raising the peak.
- A software gamma lift (what DisplayControl uses for dimming) can also brighten midtones, with a loss of contrast.

## Quirks worth knowing

- Writing gains or black levels flips the color preset from 5 to 11 (user) on its own. Setting it back to 5 restores the preset gains (50/47/42).
- Reading is safe at any time. About 100 ms per read.
- Contrast and gamma can be locked or hidden by the current mode, so a failed write is not an error in DisplayControl.

## Reproduce

```sh
displaycontrol caps ED270R          # what the monitor advertises
displaycontrol vcp ED270R 12        # read one control (hex)
displaycontrol vcp-set ED270R 12 80 # write one advertised control and read it back
```

## Boost (what DisplayControl does with this)

`displaycontrol set ED270R --boost 150` scales the three gains together by 1.5 (50/47/42 becomes 75/71/63), which keeps the white balance. The first time, it remembers your original gains and color preset. `--boost 100` writes the gains back and the original preset last, because editing gains makes the monitor switch itself to preset 11. The limit is 200 percent here, set by the red gain reaching its maximum of 100.

The same slider is in the menu bar window, under the expanded display card, as "Extra brightness".
