# TokenTracker

A macOS menu-bar app that shows how much Claude, Codex, Cursor, and Antigravity allowance is left.

It reads the sign-ins already on this Mac and asks each service for the current quota. Credentials stay where those apps stored them. The panel refreshes when you open it, when you click refresh, and every five minutes.

The menu-bar label is whichever pool is closest to empty.

## Requirements

macOS 14 or later, and Swift 6. Sign in through Claude Code, Codex, Cursor, and Antigravity first. The app has nothing of its own to log in with.

## Build

```sh
swift build -c release
.build/release/TokenTracker --check
.build/release/TokenTracker --once
```

`--once` prints the current quotas and exits.

## Install

```sh
APP="$HOME/Applications/TokenTracker.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TokenTracker "$APP/Contents/MacOS/TokenTracker"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
open "$APP"
```

The first launch can ask for Keychain access to the Claude, Cursor, and Antigravity items. Allow it. The app also registers itself to open at login.

These quota endpoints are the ones the official apps use. They are not a stable public API and can change.
