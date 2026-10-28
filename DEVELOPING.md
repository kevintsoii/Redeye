# Developing Redeye

## Requirements

- macOS 13 or later
- Xcode 26 or later

## Stack

- Swift 6, AppKit (no SwiftUI)
- Xcode project with an app target (`Redeye`, macOS 13+) and a hosted unit-test target (`RedeyeTests`, macOS 14+ because XCTest requires it)
- Apple frameworks only: AppKit, IOKit (power assertions), ServiceManagement (Launch at Login)
- No third-party dependencies

## Project layout

```
Redeye.xcodeproj/        project and shared "Redeye" scheme
Redeye/
  main.swift            app startup
  AppDelegate.swift     menu bar icon, menu, actions
  SettingsWindowController.swift  Settings window (General, About tabs)
  SleepPreventer.swift  IOKit power assertion and timer
  Assets.xcassets/      app icon
RedeyeTests/            unit tests (XCTest)
  SleepPreventerTests.swift            power assertion and timer
  AppDelegateTests.swift               menu, menu actions, status icon, quitting
  SettingsWindowControllerTests.swift  Settings window, tabs, About version
  TestHelpers.swift                    shared helpers (reading assertions from powerd, view search)
```

`Redeye/` and `RedeyeTests/` are synchronized folders: files added there are picked up by Xcode automatically. There's no Info.plist file; its values live in the target's build settings (`INFOPLIST_KEY_*`).

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

Possible things to check by hand before a release:

1. Left-click the icon. It should switch to the filled icon.
2. Run `pmset -g assertions`. Redeye should be listed under `PreventUserIdleSystemSleep`.

## Release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the target's build settings (app and test targets).
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
