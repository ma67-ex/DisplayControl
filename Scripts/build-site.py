#!/usr/bin/env python3
"""Generates the static DisplayControl website into ./site (HTML, sitemap, robots, 404).

Usage: SITE_URL=https://example.org python3 Scripts/build-site.py

Every claim on these pages describes this repository's code. If a feature is partial it says so.
"""
import os, html, datetime, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
SITE_URL = os.environ.get("SITE_URL", "https://displaycontrol.example").rstrip("/")
REPO_URL = os.environ.get("REPO_URL", "https://github.com/ma67-ex/DisplayControl").rstrip("/")
TODAY = datetime.date.today().isoformat()

LOGO_OLD = ('<svg viewBox="0 0 32 32" role="img" aria-label="DisplayControl logo"><rect width="32" height="32" rx="8" fill="#e8590c"/>'
        '<circle cx="21" cy="12" r="5" fill="#fff"/><rect x="6" y="21" width="20" height="3.2" rx="1.6" fill="#fff" opacity=".55"/>'
        '<rect x="6" y="21" width="12" height="3.2" rx="1.6" fill="#fff"/></svg>')

LOGO = '<img src="%sassets/logo.png" width="30" height="30" alt="DisplayControl logo">'
NAV = [("features.html", "Features"), ("docs/index.html", "Docs"), ("faq.html", "FAQ"),
       ("compatibility.html", "Compatibility"), ("download.html", "Download")]

DOCS = [("getting-started", "Getting started"), ("keyboard", "Keyboard"), ("sync", "Sync"), ("presets", "Presets"),
        ("schedules", "Schedules"), ("automation-cli", "Automation and CLI"), ("troubleshooting", "Troubleshooting")]

pages = []   # (path, title, description)


def rel(path, depth):
    return ("../" * depth) + path


def layout(path, title, desc, body, depth=0, current=None, sidebar=False, jsonld=""):
    cur = ' aria-current="page"'
    nav = "".join('<a href="%s"%s>%s</a>' % (rel(h, depth), cur if current == h else "", html.escape(t)) for h, t in NAV)
    canonical = f"{SITE_URL}/{path}"
    pages.append((path, title, desc))
    side = ""
    if sidebar:
        items = "".join('<a href="%s"%s>%s</a>' % (rel("docs/" + s + ".html", depth), cur if current == "docs/" + s + ".html" else "", t) for s, t in DOCS)
        side = f'<aside class="side" aria-label="Documentation"><a href="{rel("docs/index.html", depth)}">All docs</a>{items}</aside>'
        main = f'<div class="docs">{side}<main id="main" class="prose">{body}</main></div>'
    else:
        main = f'<main id="main">{body}</main>'
    doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
<link rel="canonical" href="{canonical}">
<meta property="og:type" content="website">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(desc)}">
<meta property="og:url" content="{canonical}">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="{html.escape(title)}">
<meta name="twitter:description" content="{html.escape(desc)}">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="{rel('assets/logo.png', depth)}" type="image/png">
<link rel="stylesheet" href="{rel('assets/style.css', depth)}">
{jsonld}
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site"><div class="wrap">
<a class="brand" href="{rel('index.html', depth)}">{LOGO % ('../' * depth)}<span>DisplayControl</span></a>
<nav class="main" aria-label="Main">{nav}</nav>
</div></header>
<div class="wrap">{main}</div>
<footer class="site"><div class="wrap">
<div class="cols">
<span>DisplayControl is free and open source (<a href="{rel('license.html', depth)}">MIT License</a>).</span>
<a href="{rel('privacy.html', depth)}">Privacy</a>
<a href="{REPO_URL}">Source code</a>
<a href="{rel('docs/troubleshooting.html', depth)}">Troubleshooting</a>
</div>
<p>It does not connect to the internet. Not affiliated with any monitor maker or any other display utility.</p>
</div></footer>
</body>
</html>
"""
    out = SITE / path
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(doc, encoding="utf-8")


def faq_block(items):
    return "".join(f"<details><summary>{html.escape(q)}</summary><p>{a}</p></details>" for q, a in items)


# ---------------------------------------------------------------- home

MOCK = """
<div class="mock" role="img" aria-label="Illustration of the DisplayControl menu bar window with two displays and three presets">
  <div class="top"><span>DisplayControl</span><span style="color:var(--ink-2)">Sync on</span></div>
  <div class="card"><div class="name"><span>Built-in display</span><span class="pill">Apple</span></div>
    <div class="row"><span>Brightness</span><div class="track"><i style="width:56%"></i><b style="left:56%"></b></div><span>56</span></div></div>
  <div class="card"><div class="name"><span>External monitor</span><span class="pill">DDC</span></div>
    <div class="row"><span>Brightness</span><div class="track"><i style="width:72%"></i><b style="left:72%"></b></div><span>72</span></div>
    <div class="row"><span>Contrast</span><div class="track"><i style="width:50%"></i><b style="left:50%"></b></div><span>50</span></div>
    <div class="row"><span>Volume</span><div class="track"><i style="width:30%"></i><b style="left:30%"></b></div><span>30</span></div></div>
  <div class="chips"><span class="chip">Work</span><span class="chip">Evening</span><span class="chip">Movie</span></div>
