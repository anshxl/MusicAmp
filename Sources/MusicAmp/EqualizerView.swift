import AppKit
import AudioTap

/// The eqmain.bmp window, driving MusicAmp's own EQ (`EqualizerDSP`) on Music's tapped audio.
/// ON switches the EQ, AUTO switches automatic headroom, PRESETS loads values.
final class EqualizerView: SkinView {
    static let size = CGSize(width: 275, height: 116)

    enum Hit: Equatable {
        case close, shade, on, auto, presets, slider(Int) // slider 0 is the preamp, 1…10 the bands
    }

    var settings = EqualizerDSP.Settings() { didSet { needsDisplay = true } }

    private var pressed: Hit?
    private var pressedInside = false
    private var draggingSlider: Int?
    private var dragVolume: Int? // shade mode's volume slider

    init(skin: Skin) {
        super.init(skin: skin, baseSize: Self.size)
        toolTip = "ON: MusicAmp's equalizer. AUTO: automatic headroom, so boosts cannot clip. PRESETS: Flat or a Music preset."
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var regionSection: String? { isShaded ? "equalizerws" : "equalizer" }
    private static let shadeVolume = CGRect(x: 61, y: 4, width: 97, height: 7)

    private static func sliderX(_ i: Int) -> CGFloat { i == 0 ? 21 : CGFloat(78 + 18 * (i - 1)) }
    private static let sliderTop: CGFloat = 38, sliderHeight: CGFloat = 63, thumbTravel: CGFloat = 51

    private static func rect(_ h: Hit) -> CGRect {
        switch h {
        case .close: CGRect(x: 264, y: 3, width: 9, height: 9)
        case .shade: CGRect(x: 254, y: 3, width: 9, height: 9)
        case .on: CGRect(x: 14, y: 18, width: 26, height: 12)
        case .auto: CGRect(x: 40, y: 18, width: 32, height: 12)
        case .presets: CGRect(x: 217, y: 18, width: 44, height: 12)
        case .slider(let i): CGRect(x: sliderX(i), y: sliderTop, width: 14, height: sliderHeight)
        }
    }

    private static let hits: [Hit] = [.close, .shade, .on, .auto, .presets] + (0...10).map { .slider($0) }
    private var activeHits: [Hit] { isShaded ? [.close, .shade] : Self.hits }

    /// dB value of slider `i` (0 is the preamp).
    private func value(_ i: Int) -> Double { i == 0 ? settings.preamp : settings.bands[i - 1] }

    private static func fraction(_ dB: Double) -> Double { min(1, max(0, (dB + 12) / 24)) }

    // MARK: Drawing

    override func render(in ctx: CGContext) {
        let down = { (h: Hit) in self.pressed == h && self.pressedInside ? 2 : 0 }
        if isShaded { // eq_ex.bmp strip: buttons, then volume and (inert) balance thumbs
            blit(S.EQ.shadeBackground, 0, 0)
            if down(.shade) > 0 { blit(S.EQ.shadeButtonPressed, 254, 3) }
            blit(down(.close) > 0 ? S.EQ.shadeClose.1 : S.EQ.shadeClose.0, 264, 3)
            let f = Double(dragVolume ?? controller?.volume ?? 50) / 100
            blit(S.EQ.shadeVolumeThumb[f < 1.0 / 3 ? 0 : f > 2.0 / 3 ? 2 : 1], 61 + CGFloat(f * 94).rounded(), 4)
            blit(S.EQ.shadeBalanceThumb[1], 164 + 20, 4)
            return
        }
        blit(S.EQ.background, 0, 0)
        blit(S.EQ.titleBar, 0, 0)
        if down(.close) > 0 { blit(S.EQ.close, 264, 3) }
        blit(S.EQ.on[(settings.enabled ? 1 : 0) + down(.on)], 14, 18)
        blit(S.EQ.auto[(settings.autoHeadroom ? 1 : 0) + down(.auto)], 40, 18)
        blit(down(.presets) > 0 ? S.EQ.presets.1 : S.EQ.presets.0, 217, 18)

        drawGraph()

        for i in 0...10 {
            let f = Self.fraction(value(i))
            let x = Self.sliderX(i)
            blit(S.EQ.sliderBackground(Int((f * 27).rounded())), x, Self.sliderTop)
            let thumbY = Self.sliderTop + ((1 - f) * Self.thumbTravel).rounded()
            blit(draggingSlider == i ? S.EQ.thumb.1 : S.EQ.thumb.0, x + 1, thumbY)
        }
    }

    /// The response curve, linearly interpolated between bands, coloured per row from the skin.
    private func drawGraph() {
        let origin = CGPoint(x: 86, y: 17)
        blit(S.EQ.graphBackground, origin.x, origin.y)
        blit(S.EQ.preampLine, origin.x, origin.y + ((1 - Self.fraction(value(0))) * 18).rounded())
        let ys = (1...10).map { (1 - Self.fraction(value($0))) * 18 }
        var prev: Int?
        for x in 0..<113 {
            let pos = Double(x) / 112 * 9 // position between band points
            let i = min(8, Int(pos))
            let y = Int((ys[i] + (ys[i + 1] - ys[i]) * (pos - Double(i))).rounded())
            for row in min(prev ?? y, y)...max(prev ?? y, y) {
                blit(S.EQ.graphLineColor(row: row), origin.x + CGFloat(x), origin.y + CGFloat(row))
            }
            prev = y
        }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        let p = basePoint(e)
        if isShaded, Self.shadeVolume.contains(p) {
            dragVolume = volumeAt(p)
            return needsDisplay = true
        }
        guard let h = activeHits.first(where: { Self.rect($0).contains(p) }) else {
            if p.y < 14, e.clickCount == 2 { return controller?.toggleShade(self) ?? () } // Winamp: double-click title bar
            return beginWindowDrag()
        }
        if case .slider(let i) = h {
            draggingSlider = i
            setSlider(i, at: p)
        } else {
            pressed = h
            pressedInside = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = basePoint(e)
        if continueWindowDrag() { return }
        if dragVolume != nil {
            dragVolume = volumeAt(p)
            controller?.setVolume(dragVolume!)
        } else if let i = draggingSlider {
            setSlider(i, at: p)
        } else if let h = pressed {
            pressedInside = Self.rect(h).contains(p)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let h = pressed, pressedInside { controller?.equalizerAction(h, in: self) }
        if let v = dragVolume { controller?.setVolume(v) }
        dragVolume = nil
        endWindowDrag()
        pressed = nil
        draggingSlider = nil
        needsDisplay = true
    }

    private func volumeAt(_ p: CGPoint) -> Int { min(100, max(0, Int((p.x - 61 - 1.5) / 94 * 100))) }

    /// Maps the mouse to -12…+12 dB in 0.5 dB steps and sends changes to Music while dragging.
    private func setSlider(_ i: Int, at p: CGPoint) {
        let f = 1 - (p.y - Self.sliderTop - 5.5) / Self.thumbTravel
        let dB = ((min(1, max(0, f)) * 24 - 12) * 2).rounded() / 2
        guard dB != value(i) else { return }
        controller?.setEqualizer(slider: i, to: dB)
    }
}
