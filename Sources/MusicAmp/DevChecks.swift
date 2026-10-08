import AppKit
import AudioTap
import Carbon.HIToolbox
import ZIPFoundation

/// `MusicAmp --selftest`: skin parsing checks against the bundled default skin and a synthetic broken skin.
func skinSelfTest(defaultSkinURL: URL) throws {
    EqualizerDSP.selfTest()
    PlayQueue.selfTest()
    AlbumArt.selfTest()
    let base = try Skin(url: defaultSkinURL, fallback: nil)
    precondition(base.visColors.count == 24, "default viscolor.txt should have 24 colours")
    for s in [S.main, S.titleBarSelected, S.play.0, S.digit(9, ex: false), S.char("z"), S.volumeThumb.0, S.positionThumb.1,
              S.EQ.background, S.EQ.sliderBackground(27), S.EQ.graphLineColor(row: 18), S.PL.bottomRight, S.PL.rightTile] {
        precondition(base.image(s) != nil, "default skin is missing \(s)")
    }

    // A skin with odd case, a nested folder, a 3-colour viscolor.txt with comments, and no other bitmaps.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let zipURL = dir.appendingPathComponent("test.wsz")
    let archive = try Archive(url: zipURL, accessMode: .create)
    var main = Data() // real bytes: ImageIO cannot read the 32-bit BMPs NSBitmapImageRep writes
    let baseArchive = try Archive(url: defaultSkinURL, accessMode: .read)
    _ = try baseArchive.extract(baseArchive["MAIN.BMP"]!) { main.append($0) }
    let vis = Data("// header comment\n1,2,3, // c0\n4,5,6\n7,8,9\n".utf8)
    for (path, data) in [("MySkin/Main.BMP", main), ("MySkin/VISCOLOR.txt", vis)] {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }
    let skin = try Skin(url: zipURL, fallback: base)
    precondition(skin.has("main"), "nested, mixed-case Main.BMP not found")
    precondition(!skin.has("cbuttons") && skin.image(S.play.0) != nil, "missing sheet should fall back")
    precondition(skin.visColors.count == 24 && skin.visColors[0].components![0] == 1.0 / 255, "viscolor parse/fallback")
    precondition(skin.visColors[3] == base.visColors[3], "colours after the skin's 3 should come from the fallback")
    // pledit.txt: keys are case-insensitive, "#" is optional, bad values keep the fallback.
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    precondition(base.playlistStyle.current == white && base.playlistStyle.font == "Arial", "default pledit.txt")
    let style = PlaylistStyle(ini: "[Text]\nnormal=#FF0000\nCurrent=00FF00\nSelectedBG=oops\nFont=\n", fallback: base.playlistStyle)
    precondition(style.normal == CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), "lowercase key")
    precondition(style.current == CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), "colour without #")
    precondition(style.selectedBG == base.playlistStyle.selectedBG && style.font == "Arial", "bad values fall back")

    // region.txt: sections, comments, mixed separators; mismatched counts are ignored.
    let regions = Skin.parseRegions("""
        ; comment
        [Normal]
        NumPoints=4, 3 ; trailing comment
        PointList=0,0, 275,0 275,116 0,116  10,10 20,10 15,20
        [WindowShade]
        NumPoints=4
        PointList=0,0 1,1
        """)
    precondition(regions["normal"]?.count == 2 && regions["normal"]?[1][2] == CGPoint(x: 15, y: 20), "region polygons")
    precondition(regions["windowshade"] == nil && base.regions.isEmpty, "bad or absent regions are ignored")
    let huge = Skin.parseRegions("[Normal]\nNumPoints=4611686018427387904,4611686018427387904\nPointList=0,0 1,0 1,1")
    precondition(huge.isEmpty, "overflowing NumPoints must be rejected, not trap")

    // Hotkey specs.
    precondition(HotKey.parse("ctrl+option+w").map { $0.0 == UInt32(kVK_ANSI_W) && $0.1 == UInt32(controlKey | optionKey) } == true)
    precondition(HotKey.parse("Cmd + Shift + F5") != nil && HotKey.parse("w") == nil && HotKey.parse("ctrl+w+x") == nil
                 && HotKey.parse("ctrl+banana") == nil, "hotkey parsing")
    precondition(HotKey.symbols("ctrl+option+w") == "⌃⌥W", "hotkey symbols")

    // Window snapping: within 20 pt of an edge (inside or outside) snaps; farther does not.
    let screen = NSRect(x: 0, y: 25, width: 1000, height: 800) // visible frame above a 25 pt Dock
    let size = NSSize(width: 275, height: 116)
    func snap(_ x: CGFloat, _ y: CGFloat) -> NSPoint { SkinPanel.snap(NSRect(origin: NSPoint(x: x, y: y), size: size), to: screen) }
    precondition(snap(7, 300) == NSPoint(x: 0, y: 300), "left edge inside")
    precondition(snap(-6, 300) == NSPoint(x: 0, y: 300), "left edge outside")
    precondition(snap(1000 - 275 + 9, 300) == NSPoint(x: 725, y: 300), "right edge")
    precondition(snap(400, 30) == NSPoint(x: 400, y: 25), "bottom edge (Dock)")
    precondition(snap(400, 825 - 116 - 4) == NSPoint(x: 400, y: 709), "top edge (menu bar)")
    precondition(snap(3, 28) == NSPoint(x: 0, y: 25), "corner")
    precondition(snap(19, 300) == NSPoint(x: 0, y: 300), "19 pt snaps")
    precondition(snap(25, 300) == NSPoint(x: 25, y: 300) && snap(-25, 300) == NSPoint(x: -25, y: 300), "too far: no snap")
    // Window-to-window: dock under, align left edges, stay free when far; docked groups are transitive.
    let mainFrame = NSRect(x: 100, y: 500, width: 275, height: 116)
    func snapTo(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        SkinPanel.snap(NSRect(origin: NSPoint(x: x, y: y), size: size), to: screen, others: [mainFrame])
    }
    precondition(snapTo(108, 500 - 116 - 12) == NSPoint(x: 100, y: 384), "dock below main, aligned")
    precondition(snapTo(100 + 275 + 5, 503) == NSPoint(x: 375, y: 500), "dock right of main, aligned")
    precondition(snapTo(100, 300) == NSPoint(x: 100, y: 300), "far below: free")
    let eq = NSRect(x: 100, y: 384, width: 275, height: 116), pl = NSRect(x: 100, y: 152, width: 275, height: 232)
    let loose = NSRect(x: 600, y: 152, width: 275, height: 232)
    precondition(SkinPanel.dockedGroup(mainFrame, [eq, pl, loose]) == [0, 1], "main+EQ+PL docked, loose one not")
    precondition(SkinPanel.dockedGroup(mainFrame, [pl]) == [], "PL alone does not touch main")
    print("selftest ok")
}

/// `MusicAmp --snapshot out.png`: writes the window's last rendered frame (for checking skins without a screen).
func snapshot(_ view: SkinView, to path: String) throws {
    guard let image = view.renderedImage else { throw CocoaError(.fileWriteUnknown) }
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
