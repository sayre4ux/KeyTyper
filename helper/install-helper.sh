#!/bin/bash
# Root side of Virtual Keyboard setup, run by TypeThru behind the macOS password prompt.
# Messages go to stderr, which TypeThru shows if setup fails.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 && $# -eq 1 && "$1" =~ ^[0-9]+$ && "$1" -ge 501 ]] || exit 2
USER_UID="$1"
LABEL=io.github.sayre4ux.typethru.virtual-keyboard
DEST=/Library/PrivilegedHelperTools/TypeThru-VirtualKeyboard
PLIST="/Library/LaunchDaemons/$LABEL.plist"
DRIVER_INFO='/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Info.plist'
if [[ -e "$DRIVER_INFO" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DRIVER_INFO")
    [[ "$VERSION" == '8.6.0' ]] || { echo "Installed Karabiner driver is $VERSION; this build requires 8.6.0. No driver changes made." >&2; exit 1; }
else
    /usr/sbin/pkgutil --check-signature Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg
    /usr/sbin/spctl --assess --type install Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg
    /usr/sbin/installer -pkg Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg -target /
fi
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
# Builds before 0.3 were called KeyTyper; remove that helper so only one runs.
/bin/launchctl bootout system/local.keytyper.virtual-keyboard 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/local.keytyper.virtual-keyboard.plist \
    /Library/PrivilegedHelperTools/KeyTyper-VirtualKeyboard /var/run/local.keytyper.virtual-keyboard.sock
# Wait for the old helper to release its socket/owned daemon before replacing it.
for i in {1..50}; do
    [[ ! -S /var/run/io.github.sayre4ux.typethru.virtual-keyboard.sock ]] && break
    sleep 0.1
done
[[ ! -S /var/run/io.github.sayre4ux.typethru.virtual-keyboard.sock ]] || { echo 'Old helper is still stopping. Try setup again.' >&2; exit 1; }
/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
/usr/bin/install -o root -g wheel -m 755 TypeThru-VirtualKeyboard "$DEST"
# DECISION: the user approved this app when opening it; a quarantined copy may not start under launchd.
/usr/bin/xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$DEST</string><string>$USER_UID</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
