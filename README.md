# KeyTyper

KeyTyper is a macOS menu bar app that types your clipboard as key presses. It is for remote
sessions where paste does not work, such as a locked-down VDI desktop or a remote desktop
login screen.

Press **Control+\\** and KeyTyper types the clipboard text into whatever has focus.

## How it types

KeyTyper has two kinds of typing method.

**Virtual Keyboard (recommended for VDI and remote desktops).** KeyTyper sends each key
through a virtual USB keyboard. To the remote client this looks like a real keyboard, so
clients that ignore synthetic macOS key events still receive the keys. This method needs a
one-time setup with an administrator password, described below.

**Quartz events (for apps on this Mac).** Four methods that post macOS keyboard events
directly. They need no setup, but many remote clients ignore them.

| Method | What it does |
|---|---|
| HID key events | Posts key events at the lowest level macOS allows |
| Session key events | Posts key events to the login session |
| Direct to target app | Posts key events to the front app only |
| Unicode text events | Sends characters instead of keys; can type characters your layout lacks |

Virtual Keyboard has been tested with a VDI client connected to a Windows desktop. Other
clients, including RDP, have not been tested yet. Reports are welcome.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- An internet connection for the first build, which downloads the virtual keyboard driver source
- An administrator password, for Virtual Keyboard only

## Install

1. Clone this repository and run `./build.sh`. It creates `KeyTyper.app` in the same folder.
2. Move `KeyTyper.app` to `/Applications` (optional) and open it. A keyboard icon appears in
   the menu bar.
3. When macOS asks, allow KeyTyper under **System Settings > Privacy & Security >
   Accessibility**.
4. KeyTyper then offers to set up Virtual Keyboard. Choose **Run Setup**. Terminal opens and
   asks for your administrator password.
5. If macOS asks, approve the Karabiner system extension in System Settings (Privacy &
   Security, or General > Login Items & Extensions > Driver Extensions).
6. Choose **Check Virtual Keyboard** from the KeyTyper menu. It should say the Virtual
   Keyboard is ready.
7. Choose **Test abc123 in 3 seconds**, then click a text field in your remote session within
   three seconds. You should see `abc123` appear.

You can run the setup again at any time from **Set Up Virtual Keyboard…** in the menu.

## Use

1. Copy some text on your Mac.
2. Click into the text field in the remote session.
3. Press **Control+\\**, or choose **Type Clipboard** from the menu.

Typing stops if you press **Esc** or switch to another app. Typing speed is under
**Typing Speed** in the menu. If characters are dropped, choose a slower speed.

Keep the keyboard layout on your Mac and in the remote session the same. KeyTyper sends key
positions, and the remote side turns them into characters using its own layout.

KeyTyper checks the whole text before it starts. If a character has no key on your current
layout, it types nothing and tells you.

## Troubleshooting

**Check Virtual Keyboard** reports one of these:

| Message | What to do |
|---|---|
| Not set up | Choose Set Up Virtual Keyboard… |
| Helper is not responding | Wait a few seconds and check again. If it continues, run the setup again. |
| Driver is not active yet | Approve the Karabiner system extension in System Settings, then check again. |
| Ready | Nothing. Try the abc123 test. |

**Last Attempt / Diagnostics** shows what happened the last time you typed: whether the
shortcut arrived, which app was in front, and whether typing stopped early.

Other common problems:

