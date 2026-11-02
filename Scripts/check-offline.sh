#!/usr/bin/env bash
# Proves the app keeps everything on the device. Three independent checks:
#   1. the source contains no networking code,
#   2. the built programs link no networking or web frameworks,
#   3. the running app holds no internet or local-network sockets (only its own private control socket).
# Usage: Scripts/check-offline.sh [path/to/DisplayControl.app]
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/DisplayControl.app}"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "1. Source code"
PATTERN='URLSession|URLRequest|NWConnection|NWListener|NWPathMonitor|CFSocket|CFStream|AF_INET|AF_INET6|WKWebView|NSURLConnection|import Network|SCNetworkReachability|Data\(contentsOf: *URL\(string|String\(contentsOf: *URL\(string'
if grep -rnE "$PATTERN" Sources >/dev/null; then bad "networking API found:"; grep -rnE "$PATTERN" Sources; else ok "no networking APIs in Sources/"; fi
if grep -rnE "socket\(" Sources | grep -v "AF_UNIX" >/dev/null; then bad "a socket that is not a local Unix socket"; else ok "the only sockets are local Unix sockets"; fi

echo "2. Built programs"
for b in "$APP/Contents/MacOS/DisplayControl" "$APP/Contents/Resources/bin/displaycontrol"; do
  [ -f "$b" ] || { bad "missing $b (build the app first)"; continue; }
  if otool -L "$b" | tail -n +2 | awk '{print $1}' | grep -iE "Network\.framework|CFNetwork|WebKit|Safari|Sparkle" >/dev/null; then bad "$(basename "$b") links a networking or web framework"; else ok "$(basename "$b") links no networking or web framework"; fi
done

echo "3. Running app"
if [ -d "$APP" ]; then
  "$APP/Contents/MacOS/DisplayControl" --demo >/dev/null 2>&1 &
  PID=$!
  sleep 6
  if kill -0 "$PID" 2>/dev/null; then
    NET="$(lsof -nP -a -p "$PID" -i 2>/dev/null | tail -n +2)"
    if [ -n "$NET" ]; then bad "the app has network sockets:"; echo "$NET"; else ok "no internet or local-network sockets while running"; fi
    kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  else
    bad "the app did not stay running, so it could not be checked"
  fi
fi

echo
if [ "$fail" = 0 ]; then echo "Offline check passed: nothing leaves this device."; else echo "Offline check FAILED."; exit 1; fi