</div>"""

home_body = f"""
<section class="hero">
  <div>
    <h1>Your Mac's brightness keys, for every monitor.</h1>
    <p class="lede">DisplayControl talks to external monitors the same way their own buttons do. Change real brightness, contrast, volume and input from the menu bar, the keyboard, a script or an AI assistant.</p>
    <div class="btns">
      <a class="btn primary" href="download.html">Download for Mac</a>
      <a class="btn" href="docs/getting-started.html">Read the docs</a>
    </div>
    <p class="note">Free, open source, no account, no network access. Needs macOS 13 or later. Hardware control over DDC needs an Apple Silicon Mac; see <a href="compatibility.html">compatibility</a>.</p>
  </div>
  {MOCK}
</section>

<section>
  <h2>The problem it fixes</h2>
  <div class="grid">
    <div class="tile"><h3>Buttons you cannot reach</h3><p>Monitor menus live behind the bezel, one tiny button at a time. Changing brightness at night should not need a manual.</p></div>
    <div class="tile"><h3>Screens that do not match</h3><p>Your laptop panel and your monitor are rarely the same brightness. You end up matching them by eye, again and again.</p></div>
    <div class="tile"><h3>Settings that reset</h3><p>Some monitors forget their settings when they reconnect. A schedule can put them back the moment they appear.</p></div>
  </div>
</section>

<section class="alt">
  <h2>How it works</h2>
  <ol class="steps">
    <li><strong>Detects each display.</strong> It reads the monitor's own capability list over DDC/CI, the standard that monitor buttons use, and shows only the controls the monitor really has.</li>
    <li><strong>Falls back when it must.</strong> If a monitor does not answer, DisplayControl can dim it with software gamma instead, and tells you which mode each display is in.</li>
    <li><strong>Checks its own work.</strong> After a change it reads the value back. If the monitor ignores a setting, you see a hint instead of a silent failure.</li>
  </ol>
</section>

<section>
  <h2>What you get</h2>
  <div class="grid">
    <div class="tile"><h3>Real hardware control</h3><p>Brightness, contrast, volume, mute, input source, power and rotation, where the monitor supports them.</p></div>
    <div class="tile"><h3>Sync</h3><p>Move one slider and the other displays follow, with an offset so a bright laptop and a dim monitor can still match.</p></div>
    <div class="tile"><h3>Presets</h3><p>Save a whole desk setup, including inputs, resolution and arrangement, and apply it in one click.</p></div>
    <div class="tile"><h3>Schedules</h3><p>Run a preset at a time, at sunrise or sunset, on wake, on unlock, when you plug in, or when a monitor connects.</p></div>
    <div class="tile"><h3>Keyboard</h3><p>Use the brightness and volume keys on the display under your pointer, or record your own shortcuts.</p></div>
    <div class="tile"><h3>Scriptable</h3><p>A command line tool, a <code>displaycontrol://</code> URL scheme and an MCP server for AI assistants.</p></div>
  </div>
  <p style="margin-top:20px"><a href="features.html">See every feature</a></p>
</section>

<section class="alt">
  <h2>Light on your Mac</h2>
  <p>Event driven, with no polling. On the test Mac it sat at 0.0% CPU with the window closed, with a 24 MB memory footprint. It has no network code, no analytics and no account. <a href="privacy.html">Read the privacy page</a>.</p>
</section>
"""

jsonld = f"""<script type="application/ld+json">{{"@context":"https://schema.org","@type":"SoftwareApplication","name":"DisplayControl","operatingSystem":"macOS 13 or later","applicationCategory":"UtilitiesApplication","offers":{{"@type":"Offer","price":"0","priceCurrency":"USD"}},"license":"https://opensource.org/licenses/MIT"}}</script>"""
layout("index.html", "DisplayControl: brightness keys for every monitor on your Mac",
       "Free, open source menu bar app to control external monitor brightness, contrast, volume and input from your Mac. No account, no network access.",
       home_body, 0, None, jsonld=jsonld)

# ---------------------------------------------------------------- features

feat = """
<div class="prose" style="max-width:none">
<h1>Features</h1>
<p class="lede">Each item below exists in the code today. Where something is partial, it says so.</p>

<h2>Controls</h2>
<table><tr><th>Control</th><th>How</th><th>Notes</th></tr>
<tr><td>Brightness, contrast, volume</td><td>DDC/CI, 0 to 100</td><td>Only the controls the monitor reports are shown. Values scale to the monitor's own range (100, 255 and so on).</td></tr>
<tr><td>Mute</td><td>DDC/CI</td><td>If the monitor supports it.</td></tr>
<tr><td>Input source</td><td>DDC/CI</td><td>DisplayPort, HDMI and USB-C names, or a raw code.</td></tr>
<tr><td>Power</td><td>DDC/CI</td><td>Some monitors cannot be woken over DDC once off. Turning off needs a confirmation in the AI interface.</td></tr>
<tr><td>Rotation</td><td>DDC/CI orientation code</td><td>Hidden when the monitor does not report it.</td></tr>
<tr><td>Resolution and refresh rate</td><td>macOS display modes</td><td>Includes HiDPI modes.</td></tr>
<tr><td>Built-in and Apple displays</td><td>macOS DisplayServices</td><td>Brightness. Loaded at runtime, so the app still works if macOS changes it.</td></tr>
<tr><td>Software dimming</td><td>Gamma tables</td><td>For monitors that refuse DDC, and for virtual displays. Never goes fully black, and is restored on every exit path.</td></tr></table>

