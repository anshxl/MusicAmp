import AppKit
import ServiceManagement

/// Menu-bar item, global show/hide hotkey, and launch at login.
extension AppController: NSMenuDelegate {
    static let defaultHotKey = "ctrl+option+w"
    /// Change with: defaults write local.musicamp hotkey "cmd+shift+m"
    var hotKeySpec: String { defaults.string(forKey: "hotkey") ?? Self.defaultHotKey }

    func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicAmp")
        image?.isTemplate = true
        statusItem?.button?.image = image
        let menu = NSMenu()
        menu.delegate = self // rebuilt each time it opens, so titles and checkmarks are current
        statusItem?.menu = menu

        hotKey = HotKey(hotKeySpec) { [weak self] in self?.toggleWindows() }
        if hotKey == nil { NSLog("MusicAmp: hotkey \"\(hotKeySpec)\" is invalid or taken") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        let hint = hotKey == nil ? "" : "  \(HotKey.symbols(hotKeySpec))"
        add((areWindowsShown ? "Hide MusicAmp" : "Show MusicAmp") + hint, #selector(toggleWindows))
        menu.addItem(.separator())
        add("Play/Pause", #selector(menuPlayPause))
        add("Previous", #selector(menuPrevious))
        add("Next", #selector(menuNext))
        menu.addItem(.separator())
        let shared = contextMenu() // skins, scale, windows, visualizer, login, quit
        let items = shared.items
        shared.removeAllItems()
        items.forEach(menu.addItem)
    }

    @objc private func menuPlayPause() { perform(.pause) }
    @objc private func menuPrevious() { perform(.previous) }
    @objc private func menuNext() { perform(.next) }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            explain("Could not change Launch at Login.", "\(error.localizedDescription)\n\nMusicAmp may need to be in the Applications folder.")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
