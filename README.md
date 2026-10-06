# KeyTyper

A macOS menu bar app that types your clipboard as key presses, for VDI and remote desktop
sessions where paste does not work. Press **Control+\\** to type the clipboard into whatever
has focus.

## Typing methods

- **Virtual Keyboard** (recommended for remote sessions). Keys go through a virtual USB
  keyboard, so remote clients that ignore synthetic macOS events still receive them. Needs a
  one-time setup with an administrator password.
- **Quartz events** (for apps on this Mac). Four ways of posting macOS key events. No setup,
  but many remote clients ignore them. *Unicode text events* can type characters that your
  keyboard layout lacks.

Virtual Keyboard has been tested with one VDI client connected to Windows. RDP and other
clients are untested; reports are welcome.

## Install

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). The
first build downloads the virtual keyboard driver source, so it needs internet access.

1. Run `./build.sh`, then open `KeyTyper.app`. A keyboard icon appears in the menu bar.
2. Allow KeyTyper in **System Settings > Privacy & Security > Accessibility**.
3. When KeyTyper offers Virtual Keyboard setup, choose **Run Setup** and enter your
   administrator password in Terminal.
4. If macOS asks, approve the Karabiner system extension in System Settings.
5. Choose **Check Virtual Keyboard** from the menu. It should report ready.
6. Choose **Test abc123 in 3 seconds** and click a text field in the remote session.

## Use

1. Copy text on your Mac.
2. Click the text field in the remote session.
3. Press **Control+\\**, or choose **Type Clipboard** from the menu.

Press **Esc** or switch apps to stop. Keep the keyboard layout the same on the Mac and in
the remote session.

**Typing Speed** runs from *Average typist (50 WPM)*, the default, through fast and record
typists to *Unrealistic (600 WPM)*. If characters are dropped, choose a slower speed.

Symbols with no key on your layout, such as bullets, smart quotes, dashes, and `…`, are
typed as the closest plain keys (`•` becomes `-`, `“` becomes `"`). Turn off **Replace
Symbols Without a Key** when the text must match exactly. KeyTyper types nothing if the text
still contains a character with no key.

## Troubleshooting

| Problem | Fix |
|---|---|
| Check Virtual Keyboard says *not set up* | Choose **Set Up Virtual Keyboard…** |
| It says *helper is not responding* | Wait a few seconds, check again, then rerun setup if needed |
| It says *driver is not active yet* | Approve the Karabiner system extension in System Settings |
| Diagnostics says all characters were sent, but nothing appeared | The remote text field did not have focus. Click it and retry. |
| The shortcut stops working after a rebuild | See [Signing](#signing) |
| A remote app needs Control+\\ | Use **Type Clipboard** from the menu |

**Last Attempt / Diagnostics** in the menu shows whether the shortcut arrived, which app was
in front, and why typing stopped.

## Uninstall

Choose **Uninstall KeyTyper…** from the menu. It removes the helper, settings, and the
Accessibility entry, and asks before removing the Karabiner driver. Keep the driver if
another app, such as Karabiner-Elements, uses it. Then delete `KeyTyper.app`.

## Privacy and security

KeyTyper sends key presses. It does not record them.

- No event tap and no Input Monitoring permission. It only checks whether Esc, the modifier
  keys, and the shortcut key are held down at that moment.
- The clipboard is read only when you ask KeyTyper to type, and is never saved or logged.
- No network access. Only `build.sh` downloads the driver source.
- Virtual Keyboard adds a background helper that runs as root, because the driver accepts
  only root clients. It listens on a local socket that only your user account can open,
  accepts one fixed 8-byte key report at a time, and cannot read keyboard input.
- Any program running as your user can ask the helper to press keys. Uninstall when you no
  longer need it.
- Setup verifies the driver package signature and will not replace a different installed
  driver version.

Report security issues through GitHub private vulnerability reporting.

## Signing

macOS ties the Accessibility permission to the app's signature. `build.sh` uses the first
of these it finds:

1. `KEYTYPER_SIGN_IDENTITY` (a certificate name or hash; `-` forces ad-hoc)
2. a Developer ID Application certificate
3. an Apple Development certificate (free with an Apple ID: Xcode > Settings > Accounts >
   Manage Certificates)
4. ad-hoc signing

With a certificate, the permission survives rebuilds. With ad-hoc signing, `build.sh`
clears the stale entry and macOS asks again after each build. A self-signed Code Signing
certificate from Keychain Access also works:

```sh
KEYTYPER_SIGN_IDENTITY='KeyTyper Local' ./build.sh
```

Builds are not notarized and are meant for your own Mac.

## Contributing

Run `./test.sh` before sending changes; it checks event construction without typing
anything. See [AGENTS.md](AGENTS.md) for architecture and project rules.

## License

MIT. See [LICENSE](LICENSE). The virtual keyboard driver,
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice),
is by pqrs.org under the Unlicense. `build.sh` fetches it at a pinned revision.
