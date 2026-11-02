#!/usr/bin/env bash
# DisplayControl installer: builds the app and puts it in your Applications folder.
#
# Easiest ways to run it:
#   * Double-click "Install DisplayControl.command" (after downloading the ZIP from GitHub), or
#   * Paste this into Terminal:
#       curl -fsSL https://raw.githubusercontent.com/ma67-ex/DisplayControl/main/install.sh | bash
#
# Options (environment variables):
#   DISPLAYCONTROL_INSTALL_DIR   where to put the app (default: /Applications)
#   DISPLAYCONTROL_NO_OPEN=1     do not open the app when finished
set -euo pipefail

REPO_URL="https://github.com/ma67-ex/DisplayControl.git"
INSTALL_DIR="${DISPLAYCONTROL_INSTALL_DIR:-/Applications}"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1;33m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
good()  { printf '    \033[32m✓\033[0m %s\n' "$1"; }
stop()  { printf '\n\033[31m%s\033[0m\n' "$1"; exit 1; }

clear 2>/dev/null || true
bold "DisplayControl installer"
echo "This takes about three minutes the first time. You can leave it running."

step "Checking your Mac"
[ "$(uname)" = "Darwin" ] || stop "DisplayControl is a Mac app, and this is not a Mac."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 13 ] || stop "DisplayControl needs macOS 13 or newer. Your Mac has $(sw_vers -productVersion)."
good "macOS $(sw_vers -productVersion)"

step "Checking for Apple's free developer tools"
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "    They are not installed yet. A window is about to open from Apple."
  echo "    Click Install, wait for it to finish, then run this installer again."
  xcode-select --install >/dev/null 2>&1 || true
  exit 0
fi
good "found"

step "Getting DisplayControl"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/Package.swift" ] && [ -f "$HERE/Packaging/build-app.sh" ]; then
  SRC="$HERE"
  good "using the copy you downloaded"
else
  command -v git >/dev/null 2>&1 || stop "git is missing. Install Apple's developer tools first (xcode-select --install)."
  SRC="$(mktemp -d)/DisplayControl"
  git clone --depth 1 --quiet "$REPO_URL" "$SRC"
  good "downloaded"
fi

step "Building the app (this is the slow part)"
( cd "$SRC" && bash ./Packaging/build-app.sh >/tmp/displaycontrol-install.log 2>&1 ) \
  || { tail -n 25 /tmp/displaycontrol-install.log; stop "The build did not finish. The lines above say why. You can also ask for help on the project page."; }
[ -d "$SRC/dist/DisplayControl.app" ] || stop "The build finished without producing the app."
good "built"

step "Installing"
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if [ ! -w "$INSTALL_DIR" ]; then
  INSTALL_DIR="$HOME/Applications"; mkdir -p "$INSTALL_DIR"
  echo "    /Applications is not writable here, so using $INSTALL_DIR instead."
fi
osascript -e 'tell application "DisplayControl" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$INSTALL_DIR/DisplayControl.app"
cp -R "$SRC/dist/DisplayControl.app" "$INSTALL_DIR/DisplayControl.app"
xattr -dr com.apple.quarantine "$INSTALL_DIR/DisplayControl.app" 2>/dev/null || true
good "installed in $INSTALL_DIR"

if [ "${DISPLAYCONTROL_NO_OPEN:-0}" != "1" ]; then
  step "Opening DisplayControl"
  open "$INSTALL_DIR/DisplayControl.app"
  good "look for the display icon at the top right of your screen"
fi

cat <<'EOF'

All done. Here is what to do next:

  1. Click the little display icon in your menu bar (top right).
  2. A welcome window shows your screens. Press "Test" next to a monitor to try it.
  3. Want the keyboard brightness and volume keys to work on your monitor?
     Open Settings, go to the Keyboard tab and switch it on.

Enjoy your desk.
EOF
