import AppKit

if SingleInstance.shouldQuit() {
    NSLog("Redeye: another copy is already running, quitting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
