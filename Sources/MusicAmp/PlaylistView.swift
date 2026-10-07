import AppKit
import MusicControl

/// The pledit.bmp window at Winamp's default size: Music's current playlist, double-click to play.
final class PlaylistView: SkinView {
    static let size = CGSize(width: 275, height: 232)
    private static let list = CGRect(x: 12, y: 20, width: 243, height: 174) // between the frame tiles
    private static let rowHeight: CGFloat = 13, listPadding: CGFloat = 3
    private static let scrollTrack = CGRect(x: 260, y: 20, width: 8, height: 156) // handle travel, 18 px handle
    private static let close = CGRect(x: 264, y: 3, width: 9, height: 9)
    private static let shadeButton = CGRect(x: 254, y: 3, width: 9, height: 9)
    private static let listButton = CGRect(x: 231, y: 202, width: 22, height: 18) // "LIST OPTS"
    /// Mini transport in the bottom-right corner, 10 px apart.
    private static let miniButtons: [Control] = [.previous, .play, .pause, .stop, .next, .eject]

    var tracks: [PlaylistTrack] = [] {
        didSet {
            selected = nil
            scrollRow = min(scrollRow, maxScroll)
            needsDisplay = true
        }
    }
    /// 0-based index of Music's current track in `tracks`.
    var currentIndex: Int? {
        didSet {
            guard currentIndex != oldValue else { return }
            if let c = currentIndex, !(scrollRow..<scrollRow + visibleRows).contains(c) {
                scrollRow = min(maxScroll, max(0, c - visibleRows / 2)) // bring the current track into view
            }
            needsDisplay = true
        }
    }
    var elapsed: Double? { didSet { if elapsed.map(Int.init) != oldValue.map(Int.init) { needsDisplay = true } } }

    private var selected: Int?
    private var scrollRow = 0
    private var scrollDrag = false
    private var scrollAccumulator: CGFloat = 0
    private var closePressed = false
    private var shadePressed = false
    private var pressedMini: Int?

    private var visibleRows: Int { Int((Self.list.height - 2 * Self.listPadding) / Self.rowHeight) }
    private var maxScroll: Int { max(0, tracks.count - visibleRows) }

    init(skin: Skin) { super.init(skin: skin, baseSize: Self.size) }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Drawing

    /// Full screen resolution, so the track list text stays sharp.
    override var renderScale: CGFloat { scale * (window?.backingScaleFactor ?? 2) }

    override func render(in ctx: CGContext) {
        if isShaded { return renderShade() }
        blit(S.PL.topLeft, 0, 0)
        for x in stride(from: 25, to: 250, by: 25) { blit(S.PL.topTile, CGFloat(x), 0) }
        blit(S.PL.title, 87, 0)
        blit(S.PL.topRight, 250, 0)
        for y in stride(from: 20, to: 194, by: 29) {
            blit(S.PL.leftTile, 0, CGFloat(y))
            blit(S.PL.rightTile, 255, CGFloat(y))
        }
        blit(S.PL.bottomLeft, 0, 194)
        blit(S.PL.bottomRight, 125, 194)
        if closePressed { blit(S.PL.closePressed, Self.close.minX, Self.close.minY) }
        if shadePressed { blit(S.PL.shadePressed, Self.shadeButton.minX, Self.shadeButton.minY) }

        let style = skin.playlistStyle
        ctx.setFillColor(style.normalBG)
        ctx.fill(Self.list)
        let font = NSFont(name: style.font, size: 9) ?? .systemFont(ofSize: 9)
        for r in 0..<visibleRows {
            let i = scrollRow + r
            guard i < tracks.count else { break }
            let row = CGRect(x: Self.list.minX, y: Self.list.minY + Self.listPadding + CGFloat(r) * Self.rowHeight,
                             width: Self.list.width, height: Self.rowHeight)
            if i == selected {
                ctx.setFillColor(style.selectedBG)
                ctx.fill(row)
            }
            let color = NSColor(cgColor: i == currentIndex ? style.current : style.normal) ?? .green
            let t = tracks[i]
            let duration = Self.attributed(mmss(t.duration), font, color, .right)
            let durationWidth = duration.size().width + 3
            duration.draw(in: CGRect(x: row.maxX - durationWidth - 3, y: row.minY, width: durationWidth, height: row.height))
            let title = t.artist.isEmpty ? t.name : "\(t.artist) - \(t.name)"
            Self.attributed("\(i + 1). \(title)", font, color, .left)
                .draw(in: CGRect(x: row.minX + 2, y: row.minY, width: row.width - durationWidth - 8, height: row.height))
        }

        let f = maxScroll == 0 ? 0 : CGFloat(scrollRow) / CGFloat(maxScroll)
        blit(scrollDrag ? S.PL.scrollHandle.1 : S.PL.scrollHandle.0,
             Self.scrollTrack.minX, Self.scrollTrack.minY + (f * (Self.scrollTrack.height - 18)).rounded())

        let total = tracks.reduce(0) { $0 + $1.duration }
        text("\(selected.map { mmss(tracks[$0].duration) } ?? "0:00")/\(mmss(total))", 132, 204)
        if let elapsed { text(mmss(elapsed), 191, 217) }
    }

