import AppKit

public enum RepeatMode: String, Sendable {
    case off, one, all
}

public struct PlaylistInfo: Sendable, Equatable {
    public let id: String // persistent ID
    public let name: String
}

public struct PlaylistTrack: Sendable {
    public let name: String
    public let artist: String
    public let duration: Double
}

/// Commands and reads for Music.app over Apple Events. Main thread only.
/// Every call launches Music if it is not running; check `isRunning` before reads.
public enum MusicPlayer {
    public static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    public static func playPause() throws { try tellMusic("playpause") }
    public static func play() throws { try tellMusic("play") }
    public static func pause() throws { try tellMusic("pause") }
    public static func stop() throws { try tellMusic("stop") }
    public static func next() throws { try tellMusic("next track") }
    /// Winamp-style: restarts the track if past ~3 s, else goes to the previous one (Music's own behaviour).
    public static func previous() throws { try tellMusic("back track") }

    public static func seek(to seconds: Double) throws {
        try tellMusic("set player position to \(number(max(0, seconds)))")
    }

    public static func position() throws -> Double {
        try tellMusic("player position").double
    }

    public static var volume: Int {
        get throws { Int(try tellMusic("sound volume").int32Value) }
    }
    public static func setVolume(_ v: Int) throws {
        try tellMusic("set sound volume to \(min(100, max(0, v)))")
    }

    public static var shuffle: Bool {
        get throws { try tellMusic("shuffle enabled").booleanValue }
    }
    public static func setShuffle(_ on: Bool) throws {
        try tellMusic("set shuffle enabled to \(on)")
    }

    public static var repeatMode: RepeatMode {
        get throws { RepeatMode(rawValue: try tellMusic("song repeat as text").stringValue ?? "") ?? .off }
    }
    public static func setRepeat(_ mode: RepeatMode) throws {
        try tellMusic("set song repeat to \(mode.rawValue)")
    }

    /// Current state in one Apple Event. The notification only fires on change, so call this at launch.
    public static func current() throws -> TrackInfo {
        let r = try tellMusic("""
            set s to player state as text
            if s is "stopped" then return {s, "", "", "", 0}
            tell current track to return {s, name, artist, album, duration}
            """).items
        return TrackInfo(state: PlayerState(rawValue: r[0].stringValue ?? "") ?? .stopped,
                         name: r[1].stringValue ?? "", artist: r[2].stringValue ?? "",
                         album: r[3].stringValue ?? "", duration: r[4].double)
    }

    /// All tracks of the current playlist in one Apple Event per property (3 total, not one per track).
    public static func currentPlaylist() throws -> [PlaylistTrack] { try tracks(of: "current playlist") }

    /// All tracks of the playlist with this persistent ID, fetched the same way.
    public static func tracks(ofPlaylist id: String) throws -> [PlaylistTrack] { try tracks(of: playlist(id)) }

    /// The library first, then every user playlist that is not a folder, then Apple Music playlists added to the library.
    /// (`name of ps` must be explicit: a bare `name` inside a `tell` block resolves to the script's own name.)
    public static func playlists() throws -> [PlaylistInfo] {
        let r = try tellMusic("""
            set lib to library playlist 1
            set ps to a reference to (every user playlist whose special kind is not folder)
            set ss to a reference to every subscription playlist
            return {{persistent ID of lib}, {name of lib}, persistent ID of ps, name of ps, persistent ID of ss, name of ss}
            """).items.map(\.items)
        let ids = (r[0] + r[2] + r[4]).compactMap(\.stringValue), names = (r[1] + r[3] + r[5]).compactMap(\.stringValue)
        return zip(ids, names).map { PlaylistInfo(id: $0, name: $1) }
    }

    /// Plays track `index` (1-based) of the playlist with this persistent ID; it becomes Music's current playlist.
    public static func playTrack(at index: Int, ofPlaylist id: String) throws {
        try tellMusic("play track \(index) of \(playlist(id))")
    }

