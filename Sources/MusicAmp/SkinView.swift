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
    static let shadeHeight: CGFloat = 14
    /// Winamp's "windowshade": the window folds to a 14 px strip.
    var isShaded = false { didSet { needsDisplay = true } }
    /// The size to draw and to size the window to, in base units.
    var currentSize: CGSize { isShaded ? CGSize(width: baseSize.width, height: Self.shadeHeight) : baseSize }
    /// region.txt section for the current state, or nil for a rectangular window.
    var regionSection: String? { nil }
    private var appliedRegion: [[CGPoint]]?
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
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true } // keys (Ctrl+D) without activating the app

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, e.charactersIgnoringModifiers == "d" {
            controller?.toggleDoubleSize()
        } else {
            super.keyDown(with: e)
        }
    }

    /// The skin's polygons for this window and state, if any.
    var region: [[CGPoint]]? { regionSection.flatMap { skin.regions[$0] } }

    private static func path(_ polygons: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for p in polygons { path.addLines(between: p); path.closeSubpath() }
        return path
    }

    /// Clicks outside a shaped window's region do not count as clicks on the skin.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let region, let hit = super.hitTest(point) else { return super.hitTest(point) }
        let p = convert(point, from: superview)
        return Self.path(region).contains(CGPoint(x: p.x / scale, y: p.y / scale)) ? hit : nil
    }
    override func viewDidChangeBackingProperties() { needsDisplay = true } // the playlist's renderScale follows it

    /// Pixels per base unit of the offscreen bitmap. 1 keeps pixel art exact; the playlist overrides it for sharp text.
    var renderScale: CGFloat { 1 }

    /// Subclasses draw here, in base coordinates (y down). `blit` and `text` draw into `ctx`.
    func render(in ctx: CGContext) {}

    override func updateLayer() {
        let s = renderScale, size = currentSize
        guard let ctx = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: size.height * s) // y down, like the view
        ctx.scaleBy(x: s, y: -s)
        ctx.interpolationQuality = .none
        let region = self.region
        if let region { // region.txt: pixels outside the polygons stay transparent
            ctx.addPath(Self.path(region))
            ctx.clip()
        }
        NSGraphicsContext.saveGraphicsState() // NSString drawing (playlist) needs a current, flipped context
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        self.ctx = ctx
        render(in: ctx)
        self.ctx = nil
        NSGraphicsContext.restoreGraphicsState()
        layer?.contents = ctx.makeImage()
        if region != appliedRegion { // the window shadow follows the shape
            appliedRegion = region
            window?.invalidateShadow()
        }
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
