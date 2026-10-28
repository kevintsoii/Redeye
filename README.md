# Redeye

A tiny macOS menu bar app that keeps your Mac awake so long-running work, like a Claude session, keeps going while you're away.

Inspired by [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake).

## Features

- **One click to switch modes.** Left-click the sunrise icon to step through Sleep Normally, Stay Awake and Stay Awake (Ignore Lid).
- **Works with the lid closed.** Keep Claude running with your Mac in a bag.
- **Timed sessions.** Right-click to stay awake forever or for 30 min, 1 hr, 6 hr, 12 hr or 24 hr. Left-click uses each mode's default: Forever for Stay Awake, 24 hours for Stay Awake (Ignore Lid). Change them in Settings > Stay Awake.
- **Safety cutoffs.** Optional, in Settings > Safety: let the Mac sleep when the battery runs low or the Mac gets too hot. Off by default.
- **Notifications.** Tells you when Redeye stops keeping your Mac awake on its own: a timer ran out, a Safety cutoff kicked in, or the Ignore Lid helper stopped. Turn them off in System Settings > Notifications.
- **Keep screen on.** Optional, in Settings > Stay Awake. Off by default, so the screen turns off while your Mac keeps running.
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
| Left-click | Next mode: Sleep Normally → Stay Awake → Stay Awake (Ignore Lid) → Sleep Normally |
| Right-click / Ctrl-click | Open the menu |

| Icon | Mode |
| --- | --- |
| Outline sun | Sleep Normally |
| Yellow sun | Stay Awake: your Mac won't sleep on its own, but closing the lid still sleeps it |
| Red sun | Stay Awake (Ignore Lid): your Mac won't sleep at all, even with the lid closed |

The first time you use Stay Awake (Ignore Lid), Redeye asks you to turn it on in System Settings > General > Login Items & Extensions. That lets its small helper run as administrator, which macOS requires to stop lid-close sleep.

### From the terminal

```sh
open -g redeye://activate              # Stay Awake for its default duration (Forever unless changed)
open -g "redeye://activate?hours=2"    # for 2 hours (also seconds=, minutes=; they add up)
open -g "redeye://activate?lid=1"      # Stay Awake (Ignore Lid), 24 hours unless changed
open -g "redeye://activate?forever=1"  # forever, whatever the default (works with lid=1 too)
open -g redeye://deactivate            # allow sleep
open -g redeye://toggle
```

`-g` keeps the current app in front. Redeye is launched if it isn't already running.

## Notes

Stay Awake works like `caffeinate -i`: the screen still turns off on its normal timer, but the Mac keeps running. Turn on Keep screen on while staying awake in Settings > Stay Awake to keep the screen on too (like `caffeinate -d`). Closing the lid still puts the Mac to sleep in this mode.

Stay Awake (Ignore Lid) uses `pmset disablesleep`, so nothing puts the Mac to sleep until you leave the mode. Redeye always turns sleep back on when you switch modes, when a timed session ends, when you quit, and even if Redeye crashes or is force-quit. A Mac in a bag can get warm, so this mode ends after 24 hours by default, and Settings > Safety can end it early when the battery is low or the Mac gets too hot. Claude also needs a network connection to keep working, for example your phone's hotspot. A critically low battery still shuts the Mac down.

## License

MIT. See [LICENSE](LICENSE).