<h2>System switches and color</h2>
<ul>
<li><strong>Dark Mode, Night Shift (with its warmth) and True Tone</strong> from three tiles in the window, from the command line (<code>displaycontrol extra darkmode on</code>) and inside presets. True Tone shows only on Macs that have it. These use private macOS interfaces loaded at run time, so a future macOS may change them.</li>
<li><strong>HDR switch</strong> for displays that offer one. It is hidden when macOS reports no support, and it has not been tested on an HDR monitor.</li>
<li><strong>Color profile picker</strong> per display (sRGB, Display P3, your calibrated profiles), with a reset to the display's own profile. Also available in presets and as <code>displaycontrol profile</code>.</li></ul>

<h2>Comfort and safety</h2>
<ul>
<li><strong>Fade presets.</strong> A preset can ease brightness, contrast and volume over a few seconds instead of jumping. It always ends on the exact preset values. <code>displaycontrol preset activate Evening --fade 5</code>.</li>
<li><strong>Brightness limits.</strong> Set a lowest and highest brightness per display, so a key or slider can never black a screen out.</li>
<li><strong>On-screen bar.</strong> A small bar with the glow shows the new value on the display you changed, when you use the keys. Optional.</li>
<li><strong>Brightness beside the icon.</strong> Optional number in the menu bar.</li>
<li><strong>Reset everything.</strong> One button, one command (<code>displaycontrol panic</code>) and an optional shortcut that clear software dimming, extra brightness and a switched color profile.</li></ul>

<h2>Several displays</h2>
<p><strong>Sync</strong> makes one display the host and the rest follow, for brightness, contrast and volume. Each follower has an offset: "when the host is at 100 percent, this display is at 70". Followers only change for controls they support.</p>
<p><strong>Presets</strong> store exactly what you tick: brightness, contrast, volume, mute, input, power, rotation, resolution, position and sync. They apply in a fixed order so values land on an awake display on the right input. A display that is not connected is skipped, not treated as an error.</p>
<p><strong>Schedules</strong> connect triggers to presets. See the <a href="docs/schedules.html">schedules guide</a> for the full list.</p>

<h2>Keyboard</h2>
<p>Optional brightness and volume keys for external displays (needs Accessibility permission), plus custom shortcuts for brightness, contrast, volume, mute, cycling inputs, toggling sync and applying presets.</p>

<h2>Automation</h2>
<ul>
<li><strong>Command line:</strong> <code>displaycontrol status</code>, <code>set</code>, <code>get</code>, <code>preset</code>, <code>schedule</code>, <code>sync</code>, <code>selftest</code>, <code>probe</code>. JSON when piped.</li>
<li><strong>URL scheme:</strong> <code>displaycontrol://preset/Evening</code> works from Terminal, scripts and any app that opens URLs.</li>
<li><strong>MCP server:</strong> <code>displaycontrol mcp</code> lets an AI assistant list and change displays and apply presets.</li>
<li><strong>Not implemented:</strong> native Siri, Spotlight and Shortcuts actions. They would need a full Xcode build. Until then, use the URL scheme or the command line from a Shortcuts "Run Shell Script" action.</li></ul>

<h2>Look and feel</h2>
<ul>
<li><strong>Light, Night or match the system.</strong> One button in the menu bar window cycles through them; the choice is also in Settings, General.</li>
<li><strong>A brightness glow.</strong> The brightness slider and the display icon glow in proportion to the level: brighter and wider as you raise it, dimmer as you lower it, and nearly white when boosted. Reduce Motion turns the flare off.</li></ul>

<h2>Built to be trusted</h2>
<ul>
<li>Reads values back after a write and warns when a monitor ignores them.</li>
<li>Per-display command queue: a slider drag becomes a few writes, always ending on the final value, spaced to protect monitors.</li>
<li><code>selftest</code> checks a monitor end to end and puts every value back.</li>
<li>No network access, no analytics, no account. Open source under the MIT License.</li></ul>

