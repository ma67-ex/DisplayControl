#!/usr/bin/env bash
# Double-click this file to install DisplayControl. It opens Terminal and does everything for you.
cd "$(dirname "$0")" || exit 1
bash ./install.sh
echo
read -n 1 -s -r -p "Press any key to close this window."
