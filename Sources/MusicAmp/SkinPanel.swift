import AppKit

/// Borderless, non-activating panel at normal window level (stays on one Space) that snaps to screen edges while dragged.
final class SkinPanel: NSPanel {
    static let snapDistance: CGFloat = 20 // 10 (Winamp's) felt too subtle

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false // the app is an accessory, so it is almost never active
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    // Borderless windows refuse key status by default; the skin needs it for Ctrl+D. Being a
    // non-activating panel, becoming key does not activate MusicAmp or take the menu bar.
    override var canBecomeKey: Bool { true }

    /// Moves the window, snapping to the edges of the screen under the mouse and of `others` (other windows).
    func moveSnapped(to origin: NSPoint, others: [NSRect] = []) {
        let mouse = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? screen)?.visibleFrame ?? .zero
        setFrameOrigin(Self.snap(NSRect(origin: origin, size: frame.size), to: visible, others: others))
    }

    /// Origin for `f` after snapping, per axis, the closest edge within `snapDistance`:
    /// screen edges (same edge), and other windows' facing edges (to dock) or same edges (to align when docked).
    static func snap(_ f: NSRect, to visible: NSRect, others: [NSRect] = []) -> NSPoint {
        var o = f.origin
        var bestX = snapDistance, bestY = snapDistance
        func tryX(_ edge: CGFloat, _ target: CGFloat) {
            if abs(edge - target) < bestX { bestX = abs(edge - target); o.x = f.minX + target - edge }
        }
        func tryY(_ edge: CGFloat, _ target: CGFloat) {
            if abs(edge - target) < bestY { bestY = abs(edge - target); o.y = f.minY + target - edge }
        }
        tryX(f.minX, visible.minX); tryX(f.maxX, visible.maxX)
        tryY(f.minY, visible.minY); tryY(f.maxY, visible.maxY)
        let d = snapDistance
        for r in others {
            let besideY = f.minY < r.maxY + d && r.minY < f.maxY + d // vertical ranges overlap (or nearly)
            let besideX = f.minX < r.maxX + d && r.minX < f.maxX + d
            if besideY { tryX(f.minX, r.maxX); tryX(f.maxX, r.minX) } // side by side
            if besideX { tryY(f.minY, r.maxY); tryY(f.maxY, r.minY) } // stacked
            if besideX && (abs(f.minY - r.maxY) < d || abs(f.maxY - r.minY) < d) { tryX(f.minX, r.minX); tryX(f.maxX, r.maxX) }
            if besideY && (abs(f.minX - r.maxX) < d || abs(f.maxX - r.minX) < d) { tryY(f.minY, r.minY); tryY(f.maxY, r.maxY) }
        }
        return o
    }

    /// True when two frames share an edge (within 1 pt) and overlap along it: Winamp's "docked".
    static func docked(_ a: NSRect, _ b: NSRect) -> Bool {
        let t: CGFloat = 1
        let overlapX = a.minX < b.maxX - t && b.minX < a.maxX - t
        let overlapY = a.minY < b.maxY - t && b.minY < a.maxY - t
        return overlapX && (abs(a.minY - b.maxY) <= t || abs(a.maxY - b.minY) <= t)
            || overlapY && (abs(a.minX - b.maxX) <= t || abs(a.maxX - b.minX) <= t)
    }

    /// Indices of `others` docked to `lead` directly or through each other.
    static func dockedGroup(_ lead: NSRect, _ others: [NSRect]) -> [Int] {
        var group: [Int] = [], frontier = [lead]
        while let f = frontier.popLast() {
            for (i, r) in others.enumerated() where !group.contains(i) && docked(f, r) {
                group.append(i)
                frontier.append(r)
            }
        }
        return group.sorted()
    }
}