<h2>Not included</h2>
<ul><li>Samsung and LG smart monitor control over Wi-Fi.</li>
<li>Siri, Spotlight, Shortcuts actions, widgets and Control Center controls (they need an Xcode build).</li>
<li>Other languages: the app is English only.</li>
<li>macOS \"Display Presets\" and Reference Modes.</li>
<li>Brightness beyond the panel maximum on MacBook Pro and Studio Display XDR screens. (Extra brightness through the color gains works on monitors that have them.)</li>
<li>DDC on Intel Macs. They get Apple-display control and software dimming.</li>
<li>Windows.</li></ul>
</div>
"""
layout("features.html", "Features | DisplayControl", "Everything DisplayControl can do today, and what it does not do yet.", feat, 0, "features.html")

# ---------------------------------------------------------------- download

dl = f"""
<div class="prose" style="max-width:none">
<h1>Download</h1>
<p class="lede">DisplayControl is free. Build it yourself, or download a release from the project page.</p>
<div class="btns"><a class="btn primary" href="{REPO_URL}/releases">Releases on GitHub</a><a class="btn" href="{REPO_URL}">Source code</a></div>
<p class="note">Each release lists a SHA-256 checksum. Compare it with <code>shasum -a 256 DisplayControl.zip</code> before opening the app.</p>

<h2>Install</h2>
<ol class="steps">
<li>Unzip <code>DisplayControl.zip</code> and drag <strong>DisplayControl</strong> to your Applications folder.</li>
<li>Open it. Builds that are not notarized by Apple show a warning the first time: right-click the app, choose <strong>Open</strong>, then confirm.</li>
<li>Look for the display icon in the menu bar. There is no Dock icon.</li>
<li>Optional: in Settings, turn on the keyboard keys and install the <code>displaycontrol</code> command.</li></ol>

<h2>Build from source</h2>
<pre><code>git clone {REPO_URL}.git
cd DisplayControl
./Packaging/build-app.sh
open dist/DisplayControl.app</code></pre>
<p>Needs the Swift toolchain (Command Line Tools are enough). The script tries the newest macOS SDK first and falls back to older ones if the SwiftUI macro plugin is missing.</p>

<h2>Requirements</h2>
<ul><li>macOS 13 or later.</li><li>Apple Silicon for hardware (DDC) control of third-party monitors. Intel Macs can use Apple-display control and software dimming.</li></ul>

<div class="callout warn"><strong>After rebuilding the app yourself:</strong> macOS ties the Accessibility permission to the app's code signature, and ad-hoc signing changes it on every build. If the keyboard keys stop working, remove DisplayControl from the Accessibility list and add it again.</div>
</div>
"""
layout("download.html", "Download | DisplayControl", "Download DisplayControl for macOS or build it from source.", dl, 0, "download.html")

# ---------------------------------------------------------------- compatibility

comp = """
<div class="prose" style="max-width:none">
<h1>Compatibility</h1>
<p class="lede">Whether DDC works depends on the Mac, the cable, anything between them and how well the monitor implements the standard. This page lists only what has actually been tested.</p>

<h2>Tested combinations</h2>
<table><tr><th>Monitor</th><th>Mac and connection</th><th>Brightness</th><th>Contrast</th><th>Volume</th><th>Input</th><th>Reported by</th></tr>
<tr><td>Acer ED270R S3</td><td>Apple Silicon MacBook, HDMI</td><td>Works</td><td>Reads, but writes did not change it in the monitor's active picture mode</td><td>Not offered by the monitor</td><td>Reads (HDMI 1)</td><td>The author, with <code>displaycontrol selftest</code></td></tr></table>
<p>That is one row. No success rate is claimed. If you test another monitor, please add it.</p>

<h2>Add your monitor</h2>
<ol class="steps">
<li>Open DisplayControl and run <code>displaycontrol probe</code> in Terminal.</li>
<li>Run <code>displaycontrol selftest "Your monitor name"</code>. It nudges brightness by three points and restores it.</li>
<li>Open an issue on the <a href="REPO">project page</a> with the monitor model, Mac model, cable or dock, and both outputs.</li></ol>

