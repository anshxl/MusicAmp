import CoreGraphics

/// A rectangle in one skin bitmap. Coordinates come from Webamp's skinSprites.ts (MIT).
struct Sprite: Hashable {
    let sheet: String // lowercase file name without extension, e.g. "cbuttons"
    let rect: CGRect

    init(_ sheet: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        self.sheet = sheet
        rect = CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Sprites of the main window, named as in Webamp.
enum S {
    static let main = Sprite("main", 0, 0, 275, 116)
    static let titleBar = Sprite("titlebar", 27, 15, 275, 14)
    static let titleBarSelected = Sprite("titlebar", 27, 0, 275, 14)
    static let options = (Sprite("titlebar", 0, 0, 9, 9), Sprite("titlebar", 0, 9, 9, 9))
    static let minimize = (Sprite("titlebar", 9, 0, 9, 9), Sprite("titlebar", 9, 9, 9, 9))
    static let shade = (Sprite("titlebar", 0, 18, 9, 9), Sprite("titlebar", 9, 18, 9, 9))
    static let close = (Sprite("titlebar", 18, 0, 9, 9), Sprite("titlebar", 18, 9, 9, 9))
    static let clutterBar = Sprite("titlebar", 304, 0, 8, 43)
    static let clutterDoubleSelected = Sprite("titlebar", 328, 69, 8, 8) // the "D" button, lit when doubled

    // Main window shade mode (titlebar.bmp)
    enum Shade {
        static let background = Sprite("titlebar", 27, 29, 275, 14)
        static let button = (Sprite("titlebar", 0, 27, 9, 9), Sprite("titlebar", 9, 27, 9, 9)) // in shade: normal, pressed
        static let positionBackground = Sprite("titlebar", 0, 36, 17, 7)
        static let positionThumb = [17, 20, 23].map { Sprite("titlebar", $0, 36, 3, 7) } // left, middle, right third
    }

    // cbuttons.bmp: (normal, pressed)
    static let previous = (Sprite("cbuttons", 0, 0, 23, 18), Sprite("cbuttons", 0, 18, 23, 18))
    static let play = (Sprite("cbuttons", 23, 0, 23, 18), Sprite("cbuttons", 23, 18, 23, 18))
    static let pause = (Sprite("cbuttons", 46, 0, 23, 18), Sprite("cbuttons", 46, 18, 23, 18))
    static let stop = (Sprite("cbuttons", 69, 0, 23, 18), Sprite("cbuttons", 69, 18, 23, 18))
    static let next = (Sprite("cbuttons", 92, 0, 22, 18), Sprite("cbuttons", 92, 18, 22, 18))
    static let eject = (Sprite("cbuttons", 114, 0, 22, 16), Sprite("cbuttons", 114, 16, 22, 16))

    // shufrep.bmp: [off, off pressed, on, on pressed]
    static let repeatButton = [0, 15, 30, 45].map { Sprite("shufrep", 0, $0, 28, 15) }
    static let shuffleButton = [0, 15, 30, 45].map { Sprite("shufrep", 28, $0, 47, 15) }
    // [off, on, off pressed, on pressed]
    static let eqButton = [(0, 61), (0, 73), (46, 61), (46, 73)].map { Sprite("shufrep", $0.0, $0.1, 23, 12) }
    static let playlistButton = [(23, 61), (23, 73), (69, 61), (69, 73)].map { Sprite("shufrep", $0.0, $0.1, 23, 12) }

    // playpaus.bmp
    static let playing = Sprite("playpaus", 0, 0, 9, 9)
    static let paused = Sprite("playpaus", 9, 0, 9, 9)
    static let stopped = Sprite("playpaus", 18, 0, 9, 9)

    // monoster.bmp
    static let stereo = (off: Sprite("monoster", 0, 12, 29, 12), on: Sprite("monoster", 0, 0, 29, 12))
    static let mono = (off: Sprite("monoster", 29, 12, 27, 12), on: Sprite("monoster", 29, 0, 27, 12))

    // posbar.bmp, volume.bmp, balance.bmp. Volume/balance backgrounds are 28 frames, 15 px apart.
    static let positionBackground = Sprite("posbar", 0, 0, 248, 10)
    static let positionThumb = (Sprite("posbar", 248, 0, 29, 10), Sprite("posbar", 278, 0, 29, 10))
    static func volumeBackground(_ frame: Int) -> Sprite { Sprite("volume", 0, frame * 15, 68, 13) }
    static let volumeThumb = (Sprite("volume", 15, 422, 14, 11), Sprite("volume", 0, 422, 14, 11))
    static func balanceBackground(_ frame: Int) -> Sprite { Sprite("balance", 9, frame * 15, 38, 13) }
    static let balanceThumb = (Sprite("balance", 15, 422, 14, 11), Sprite("balance", 0, 422, 14, 11))

    // numbers.bmp (blank is the 10th cell) / nums_ex.bmp (adds blank and minus cells)
    static func digit(_ d: Int, ex: Bool) -> Sprite { Sprite(ex ? "nums_ex" : "numbers", d * 9, 0, 9, 13) }
    static let minusEx = Sprite("nums_ex", 99, 0, 9, 13)
    static let minus = Sprite("numbers", 20, 6, 5, 1)

    // eqmain.bmp
    enum EQ {
        static let background = Sprite("eqmain", 0, 0, 275, 116)
        static let titleBar = Sprite("eqmain", 0, 134, 275, 14)
        static let close = Sprite("eqmain", 0, 125, 9, 9) // pressed; the normal one is part of the title bar
        static let on = [10, 69, 128, 187].map { Sprite("eqmain", $0, 119, 26, 12) } // off, on, off pressed, on pressed
        static let auto = [36, 95, 154, 213].map { Sprite("eqmain", $0, 119, 32, 12) }
        static let presets = (Sprite("eqmain", 224, 164, 44, 12), Sprite("eqmain", 224, 176, 44, 12))
        static let thumb = (Sprite("eqmain", 0, 164, 11, 11), Sprite("eqmain", 0, 176, 11, 11))
        static let graphBackground = Sprite("eqmain", 0, 294, 113, 19)
        static func graphLineColor(row: Int) -> Sprite { Sprite("eqmain", 115, 294 + row, 1, 1) }
        static let preampLine = Sprite("eqmain", 0, 314, 113, 1)
        // eq_ex.bmp: shade mode
        static let shadeBackground = Sprite("eq_ex", 0, 0, 275, 14)
        static let shadeVolumeThumb = [1, 4, 7].map { Sprite("eq_ex", $0, 30, 3, 7) } // left, centre, right third
        static let shadeBalanceThumb = [11, 14, 17].map { Sprite("eq_ex", $0, 30, 3, 7) }
        static let shadeButtonPressed = Sprite("eq_ex", 1, 38, 9, 9) // "maximize", in shade
        static let shadeClose = (Sprite("eq_ex", 11, 38, 9, 9), Sprite("eq_ex", 11, 47, 9, 9))
        /// Slider background frame 0…27: 14 per row, 15 px apart; rows 65 px apart.
        static func sliderBackground(_ n: Int) -> Sprite { Sprite("eqmain", 13 + n % 14 * 15, 164 + n / 14 * 65, 14, 63) }
    }

    // pledit.bmp
    enum PL {
        static let topLeft = Sprite("pledit", 0, 0, 25, 20)
        static let title = Sprite("pledit", 26, 0, 100, 20)
        static let topTile = Sprite("pledit", 127, 0, 25, 20)
        static let topRight = Sprite("pledit", 153, 0, 25, 20)
        static let leftTile = Sprite("pledit", 0, 42, 12, 29)
        static let rightTile = Sprite("pledit", 31, 42, 20, 29)
        static let bottomLeft = Sprite("pledit", 0, 72, 125, 38)
        static let bottomRight = Sprite("pledit", 126, 72, 150, 38)
        static let scrollHandle = (Sprite("pledit", 52, 53, 8, 18), Sprite("pledit", 61, 53, 8, 18))
        static let closePressed = Sprite("pledit", 52, 42, 9, 9)
        static let shadePressed = Sprite("pledit", 62, 42, 9, 9) // "collapse", in normal mode
        static let expandPressed = Sprite("pledit", 150, 42, 9, 9) // in shade mode
        static let shadeLeft = Sprite("pledit", 72, 42, 25, 14)
        static let shadeTile = Sprite("pledit", 72, 57, 25, 14)
        static let shadeRight = Sprite("pledit", 99, 42, 50, 14)
    }

    /// text.bmp: 5×6 cells. Unknown characters render as a space.
    static func char(_ c: Character) -> Sprite {
        let (row, col) = fontLookup[Character(c.lowercased())] ?? (0, 30)
        return Sprite("text", col * 5, row * 6, 5, 6)
    }

    private static let fontLookup: [Character: (Int, Int)] = {
        var t: [Character: (Int, Int)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz\"@".enumerated() { t[c] = (0, i) }
        for (i, c) in "0123456789….:()-'!_+\\/[]^&%,=$#".enumerated() { t[c] = (1, i) }
        for (i, c) in "åöä?*".enumerated() { t[c] = (2, i) }
        for (c, v) in [("<", 22), (">", 23), ("{", 22), ("}", 23)] { t[Character(c)] = (1, v) }
        t[" "] = (0, 30)
        return t
    }()
}
