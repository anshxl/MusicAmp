import AppKit
import MusicControl

/// The equalizer and playlist windows.
extension AppController {
    var isEqualizerVisible: Bool { eqPanel.isVisible }
    var isPlaylistVisible: Bool { plPanel.isVisible }

    @objc func toggleEqualizer() { toggle(eqPanel, key: "eqVisible") }

    @objc func togglePlaylist() {
        toggle(plPanel, key: "plVisible")
        if isPlaylistVisible { refreshPlaylist(force: true) }
    }

    private func toggle(_ panel: SkinPanel, key: String) {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        defaults.set(panel.isVisible, forKey: key)
        mainNeedsDisplay() // EQ/PL button lights
    }

    // MARK: Equalizer

    func setEqualizer(slider: Int, to dB: Double) {
        if slider == 0 { eqSettings.preamp = dB } else { eqSettings.bands[slider - 1] = dB }
        applyEqualizer()
    }

    func equalizerAction(_ hit: EqualizerView.Hit, in view: EqualizerView) {
        switch hit {
        case .close: toggleEqualizer()
        case .shade: toggleShade(view)
        case .on:
            eqSettings.enabled.toggle()
            applyEqualizer()
            if eqSettings.enabled, tapHasOutput == false, MusicPlayer.isRunning {
                explain("The equalizer cannot reach your output device.",
                        "MusicAmp plays Music's audio through the current output device. It could not use that device "
                            + "(AirPlay devices are not supported), so Music plays without the equalizer.")
            }
        case .auto:
            eqSettings.autoHeadroom.toggle()
            applyEqualizer()
        case .presets:
            let menu = NSMenu()
            menu.addItem(withTitle: "Flat", action: #selector(loadFlatPreset), keyEquivalent: "").target = self
            let names = MusicPlayer.isRunning ? (try? Equalizer.presetNames()) ?? [] : []
            if !names.isEmpty {
                menu.addItem(.separator())
                menu.addItem(withTitle: "From Music:", action: nil, keyEquivalent: "").isEnabled = false
                for name in names {
                    menu.addItem(withTitle: name, action: #selector(loadMusicPreset(_:)), keyEquivalent: "").target = self
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 217 * view.scale, y: 30 * view.scale), in: view)
        case .slider: break
        }
    }

    @objc private func loadFlatPreset() {
        eqSettings.preamp = 0
        eqSettings.bands = Array(repeating: 0, count: 10)
        applyEqualizer()
    }

    /// Copies a Music preset's values. Music's bands are 32 Hz…16 kHz, Winamp's 60 Hz…16 kHz;
    /// like Winamp, the 10 sliders map one to one.
    @objc private func loadMusicPreset(_ item: NSMenuItem) {
        guard let p = try? Equalizer.preset(named: item.title) else { return }
        eqSettings.preamp = p.preamp
        eqSettings.bands = p.bands
        applyEqualizer()
    }

    func explain(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Playlist

    /// Persistent ID of the playlist the window shows, or nil to follow Music's now-playing playlist.
    var chosenPlaylistID: String? { defaults.string(forKey: "plSource") }

    /// Refetches the track list only when the shown playlist changes; the current-track marker is
    /// updated on every call. Costs 2 Apple Events when nothing changed.
    func refreshPlaylist(force: Bool = false) {
        guard isPlaylistVisible, MusicPlayer.isRunning else { return }
        let nowPlaying = try? MusicPlayer.playlistState()
        guard let shownID = chosenPlaylistID ?? nowPlaying?.id else { return plView.currentIndex = nil }
        if force || shownID != lastPlaylistID {
            // ponytail: synchronous on main (about 270 ms for 1300 tracks); move off main if big playlists stutter
            plView.tracks = (try? MusicPlayer.tracks(ofPlaylist: shownID)) ?? []
            lastPlaylistID = shownID
        }
        plView.currentIndex = nowPlaying?.id == shownID ? nowPlaying!.index - 1 : nil
    }

    func playPlaylistTrack(_ index: Int) {
        guard let id = lastPlaylistID else { return }
        run { try MusicPlayer.playTrack(at: index + 1, ofPlaylist: id) }
    }

    /// "Now Playing" plus the library and every playlist, for the LIST button and the context menu.
    func playlistSourceMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, id: String?) {
            let item = menu.addItem(withTitle: title, action: #selector(choosePlaylistSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = id == chosenPlaylistID ? .on : .off
        }
        add("Now Playing", id: nil)
        menu.addItem(.separator())
        let lists = MusicPlayer.isRunning ? (try? MusicPlayer.playlists()) ?? [] : []
        for p in lists { add(p.name, id: p.id) }
        return menu
    }

    @objc private func choosePlaylistSource(_ item: NSMenuItem) {
        defaults.set(item.representedObject as? String, forKey: "plSource")
        if !isPlaylistVisible { togglePlaylist() } else { refreshPlaylist(force: true) }
    }
}
