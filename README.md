# Redeye

A tiny macOS menu bar app that keeps your Mac awake so long-running work, like a Claude session, keeps going while you're away.

Inspired by [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake).

## Features

- **One click to toggle.** Left-click the sunrise icon to keep your Mac awake; click again to allow sleep.
- **Timed sessions.** Right-click to stay awake forever or for 30 min, 1 hr, 6 hr, 12 hr or 24 hr.
- **Launch at Login.** Optional, in Settings (right-click → Settings…).
- **Scriptable.** Control it from the terminal or a script with the `redeye://` URL scheme.
- **Menu bar only.** No Dock icon, no windows.

## Requirements

- macOS 13 Ventura or later
- Xcode 26 or later to build

## Build

Open `Redeye.xcodeproj` in Xcode and press Run, or from the terminal:

```sh
xcodebuild -project Redeye.xcodeproj -scheme Redeye -configuration Release -derivedDataPath build build
```

This produces `build/Build/Products/Release/Redeye.app`. Move it to `/Applications` and open it.

See [DEVELOPING.md](DEVELOPING.md) for project details.

## Usage

| Action | Result |
| --- | --- |
| Left-click | Toggle awake on/off |
| Right-click / Ctrl-click | Open the menu |

A filled sunrise means your Mac is being kept awake.

### From the terminal

```sh
open -g redeye://activate              # keep awake indefinitely
open -g "redeye://activate?hours=2"    # for 2 hours (also seconds=, minutes=; they add up)
open -g redeye://deactivate            # allow sleep
open -g redeye://toggle
```

`-g` keeps the current app in front. Redeye is launched if it isn't already running.

## Notes

Redeye prevents idle sleep the same way `caffeinate -i` does: the screen still turns off on its normal timer, but the Mac keeps running. Closing the lid on a MacBook will still put it to sleep unless it's connected to power and an external display.

## License

MIT. See [LICENSE](LICENSE).
