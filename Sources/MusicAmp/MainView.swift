import AppKit
import MusicControl

/// Clickable areas of the main window, in base coordinates. Hit-tested in declaration order.
enum Control: CaseIterable {
    case options, minimize, shade, close, doubleSize
    case previous, play, pause, stop, next, eject, shuffle, repeatButton, eq, playlist
    case position, volume, balance, time, visualizer, titleBar

    /// Where the control is in the normal (275×116) or shaded (275×14) layout; nil if it is not shown.
    func rect(shaded: Bool) -> CGRect? {
        let r: (Int, Int, Int, Int)?
        switch (self, shaded) {
        case (.options, _): r = (6, 3, 9, 9)
        case (.minimize, _): r = (244, 3, 9, 9)
        case (.shade, _): r = (254, 3, 9, 9)
        case (.close, _): r = (264, 3, 9, 9)
        case (.titleBar, _): r = (0, 0, 275, 14)
        case (.doubleSize, false): r = (10, 47, 8, 8) // the clutter bar's "D"
        case (.previous, false): r = (16, 88, 23, 18)
        case (.play, false): r = (39, 88, 23, 18)
        case (.pause, false): r = (62, 88, 23, 18)
        case (.stop, false): r = (85, 88, 23, 18)
        case (.next, false): r = (108, 88, 22, 18)
        case (.eject, false): r = (136, 89, 22, 16)
        case (.shuffle, false): r = (164, 89, 47, 15)
        case (.repeatButton, false): r = (210, 89, 28, 15)
        case (.eq, false): r = (219, 58, 23, 12)
        case (.playlist, false): r = (242, 58, 23, 12)
        case (.position, false): r = (16, 72, 248, 10)
        case (.volume, false): r = (107, 57, 68, 13)
        case (.balance, false): r = (177, 57, 38, 13)
        case (.time, false): r = (36, 26, 63, 13)
        case (.visualizer, false): r = (24, 43, 76, 16)
        // Shade: the mini transport is drawn in the background art.
        case (.previous, true): r = (169, 2, 7, 10)
        case (.play, true): r = (176, 2, 10, 10)
        case (.pause, true): r = (186, 2, 9, 10)
        case (.stop, true): r = (195, 2, 9, 10)
        case (.next, true): r = (204, 2, 10, 10)
        case (.eject, true): r = (215, 2, 10, 10)
        case (.position, true): r = (226, 4, 17, 7)
        case (.time, true): r = (127, 4, 30, 6)
        case (.visualizer, true): r = (79, 5, 38, 5)
        default: r = nil
        }
        return r.map { CGRect(x: $0.0, y: $0.1, width: $0.2, height: $0.3) }
    }

    var isButton: Bool { ![.position, .volume, .balance, .time, .visualizer, .titleBar].contains(self) }
}

final class MainView: SkinView {
    static let size = CGSize(width: 275, height: 116)

    // Only the visualizer, marquee and time redraw every frame; anything else redraws when it changes.
    var track = TrackInfo(state: .stopped, name: "", artist: "", album: "", duration: 0) {
        didSet {
            if track.name != oldValue.name { marqueeTick = 0 }
            if track != oldValue { needsDisplay = true }
        }
    }
    var status = PlayerStatus(position: 0, volume: 50, shuffle: false, repeatMode: .off) {
        didSet { if status != oldValue { needsDisplay = true } }
    }
    var format = (kbps: 0, hz: 0) { didSet { needsDisplay = true } }
    var showRemaining = false { didSet { needsDisplay = true } }
    var albumArt: AlbumArt? { didSet { needsDisplay = true } }
    private var visColors: [CGColor] { albumArt?.visColors(over: skin.visColors) ?? skin.visColors }
    let visualizer: Visualizer

    private var pressed: Control?
    private var pressedInside = false
    private var dragFraction: Double? // position slider while dragging
    private var dragVolume: Int?
    private var tick = 0, marqueeTick = 0
    private var visualizerWasBusy = false