<h2>What usually goes wrong</h2>
<ul>
<li><strong>Picture modes.</strong> Game, Movie and similar presets can lock brightness or contrast. Switch the monitor to a Custom mode.</li>
<li><strong>DDC/CI turned off.</strong> Some monitors have a menu switch for it.</li>
<li><strong>Docks, hubs, KVMs and adapters.</strong> Cheap ones often block the signal.</li>
<li><strong>Some Apple Silicon ports.</strong> Others have reported DDC failing over HDMI on certain Macs. If that happens to you, try USB-C or DisplayPort. DisplayControl falls back to software dimming on its own.</li>
<li><strong>Intel Macs.</strong> Hardware DDC is not implemented for Intel. Software dimming and Apple displays work.</li></ul>
</div>
""".replace('href="REPO"', f'href="{REPO_URL}/issues"')
layout("compatibility.html", "Compatibility | DisplayControl", "Which monitors and connections have been tested with DisplayControl, and how to add yours.", comp, 0, "compatibility.html")

# ---------------------------------------------------------------- FAQ

faq_items = [
 ("Does DisplayControl change real brightness or just dim the picture?",
  "Both are available and it tells you which is in use. Over DDC it changes the monitor's real backlight. If a monitor does not answer, it uses software dimming, which darkens the picture but not the backlight. The badge on each display card shows the mode."),
 ("Is it really free?", "Yes. It is open source under the MIT License. There is no trial, no account and no licence key."),
 ("Does it connect to the internet?", "No. The app contains no networking code, no analytics and no crash reporting. The only things that touch the network are you, when you download a release or open a link."),
 ("Will it work with my monitor?", "Most monitors made in the last decade support DDC/CI, but support varies. Run <code>displaycontrol probe</code> to see what your Mac exposes, and <code>displaycontrol selftest</code> to test a monitor. The <a href=\"compatibility.html\">compatibility page</a> lists what has been tested."),
 ("It says the monitor is not confirming changes. What does that mean?", "After each change DisplayControl reads the value back. If the monitor reports something different, you get this hint. The usual causes are a locked picture mode (switch the monitor to Custom) or DDC/CI being turned off in the monitor's own menu."),
 ("Do docks, hubs and KVM switches work?", "Sometimes. Many pass DDC through, many cheap ones block it. Try the monitor connected directly to see whether the dock is the problem."),
 ("Does HDMI work on Apple Silicon?", "It worked in our test on one Apple Silicon MacBook. Others have reported DDC over HDMI failing on some Macs. If it fails for you, try USB-C or DisplayPort. The app falls back to software dimming automatically."),
 ("Does it work on Intel Macs?", "Partly. Built-in and Apple displays and software dimming work. DDC for third-party monitors is only implemented for Apple Silicon."),
 ("Which macOS versions does it need?", "macOS 13 or later."),
 ("Why does it want Accessibility permission?", "Only for the optional brightness and volume keys. macOS requires that permission to read those keys. Everything else works without it, and you can leave it off."),
 ("The keys stopped working after I rebuilt the app.", "macOS ties the permission to the app's code signature, and ad-hoc signing changes it on each build. Remove DisplayControl from System Settings, Privacy and Security, Accessibility, then add it again."),
 ("Do the keys still control my laptop screen?", "Yes. DisplayControl only takes the keys when the pointer is on an external display it can control. Otherwise macOS handles them as usual."),
 ("What happens to software dimming if the app crashes?", "macOS can leave the gamma table as it was. Relaunch the app, or run <code>displaycontrol reset-gamma</code>, or log out and in. On a normal quit, on SIGTERM and on SIGINT the app restores every display."),
 ("Can I control volume?", "If the monitor has speakers and reports the control. DisplayControl hides controls the monitor does not report instead of showing ones that do nothing."),
 ("Why does my monitor ignore the contrast slider?", "Many monitors lock contrast in some picture modes. The self-test reports it, and the card shows the hint."),
 ("Can I turn a monitor off and on?", "You can send the power command. Some monitors cannot be woken over DDC once off, so switching its input from the Mac or pressing its button may be needed."),
 ("How do schedules deal with sleep?", "If the Mac was asleep at a scheduled time, the most recent missed time-based schedule runs once on wake, but only if it was within the last two hours."),
 ("How are sunrise and sunset calculated?", "On your Mac with the standard NOAA equations, from latitude and longitude you type in or allow once. Nothing is looked up online."),
 ("A monitor resets when I reconnect it. Can I fix that?", "Make a preset and a schedule with the trigger <em>Monitor connects</em>. The preset is applied each time it appears."),
 ("Can I use it from Shortcuts, Siri or Spotlight?", "Not natively yet. Use the URL scheme (<code>open \"displaycontrol://preset/Evening\"</code>) or the command line from a Shortcuts \"Run Shell Script\" action. Native actions are not implemented."),
 ("Can an AI assistant control my monitors?", "Yes, through the MCP server: <code>displaycontrol mcp</code>. It can read and set displays and apply presets. Turning a display off needs an explicit confirmation."),
 ("Is there a Windows version?", "No."),
 ("What about Samsung and LG smart monitors?", "Not supported yet. Those use network protocols rather than DDC."),
 ("Where are my settings stored?", "In <code>~/Library/Application Support/DisplayControl/</code> as JSON files, written safely with a backup copy."),
 ("How do I uninstall it?", "Quit the app, delete it from Applications, and delete the folder above. If you installed the command, delete <code>/usr/local/bin/displaycontrol</code>."),
 ("How do I report a bug?", f"Open an issue on the <a href=\"{REPO_URL}/issues\">project page</a> and paste the output of <em>About, Copy diagnostics</em>."),
]
layout("faq.html", "FAQ | DisplayControl", "Answers about compatibility, permissions, privacy, schedules and troubleshooting for DisplayControl.",
       '<div class="prose" style="max-width:none"><h1>Questions</h1>' + faq_block(faq_items) + "</div>", 0, "faq.html")

# ---------------------------------------------------------------- privacy / license / 404

layout("privacy.html", "Privacy | DisplayControl", "DisplayControl does not connect to the internet and collects nothing.", """
<div class="prose" style="max-width:none"><h1>Privacy</h1>
<p>DisplayControl collects nothing.</p>
<ul>
<li><strong>No network access.</strong> The app has no networking code. The "Check for updates" button opens a web page in your browser; the app itself never makes the request.</li>
<li><strong>No analytics, no crash reporting, no accounts.</strong></li>
<li><strong>Stored on your Mac only:</strong> display settings, presets, schedules and preferences, as JSON in <code>~/Library/Application Support/DisplayControl/</code>.</li>
<li><strong>Location</strong> is optional, requested only when you choose it for sunrise and sunset schedules, used to compute those times on your Mac and saved there as two numbers. You can type coordinates instead.</li>
<li><strong>Accessibility</strong> is optional and used only to read the brightness and volume keys.</li>
<li><strong>Diagnostics</strong> stay on your Mac until you choose to copy them.</li></ul>
<p>This website uses no cookies, no analytics and no third-party scripts or fonts.</p></div>""", 0, None)

layout("license.html", "MIT License | DisplayControl", "DisplayControl is released under the MIT License.", """
<div class="prose" style="max-width:none"><h1>MIT License</h1>
<p>Copyright (c) 2026 Muhammad Abdullah</p>
<p>Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:</p>
<p>The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.</p>
<p>THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.</p></div>""", 0, None)

layout("404.html", "Page not found | DisplayControl", "That page does not exist.", """
<div class="prose" style="max-width:none"><h1>Page not found</h1><p>That page is not here. Try the <a href="index.html">home page</a>, the <a href="docs/index.html">docs</a> or the <a href="faq.html">FAQ</a>.</p></div>""", 0, None)
pages[:] = [p for p in pages if p[0] != "404.html"]      # keep the 404 out of the sitemap

# ---------------------------------------------------------------- docs

def doc(slug, title, desc, body):
    crumbs = f'<p class="crumbs"><a href="index.html">Docs</a> / {html.escape(title)}</p>'
    layout(f"docs/{slug}.html", f"{title} | DisplayControl docs", desc, crumbs + f"<h1>{html.escape(title)}</h1>" + body,
           1, f"docs/{slug}.html", sidebar=True)

doc("getting-started", "Getting started", "Install DisplayControl, find it in the menu bar and understand control modes.", """
<h2>Install</h2>
<p>Drag <strong>DisplayControl</strong> to Applications and open it. If macOS warns that the app is from an unidentified developer, right-click it, choose <strong>Open</strong> and confirm once. It has no Dock icon: look for the display symbol in the menu bar.</p>
<p>If you cannot see it, your menu bar may be full. Close a few menu bar items, or check your menu bar manager.</p>

