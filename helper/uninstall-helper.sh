#!/bin/bash
# Root side of Uninstall TypeThru, run by TypeThru behind the macOS password prompt.
# Removes the helper, and the Karabiner driver files only when asked.
set -euo pipefail
[[ $EUID -eq 0 && $# -eq 1 && ( "$1" == keep-driver || "$1" == remove-driver ) ]] || exit 2
LABEL=io.github.sayre4ux.typethru.virtual-keyboard
DRIVER_DIR='/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice'
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/rm -f "/Library/LaunchDaemons/$LABEL.plist" /Library/PrivilegedHelperTools/TypeThru-VirtualKeyboard \
    /var/run/io.github.sayre4ux.typethru.virtual-keyboard.sock
# Builds before 0.3 were called KeyTyper.
/bin/launchctl bootout system/local.keytyper.virtual-keyboard 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/local.keytyper.virtual-keyboard.plist \
    /Library/PrivilegedHelperTools/KeyTyper-VirtualKeyboard /var/run/local.keytyper.virtual-keyboard.sock
/usr/bin/pkill -x KeyTyper || true
if [[ "$1" == remove-driver && -d "$DRIVER_DIR" ]]; then
    /bin/bash "$DRIVER_DIR/scripts/uninstall/remove_files.sh" >/dev/null 2>&1 || true
    /usr/sbin/pkgutil --forget org.pqrs.Karabiner-DriverKit-VirtualHIDDevice >/dev/null 2>&1 || true
fi
