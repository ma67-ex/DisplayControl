<div align="center">

<img src="docs/images/logo.png" width="110" alt="DisplayControl logo">

# DisplayControl

**Change your monitor's brightness and volume from your Mac. No buttons, no menus.**

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-1f2937?style=flat-square&logo=apple&logoColor=white)
![Free](https://img.shields.io/badge/price-free-34d399?style=flat-square)
![Works offline](https://img.shields.io/badge/works-offline-0ea5e9?style=flat-square)
![MIT](https://img.shields.io/badge/license-MIT-6366f1?style=flat-square)

<img src="docs/images/hero.png" width="780" alt="DisplayControl in dark and light mode">

</div>

## What it does

Your Mac can change its own screen brightness, but not your monitor's. DisplayControl adds that, in your menu bar.

- **Brightness, contrast and volume** for each screen, with simple sliders.
- **Use your keyboard keys** to change the screen your mouse is on.
- **Match your screens** so they all move together.
- **Save setups** like "Work" or "Movie" and switch with one click.
- **Dim at night on its own.** Pick a time, or sunrise and sunset.
- **Light and dark look.** The sliders glow brighter as you turn the brightness up.
- **Free and private.** No account. It never connects to the internet.

## Install (3 minutes)

1. Press **⌘ Space**, type **Terminal**, press **Return**.
2. Paste this line and press **Return**:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/ma67-ex/DisplayControl/main/install.sh | bash
   ```

3. Wait until it says **All done**.

If a window from Apple asks to install developer tools, click **Install**, then paste the line again.

**Prefer clicking?** Press the green **Code** button, choose **Download ZIP**, open the folder, then right-click **Install DisplayControl** and choose **Open**.

## Use it

1. Click the small **display icon** at the top right of your screen.
2. Drag a slider. Your monitor changes.
3. Want the keyboard keys to work? Click the **gear**, open **Keyboard**, and turn it on.

<div align="center">
<img src="docs/images/glow.png" width="300" alt="Sliders that glow brighter as brightness goes up">
&nbsp;&nbsp;
<img src="docs/images/settings.png" width="460" alt="Settings window">
</div>

## Privacy

Everything stays on your Mac. To check for yourself, run `./Scripts/check-offline.sh`.

## For developers

Terminal commands, a link scheme and an AI helper are built in. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Free to use and change under the [MIT License](LICENSE). If it helps you, give it a ⭐.