<h2>First run</h2>
<p>A short welcome shows each display, the way DisplayControl chose to control it, and a <strong>Test</strong> button. A test changes brightness by a few points, reads it back and restores it.</p>

<h2>The window</h2>
<p>Click the menu bar icon. Each display has a card with brightness, contrast and volume sliders for the controls it really has. The chevron opens more: input, power, mute, rotation, resolution, control mode, the sync offset and a self-test.</p>

<h2>Control modes</h2>
<table><tr><th>Mode</th><th>What it does</th></tr>
<tr><td><strong>DDC</strong></td><td>Talks to the monitor over its cable using DDC/CI. Changes the real backlight and the other hardware controls.</td></tr>
<tr><td><strong>Apple</strong></td><td>Built-in screens and Apple displays, through macOS.</td></tr>
<tr><td><strong>Software</strong></td><td>Darkens the picture with gamma. Works on almost anything, including virtual and Sidecar displays, but is not real brightness.</td></tr></table>
<p>The default is automatic: DDC if the monitor answers, otherwise Apple, otherwise software. You can force a mode per display. A monitor that has just been plugged in is retried after 2, 4 and 8 seconds, because monitors often ignore DDC while the link comes up.</p>

<h2>Where things are saved</h2>
<p>Settings, presets and schedules are JSON files in <code>~/Library/Application Support/DisplayControl/</code>. A backup copy is kept, and a damaged file falls back to it.</p>
<p>Next: <a href="keyboard.html">keyboard</a>, <a href="sync.html">sync</a>, <a href="presets.html">presets</a>.</p>
""")

doc("keyboard", "Keyboard", "Use brightness and volume keys and custom shortcuts with external displays.", """
<h2>Brightness and volume keys</h2>
<p>Settings, Keyboard, then turn on the brightness and volume keys. macOS asks for Accessibility permission because that is the only way to read those keys.</p>
<ul><li>The keys control the display under the mouse pointer. A setting makes them control every display instead.</li>
<li>If the pointer is on the built-in screen, or on a display DisplayControl cannot control, macOS handles the key as usual.</li>
<li>Each press changes the value by the display's step size (1, 2, 5 or 10, in Settings, General).</li></ul>
<div class="callout warn">If you rebuild the app, macOS may forget the permission because the code signature changed. Remove DisplayControl from the Accessibility list and add it again.</div>

<h2>Custom shortcuts</h2>
<p>In Settings, Keyboard, click a row, then press the keys. A shortcut needs at least one modifier (<kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>⌘</kbd>) so it can never block normal typing. Escape cancels and Delete clears.</p>
<p>Available actions: brightness up and down, contrast up and down, volume up and down, mute, cycle input and toggle sync. Each preset also has its own shortcut in its editor. Custom shortcuts do not need Accessibility permission.</p>
""")

doc("sync", "Sync", "Make several displays follow one host with optional offsets.", """
<h2>How it works</h2>
<p>Turn sync on from the header of the window. The first external display becomes the <strong>host</strong> (or the built-in display if there is none). To use a different host, run <code>displaycontrol sync enable "Name"</code>, or press the toggle-sync shortcut while the pointer is on that display. Changes to the host's brightness, contrast or volume are copied to every <strong>follower</strong>.</p>
<ul><li>Sync follows only controls the follower supports. A built-in screen has no volume, so it ignores volume changes.</li>
<li>Sync goes one way, host to followers. Moving a follower on its own does not change the host.</li>
<li>Followers are updated at the same time, each through its own queue, so three displays take about as long as one.</li></ul>

