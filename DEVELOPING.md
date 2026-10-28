# Developing Redeye

## Requirements

- macOS 13 or later
- Xcode 26 or later

## Stack

- Swift 6, AppKit (no SwiftUI)
- Xcode project with an app target (`Redeye`, macOS 13+) and a hosted unit-test target (`RedeyeTests`, macOS 14+ because XCTest requires it)
- Apple frameworks only: AppKit, IOKit (power assertions), ServiceManagement (Launch at Login, the privileged helper), XPC (`NSXPCConnection`)
- A second target, `RedeyeHelper`: a command-line tool embedded in the app that runs as root for Stay Awake (Ignore Lid)
- No third-party dependencies

## Project layout

```
Redeye.xcodeproj/        project and shared "Redeye" scheme
Redeye/
  main.swift            app startup
  AppDelegate.swift     menu bar icon, menu, actions
  SettingsWindowController.swift  Settings window (General, Stay Awake, About tabs)
  SleepPreventer.swift  sleep modes, IOKit power assertion and timer
  LidSleepHelper.swift  registers and talks to the privileged helper
  URLCommand.swift      parses redeye:// URLs
  SingleInstance.swift  quits a second copy at launch
  Info.plist            only the URL scheme; everything else is generated
  Assets.xcassets/      app icon
RedeyeHelper/           privileged helper (regular group: add new files to the target by hand)
  main.swift            XPC listener that runs `pmset -a disablesleep` as root
  com.kevin.redeye.helper.plist  launchd plist, copied to Contents/Library/LaunchDaemons
Shared/
  HelperProtocol.swift  XPC protocol, compiled into both the app and the helper
  HelperSleepState.swift  the helper's bookkeeping, compiled into the helper and the tests
RedeyeTests/            unit tests (XCTest)
  SleepPreventerTests.swift            modes, power assertion, timer, helper requests, Keep screen on
  HelperSleepStateTests.swift          the helper's bookkeeping: disconnects, retries, failed pmset
  AppDelegateTests.swift               menu, menu actions, URL handling, status icon, quitting
  URLCommandTests.swift                URL parsing, scheme registration
  SingleInstanceTests.swift            finding other running copies
  SettingsWindowControllerTests.swift  Settings window, tabs, Keep screen on, About version
  TestHelpers.swift                    shared helpers (reading assertions from powerd, view search, fake helper)
```

The app target embeds `RedeyeHelper` in `Contents/MacOS` and the launchd plist in `Contents/Library/LaunchDaemons` with two Copy Files build phases.

`Redeye/` and `RedeyeTests/` are synchronized folders: files added there are picked up by Xcode automatically. Most Info.plist values live in the target's build settings (`INFOPLIST_KEY_*`). `Redeye/Info.plist` holds only `CFBundleURLTypes`, which has no build setting; Xcode merges it into the generated plist. It's excluded from the synchronized folder's resources so it isn't copied twice.

## Build and run

In Xcode: open `Redeye.xcodeproj` and press ⌘R. The app runs in the menu bar only, with no Dock icon or window.

From the terminal:

```sh
xcodebuild -project Redeye.xcodeproj -scheme Redeye -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Redeye.app
```

Launch at Login only works reliably when the app is in `/Applications`.

## Test

Unit tests live in `RedeyeTests/` (XCTest, hosted in the app). Quit Redeye first, then run them in Xcode with ⌘U, or:

```sh
killall Redeye; xcodebuild -project Redeye.xcodeproj -scheme Redeye -derivedDataPath build test
```

GitHub Actions (`.github/workflows/ci.yml`) runs the same tests plus a Release build on a `macos-26` runner for every push to `main` and every pull request. When a run fails, the `.xcresult` bundle is uploaded as an artifact.

Tests use `FakeSleepDisabler` in place of the helper, so they never change the real `disablesleep`.

Possible things to check by hand before a release:

1. Left-click the icon three times. It should go yellow, red, then back to the outline.
2. In the yellow mode, run `pmset -g assertions`. Redeye should be listed under `PreventUserIdleSystemSleep` (`PreventUserIdleDisplaySleep` with Keep screen on).
3. In the red mode, `pmset -g | grep SleepDisabled` should show 1. Run `killall -9 Redeye`; within a couple of seconds it should be back to 0. Repeat with Quit Redeye from the menu, `kill -TERM`, `kill -SEGV`, a timed session ending, and switching to another mode; each should leave `SleepDisabled` at 0 and no Redeye entry in `pmset -g assertions`.
4. Run `open -g "redeye://activate?minutes=5"`, `open -g redeye://toggle` and `open -g redeye://deactivate` and check the icon each time.
5. Open a second copy (`build/Build/Products/Release/Redeye.app/Contents/MacOS/Redeye`). It should quit right away with "another copy is already running".

