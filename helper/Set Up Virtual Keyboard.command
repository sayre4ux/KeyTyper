#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo 'KeyTyper Virtual Keyboard — one-time setup'
echo 'Installs a background helper for your Mac user account. The main app does not run as administrator.'
echo 'The signed Karabiner virtual keyboard driver retains its original identity.'
echo
sudo /bin/bash "$PWD/install-helper.sh" "$(id -u)"
'/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager' activate
echo
echo 'If macOS asks, approve the Karabiner system extension in System Settings'
echo '(Privacy & Security, or General > Login Items & Extensions > Driver Extensions).'
echo 'Restart only if macOS asks.'
echo 'Then return to KeyTyper > Check Virtual Keyboard.'
read -r -p 'Press Return to close. ' unused
