import Foundation
import MusicControl

let usage = """
    usage: MusicCtl <command>
      watch                 print track/state notifications and the 4 Hz position
      status                current track, volume, shuffle, repeat
      playpause | play | pause | next | prev
      seek <seconds> | volume <0-100> | shuffle on|off | repeat off|one|all
      playlist              tracks of the current playlist (bulk fetch)
      playtrack <index>     play track <index> (1-based) of the current playlist
      playlists [id]        your playlists (persistent ID, name); with an ID, its first tracks
      eq [preset]           EQ state, preset names, or one preset's bands
      eqset <preset> <band 0-10> <dB>   band 0 is the preamp
      selftest
    """

func describe(_ t: TrackInfo) -> String {
    "[\(t.state.rawValue)] \(t.artist) - \(t.name) (\(t.album)) \(String(format: "%.1f", t.duration)) s"
}

let args = Array(CommandLine.arguments.dropFirst())
let arg1 = args.count > 1 ? args[1] : ""

do {
    switch args.first ?? "" {
    case "watch":
        print(describe(try MusicPlayer.current()))
        let observer = PlayerInfoObserver { print("notification:", describe($0)) }
        let poller = PositionPoller { print(String(format: "\rposition %7.2f s  volume %3d", $0.position, $0.volume), terminator: ""); fflush(stdout) }
        poller.start()
        withExtendedLifetime((observer, poller)) { RunLoop.main.run() }
    case "status":
        print(describe(try MusicPlayer.current()))
        print("volume \(try MusicPlayer.volume), shuffle \(try MusicPlayer.shuffle), repeat \(try MusicPlayer.repeatMode.rawValue)")
    case "playpause": try MusicPlayer.playPause()
    case "play": try MusicPlayer.play()
    case "pause": try MusicPlayer.pause()
    case "next": try MusicPlayer.next()
    case "prev": try MusicPlayer.previous()
    case "seek": try MusicPlayer.seek(to: Double(arg1) ?? 0)
    case "volume": try MusicPlayer.setVolume(Int(arg1) ?? 50)
    case "shuffle": try MusicPlayer.setShuffle(arg1 == "on")
    case "repeat": try MusicPlayer.setRepeat(RepeatMode(rawValue: arg1) ?? .off)
    case "playlist":
        let start = Date()
        let tracks = try MusicPlayer.currentPlaylist()
        let current = try MusicPlayer.currentIndex()
        for (i, t) in tracks.enumerated().prefix(20) {
            print(i + 1 == current ? ">" : " ", i + 1, t.artist, "-", t.name, String(format: "%.0f s", t.duration))
        }
        print(String(format: "%d tracks fetched in %.0f ms", tracks.count, Date().timeIntervalSince(start) * 1000))
    case "playtrack": try MusicPlayer.playTrack(at: Int(arg1) ?? 1)
    case "playlists":
        for p in try MusicPlayer.playlists() { print(p.id, p.name) }
        if !arg1.isEmpty { print(try MusicPlayer.tracks(ofPlaylist: arg1).prefix(5).map { "\($0.artist) - \($0.name)" }) }
    case "eq":
        print("EQ enabled: \(try Equalizer.isEnabled)")
        if arg1.isEmpty {
            print(try Equalizer.presetNames().joined(separator: ", "))
        } else {
            let p = try Equalizer.preset(named: arg1)
            print("\(p.name): preamp \(p.preamp)", zip(EQPreset.frequencies, p.bands).map { "\($0)=\($1)" }.joined(separator: " "))
        }
    case "eqset":
        guard args.count == 4, let band = Int(args[2]), (0...10).contains(band), let dB = Double(args[3]) else {
            print(usage); exit(2)
        }
        try Equalizer.set(preset: args[1], band: band, to: dB)
    case "selftest": musicControlSelfTest()
    default: print(usage); exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("MusicCtl: \(error)\n".utf8))
    exit(1)
}
