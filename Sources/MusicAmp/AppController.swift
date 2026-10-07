import AppKit
import AudioTap
import CoreAudio
import MusicControl
import os
import UniformTypeIdentifiers

/// The latest `Spectrum.size` mono samples, written on the real-time audio thread and read by the
/// 30 fps frame timer on main. Fixed buffer, no allocation; the audio thread never waits for the lock.
final class SampleRing: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Spectrum.size)
    private var next = 0, filled = 0

    deinit { buffer.deallocate() }

    /// Audio thread: appends the mono mix of the tap's interleaved stereo. Skips the buffer if main holds the lock.
    func append(stereo input: UnsafePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = ins.first, first.mNumberChannels == 2,
              let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        nonisolated(unsafe) let p = data // only used inside this call
        let frames = Int(first.mDataByteSize) / (2 * MemoryLayout<Float>.size)
        lock.withLockIfAvailable {
            for f in 0..<frames {
                buffer[next] = (p[2 * f] + p[2 * f + 1]) * 0.5
                next = (next + 1) % Spectrum.size
            }
            filled = min(Spectrum.size, filled + frames)
        }
    }

    func snapshot() -> [Float]? {
        lock.withLock { filled == Spectrum.size ? (0..<Spectrum.size).map { buffer[(next + $0) % Spectrum.size] } : nil }
    }

    func clear() { lock.withLock { filled = 0 } }
}

