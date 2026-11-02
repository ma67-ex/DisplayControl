# Verifying DisplayControl on your hardware

Unit tests use a simulated monitor, so they cannot prove that a real monitor behaves. Run this once per monitor.

1. **Probe.** With the app closed or open, run `displaycontrol probe`. You should see your monitor listed, an `External candidates` count of at least 1, a `paired` line, a raw reply that starts with `6E 88 02 00`, and `DDC WORKS`.
2. **Self-test.** `displaycontrol selftest "Your monitor"`. Every line should say PASS. It changes values by three points and restores them. A contrast or volume FAIL usually means the monitor locks that control in its current picture mode.
3. **Brightness.** Move the slider in the menu bar window. The backlight changes and the monitor's own on-screen menu agrees.
4. **Volume, contrast, input.** Each works, or is correctly absent from the card.
5. **Sync.** Turn sync on with a second display. Moving the host moves the follower. Set an offset and check it.
6. **Preset round trip.** Save a preset, change things, apply the preset. Include an input switch if you have two sources.
7. **Schedules.** Create a schedule for one minute ahead and see it fire. Put the Mac to sleep across a schedule and check the catch-up on wake. Create a "monitor connects" schedule, unplug and replug.
8. **Keys.** Turn on the keys, grant Accessibility, put the pointer on the monitor and press brightness up and down. Then put it on the laptop screen: macOS must handle the keys.
9. **Hotplug.** Unplug and replug the monitor. Settings return and nothing crashes.
10. **Quit while dimmed.** Set the monitor to Software mode at 50 percent, then quit the app from its window. The screen returns to normal. If it ever does not, `displaycontrol reset-gamma` fixes it.

Please share `displaycontrol probe` output for any monitor that does not work.
