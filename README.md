# MusicAmp

A Winamp 2-style mini player for Apple Music (Music.app) on macOS, with classic `.wsz` skins.

**Status: Phase 4 done.** The `MusicAmp` app (main, equalizer and playlist windows, skins, visualizer), plus `TapSpike` and `MusicCtl` test CLIs.

## Run MusicAmp

```sh
scripts/build-app.sh          # builds .build/MusicAmp.app (release, ad-hoc signed)
open .build/MusicAmp.app      # asks for Audio Recording and Automation (Music) on first launch
```

For development, `swift run MusicAmp` (or `.build/MusicAmp.app/Contents/MacOS/MusicAmp`) runs it from the
terminal, which uses the terminal's permissions instead.

- **Right-click** anywhere (or click the options button, top left) for the menu: load a skin, the default skin,
  scale 1×/2×/3×, visualizer mode, quit.
- **Drop a .wsz** on the window to switch skins. MusicAmp remembers the last skin, scale, mode and window position.
- **Click the visualizer** to cycle thick bars → thin bars → oscilloscope → off. **Click the time** to show time remaining.
- Drag the window by the title bar (or any part of the skin that is not a control). It snaps to screen edges within 20 points.
- Eject opens Music. Minimize hides MusicAmp; launch it again to bring it back. Close quits.
- **EQ** and **PL** (main window, or the right-click menu) show and hide the equalizer and playlist windows.
  On first launch they stack under the main window; after that each window remembers its position.
- Windows snap to screen edges and to each other (within 20 points). Windows touching the main window, directly
  or through each other, are docked: dragging the main window moves them too. Dragging EQ or the playlist moves
  only that window, as in Winamp. Changing the scale keeps docked windows docked.
- **EQ** window: ON switches MusicAmp's equalizer, AUTO switches automatic headroom (see Phase 4).
- Not yet wired: shade buttons and the clutter bar (Phase 5). Balance is drawn centred and does nothing,
  because Music has no balance control.

## Requirements

- macOS 15 or later (built and tested on macOS 27.0.1 / Darwin 27.0.0).
- Swift 6 toolchain. The Command Line Tools are enough; Xcode is not needed.

## Phase 1: TapSpike

TapSpike captures Music.app's audio output with a Core Audio process tap
(`CATapDescription` + `AudioHardwareCreateProcessTap` in a private aggregate device).
Every 100 ms it prints the RMS level and a 20-band spectrum (1024-point Hann FFT, log-spaced bands, 50 Hz to 16 kHz).

```sh
swift build
.build/debug/TapSpike --selftest     # FFT/RMS check with a synthetic 1 kHz sine
.build/debug/TapSpike                # tap Music.app (start a track first)
.build/debug/TapSpike --pid <PID>    # tap any process, e.g. afplay, to test the pipeline
scripts/tapspike-app.sh              # same as above, run from a minimal .app bundle
```

Ctrl+C stops the IOProc and destroys the aggregate device and the tap.

Output line meanings:
- `(no callbacks)`: the IOProc did not run. A tap-only aggregate device runs only while the tapped process plays audio.
- `(digital silence)`: buffers arrive but hold only zeros. This is what a denied permission (or blocked DRM audio) looks like.

### Why two ways to run it

The bare CLI embeds its Info.plist (with `NSAudioCaptureUsageDescription`) in the binary through a `-sectcreate __TEXT __info_plist` linker flag.
But TCC gives the permission to the *responsible process*. For a CLI, that is the terminal app (Terminal, iTerm, VS Code).
`scripts/tapspike-app.sh` wraps the binary in an ad-hoc-signed `.app` and launches it with `open`, so TapSpike asks for itself.
The ad-hoc signature changes on every build, so macOS can ask again after a rebuild.

Result (macOS 27.0.1): the bare CLI, run from the VS Code terminal, showed **no** permission prompt and captured
real audio from a streamed, FairPlay-protected Apple Music track ("HLS media"). DRM does not silence the tap.

## Phase 2: MusicControl

`Sources/MusicControl` controls Music.app with public APIs only:

- Track and state changes: the `com.apple.Music.playerInfo` distributed notification (`PlayerInfoObserver`). No polling.
- Commands: `NSAppleScript` (play/pause, next, previous, seek, volume, shuffle, repeat, play track N).
- Position: `PositionPoller` reads `player position` at 4 Hz. The app starts it only while the window is visible.
- Playlist: one Apple Event fetches each column (`name of every track of current playlist`, and so on). 1302 tracks take about 270 ms.

```sh
.build/debug/MusicCtl selftest
.build/debug/MusicCtl watch          # notifications + 4 Hz position; Ctrl+C to stop
.build/debug/MusicCtl status | playlist | eq Rock
.build/debug/MusicCtl playpause | next | prev | seek 60 | volume 40 | shuffle on | repeat all
.build/debug/MusicCtl eqset Manual 1 3.5    # band 1 (32 Hz) of preset "Manual" to +3.5 dB
```

### Equalizer limits (Music 1.7, macOS 27.0.1)

| AppleScript property | Read | Write |
|---|---|---|
| `band 1` … `band 10`, `preamp` of any EQ preset | yes | yes (-12 to +12 dB) |
| `EQ enabled` | yes | **no** (error -10006) |
| `current EQ preset` | **no** (error -1731) | **no** (error -1731) |

All 23 presets report `modifiable = true`, including the built-in ones.
Tested later (Phase 4): edits are saved, but Music's live EQ ignores them until you select the preset again
in Music or relaunch Music, and `EQ enabled` reads `false` even while it is on. So the app does not use
Music's EQ; it has its own (see Phase 4). `MusicCtl eq`/`eqset` still read and write Music's presets.