final class AppController: NSObject, NSApplicationDelegate {
    private static let musicBundleID = "com.apple.Music"
    static let defaultSkinURL = Bundle.main.url(forResource: "base-2.91", withExtension: "wsz")
        ?? URL(fileURLWithPath: #filePath) // `swift run` without an app bundle: use the source tree copy
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/base-2.91.wsz")

    let defaults = UserDefaults.standard
    private var defaultSkin: Skin!
    private var panel: SkinPanel!
    private var view: MainView!
    var eqPanel: SkinPanel!
    var eqView: EqualizerView!
    var plPanel: SkinPanel!
    var plView: PlaylistView!
    var lastPlaylistID: String?
    private var skinViews: [SkinView] { [view, eqView, plView] }
    private var observer: PlayerInfoObserver?
    private var poller: PositionPoller!
    private var frameTimer: Timer?
    private var tap: ProcessTap?
    private var tapStarting = false
    /// False when the tap could not include the output device (for example AirPlay): visualizer only, no EQ.
    private(set) var tapHasOutput = false
    private(set) var sampleRate = 48_000.0
    private let ring = SampleRing()
    let eqDSP = EqualizerDSP()
    var eqSettings = EqualizerDSP.Settings()
    private static let frameNames = ["MusicAmpMain", "MusicAmpEQ", "MusicAmpPL"]
    var statusItem: NSStatusItem?
    var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            defaultSkin = try Skin(url: Self.defaultSkinURL, fallback: nil)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
        let saved = defaults.string(forKey: "skinPath").flatMap { try? Skin(url: URL(fileURLWithPath: $0), fallback: defaultSkin) }
        let mode = Visualizer.Mode(rawValue: defaults.integer(forKey: "visualizerMode")) ?? .thickBars
        let skin = saved ?? defaultSkin!
        view = MainView(skin: skin, visualizer: Visualizer(mode: mode))
        eqView = EqualizerView(skin: skin)
        plView = PlaylistView(skin: skin)
        panel = SkinPanel(size: MainView.size)
        eqPanel = SkinPanel(size: EqualizerView.size)
        plPanel = SkinPanel(size: PlaylistView.size)
        for (p, v) in [(panel!, view as SkinView), (eqPanel!, eqView!), (plPanel!, plView!)] {
            p.contentView = v
            v.controller = self
        }

        // Restore saved positions; on first launch stack EQ and playlist under the main window, like Winamp.
        // Set autosave names right after restoring: setting one later re-applies the saved position.
        let restored = zip([panel!, eqPanel!, plPanel!], Self.frameNames).map { p, name in
            defer { p.setFrameAutosaveName(name) }
            return p.setFrameUsingName(name)
        }
        if !restored[0] { panel.center() }
        for (v, key) in shadeKeys { v.isShaded = defaults.bool(forKey: key) }
        applyScale(min(3, max(1, defaults.integer(forKey: "scale"))), keepDocked: false)
        if !restored[1] { eqPanel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: panel.frame.minY)) }
        if !restored[2] { plPanel.setFrameTopLeftPoint(NSPoint(x: eqPanel.frame.minX, y: eqPanel.frame.minY)) }
        panel.orderFrontRegardless()

        setUpMenuBar()
        observer = PlayerInfoObserver { [weak self] in self?.trackChanged($0) }
        poller = PositionPoller { [weak self] s in
            guard let self else { return }
            view.status = s
            if eqView.isShaded { eqView.needsDisplay = true } // its volume slider
            if view.track.state != .stopped { plView.elapsed = s.position }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        eqSettings = defaults.data(forKey: "equalizer").flatMap { try? JSONDecoder().decode(EqualizerDSP.Settings.self, from: $0) }
            ?? EqualizerDSP.Settings()
        applyEqualizer()
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main) { [weak self] _, _ in
            self?.restartTap() // the aggregate device contains the old output device
        }
        if MusicPlayer.isRunning, let t = try? MusicPlayer.current() { trackChanged(t) }
        if defaults.bool(forKey: "eqVisible") { toggleEqualizer() }
        if defaults.bool(forKey: "plVisible") { togglePlaylist() }
        visibilityChanged()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { // let the tap and a few frames run
                for (name, p) in zip(Self.frameNames, [self.panel!, self.eqPanel!, self.plPanel!]) {
                    print(name, p.isVisible ? "visible" : "hidden", NSStringFromRect(p.frame))
                }
                do {
                    try snapshot(self.view, to: args[i + 1])
                    for (v, suffix) in [(self.eqView!, "-eq"), (self.plView!, "-pl")] as [(SkinView, String)] where v.window?.isVisible == true {
                        try snapshot(v, to: args[i + 1].replacingOccurrences(of: ".png", with: "\(suffix).png"))
                    }
                } catch { NSLog("snapshot failed: \(error)") }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindows()
        return true
    }

    // Private taps and aggregate devices are owned by this process; Core Audio also removes them if we crash.
    func applicationWillTerminate(_ notification: Notification) { tap?.stop() }

    // MARK: Music state

    private func trackChanged(_ t: TrackInfo) {
        let newTrack = t.name != view.track.name || t.album != view.track.album
        view.track = t
        refreshPlaylist()
        guard t.state != .stopped else { return plView.elapsed = nil }
        if newTrack { view.format = (try? MusicPlayer.audioFormat()) ?? (0, 0) }
        if view.format.hz == 0 { view.format.hz = Int(sampleRate) }
        startTap()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == Self.musicBundleID else { return }
        tap?.stop()
        tap = nil
        ring.clear()
        view.track.state = .stopped
        plView.elapsed = nil
    }

    /// One tap feeds both the visualizer and the EQ. It sits in an aggregate device together with the
    /// default output device: the render block reads Music's audio and writes the EQ'd audio in the same
    /// IO cycle. With the EQ on, the tap mutes Music's own output; with it off, the block writes silence.
    /// Creation can block for seconds (TCC check), so it runs off the main thread.
    private func startTap() {
        guard tap == nil, !tapStarting,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).first?.processIdentifier
        else { return }
        tapStarting = true
        let ring = self.ring, dsp = eqDSP, muted = eqSettings.enabled
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (ProcessTap, Bool)? in
                guard let process = try audioProcessObject(pid: pid) else { return nil }
                do {
                    let tap = try ProcessTap(process: process, outputDeviceUID: try defaultOutputDeviceUID(), muted: muted) { input, output in
                        ring.append(stereo: input)
                        dsp.render(input: input, output: output)
                    }
                    return (tap, true)
                } catch {
                    NSLog("MusicAmp: EQ output unavailable (\(error)); visualizer only")
                    return (try ProcessTap(process: process, outputDeviceUID: nil) { input, _ in ring.append(stereo: input) }, false)
                }
            }
            DispatchQueue.main.async {
                self.tapStarting = false
                switch result {
                case .success(let (tap, hasOutput)?):
                    self.tap = tap
                    self.tapHasOutput = hasOutput
                    self.sampleRate = tap.format.mSampleRate
                    self.applyEqualizer() // the tap's rate, and any ON/OFF change made while it was starting
                case .success(nil): break // Music has not played audio yet; retried on the next notification
                case .failure(let error): NSLog("MusicAmp: audio tap failed: \(error)")
                }
            }
        }
    }

    /// Rebuilds the tap, for example after the default output device changes.
    private func restartTap() {
        tap?.stop()
        tap = nil
        ring.clear()
        if MusicPlayer.isRunning { startTap() }
    }

    /// Sends `eqSettings` to the audio thread, matches the tap's mute to it, and saves it.
    func applyEqualizer() {
        let wantMuted = eqSettings.enabled && tapHasOutput
        if !wantMuted { try? tap?.setMuted(false) } // unmute before the DSP stops writing: no gap
        eqDSP.update(eqSettings, sampleRate: sampleRate)
        if wantMuted { try? tap?.setMuted(true) } // mute after the DSP starts writing
        eqView.settings = eqSettings
        defaults.set(try? JSONEncoder().encode(eqSettings), forKey: "equalizer")
    }

    // MARK: Visibility-gated timers

    @objc private func visibilityChanged() {
        if panel.occlusionState.contains(.visible) {
            poller.start()
            if frameTimer == nil {
                frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.frame() }
            }
        } else {
            poller.stop()
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private func frame() {
        let playing = view.track.state == .playing
        view.visualizer.update(samples: playing ? ring.snapshot() : nil, sampleRate: sampleRate)
        view.advance()
    }

    // MARK: Actions from the view

    func run(_ command: () throws -> Void) {
        do { try command() } catch { NSLog("MusicAmp: \(error)") }
    }

    func perform(_ control: Control) {
        switch control {
        case .previous: run(MusicPlayer.previous)
        case .play: run(MusicPlayer.play)
        case .pause: run(MusicPlayer.playPause)
        case .stop: run(MusicPlayer.stop)
        case .next: run(MusicPlayer.next)
        case .eject: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        case .shuffle:
            view.status.shuffle.toggle()
            run { try MusicPlayer.setShuffle(view.status.shuffle) }
        case .repeatButton:
            view.status.repeatMode = view.status.repeatMode == .off ? .all : .off
            run { try MusicPlayer.setRepeat(view.status.repeatMode) }
        case .options:
            contextMenu().popUp(positioning: nil, at: NSPoint(x: 6 * view.scale, y: 12 * view.scale), in: view)
        case .minimize: hideWindows() // back with the hotkey, the menu-bar item, or by launching MusicAmp again
        case .close: NSApp.terminate(nil)
        case .eq: toggleEqualizer()
        case .playlist: togglePlaylist()
        case .shade: toggleShade(view)
        case .doubleSize: toggleDoubleSize()
        default: break
        }
    }

    func seek(to seconds: Double) {
        view.status.position = seconds
        run { try MusicPlayer.seek(to: seconds) }
    }

    func mainNeedsDisplay() { view.needsDisplay = true }

    /// Music's volume as last polled (0…100), for the EQ window's shade slider.
    var volume: Int { view.status.volume }

    func setVolume(_ v: Int) {
        view.status.volume = v // show it now, not at the next volume poll
        run { try MusicPlayer.setVolume(v) }
    }

    func visualizerModeChanged() {
        defaults.set(view.visualizer.mode.rawValue, forKey: "visualizerMode")
        view.needsDisplay = true
    }

    // MARK: Skins, scale, menu

    func loadSkin(_ url: URL) {
        do {
            setSkin(try Skin(url: url, fallback: defaultSkin))
            defaults.set(url.path, forKey: "skinPath")
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    private func setSkin(_ skin: Skin) {
        for v in skinViews { v.skin = skin }
    }

    // MARK: Shade, double size, show/hide

    private var shadeKeys: [(SkinView, String)] { [(view, "shadeMain"), (eqView, "shadeEQ"), (plView, "shadePL")] }

    /// Folds or unfolds a window from its top edge. Windows docked below it move with its bottom edge,
    /// as in Winamp, so the stack stays together.
    func toggleShade(_ v: SkinView) {
        guard let p = v.window else { return }
        let others: [SkinPanel] = [panel, eqPanel, plPanel].filter { $0 !== p }
        let below = SkinPanel.dockedGroup(p.frame, others.map(\.frame)).map { others[$0] }.filter { $0.frame.maxY <= p.frame.minY + 1 }
        let oldHeight = p.frame.height
        v.isShaded.toggle()
        let height = v.currentSize.height * v.scale
        p.setFrame(NSRect(x: p.frame.minX, y: p.frame.maxY - height, width: p.frame.width, height: height), display: true)
        for w in below { w.setFrameOrigin(NSPoint(x: w.frame.minX, y: w.frame.minY + oldHeight - height)) }
        if let key = shadeKeys.first(where: { $0.0 === v })?.1 { defaults.set(v.isShaded, forKey: key) }
    }

    /// Winamp's double size: 1× ↔ 2× (from 3×, back to 1×).
    @objc func toggleDoubleSize() { applyScale(view.scale == 1 ? 2 : 1) }

    var areWindowsShown: Bool { panel.isVisible }

    @objc func toggleWindows() { areWindowsShown ? hideWindows() : showWindows() }

    /// Hides every window; "eqVisible"/"plVisible" keep what to bring back.
    func hideWindows() { for p in [panel!, eqPanel!, plPanel!] { p.orderOut(nil) } }

    func showWindows() {
        panel.orderFrontRegardless()
        if defaults.bool(forKey: "eqVisible") { eqPanel.orderFrontRegardless() }
        if defaults.bool(forKey: "plVisible") { plPanel.orderFrontRegardless(); refreshPlaylist(force: true) }
    }

    /// Windows that move with `w`. Only the main window drags its docked windows along, as in Winamp.
    func dockedWindows(movingWith w: NSWindow) -> [NSWindow] {
        guard w === panel else { return [] }
        let others: [NSWindow] = [eqPanel, plPanel]
        return SkinPanel.dockedGroup(panel.frame, others.map(\.frame)).map { others[$0] }
    }

    /// Frames of the visible windows a dragged window can snap to.
    func snapTargets(excluding: [NSWindow]) -> [NSRect] {
        [panel!, eqPanel!, plPanel!].filter { $0.isVisible && !excluding.contains($0) }.map(\.frame)
    }

    /// Resizes every window from its top-left corner. With `keepDocked`, windows docked to the main window
    /// keep their place relative to it, so a growing main window does not overlap the EQ below it.
    /// At launch it is false: these non-resizable panels restore only their saved top-left corners, which
    /// already belong to the saved scale.
    private func applyScale(_ s: Int, keepDocked: Bool = true) {
        let docked = keepDocked ? dockedWindows(movingWith: panel).map(ObjectIdentifier.init) : []
        let anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let ratio = MainView.size.width * CGFloat(s) / panel.frame.width
        for v in skinViews {
            guard let p = v.window else { continue }
            let size = NSSize(width: v.currentSize.width * CGFloat(s), height: v.currentSize.height * CGFloat(s))
            var topLeft = NSPoint(x: p.frame.minX, y: p.frame.maxY)
            if docked.contains(ObjectIdentifier(p)) {
                topLeft = NSPoint(x: anchor.x + (topLeft.x - anchor.x) * ratio, y: anchor.y + (topLeft.y - anchor.y) * ratio)
            }
            p.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
            v.scale = CGFloat(s)
        }
        defaults.set(s, forKey: "scale")
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0, on: Bool = false) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
        }
        add("Load Skin…", #selector(chooseSkin))
        add("Default Skin", #selector(useDefaultSkin), on: view.skin === defaultSkin)
        menu.addItem(.separator())
        add("Equalizer", #selector(toggleEqualizer), on: isEqualizerVisible)
        add("Playlist", #selector(togglePlaylist), on: isPlaylistVisible)
        menu.addItem(withTitle: "Playlist Source", action: nil, keyEquivalent: "").submenu = playlistSourceMenu()
        menu.addItem(.separator())
        for s in 1...3 { add("Scale \(s)×", #selector(scaleItem(_:)), tag: s, on: Int(view.scale) == s) }
        add("Double Size (⌃D)", #selector(toggleDoubleSize), on: view.scale >= 2)
        menu.addItem(.separator())
        for m in Visualizer.Mode.allCases {
            add("Visualizer: \(m.title)", #selector(visualizerItem(_:)), tag: m.rawValue, on: view.visualizer.mode == m)
        }
        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLaunchAtLogin), on: launchesAtLogin)
        menu.addItem(.separator())
        add("Quit MusicAmp", #selector(NSApplication.terminate(_:)))
        menu.items.last?.target = NSApp
        return menu
    }

    @objc private func chooseSkin() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [UTType(filenameExtension: "wsz"), .zip].compactMap { $0 }
        NSApp.activate()
        if open.runModal() == .OK, let url = open.url { loadSkin(url) }
    }

    @objc private func useDefaultSkin() {
        setSkin(defaultSkin)
        defaults.removeObject(forKey: "skinPath")
    }

    @objc private func scaleItem(_ item: NSMenuItem) { applyScale(item.tag) }

    @objc private func visualizerItem(_ item: NSMenuItem) {
        view.visualizer.mode = Visualizer.Mode(rawValue: item.tag)!
        visualizerModeChanged()
    }
}
