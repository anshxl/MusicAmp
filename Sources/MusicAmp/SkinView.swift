import AppKit

/// Shared plumbing for the skinned windows: base-coordinate drawing, sprite and text blitting,
/// window dragging, and the context menu.
///
/// Each window renders at its base pixel size into a small bitmap that becomes the layer's contents;
/// the GPU scales it up with nearest-neighbour filtering. Drawing into the view at 3× Retina instead
/// cost about 70 MB of window backing store for three windows.
class SkinView: NSView {
    weak var controller: AppController?
    var skin: Skin { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    let baseSize: CGSize
    private var windowDrag: (mouse: NSPoint, origin: NSPoint, followers: [(NSWindow, NSPoint)])?
    private var ctx: CGContext?

    init(skin: Skin, baseSize: CGSize) {
        self.skin = skin
        self.baseSize = baseSize
        super.init(frame: NSRect(origin: .zero, size: baseSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeBackingProperties() { needsDisplay = true } // the playlist's renderScale follows it

    /// Pixels per base unit of the offscreen bitmap. 1 keeps pixel art exact; the playlist overrides it for sharp text.
    var renderScale: CGFloat { 1 }

    /// Subclasses draw here, in base coordinates (y down). `blit` and `text` draw into `ctx`.
    func render(in ctx: CGContext) {}

    override func updateLayer() {
        let s = renderScale
        guard let ctx = CGContext(data: nil, width: Int(baseSize.width * s), height: Int(baseSize.height * s),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: baseSize.height * s) // y down, like the view
        ctx.scaleBy(x: s, y: -s)
        ctx.interpolationQuality = .none
        NSGraphicsContext.saveGraphicsState() // NSString drawing (playlist) needs a current, flipped context
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        self.ctx = ctx
        render(in: ctx)
        self.ctx = nil
        NSGraphicsContext.restoreGraphicsState()
        layer?.contents = ctx.makeImage()
    }

    /// The last rendered frame at base resolution (× renderScale).
    var renderedImage: CGImage? { (layer?.contents as AnyObject?).map { $0 as! CGImage } }

    func blit(_ s: Sprite, _ x: CGFloat, _ y: CGFloat) {
        guard let ctx, let img = skin.image(s) else { return }
        ctx.saveGState() // CGImage draws bottom-up; flip locally inside the y-down view
        ctx.translateBy(x: x, y: y + s.rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: s.rect.size))
        ctx.restoreGState()
    }

    /// Draws `str` with the skin's text.bmp font.
    func text(_ str: String, _ x: CGFloat, _ y: CGFloat) {
        for (i, c) in str.enumerated() { blit(S.char(c), x + CGFloat(i * 5), y) }
    }

    func basePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    // MARK: Window dragging (subclasses call these from their mouse handlers)

    func beginWindowDrag() {
        guard let w = window else { return }
        let followers = (controller?.dockedWindows(movingWith: w) ?? []).map { ($0, $0.frame.origin) }
        windowDrag = (NSEvent.mouseLocation, w.frame.origin, followers)
    }

    /// Moves the window (and any docked followers) if a drag is in progress. Returns false otherwise.
    func continueWindowDrag() -> Bool {
        guard let drag = windowDrag, let w = window as? SkinPanel else { return false }
        let m = NSEvent.mouseLocation
        let others = controller?.snapTargets(excluding: [w] + drag.followers.map(\.0)) ?? []
        w.moveSnapped(to: NSPoint(x: drag.origin.x + m.x - drag.mouse.x, y: drag.origin.y + m.y - drag.mouse.y), others: others)
        let dx = w.frame.minX - drag.origin.x, dy = w.frame.minY - drag.origin.y
        for (f, o) in drag.followers { f.setFrameOrigin(NSPoint(x: o.x + dx, y: o.y + dy)) }
        return true
    }

    func endWindowDrag() { windowDrag = nil }

    override func rightMouseDown(with e: NSEvent) {
        if let menu = controller?.contextMenu() { NSMenu.popUpContextMenu(menu, with: e, for: self) }
    }
}