## Phase 3: skin engine and main window

- `Skin` reads a `.wsz` with ZIPFoundation, matching file names case-insensitively and ignoring folders inside the zip.
  It decodes each bitmap once to RGBA. Any missing bitmap, too-small bitmap or missing viscolor colour comes from the
  bundled default skin (`Support/base-2.91.wsz`). Zip entries over 8 MB are skipped.
- `MainView` draws every sprite in 275×116 base coordinates. It re-renders every frame (30 fps) only while the
  visualizer moves; otherwise about 4 times per second (marquee) or when the state changes.
- `Visualizer` uses a 75-band FFT from the process tap. Thick mode shows 19 bars (the loudest of each group of 4 bands);
  thin mode shows 75. Peaks fall with gravity. The oscilloscope uses the last 576 samples.
  The dB window (-60 to -6 dB) and fall speeds are constants at the top of `Visualizer.swift`.
- `PositionPoller` reads the position at 4 Hz and volume, shuffle and repeat every 2 s, only while the window is visible.

Checks (no screen needed):

```sh
.build/debug/MusicAmp --selftest              # EQ response, skin parsing, viscolor, pledit.txt, snapping, docking
.build/debug/MusicAmp --snapshot /tmp/a.png   # writes a.png (+ a-eq.png, a-pl.png if open) after 2 s, then quits
```

Measured on macOS 27.0.1 with a streamed track playing (main window only, before Phase 4's rendering change):
CPU about 7% with thick bars, 8% with thin bars, 4% with the visualizer off, and 2.6% when paused.

## Phase 4: equalizer and playlist windows

**Equalizer** (`EqualizerView`, eqmain.bmp) is MusicAmp's own 10-band EQ, not Music's. Music's EQ cannot be
driven live by a script (see Phase 2): script edits change the saved preset, but Music's live EQ reloads a preset
only when you select it in Music's window or relaunch Music, and a script cannot select one.

How it works (`EqualizerDSP`, `ProcessTap` output mode):

- The process tap sits in a private aggregate device together with the default output device. One real-time
  callback reads Music's audio from the tap and writes the processed audio to the device, on the same clock,
  with no extra buffering. Added latency is roughly one IO cycle (about 10–20 ms).
- **ON**: the tap mutes Music's own output and MusicAmp plays the EQ'd audio. **OFF**: the tap is unmuted, MusicAmp
  writes silence, and Music plays exactly as without MusicAmp. If MusicAmp quits or crashes, the tap disappears and
  Music plays normally.
- Peaking biquads (RBJ cookbook, Q 1.4) at Winamp's 60 Hz…16 kHz, in 32-bit float, at the device's sample rate,
  so there is no extra resampling. With all sliders at 0 dB the samples pass through unchanged.
- **AUTO** is automatic headroom: the output drops by the largest boost, so boosts cannot clip. The preamp adds to it.
- **PRESETS**: Flat, or copy the values of one of Music's presets.
- Settings are saved. Changing the default output device rebuilds the tap. If the device cannot join an aggregate
  device (for example AirPlay), MusicAmp keeps the visualizer and explains that the EQ is unavailable.
- The tap mixes down to stereo, so multichannel (Dolby Atmos to a multichannel device) becomes stereo while the EQ is on.

Measured with a streamed track: EQ on and flat, MusicAmp's output level matched Music's (-36.1 vs -37.8 dBFS);
all bands at -12 dB, it was about 15 dB lower (neighbouring bands overlap); EQ off, MusicAmp output silence.

**Playlist** (`PlaylistView`, pledit.bmp, Winamp's default 275×232 size). By default it shows Music's now-playing
playlist. Use **LIST OPTS** (bottom right) or the right-click menu's **Playlist Source** to show the library, any
of your playlists, or an Apple Music playlist you added; "Now Playing" goes back to the default. It uses
the colours and font from pledit.txt. The current track uses the "Current" colour and scrolls into view when it changes.
Click selects; double-click plays. Scroll with the wheel or drag the scroll handle. The mini transport buttons work.
The bottom text shows the selected track's length / the total length, and the elapsed time.

On every track change, MusicAmp checks the now-playing playlist's persistent ID (2 Apple Events) and fetches the
track list again only when the shown playlist changes. Double-click plays that track in the shown playlist.

**Rendering.** Each window renders at its base pixel size into a layer, and the GPU scales it with nearest-neighbour
filtering. The playlist renders at screen resolution so its text stays sharp. With all three windows open and music
playing: 26 MB footprint at 1×, 33 MB at 2×, 43 MB at 3×; CPU about 8–10%.

## Permissions

| Permission | Info.plist key | Why | Where to reset |
|---|---|---|---|
| System Audio Recording Only | `NSAudioCaptureUsageDescription` | Read Music.app's audio for the visualizer | System Settings > Privacy & Security > Screen & System Audio Recording |
| Automation > Music | `NSAppleEventsUsageDescription` | Control playback, EQ and playlist | System Settings > Privacy & Security > Automation |

When you run the CLIs from a terminal, macOS asks on behalf of the terminal app, not the CLI.

## Credits

- Sprite coordinates, element positions and the text font table come from
  [Webamp](https://github.com/captbaritone/webamp) by Jordan Eldredge (MIT): `skinSprites.ts`,
  `main-window.css`, `equalizer-window.css`, `playlist-window.css` and the EQ band sprite math.
- The default skin `Support/base-2.91.wsz` is the Winamp 2.91 base skin (Nullsoft), copied from the Webamp repository.
