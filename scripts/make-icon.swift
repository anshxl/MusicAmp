// Builds Support/AppIcon.icns and Support/AppIcon.png from Support/AppIcon-source.jpg.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

// The source is a 1024×1024 JPEG: a rounded square on a grey background with a soft shadow.
// ponytail: crop rectangle and corner radius measured from this one image; re-measure for a new source.
let cardInSource = CGRect(x: 173, y: 173, width: 680, height: 695) // just inside the card's edge, top-left origin
let body = CGRect(x: 100, y: 100, width: 824, height: 824)         // Apple's icon grid: 824 px body in 1024
let cornerRadius: CGFloat = 170                                    // covers the card's own corner (≈160 at this size)

let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: "Support/AppIcon-source.jpg")))!.cgImage!
let card = source.cropping(to: cardInSource)!

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    ctx.clip() // everything outside the rounded square stays transparent
    ctx.draw(card, in: body)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try writePNG(render(points), iconset.appendingPathComponent("icon_\(points)x\(points).png").path)
    try writePNG(render(points * 2), iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png").path)
}
try writePNG(render(1024), "Support/AppIcon.png")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("Wrote Support/AppIcon.icns and Support/AppIcon.png")
