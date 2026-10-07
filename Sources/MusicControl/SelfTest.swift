import Foundation

/// `MusicCtl selftest`: checks the pure parsing/quoting logic without talking to Music.
public func musicControlSelfTest() {
    let t = PlayerInfoObserver.parse([
        "Player State": "Playing", "Name": "RAF", "Artist": "A$AP Mob", "Album": "Cozy Tapes", "Total Time": 255_412.0,
    ])
    precondition(t == TrackInfo(state: .playing, name: "RAF", artist: "A$AP Mob", album: "Cozy Tapes", duration: 255.412))
    precondition(PlayerInfoObserver.parse(["Player State": "Stopped"]).state == .stopped)
    precondition(quoted(#"a "b" \c"#) == #""a \"b\" \\c""#)
    precondition(number(0.00001) == "0.000" && number(-2.5) == "-2.500")
    print("selftest ok")
}
