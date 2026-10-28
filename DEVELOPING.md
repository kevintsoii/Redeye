# Developing Redeye

Swift 6 and AppKit, macOS 13+ (tests need 14+), Xcode 26+. Apple frameworks only, no third-party dependencies.

## Layout

```
Redeye/                  app (synchronized folder: new files are picked up automatically)
  AppDelegate.swift      menu bar icon, menu, URL handling, alerts
  SettingsWindowController.swift  General, Stay Awake, Safety and About tabs
  SleepPreventer.swift   the three modes, power assertion, timer, default durations, Safety cutoffs
  PowerMonitor.swift     battery, power source and thermal state
  Notifier.swift         notifications when a mode ends on its own
  LidSleepHelper.swift   registers and talks to the privileged helper
  URLCommand.swift       parses redeye:// URLs
  SingleInstance.swift   quits a second copy at launch
  Info.plist             URL scheme only; the rest comes from INFOPLIST_KEY_* build settings
RedeyeHelper/            root launchd daemon that runs `pmset -a disablesleep` (add files to the target by hand)
Shared/                  XPC protocol and helper bookkeeping, shared with the helper and tests
RedeyeTests/             XCTest, hosted in the app
```

The app embeds `RedeyeHelper` in `Contents/MacOS` and its launchd plist in `Contents/Library/LaunchDaemons`.

## Build, run, test

```sh
xcodebuild -project Redeye.xcodeproj -scheme Redeye -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Redeye.app

killall Redeye; xcodebuild -project Redeye.xcodeproj -scheme Redeye -derivedDataPath build test
```

Or ⌘R / ⌘U in Xcode. CI (`.github/workflows/ci.yml`) runs the tests and a Release build on every push to `main` and every PR.

Tests use fakes (`FakeSleepDisabler`, `FakePowerMonitor`, `FakeNotifier`), so they never touch the real `disablesleep`, battery or Notification Center.

With the repo in `~/Desktop`, macOS may ask whether Redeye can access the Desktop folder when tests run. That's the Debug test host reading its build products, and it asks again after rebuilds because ad-hoc signatures change. Allow it, or keep the repo outside Desktop, Documents and Downloads.

Launch at Login only works reliably from `/Applications`.

## How it works

**Modes.** `SleepPreventer` holds a `PreventUserIdleSystemSleep` assertion (`PreventUserIdleDisplaySleep` with Keep screen on) for Stay Awake, plus `disablesleep` through the helper for Stay Awake (Ignore Lid).

**Durations.** Left-click and URLs without a time use `defaultDuration(for:)`, saved per mode in seconds (0 is Forever). Defaults are Forever for Stay Awake and 24 hours for Ignore Lid.

**Safety.** The battery and heat cutoffs are checked when a mode starts and whenever `PowerMonitor` reports a change. The battery cutoff only applies on battery power.

**Errors and notifications.** If a mode can't start (helper not approved, a cutoff already applies), `onError` reports it and the app shows an alert. If a running mode ends on its own (timer, cutoff, helper lost), `onAutoStop` reports an `AutoStop` and the app posts a notification. Redeye asks for notification permission the first time a mode starts.

**Single copy.** A second copy quits at launch. Running tests registers the Debug build with LaunchServices, so `redeye://` URLs can go to that copy and get lost. Fix it with:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u build/Build/Products/Debug/Redeye.app
```

## The helper

`RedeyeHelper` is registered with `SMAppService.daemon`. The user approves it once in Login Items & Extensions. The app talks to it over XPC (`com.kevin.redeye.helper`), and it only accepts clients signed as `com.kevin.redeye`. Once releases are Developer ID signed, add the team ID to `clientRequirement` in `RedeyeHelper/main.swift`.

`disablesleep` outlives the app, so the helper resets it to 0 at these times:
- when asked
- when the app's connection drops
- when the helper starts (at boot, and after a crash)
- on SIGTERM
- before exiting when idle

The logic lives in `Shared/HelperSleepState.swift` and is tested by `HelperSleepStateTests`.

Gotchas:
- launchd only runs the helper build that was registered (otherwise `spawn failed`, exit 78, `needs LWCR update`). Redeye re-registers when the helper's code hash changes, so ad-hoc rebuilds keep working without re-approval.
- Stale LaunchServices entries for deleted copies of Redeye can break it ("Could not find and/or execute program"). Find them with `lsregister -dump | grep -i 'path:.*Redeye.app'` and remove them with `lsregister -u <path>`.
- Logs: `/usr/bin/log show --predicate 'process == "RedeyeHelper"' --last 1h`. Use the full path, because `log` is a zsh builtin.
- Manual reset: `sudo pmset -a disablesleep 0`.

## Manual checks before a release

1. Left-click three times: yellow, red, outline.
2. Yellow: `pmset -g assertions` lists Redeye. Red: `pmset -g | grep SleepDisabled` shows 1.
3. In red, `killall -9 Redeye`, Quit, a timer ending and switching modes each bring `SleepDisabled` back to 0, with no Redeye assertion left.
4. `open -g "redeye://activate?seconds=10"`: the icon turns yellow, then back, and a "Stay Awake ended" notification appears.
5. With the battery cutoff set above the current charge and the charger unplugged, Stay Awake is refused with an alert. Unplugging the charger mid-session ends it with a notification instead.
6. Opening a second copy quits it right away.

## Release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in all three targets.
2. Date the `[Unreleased]` heading in `CHANGELOG.md` and start a new one.
3. Run the tests and the manual checks.
4. Archive with a Developer ID team set (Product > Archive > Distribute App > Direct Distribution). Hardened runtime is already on.
5. Notarize, staple and zip:

   ```sh
   xcrun notarytool store-credentials redeye-notary --apple-id <apple-id> --team-id <team-id>  # once
   ditto -c -k --keepParent Redeye.app Redeye.zip
   xcrun notarytool submit Redeye.zip --keychain-profile redeye-notary --wait
   xcrun stapler staple Redeye.app
   ditto -c -k --keepParent Redeye.app Redeye-<version>.zip
   ```

6. `spctl -a -vv Redeye.app` should say `source=Notarized Developer ID`. Upload the zip to a GitHub Release with the changelog section as notes.

Until then, builds are ad-hoc signed and Gatekeeper blocks them on other Macs.
