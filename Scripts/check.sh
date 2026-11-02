#!/usr/bin/env bash
# Builds, runs every test and checks the website. With only the Command Line Tools installed, the newest
# SDK may lack the SwiftUI macro plugin, so fall back to older SDKs.
set -euo pipefail
cd "$(dirname "$0")/.."
run() { swift test "$@"; }
if ! run 2>/tmp/dc-check.err; then
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX2*.sdk 2>/dev/null | sort -r); do
    echo "Retrying with $sdk"
    if run --sdk "$sdk"; then ok=1; break; fi
  done
  [ "${ok:-0}" = 1 ] || { tail -20 /tmp/dc-check.err; exit 1; }
fi
python3 Scripts/build-site.py
python3 Scripts/check-site.py
echo "All checks passed."
