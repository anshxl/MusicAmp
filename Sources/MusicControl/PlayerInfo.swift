import Foundation

public enum PlayerState: String, Sendable {
    case playing, paused, stopped
}

public struct TrackInfo: Equatable, Sendable {
    public var state: PlayerState
    public var name: String
    public var artist: String
    public var album: String
    public var duration: Double // seconds; 0 when unknown (e.g. radio streams)

    public init(state: PlayerState, name: String, artist: String, album: String, duration: Double) {
        (self.state, self.name, self.artist, self.album, self.duration) = (state, name, artist, album, duration)
    }
}

/// Pushes track/state changes from Music's "com.apple.Music.playerInfo" distributed
/// notification. Needs a running main run loop. Keep the returned object alive.
public final class PlayerInfoObserver {
    private var token: NSObjectProtocol?

    public init(_ onChange: @escaping (TrackInfo) -> Void) {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { note in
            onChange(Self.parse(note.userInfo ?? [:]))
        }
    }

    deinit {
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
    }

    static func parse(_ info: [AnyHashable: Any]) -> TrackInfo {
        TrackInfo(
            state: PlayerState(rawValue: (info["Player State"] as? String ?? "").lowercased()) ?? .stopped,
            name: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: (info["Total Time"] as? Double ?? 0) / 1000 // milliseconds in the notification
        )
    }
}
