# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - Unreleased

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
