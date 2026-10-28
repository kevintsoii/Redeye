# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- MIT license.
- `redeye://` URL scheme for scripts and the terminal: `open -g redeye://activate`, `redeye://deactivate` and `redeye://toggle`. `activate` takes optional `seconds`, `minutes` and `hours` (e.g. `redeye://activate?hours=2`).
- Only one copy of Redeye runs at a time. Opening a second copy quits it, so there's never a second menu bar icon.
- Stay Awake (Ignore Lid): a second mode that stops your Mac sleeping even when you close the lid or choose Apple menu > Sleep, for keeping Claude running in a bag. Uses a small helper that runs as administrator (`pmset disablesleep`), which you approve once in System Settings > General > Login Items & Extensions. Sleep is always turned back on when you leave the mode, quit Redeye, or if Redeye crashes or is force-quit.
- Left-click now steps through three modes: Sleep Normally (outline sun), Stay Awake (yellow sun), Stay Awake (Ignore Lid) (red sun).
- Stay Awake (Ignore Lid) submenu with the same durations as Stay Awake.
- Keep screen on while staying awake setting in a new Stay Awake tab in Settings: keeps the screen on too, like `caffeinate -d`. Off by default.
- `lid=1` parameter for the URL scheme: `open -g "redeye://activate?lid=1"`.
- Default durations for left-click in Settings > Stay Awake: Forever for Stay Awake, 24 hours for Stay Awake (Ignore Lid).
- Safety tab in Settings: let the Mac sleep when the battery is low or the Mac gets too hot. Both off by default.

## [1.0.0] - 2026-10-27

### Added

- Menu bar app with a sunrise icon that fills in while the Mac is being kept awake. No Dock icon.
- Left-click to toggle, right-click or Ctrl-click to open the menu.
- Keeps the Mac running while letting the screen turn off (like `caffeinate -i`).
- Keep Awake durations in the menu: Forever, 30 Minutes, 1 Hour, 6 Hours, 12 Hours, 24 Hours.
- Allow Sleep menu item to end a session early.
- Status line in the menu ("Sleep allowed", "Awake indefinitely" or "Awake until 3:45 PM") and a tooltip on the icon.
- Sleep is allowed again when a timed session ends, when you quit Redeye, or if it crashes.
- Settings window (⌘,) with General (Launch at Login) and About (version) tabs.
- App icon: a red sun on the horizon at night.
- Xcode project (`Redeye.xcodeproj`) to build and ad-hoc sign `Redeye.app`, with unit tests.