<h2>Offsets</h2>
<p>100 percent on one display rarely looks like 100 percent on another. Open a follower's expanded card and set <em>When host is 100%</em>, for example 70. Other values scale in proportion: host 50 becomes follower 35.</p>

<h2>In presets</h2>
<p>A preset can include the sync state. When it turns sync on, that happens after the values are applied; when it turns sync off, before.</p>
""")

doc("presets", "Presets", "Save and restore a whole display setup in one click.", """
<h2>Creating a preset</h2>
<p>Set your displays up the way you like, open Settings, Presets, and choose <strong>Save current setup</strong>. Then <strong>Edit</strong> it and keep only what you want it to change. Nothing is included unless it is ticked.</p>
<table><tr><th>Can store</th><th>Notes</th></tr>
<tr><td>Brightness, contrast, volume, mute</td><td>Percentages.</td></tr>
<tr><td>Input source</td><td>Switch a monitor between computers.</td></tr>
<tr><td>Power, rotation</td><td>Where the monitor supports them.</td></tr>
<tr><td>Resolution and refresh rate</td><td>Through macOS display modes.</td></tr>
<tr><td>Position</td><td>The arrangement of displays.</td></tr>
<tr><td>Sync</td><td>On or off, and the host.</td></tr></table>

<h2>Applying</h2>
<p>Choose a preset in the window, press its shortcut, run it from a schedule or use the command line or URL scheme. Items apply in a fixed order: position, control mode, resolution, rotation, power, input, then mute, brightness, contrast and volume. A display that is not connected is skipped and reported, and the rest still applies.</p>
<p>A <strong>delay</strong> can wait a few seconds first, which helps monitors that need time to wake.</p>
<pre><code>displaycontrol preset activate "Evening" --delay 5
open "displaycontrol://preset/Evening"</code></pre>
""")

doc("schedules", "Schedules", "Run presets automatically by time, sun position or system events.", """
<h2>Triggers</h2>
<table><tr><th>Group</th><th>Triggers</th></tr>
<tr><td>Time</td><td>A time of day on chosen weekdays (none chosen means every day).</td></tr>
<tr><td>Sun</td><td>Sunrise or sunset, with an offset of up to four hours before or after.</td></tr>
<tr><td>System</td><td>Mac wakes, screen locks, screen unlocks, DisplayControl starts, Dark or Light Mode turns on.</td></tr>
<tr><td>Power</td><td>Plugged in, or on battery.</td></tr>
<tr><td>Monitors</td><td>Any or a specific monitor connects or disconnects.</td></tr></table>
<p>Create a preset first, then add a schedule in Settings, Schedules. Each can be switched on and off without deleting it.</p>

<h2>When the condition ends</h2>
<p>For paired triggers (plugged in and on battery, Dark and Light Mode, lock and unlock, monitor connects and disconnects) you can pick a second preset to apply when the condition ends.</p>

<h2>Sunrise and sunset</h2>
<p>Allow your location once, or type latitude and longitude. The times are calculated on your Mac with the NOAA solar equations, accurate to about a minute or two. In polar day and polar night there is no sunrise or sunset, and those schedules skip until there is.</p>

<h2>Sleep, clock and daylight saving</h2>
<ul><li>Timers are one-shot and computed for the next fire time, so nothing wakes the Mac while idle.</li>
<li>If the Mac slept through a time-based schedule, the most recent missed one runs once when it wakes, if it was within two hours.</li>
<li>Timers are recomputed after wake and when the clock or time zone changes. Wall-clock times survive daylight saving changes.</li>
<li>Starting the app is not treated as a monitor connecting, so a "monitor connects" schedule does not fire at launch.</li></ul>
""")

doc("automation-cli", "Automation and CLI", "Control displays from scripts, URLs and AI assistants.", """
<h2>Command line</h2>
<p>Install it from Settings, Command Line, or run the command shown there. DisplayControl must be running. Add <code>--launch</code> to start it if it is not.</p>
<pre><code>displaycontrol status
displaycontrol list
displaycontrol get "Acer" --brightness
displaycontrol set "Acer" --brightness 70 --contrast 50
displaycontrol set --all --brightness 40
displaycontrol set "Acer" --input hdmi2
displaycontrol preset list
displaycontrol preset activate "Evening" --delay 5
displaycontrol schedule list
displaycontrol sync enable "Acer"
displaycontrol mode "Acer" software
displaycontrol selftest "Acer"
displaycontrol probe
displaycontrol extras
displaycontrol extra nightshift on
displaycontrol extra nightshift-strength 70
displaycontrol profiles "Built-in"
displaycontrol profile "Built-in" sRGB
displaycontrol reset-gamma</code></pre>
<p>Pick a display by name (partial is fine), <code>--index N</code> or <code>--uuid KEY</code>. Output is readable in a terminal and JSON when piped; force either with <code>--human</code> or <code>--json</code>.</p>
<table><tr><th>Exit code</th><th>Meaning</th></tr>
<tr><td>0</td><td>Success</td></tr><tr><td>1</td><td>Bad usage</td></tr><tr><td>2</td><td>DisplayControl is not running</td></tr>
<tr><td>3</td><td>Display or preset not found</td></tr><tr><td>4</td><td>The display refused, or a self-test failed</td></tr><tr><td>5</td><td>Partial success (some preset items skipped)</td></tr></table>
<p><code>probe</code> works without the app. <code>selftest --mock</code> runs the whole pipeline against a simulated monitor.</p>

