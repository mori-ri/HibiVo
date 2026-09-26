// Generates app and menu bar icons from Resources/AppIconSource.png (transparent background).
//
//   swift scripts/make-icons.swift
//
// Outputs:
//   Resources/AppIcon.icns          logo on a white rounded square (macOS app icon grid)
//   Resources/MenuBarIcon.png/@2x   monochrome template silhouette for the menu bar
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appending(path: "Resources")

guard let source = NSImage(contentsOf: resources.appending(path: "AppIconSource.png")),
    let sourceRep = source.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: source.tiffRepresentation!)
else { fatalError("Resources/AppIconSource.png not found") }

/// Bounding box of non-transparent pixels, in image coordinates (origin bottom-left).
func contentBounds(_ rep: NSBitmapImageRep) -> NSRect {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // colorAt uses top-left origin; convert to bottom-left for drawing.
    return NSRect(x: minX, y: rep.pixelsHigh - maxY - 1, width: maxX - minX + 1, height: maxY - minY + 1)
}

let crop = contentBounds(sourceRep)
let sourceSize = NSSize(width: sourceRep.pixelsWide, height: sourceRep.pixelsHigh)
source.size = sourceSize

func render(pixels: NSSize, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(origin: .zero, size: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawLogo(fitting box: NSRect) {
    let scale = min(box.width / crop.width, box.height / crop.height)
    let size = NSSize(width: crop.width * scale, height: crop.height * scale)
    let dest = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    source.draw(in: dest, from: crop, operation: .sourceOver, fraction: 1)
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: App icon (1024 grid: 824 pt rounded square, ~22% corner radius, 100 pt margin)

func appIcon(pixels: Int) -> NSBitmapImageRep {
    render(pixels: NSSize(width: pixels, height: pixels)) { canvas in
        let unit = canvas.width / 1024
        let tile = canvas.insetBy(dx: 100 * unit, dy: 100 * unit).offsetBy(dx: 0, dy: 6 * unit)
        let path = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 18 * unit
        shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        path.addClip()
        drawLogo(fitting: tile.insetBy(dx: tile.width * 0.1, dy: tile.height * 0.1))
    }
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(appIcon(pixels: points), to: iconset.appending(path: "icon_\(points)x\(points).png"))
    writePNG(appIcon(pixels: points * 2), to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appending(path: "AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")

// MARK: Menu bar template (black + alpha only; macOS tints it for light/dark menu bars)

let menuBarHeight: CGFloat = 16
let menuBarWidth = (crop.width / crop.height * menuBarHeight).rounded(.up)
for scale in [1, 2] {
    let pixels = NSSize(width: menuBarWidth * CGFloat(scale), height: menuBarHeight * CGFloat(scale))
    let rep = render(pixels: pixels) { canvas in
        drawLogo(fitting: canvas)
        NSColor.black.setFill()
        canvas.fill(using: .sourceIn)  // Keep the logo's alpha, replace its colour with black.
    }
    rep.size = NSSize(width: menuBarWidth, height: menuBarHeight)
    writePNG(rep, to: resources.appending(path: scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@2x.png"))
}

print("Wrote AppIcon.icns and MenuBarIcon.png (\(Int(menuBarWidth))x\(Int(menuBarHeight)) pt)")
