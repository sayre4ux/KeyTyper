#!/bin/sh
# Security and repository audit. Read-only: changes nothing outside .build and posts no input.
# Run by make audit and make check (before every push). Needs: brew install shellcheck gitleaks
set -eu
cd "$(dirname "$0")/.."
APP=${TYPETHRU_APP:-TypeThru.app}
failed=0
fail() { echo "FAIL: $*"; failed=1; }
ok() { echo "ok  $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { fail "$1 is not installed. Run: brew install $1"; return 1; }; }

# Commits not yet pushed: compared with the upstream branch, or everything if there is none.
UPSTREAM=$(git rev-parse --verify -q '@{upstream}' 2>/dev/null || git rev-parse --verify -q origin/main || true)
RANGE=${UPSTREAM:+$UPSTREAM..HEAD}

# 1. Static analysis of the root helper.
SOURCE=.build/virtualhid-source
if [ -d "$SOURCE/include" ]; then
    # DECISION: unix.BlockInCriticalSection is off. It reads std::weak_ptr::lock() in the driver
    # library as a mutex and reports the helper's recv; no mutex is held there.
    found=$(clang++ --analyze -std=c++23 -isystem "$SOURCE/include" -isystem "$SOURCE/vendor/vendor/include" \
        -Xanalyzer -analyzer-disable-checker=unix.BlockInCriticalSection \
        -I helper -o /dev/null helper/virtual-keyboard.cpp 2>&1 | grep -E 'warning:|error:' \
        | grep -v 'Path diagnostic report is not generated' || true)
    [ -z "$found" ] && ok "clang static analyzer: root helper" || fail "clang static analyzer:
$found"
else
    fail "driver headers missing; run make build first"
fi

# 2. Shell scripts.
if need shellcheck; then
    if shellcheck -S warning scripts/*.sh helper/*.sh .githooks/pre-push; then ok "shellcheck: all scripts"
    else fail "shellcheck found problems above"; fi
fi

# 3. Secrets in the whole git history.
if need gitleaks; then
    if gitleaks git --no-banner --redact --log-level error .; then ok "gitleaks: no secrets in git history"
    else fail "gitleaks found possible secrets above"; fi
fi

# 4. No personal email addresses in commits about to be pushed.
emails=$(git log --format='%ae%n%ce' ${RANGE:+"$RANGE"} | sort -u | grep -v '@users\.noreply\.github\.com$' || true)
[ -z "$emails" ] && ok "commit emails are GitHub noreply addresses" || fail "personal email in commits to push: $emails"

# 5. Repository hygiene.
bad=$(git ls-files | grep -E '(^|/)(\.DS_Store|DEVLOG\.md|ResourceHashes\.swift)$|\.app/|\.dmg$|^\.build/|\.iconset/' || true)
[ -z "$bad" ] && ok "no build output or local files tracked" || fail "tracked files that belong local only: $bad"
ignored=$(git ls-files -ci --exclude-standard)
[ -z "$ignored" ] && ok "no tracked file is also ignored" || fail "tracked but ignored: $ignored"
large=$(git ls-files -z | xargs -0 stat -f '%z %N' | awk '$1 > 2000000 { print $2 }')
[ -z "$large" ] && ok "no tracked file over 2 MB" || fail "large tracked files: $large"
untracked=$(git ls-files --others --exclude-standard)
[ -z "$untracked" ] || echo "note: untracked files (add or ignore them): $untracked"
# Commands only: comments and this check's own pattern do not count.
removals=$(grep -n -E '^[^#]*rm -[a-zA-Z]*r[a-zA-Z]*f' scripts/*.sh helper/*.sh .githooks/pre-push | grep -v '^scripts/audit.sh:' || true)
[ -z "$removals" ] && ok "no rm -rf in scripts" || fail "rm -rf in scripts (delete specific files instead): $removals"

# 6. Privacy contract (README "Privacy"): no event taps, input monitoring, logging, or clipboard
# writes; network only for the update check.
taps=$(grep -n -E 'tapCreate|addGlobalMonitorForEvents|IOHIDManagerOpen|IOHIDDeviceOpen|NSLog\(|os_log|Logger\(|OSLog|setString\(|clearContents\(' Sources/*.swift || true)
[ -z "$taps" ] && ok "no event taps, logging, or clipboard writes" || fail "breaks the privacy contract: $taps"
network=$(grep -n -E 'URLSession|URLRequest|NWConnection|NWPathMonitor|CFStream|getaddrinfo' Sources/*.swift | grep -v '^Sources/Updates.swift:' || true)
[ -z "$network" ] && ok "network access only in the update check" || fail "network access outside Updates.swift: $network"
prints=$(grep -n 'print(' Sources/*.swift | grep -v '^Sources/main.swift:' || true)
[ -z "$prints" ] && ok "no print output outside --print-map" || fail "print outside main.swift: $prints"
if [ -n "$RANGE" ] && git diff "$RANGE" -- '*.swift' '*.cpp' '*.hpp' ':!Tests' | grep -E '^\+' | grep -q -E 'URLSession|NWConnection|tapCreate|addGlobalMonitor|NSPasteboard|AXUIElement|CGEventSource\.(keyState|buttonState)|UserDefaults'; then
    if git diff --quiet "$RANGE" -- README.md; then
        fail "changes touch clipboard, network, settings, or input checks; review README Privacy and update it in the same push"
    else
        ok "privacy-related changes come with a README update (review it)"
    fi
else
    ok "no new privacy-related code to review"
fi

# 7. No VDI or remote desktop vendor names in the app or README.
vendors=$(grep -n -i -E 'citrix|vmware|horizon client|omnissa|workspaces|azure virtual desktop|windows 365|parallels|teamviewer|anydesk|chrome remote' Sources/*.swift README.md || true)
[ -z "$vendors" ] && ok "no vendor names in the app or README" || fail "vendor names: $vendors"

# 8. Built app: valid signature, and setup fingerprints match the bundled files.
if [ -d "$APP" ]; then
    codesign --verify --deep --strict "$APP" 2>/dev/null && ok "$APP signature valid" || fail "$APP signature invalid"
    for file in install-helper.sh uninstall-helper.sh TypeThru-VirtualKeyboard Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg; do
        hash=$(shasum -a 256 "$APP/Contents/Resources/$file" | cut -c1-64)
        grep -q "\"$file\": \"$hash\"" .build/ResourceHashes.swift || fail "setup fingerprint mismatch for $file; rebuild"
    done
    ok "setup fingerprints match the bundled files"
fi

# 9. Installed system, if set up (read-only).
HELPER=/Library/PrivilegedHelperTools/TypeThru-VirtualKeyboard
PLIST=/Library/LaunchDaemons/io.github.sayre4ux.typethru.virtual-keyboard.plist
SOCKET=/var/run/io.github.sayre4ux.typethru.virtual-keyboard.sock
if [ -e "$HELPER" ]; then
    [ "$(stat -f '%Su:%Sg %Lp' "$HELPER")" = "root:wheel 755" ] && ok "installed helper owned by root, mode 755" || fail "installed helper owner or mode: $(stat -f '%Su:%Sg %Lp' "$HELPER")"
    [ "$(stat -f '%Su:%Sg %Lp' "$PLIST")" = "root:wheel 644" ] && ok "launch daemon plist owned by root, mode 644" || fail "plist owner or mode: $(stat -f '%Su:%Sg %Lp' "$PLIST")"
    if [ -S "$SOCKET" ]; then
        [ "$(stat -f '%Su %Lp' "$SOCKET")" = "$(id -un) 600" ] && ok "helper socket only for $(id -un), mode 600" || fail "socket owner or mode: $(stat -f '%Su %Lp' "$SOCKET")"
    fi
else
    echo "note: Virtual Keyboard is not installed on this Mac; skipped installed-file checks"
fi

[ "$failed" = 0 ] && echo "Audit passed." || { echo "Audit failed."; exit 1; }