    /// The 275×14 strip: the current track and its length in the text.bmp font.
    private func renderShade() {
        blit(S.PL.shadeLeft, 0, 0)
        for x in stride(from: 25, to: 225, by: 25) { blit(S.PL.shadeTile, CGFloat(x), 0) }
        blit(S.PL.shadeRight, 225, 0)
        if closePressed { blit(S.PL.closePressed, Self.close.minX, Self.close.minY) }
        if shadePressed { blit(S.PL.expandPressed, Self.shadeButton.minX, Self.shadeButton.minY) }
        guard let i = currentIndex, i < tracks.count else { return }
        let t = tracks[i], time = mmss(t.duration)
        let timeX = 245 - CGFloat(time.count * 5) // right edge 30 px from the window's
        let title = "\(i + 1). " + (t.artist.isEmpty ? t.name : "\(t.artist) - \(t.name)")
        text(String(title.prefix(Int((timeX - 5 - 5) / 5))), 5, 4)
        text(time, timeX, 4)
    }

    private static func attributed(_ s: String, _ font: NSFont, _ color: NSColor, _ align: NSTextAlignment) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        p.alignment = align
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    private func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // MARK: Mouse

    private func miniButton(at p: CGPoint) -> Int? {
        let i = Int((p.x - 128) / 10)
        return p.y >= 216 && p.y < 226 && p.x >= 128 && i < Self.miniButtons.count ? i : nil
    }

    override func mouseDown(with e: NSEvent) {
        let p = basePoint(e)
        if Self.close.contains(p) {
            closePressed = true
        } else if Self.shadeButton.contains(p) {
            shadePressed = true
        } else if isShaded || p.y < 20 { // title bar (the whole strip when shaded)
            if e.clickCount == 2 { controller?.toggleShade(self) } else { beginWindowDrag() } // Winamp: double-click
        } else if CGRect(x: 258, y: 20, width: 12, height: 174).contains(p) { // the scrollbar column
            scrollDrag = true
            scroll(toHandleAt: p.y)
        } else if Self.list.contains(p) {
            let i = scrollRow + Int((p.y - Self.list.minY - Self.listPadding) / Self.rowHeight)
            guard i >= 0, i < tracks.count else { return }
            selected = i
            if e.clickCount == 2 { controller?.playPlaylistTrack(i) }
        } else if let i = miniButton(at: p) {
            pressedMini = i
        } else if Self.listButton.contains(p), let menu = controller?.playlistSourceMenu() {
            menu.popUp(positioning: nil, at: NSPoint(x: Self.listButton.minX * scale, y: Self.listButton.maxY * scale), in: self)
        } else {
            beginWindowDrag()
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        if continueWindowDrag() { return }
        if scrollDrag { scroll(toHandleAt: basePoint(e).y) }
    }

    override func mouseUp(with e: NSEvent) {
        let p = basePoint(e)
        if closePressed, Self.close.contains(p) { controller?.togglePlaylist() }
        if shadePressed, Self.shadeButton.contains(p) { controller?.toggleShade(self) }
        shadePressed = false
        if let i = pressedMini, miniButton(at: p) == i { controller?.perform(Self.miniButtons[i]) }
        closePressed = false
        pressedMini = nil
        scrollDrag = false
        endWindowDrag()
        needsDisplay = true
    }

    override func scrollWheel(with e: NSEvent) {
        scrollAccumulator -= e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / Self.rowHeight : e.scrollingDeltaY
        let rows = Int(scrollAccumulator)
        guard rows != 0 else { return }
        scrollAccumulator -= CGFloat(rows)
        scrollRow = min(maxScroll, max(0, scrollRow + rows))
        needsDisplay = true
    }

    private func scroll(toHandleAt y: CGFloat) {
        let f = min(1, max(0, (y - Self.scrollTrack.minY - 9) / (Self.scrollTrack.height - 18)))
        scrollRow = Int((f * CGFloat(maxScroll)).rounded())
        needsDisplay = true
    }
}