- **The shortcut does nothing after a rebuild.** Without a signing certificate, macOS treats
  each build as a new app and forgets the Accessibility permission. Quit and reopen KeyTyper
  and allow it again, or set up signing (see [Signing](#signing)) so this stops happening.
- **KeyTyper says it sent everything, but nothing appeared.** The keys reached the remote
  client, but the remote text field did not have focus. Click into the field and try again.
- **Control+\\ is used by an app in the remote session.** Use **Type Clipboard** from the
  menu instead.

The shortcut uses Control only, on purpose. Modifier keys still reach the remote session
when KeyTyper takes the shortcut. On Windows, a lone Alt press opens the menu bar, so a
shortcut with Option breaks typing.

## Uninstall

1. Choose **Uninstall KeyTyper…** from the KeyTyper menu. Terminal opens.
2. Answer whether to remove the Karabiner virtual keyboard driver as well. Answer **n** if
   another app, such as Karabiner-Elements, uses it. If Karabiner-Elements is installed, the
   uninstaller warns you.
3. Enter your administrator password when asked.
4. Delete `KeyTyper.app`.

The uninstaller quits KeyTyper and removes:

- the background helper and its launch daemon
- KeyTyper's settings and its Accessibility permission
- if you agreed, the Karabiner driver, its files, and its install record

If the driver still appears in System Settings afterwards, restart your Mac.

## What KeyTyper does and does not do

KeyTyper sends key presses. It does not record them. Because it uses a keyboard driver and a
background helper, here is exactly what it can and cannot see:

- **It does not read what you type.** It does not install an event tap and does not ask for
  the Input Monitoring permission. The only keys it checks are Esc (to stop typing), the
  modifier keys (to wait until you let go of the shortcut), and the shortcut's own key. It
  checks whether those keys are held down at that moment; it never receives a stream of key
  presses.
- **It reads the clipboard only when you ask it to type**, with the shortcut or the menu.
  The text is typed and then discarded. It is never saved, logged, or sent anywhere.
- **It makes no network connections.** Only `build.sh` uses the internet, to download the
  driver source from GitHub.
- **The helper only sends keys.** It accepts one fixed 8-byte key report at a time from your
  Mac user account, presses that key on the virtual keyboard, and replies with one status
  byte. It has no way to read keyboard input.
- **It asks for one permission**: Accessibility. macOS requires it to post key events, and
  KeyTyper checks it before typing with any method.

### Security notes

- KeyTyper runs as your user. The helper runs as root, because the virtual keyboard driver
  accepts only root clients.
- The helper's local socket can be opened only by your Mac user account. Any program running
  as your user can ask it to press keys without the Accessibility permission. Uninstall
  KeyTyper when you no longer need it.
- Setup checks the driver package's signature before installing it, and refuses to replace a
  different installed driver version.

All of this is in about 900 lines of source in this repository, so you can check it. Please
report security problems privately through GitHub's private vulnerability reporting.

## Development

### Signing

macOS ties the Accessibility permission to the app's signature. `build.sh` signs with the
first certificate it finds:

1. the `KEYTYPER_SIGN_IDENTITY` environment variable, if set
2. a **Developer ID Application** certificate (paid Apple Developer Program)
3. an **Apple Development** certificate (free: sign in with your Apple ID in Xcode >
   Settings > Accounts, then choose Manage Certificates > + > Apple Development)
4. otherwise, ad-hoc signing

With any certificate, you allow Accessibility once and the permission survives rebuilds.
With ad-hoc signing, every build is a new app to macOS, so `build.sh` clears the stale
permission entry and KeyTyper asks again when you reopen it.

No Apple account? Create a self-signed certificate in Keychain Access > Certificate
Assistant > Create a Certificate, with Certificate Type set to **Code Signing**, then build
with its name:

```sh
KEYTYPER_SIGN_IDENTITY='KeyTyper Local' ./build.sh
```

The first signed build may ask for access to your keychain; choose **Always Allow**. Builds
are not notarized, so they are meant for your own Mac.

### Files

| File | Purpose |
|---|---|
| `main.swift` | Menu bar app, shortcut, key map, and the Quartz typing methods |
| `VirtualKeyboard.swift` | Talks to the helper over its local socket |
| `helper/virtual-keyboard.cpp` | Root helper that drives the virtual keyboard |
| `helper/*.sh`, `helper/*.command` | Setup and uninstall |
| `build.sh` | Builds the app and the helper |
| `test.sh` | Tests event construction without sending any keys |

```sh
./test.sh
```

To see which keys a piece of text would use, without typing anything:

```sh
KeyTyper.app/Contents/MacOS/KeyTyper --print-map 'Hello, world!'
```

## License

MIT. See [LICENSE](LICENSE).

The virtual keyboard driver is
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
by pqrs.org, released into the public domain. `build.sh` downloads it at a pinned revision,
and the built app includes its signed installer package and license.
