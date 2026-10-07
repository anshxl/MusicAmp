import AppKit

if CommandLine.arguments.contains("--selftest") {
    do { try skinSelfTest(defaultSkinURL: AppController.defaultSkinURL) } catch { print("selftest failed: \(error)"); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory) // no Dock icon; the panel never steals focus
app.run()
