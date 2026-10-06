# TypeThru

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

Requires macOS 13 or later, on Apple silicon or Intel.

1. Download `TypeThru-<version>.dmg` from
   [Releases](https://github.com/sayre4ux/KeyTyper/releases) and open it.
2. Drag **TypeThru** into **Applications**, eject the disk, and open TypeThru from
   Applications. The TypeThru icon appears in the menu bar; click it to open the TypeThru panel.
3. The beta is not notarized yet. If macOS says it cannot verify TypeThru, open
   **System Settings > Privacy & Security**, scroll down, and choose **Open Anyway**. This is
   needed once.
4. Allow TypeThru in **System Settings > Privacy & Security > Accessibility** when asked.
5. When TypeThru offers Virtual Keyboard setup, choose **Set Up** and enter your administrator
   password.
6. If macOS asks, allow the Karabiner driver in System Settings.
7. In the panel, choose the **Short** typing test and click a text field in the remote session.

### Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`). The first build downloads
the virtual keyboard driver source, so it needs internet access. Run `./build.sh` to build
`TypeThru.app`, or `./package.sh` to build the disk image.

## Use

1. Copy text on your Mac.
2. Click the text field in the remote session.
3. Press **Control+\\**, or choose **Type Clipboard** in the TypeThru panel.

Press **Esc**, click the mouse, or switch apps or windows to stop. Keep the keyboard layout the
same on the Mac and in the remote session.

Line breaks are typed as Return. Turn on **Type line breaks as Shift+Return** for chat apps
where Return sends the message; leave it off for spreadsheets, where Shift+Return moves up a
cell.

**Speed** in the panel runs from *Average typist · 50 WPM*, the default, through fast and
record typists to *Unrealistic · 600 WPM*. If characters are dropped, choose a slower speed.

Symbols with no key on your layout, such as bullets, smart quotes, dashes, and `…`, are
typed as the closest plain keys (`•` becomes `-`, `“` becomes `"`). Turn off **Replace
symbols without a key** when the text must match exactly. TypeThru types nothing if the text
still contains a character with no key.

### Typing tests

Each test starts 3 seconds after you choose it, so click the target text field first.

| Test | Types | Checks |
|---|---|---|
| Short | `abc123` | The method works at all |
| Capitals | `AbC123!` | Shift reaches the remote session |
| Symbols | all 32 keyboard symbols | The keyboard layout matches on both sides |
| Smart symbols | `• “double” — …` and more | Symbol replacement; expect `- "double" -- ...` |
| Long | four lines with Tab and Return | Your selected speed. Use a multi-line field |

All tests except Long run at the slowest speed, so the method is the only thing tested.

## Troubleshooting

| Problem | Fix |
|---|---|
| Check Virtual Keyboard says *not set up* | Choose **Set Up Virtual Keyboard…** |
| It says *helper is not responding* | Wait a few seconds, check again, then rerun setup if needed |
| It says *driver is not active yet* | Approve the Karabiner system extension in System Settings |
| Diagnostics says all characters were sent, but nothing appeared | The remote text field did not have focus. Click it and retry. |
| The shortcut stops working after a rebuild | See [Signing](#signing) |
| A remote app needs Control+\\ | Use **Type Clipboard** in the panel |

**More > Last Attempt / Diagnostics** in the panel shows whether the shortcut arrived, which app was
in front, and why typing stopped.

## Uninstall

Choose **More > Uninstall TypeThru…** in the panel and enter your administrator password. It removes
the helper, settings, and the Accessibility entry, then quits. Tick **Also remove the Karabiner
virtual keyboard driver** only if no other app, such as Karabiner-Elements, uses it. Then move
TypeThru from Applications to the Trash.

## Privacy and security

TypeThru sends key presses. It does not record them.

- No event tap and no Input Monitoring permission. It only checks whether Esc, the modifier
  keys, the shortcut key, or a mouse button is held down at that moment, and while typing,
  which app and window are in front. It never sees what you type or where you click.
- The clipboard is read only when you ask TypeThru to type, and is never saved or logged.
- No network access. Only `build.sh` downloads the driver source.
- Virtual Keyboard adds a background helper that runs as root, because the driver accepts
  only root clients. It listens on a local socket that only your user account can open,
  accepts one fixed 8-byte key report at a time, and cannot read keyboard input.
- Any program running as your user can ask the helper to press keys. Uninstall when you no
  longer need it.
- Setup and uninstall run scripts bundled in the app as root, after you enter your password
  in the standard macOS prompt.
- Setup verifies the driver package signature and will not replace a different installed
  driver version.

Report security issues through GitHub private vulnerability reporting.

## Signing

macOS ties the Accessibility permission to the app's signature. `build.sh` uses the first
of these it finds:

1. `TYPETHRU_SIGN_IDENTITY` (a certificate name or hash; `-` forces ad-hoc)
2. a Developer ID Application certificate
3. an Apple Development certificate (free with an Apple ID: Xcode > Settings > Accounts >
   Manage Certificates)
4. ad-hoc signing

With a certificate, the permission survives rebuilds. With ad-hoc signing, `build.sh`
clears the stale entry and macOS asks again after each build. A self-signed Code Signing
certificate from Keychain Access also works:

```sh
TYPETHRU_SIGN_IDENTITY='TypeThru Local' ./build.sh
```

Release disk images are ad-hoc signed and not notarized during the beta. With a Developer ID
certificate, `package.sh` signs with the hardened runtime, and notarizes the disk image when
`TYPETHRU_NOTARY_PROFILE` names a `notarytool` keychain profile.

## Contributing

Run `./test.sh` before sending changes; it checks event construction without typing
anything. See [AGENTS.md](AGENTS.md) for architecture and project rules.

## License

MIT. See [LICENSE](LICENSE). The virtual keyboard driver,
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice),
is by pqrs.org under the Unlicense. `build.sh` fetches it at a pinned revision.