    init(skin: Skin, visualizer: Visualizer) {
        self.visualizer = visualizer
        super.init(skin: skin, baseSize: Self.size)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var regionSection: String? { isShaded ? "windowshade" : "normal" }

    /// Called once per animation frame (30 fps).
    func advance() {
        tick += 1
        marqueeTick += 1
        // Re-render for a moving visualizer (plus one frame to clear it), and for the marquee step / time blink.
        if !visualizer.isIdle || visualizerWasBusy || tick % 7 == 0 { needsDisplay = true }
        visualizerWasBusy = !visualizer.isIdle
    }

    // MARK: Drawing

    override func render(in ctx: CGContext) {
        func button(_ c: Control, _ sprites: (Sprite, Sprite)) {
            guard let r = c.rect(shaded: isShaded) else { return }
            blit(pressed == c && pressedInside ? sprites.1 : sprites.0, r.minX, r.minY)
        }
        if isShaded { return renderShade(ctx, button: button) }

        let state = track.state
        blit(S.main, 0, 0)
        // Before the other sprites, so controls stay readable over bright art; only main.bmp's dark areas show it.
        if let art = albumArt?.overlay {
            ctx.saveGState() // CGImage draws bottom-up; flip locally inside the y-down view
            ctx.translateBy(x: 0, y: Self.size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setBlendMode(.lighten)
            ctx.draw(art, in: CGRect(origin: .zero, size: Self.size))
            ctx.restoreGState()
        }
        blit(S.titleBarSelected, 0, 0)
        button(.options, S.options)
        button(.minimize, S.minimize)
        button(.shade, S.shade)
        button(.close, S.close)
        blit(S.clutterBar, 10, 22)
        if scale >= 2 { blit(S.clutterDoubleSelected, 10, 47) }

        blit(state == .playing ? S.playing : state == .paused ? S.paused : S.stopped, 26, 28)

        // Time: hidden when stopped, blinks when paused.
        if state != .stopped && (state != .paused || (tick / 30) % 2 == 0) {
            let pos = dragFraction.map { $0 * track.duration } ?? status.position
            let t = max(0, Int(showRemaining ? track.duration - pos : pos))
            let ex = skin.has("nums_ex")
            if showRemaining { ex ? blit(S.minusEx, 36, 26) : blit(S.minus, 38, 32) }
            for (x, d) in zip([48, 60, 78, 90], [t / 600 % 10, t / 60 % 10, t % 60 / 10, t % 10]) {
                blit(S.digit(d, ex: ex), CGFloat(x), 26)
            }
        }

        visualizer.draw(in: ctx, at: CGPoint(x: 24, y: 43), colors: visColors)

        // Scrolling title, one 5 px character step every 7 frames when it does not fit.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 111, y: 27, width: 154, height: 6))
        let title = track.name.isEmpty ? "MusicAmp" : "\(track.artist) - \(track.name) (\(mmss(track.duration)))"
        if title.count * 5 <= 154 {
            text(title, 111, 27)
        } else {
            let loop = title + "  ***  "
            let offset = CGFloat((marqueeTick / 7 * 5) % (loop.count * 5))
            text(loop + loop, 111 - offset, 27)
        }
        ctx.restoreGState()

        if state != .stopped {
            if format.kbps > 0 { text(String(format: "%3d", format.kbps % 1000), 111, 43) }
            if format.hz > 0 { text(String(format: "%2d", format.hz / 1000 % 100), 156, 43) }
        }
        blit(state == .playing ? S.stereo.on : S.stereo.off, 239, 41)
        blit(S.mono.off, 212, 41)

        let volume = dragVolume ?? status.volume
        blit(S.volumeBackground(min(27, volume * 28 / 100)), 107, 57)
        blit(dragVolume != nil ? S.volumeThumb.1 : S.volumeThumb.0, 107 + CGFloat(volume * 51 / 100), 58)
        blit(S.balanceBackground(0), 177, 57) // ponytail: Music has no balance; drawn centred, inert
        blit(S.balanceThumb.0, 177 + 12, 58)

        let eqDown = pressed == .eq && pressedInside ? 2 : 0, plDown = pressed == .playlist && pressedInside ? 2 : 0
        blit(S.eqButton[(controller?.isEqualizerVisible == true ? 1 : 0) + eqDown], 219, 58)
        blit(S.playlistButton[(controller?.isPlaylistVisible == true ? 1 : 0) + plDown], 242, 58)

        blit(S.positionBackground, 16, 72)
        if state != .stopped, track.duration > 0 {
            let f = dragFraction ?? min(1, status.position / track.duration)
            blit(dragFraction != nil ? S.positionThumb.1 : S.positionThumb.0, 16 + CGFloat(f * 219).rounded(), 72)
        }

        button(.previous, S.previous)
        button(.play, S.play)
        button(.pause, S.pause)
        button(.stop, S.stop)
        button(.next, S.next)
        button(.eject, S.eject)
        let down = pressedInside ? 1 : 0
        blit(S.shuffleButton[(status.shuffle ? 2 : 0) + (pressed == .shuffle ? down : 0)], 164, 89)
        blit(S.repeatButton[(status.repeatMode != .off ? 2 : 0) + (pressed == .repeatButton ? down : 0)], 210, 89)
    }

    /// The 275×14 strip: title-bar buttons, mini visualizer, time and position.
    private func renderShade(_ ctx: CGContext, button: (Control, (Sprite, Sprite)) -> Void) {
        let state = track.state
        blit(S.Shade.background, 0, 0)
        button(.options, S.options)
        button(.minimize, S.minimize)
        button(.shade, S.Shade.button)
        button(.close, S.close)
        visualizer.drawMini(in: ctx, at: CGPoint(x: 79, y: 5), colors: visColors)
        if state != .stopped && (state != .paused || (tick / 30) % 2 == 0) {
            let pos = dragFraction.map { $0 * track.duration } ?? status.position
            let t = max(0, Int(showRemaining ? track.duration - pos : pos))
            text((showRemaining ? "-" : " ") + String(format: "%2d:%02d", t / 60 % 100, t % 60), 127, 4)
        }
        blit(S.Shade.positionBackground, 226, 4)
        if state != .stopped, track.duration > 0 {
            let f = dragFraction ?? min(1, status.position / track.duration)
            blit(S.Shade.positionThumb[f < 1.0 / 3 ? 0 : f > 2.0 / 3 ? 2 : 1], 226 + CGFloat(f * 14).rounded(), 4)
        }
    }

    private func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        let p = basePoint(e)
        guard let c = Control.allCases.first(where: { $0.rect(shaded: isShaded)?.contains(p) == true }) else {
            return beginWindowDrag() // the rest of the skin drags the window too, like Winamp
        }
        switch c {
        case .titleBar where e.clickCount == 2: controller?.toggleShade(self) // Winamp: double-click title bar
        case .titleBar: beginWindowDrag()
        case .time: showRemaining.toggle()
        case .visualizer:
            visualizer.mode = Visualizer.Mode(rawValue: (visualizer.mode.rawValue + 1) % Visualizer.Mode.allCases.count)!
            controller?.visualizerModeChanged()
        case .position:
            if track.state != .stopped, track.duration > 0 { dragFraction = fraction(p) }
        case .volume: dragVolume = volumeAt(p)
        case .balance: break
        default:
            pressed = c
            pressedInside = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = basePoint(e)
        if continueWindowDrag() {
        } else if dragFraction != nil {
            dragFraction = fraction(p)
        } else if dragVolume != nil {
            dragVolume = volumeAt(p)
            controller?.setVolume(dragVolume!)
        } else if let c = pressed {
            pressedInside = c.rect(shaded: isShaded)?.contains(p) == true
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let f = dragFraction { controller?.seek(to: f * track.duration) }
        if let v = dragVolume {
            controller?.setVolume(v)
            status.volume = v
        }
        if let c = pressed, pressedInside, c.isButton { controller?.perform(c) }
        endWindowDrag()
        dragFraction = nil
        dragVolume = nil
        pressed = nil
        needsDisplay = true
    }

    private func fraction(_ p: CGPoint) -> Double {
        isShaded ? min(1, max(0, Double(p.x - 226 - 1.5) / 14)) : min(1, max(0, Double(p.x - 16 - 14.5) / 219))
    }
    private func volumeAt(_ p: CGPoint) -> Int { min(100, max(0, Int(Double(p.x - 107 - 7) / 51 * 100))) }

    // MARK: Drag and drop a .wsz

    private func skinURL(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.first { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { skinURL(info) == nil ? [] : .copy }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard let url = skinURL(info) else { return false }
        controller?.loadSkin(url)
        return true
    }
}