## Single copy and the URL scheme

`main.swift` quits at launch if another app with the same bundle ID is running (skipped when hosting unit tests). Running tests registers the Debug build with LaunchServices, and `redeye://` URLs may then go to the Debug copy, which quits because the Release copy is already running, so the URL is lost. If URLs stop working, unregister the Debug build:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u build/Build/Products/Debug/Redeye.app
```

## Stay Awake (Ignore Lid) and the helper

Blocking lid-close sleep needs `pmset -a disablesleep 1`, which needs root, so `RedeyeHelper` runs as a launchd daemon registered with `SMAppService.daemon(plistName:)`. The first registration puts it in System Settings > General > Login Items & Extensions, where the user must allow it; until then Redeye shows an alert and falls back to allowing sleep.

The app connects over XPC (`NSXPCConnection`, Mach service `com.kevin.redeye.helper`) and asks it to turn `disablesleep` on or off. `disablesleep` is a persistent system setting that outlives Redeye, so the helper resets it to 0:

- when the app asks (leaving the mode, timer expiry, quitting),
- when the app's XPC connection drops (crash, force-quit),
- when the helper starts (`RunAtLoad`, so at every boot; also after a helper crash, since `KeepAlive` restarts it on a non-zero exit),
- on SIGTERM.

It exits after 10 seconds with no connections, resetting once more first; launchd starts it again on demand. The bookkeeping (who holds sleep off, retries, failed `pmset`) lives in `Shared/HelperSleepState.swift`, which is compiled into the helper and the test target and covered by `HelperSleepStateTests`.

launchd only runs the exact helper build that was registered; any other build fails to spawn (`launchctl print system/com.kevin.redeye.helper` shows `spawn failed`, exit 78, `needs LWCR update`). Ad-hoc builds change on every build, so Redeye stores the helper's code hash at registration and, at launch and before entering Ignore Lid, unregisters and registers again when it differs. No re-approval is needed. Re-registering reloads the helper, which resets `disablesleep` as it starts.

launchd finds the helper through the app's bundle ID, so stale LaunchServices entries for deleted copies of Redeye (old clones, worktrees) can also make it fail with "Could not find and/or execute program". List them with `lsregister -dump | grep -i 'path:.*Redeye.app'` and remove dead ones with `lsregister -u <path>`.

Logs: `/usr/bin/log show --predicate 'process == "RedeyeHelper"' --last 1h` (in zsh, plain `log` is a shell builtin).

The helper only accepts connections from code signed with the identifier `com.kevin.redeye`. Once releases are Developer ID signed, tighten `clientRequirement` in `RedeyeHelper/main.swift` to also require the team ID.

To reset by hand during development: `sudo pmset -a disablesleep 0`. To unregister the helper, turn Redeye off in Login Items & Extensions.

## Release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the build settings of all three targets (app, helper, tests).
2. In `CHANGELOG.md`, replace `Unreleased` in the version heading with the release date (`YYYY-MM-DD`). Later changes go in a new `## [Unreleased]` section at the top.
3. Run the tests and the manual checks above.
4. Archive and export with Developer ID: in Xcode, set the team under Signing & Capabilities, run Product > Archive, then Distribute App > Direct Distribution. Hardened runtime is already on.
5. Notarize and staple:

   ```sh
   # one time: store credentials (use an app-specific password)
   xcrun notarytool store-credentials redeye-notary --apple-id <apple-id> --team-id <team-id>

   ditto -c -k --keepParent Redeye.app Redeye.zip
   xcrun notarytool submit Redeye.zip --keychain-profile redeye-notary --wait
   xcrun stapler staple Redeye.app
   ditto -c -k --keepParent Redeye.app Redeye-<version>.zip   # re-zip the stapled app
   ```

6. Check it: `spctl -a -vv Redeye.app` should say `source=Notarized Developer ID`.
7. Upload the zip to a GitHub Release, with the changelog section as the notes.

Until a Developer ID team is set, builds are ad-hoc signed and Gatekeeper will block them on other Macs.