<h2>URL scheme</h2>
<pre><code>open "displaycontrol://preset/Movie%20Night"
open "displaycontrol://set?display=Acer&amp;brightness=60"</code></pre>
<p>From Shortcuts, use a <em>Run Shell Script</em> or <em>Open URLs</em> action. From AppleScript: <code>do shell script "open 'displaycontrol://preset/Evening'"</code>.</p>

<h2>AI assistants (MCP)</h2>
<p>DisplayControl includes a Model Context Protocol server over stdio. Add it to your assistant's configuration:</p>
<pre><code>{ "mcpServers": { "displaycontrol": { "command": "/usr/local/bin/displaycontrol", "args": ["mcp"] } } }</code></pre>
<p>Tools: list and get displays, set displays, list and activate presets, set sync, list schedules and enable or disable one. Values are limited to 0 to 100, and turning a display off needs <code>confirm: true</code>.</p>
<p>The control channel is a Unix socket in your Application Support folder, readable only by you. There is no network listener.</p>
""")

doc("troubleshooting", "Troubleshooting", "Fix monitors that do not respond, keys that stop working and dimmed screens.", """
<h2>A monitor does not respond</h2>
<ol>
<li>Switch the monitor's picture mode to <strong>Custom</strong>. Game, Movie and Reader modes often lock brightness and contrast.</li>
<li>Look for a <strong>DDC/CI</strong> option in the monitor's menu and turn it on.</li>
<li>Connect the monitor directly, without a hub, dock, KVM or adapter, to see whether that was the problem.</li>
<li>Try another port. If HDMI fails on your Apple Silicon Mac, use USB-C or DisplayPort.</li>
<li>In the display's expanded card, press <strong>Re-detect</strong>, or choose a control mode by hand.</li>
<li>Run <code>displaycontrol probe</code> and <code>displaycontrol selftest "name"</code>.</li></ol>
<p>Reading <code>probe</code>: <em>External candidates: 0</em> means macOS exposes no DDC service for that monitor. <em>read failed</em> after a successful pairing means the monitor did not give a valid answer.</p>

<h2>A screen stays dim</h2>
<p>Run <code>displaycontrol reset-gamma</code>, or choose <em>Reset dimming</em> in the window. If the app is not running, relaunch it first, or log out and in.</p>

<h2>The keyboard keys do nothing</h2>
<ul><li>Is the setting on, and is DisplayControl ticked in System Settings, Privacy and Security, Accessibility?</li>
<li>Rebuilt the app? Remove it from the list and add it again.</li>
<li>The keys only apply to the display under the pointer. Move the pointer onto the monitor.</li></ul>

<h2>The icon is missing from the menu bar</h2>
<p>Too many menu bar items can hide it. Quit a few, or use a menu bar manager and make sure DisplayControl is shown.</p>

<h2>Sunrise schedules do nothing</h2>
<p>They need a location. Add one in Settings, Schedules.</p>

<h2>Report a problem</h2>
<p>Open About, choose <strong>Copy diagnostics</strong>, and paste the result into an issue with your monitor and Mac models. The diagnostics contain no personal data: macOS version, chip, display vendor and product IDs, control modes and recent DDC log lines.</p>
""")

layout("docs/index.html", "Documentation | DisplayControl", "Guides for installing, using and automating DisplayControl.", "<h1>Documentation</h1>" +
       '<div class="grid">' + "".join(f'<a class="tile" style="text-decoration:none;color:inherit" href="{s}.html"><h3>{t}</h3></a>' for s, t in DOCS) + "</div>",
       1, "docs/index.html", sidebar=True)

# ---------------------------------------------------------------- assets

(SITE / "assets").mkdir(exist_ok=True)
import shutil
shutil.copy(ROOT / "Packaging" / "AppIcon-site.png", SITE / "assets" / "logo.png")
(SITE / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}/sitemap.xml\n", encoding="utf-8")
urls = "".join(f"<url><loc>{SITE_URL}/{p}</loc><lastmod>{TODAY}</lastmod></url>" for p, _, _ in sorted(pages))
(SITE / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + urls + "</urlset>\n", encoding="utf-8")
print(f"Wrote {len(pages)} pages to {SITE}")
