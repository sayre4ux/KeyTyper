#!/bin/bash
# Removes everything KeyTyper setup added. The Karabiner driver is removed only if you agree.
set -euo pipefail
LABEL=local.keytyper.virtual-keyboard
DRIVER_DIR='/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice'
MANAGER='/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager'

echo 'Uninstall KeyTyper'
echo
echo 'This removes the KeyTyper background helper, its settings, and its Accessibility permission.'
echo 'It can also remove the Karabiner virtual keyboard driver that KeyTyper setup installs.'
echo
REMOVE_DRIVER=n
if [[ -d "$DRIVER_DIR" ]]; then
    if [[ -d /Applications/Karabiner-Elements.app ]]; then
        echo 'Karabiner-Elements is installed and uses the same driver.'
        echo 'Keep the driver unless you are also removing Karabiner-Elements.'
    fi
    read -r -p 'Also remove the Karabiner virtual keyboard driver? [y/N] ' answer
    [[ "$answer" =~ ^[Yy]$ ]] && REMOVE_DRIVER=y
fi

/usr/bin/pkill -x KeyTyper || true

echo 'Removing the background helper (administrator password required)...'
sudo /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo /bin/rm -f "/Library/LaunchDaemons/$LABEL.plist" /Library/PrivilegedHelperTools/KeyTyper-VirtualKeyboard \
    /var/run/local.keytyper.virtual-keyboard.sock

if [[ "$REMOVE_DRIVER" == y ]]; then
    echo 'Deactivating the driver. macOS may ask for your password again.'
    "$MANAGER" deactivate || echo 'Deactivation did not finish. Continuing with file removal.'
    sudo /bin/bash "$DRIVER_DIR/scripts/uninstall/remove_files.sh" >/dev/null 2>&1 || true
    sudo /usr/sbin/pkgutil --forget org.pqrs.Karabiner-DriverKit-VirtualHIDDevice >/dev/null 2>&1 || true
fi

/usr/bin/defaults delete local.keytyper >/dev/null 2>&1 || true
/usr/bin/tccutil reset Accessibility local.keytyper >/dev/null 2>&1 \
    || echo 'Remove KeyTyper from System Settings > Privacy & Security > Accessibility yourself.'

echo
echo 'Done. Delete KeyTyper.app to finish.'
[[ "$REMOVE_DRIVER" == y ]] && echo 'Restart your Mac if the driver still appears in System Settings.'
read -r -p 'Press Return to close. ' unused
