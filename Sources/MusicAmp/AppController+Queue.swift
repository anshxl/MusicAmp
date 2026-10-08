import Foundation
import MusicControl

/// Music 1.7 plays a track started by script (`play track N of playlist`) with no queue after it:
/// it stops at the end, and its own Next does nothing. So for tracks started from MusicAmp's playlist
/// window, MusicAmp keeps the queue: Next/Previous and the end of a track play the neighbouring track.
/// Playback started in Music itself keeps using Music's own queue.
struct PlayQueue: Equatable {
    let playlistID: String
    let count: Int
    var index: Int // 0-based

    /// The index to play next, or nil to stop. `automatic` is a track ending on its own (repeat one replays it;
    /// the buttons still move on, as in Winamp).
    static func step(from index: Int, count: Int, forward: Bool, automatic: Bool, shuffle: Bool,
                     repeatMode: RepeatMode, random: (Range<Int>) -> Int = { Int.random(in: $0) }) -> Int? {
        guard count > 0 else { return nil }
        if automatic && repeatMode == .one { return index }
        if shuffle && count > 1 {
            var j = index
            while j == index { j = random(0..<count) }
            return j
        }
        let j = index + (forward ? 1 : -1)
        if (0..<count).contains(j) { return j }
        if repeatMode == .all { return (j + count) % count }
        return forward ? nil : 0 // past the start: replay the first track
    }

    /// `MusicAmp --selftest`
    static func selfTest() {
        func s(_ i: Int, _ fwd: Bool, auto: Bool = false, shuffle: Bool = false, _ r: RepeatMode = .off) -> Int? {
            step(from: i, count: 5, forward: fwd, automatic: auto, shuffle: shuffle, repeatMode: r, random: { _ in 3 })
        }
        precondition(s(1, true) == 2 && s(1, false) == 0, "next / previous")
        precondition(s(4, true) == nil && s(4, true, .all) == 0 && s(0, false, .all) == 4 && s(0, false) == 0, "ends")
        precondition(s(2, true, auto: true, .one) == 2 && s(2, true, .one) == 3, "repeat one: only automatic replays")
        precondition(s(1, true, shuffle: true) == 3, "shuffle picks another track")
        precondition(step(from: 0, count: 1, forward: true, automatic: true, shuffle: true, repeatMode: .off) == nil, "lone track")
    }
}

extension AppController {
    /// Starts track `index` (0-based) of a playlist with a MusicAmp queue behind it.
    func startQueue(playlistID: String, count: Int, index: Int) {
        playQueue = PlayQueue(playlistID: playlistID, count: count, index: index)
        playQueued(index)
    }

    private func playQueued(_ index: Int) {
        guard let id = playQueue?.playlistID else { return }
        playQueue?.index = index
        lastQueuedPlay = Date()
        run { try MusicPlayer.playTrack(at: index + 1, ofPlaylist: id) }
    }

    /// Next or Previous from MusicAmp. Returns false when no MusicAmp queue is active, so the caller
    /// uses Music's own next/previous.
    func stepQueue(forward: Bool) -> Bool {
        guard let q = playQueue else { return false }
        let s = playerStatus
        if let i = PlayQueue.step(from: q.index, count: q.count, forward: forward, automatic: false,
                                  shuffle: s.shuffle, repeatMode: s.repeatMode) {
            playQueued(i)
        }
        return true
    }

    /// Runs on every playerInfo notification. A lone track that ends sends "paused" then "stopped" with no
    /// track info; "stopped" moves the queue on, unless it came from MusicAmp's Stop or from our own track change.
    func queueTrackChanged(_ t: TrackInfo) {
        guard let q = playQueue else { return }
        switch t.state {
        case .stopped:
            if queueStopRequested { return queueStopRequested = false }
            guard Date().timeIntervalSince(lastQueuedPlay) > 1.5 else { return }
            let s = playerStatus
            if let i = PlayQueue.step(from: q.index, count: q.count, forward: true, automatic: true,
                                      shuffle: s.shuffle, repeatMode: s.repeatMode) {
                playQueued(i)
            } else {
                playQueue = nil // end of the playlist
            }
        case .playing:
            // Anything else playing (started in Music, say) ends MusicAmp's queue.
            guard let now = try? MusicPlayer.playlistState(), now.id == q.playlistID, now.index - 1 == q.index else {
                return playQueue = nil
            }
        case .paused:
            break
        }
    }
}