    private static func playlist(_ id: String) -> String { "(first playlist whose persistent ID is \(quoted(id)))" }

    private static func tracks(of playlist: String) throws -> [PlaylistTrack] {
        let cols = try tellMusic("""
            tell \(playlist) to return {name of every track, artist of every track, duration of every track}
            """).items.map(\.items)
        guard cols.count == 3 else { return [] }
        return zip(cols[0], zip(cols[1], cols[2])).map {
            PlaylistTrack(name: $0.stringValue ?? "", artist: $1.0.stringValue ?? "", duration: $1.1.double)
        }
    }

    /// Persistent ID of the current playlist and the 1-based index of the current track in it.
    /// Cheap (2 Apple Events), so callers can check it on every track change and refetch the
    /// track list only when the ID changes. Nil when stopped.
    public static func playlistState() throws -> (id: String, index: Int)? {
        let r = try tellMusic("""
            if player state is stopped then return {"", 0}
            return {persistent ID of current playlist, index of current track}
            """).items
        guard let id = r[0].stringValue, !id.isEmpty else { return nil }
        return (id, Int(r[1].int32Value))
    }

    /// 1-based index of the current track in the current playlist, or nil when stopped.
    public static func currentIndex() throws -> Int? {
        let i = Int(try tellMusic("if player state is stopped then return 0\nindex of current track").int32Value)
        return i > 0 ? i : nil
    }

    /// Plays track `index` (1-based) of the current playlist.
    public static func playTrack(at index: Int) throws {
        try tellMusic("play track \(index) of current playlist")
    }
}

/// Values Music sends no notification for, read together in one Apple Event.
public struct PlayerStatus: Equatable, Sendable {
    public var position: Double
    public var volume: Int
    public var shuffle: Bool
    public var repeatMode: RepeatMode

    public init(position: Double, volume: Int, shuffle: Bool, repeatMode: RepeatMode) {
        (self.position, self.volume, self.shuffle, self.repeatMode) = (position, volume, shuffle, repeatMode)
    }
}

extension MusicPlayer {
    public static func status() throws -> PlayerStatus {
        let r = try tellMusic("return {player position, sound volume, shuffle enabled, song repeat as text}").items
        return PlayerStatus(position: r[0].double, volume: Int(r[1].int32Value), shuffle: r[2].booleanValue,
                            repeatMode: RepeatMode(rawValue: r[3].stringValue ?? "") ?? .off)
    }

    /// `{bit rate (kbps), sample rate (Hz)}` of the current track; 0 when Music does not know.
    public static func audioFormat() throws -> (kbps: Int, hz: Int) {
        let r = try tellMusic("if player state is stopped then return {0, 0}\ntell current track to return {bit rate, sample rate}").items
        return (Int(r[0].int32Value), Int(r[1].int32Value))
    }
}

/// Polls `PlayerStatus` on the main run loop. Start it only while the UI is visible.
/// Position is read every tick; volume, shuffle and repeat every 8th tick (AppleScript sends one
/// Apple Event per property, so the full status costs four round trips to Music).
public final class PositionPoller {
    private var timer: Timer?
    private var last: PlayerStatus?
    private var ticks = 0
    private let onStatus: (PlayerStatus) -> Void

    public init(_ onStatus: @escaping (PlayerStatus) -> Void) { self.onStatus = onStatus }

    public func start(hz: Double = 4) {
        guard timer == nil else { return }
        ticks = 0
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / hz, repeats: true) { [weak self] _ in self?.poll() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard MusicPlayer.isRunning else { return } // never relaunch Music after the user quits it
        defer { ticks += 1 }
        if ticks % 8 == 0 || last == nil {
            last = try? MusicPlayer.status()
        } else if let p = try? MusicPlayer.position() {
            last?.position = p
        }
        if let last { onStatus(last) }
    }
}
