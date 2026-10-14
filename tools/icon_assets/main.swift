import AppKit

@main struct GenerateIcons {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func render(width: Int, height: Int, draw: () -> Void) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let size = points * scale
                let data = render(width: size, height: size) {
                    BrandIcons.drawAppIcon(in: NSRect(x: 0, y: 0, width: size, height: size))
                }
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
        // Actual shared drawing code, at native menu size and 4x for visual inspection.
        let preview = render(width: 720, height: 280) {
            NSColor.white.setFill(); NSRect(x: 0, y: 140, width: 720, height: 140).fill()
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 720, height: 140).fill()
            for (i, status) in CaptionMenuStatus.allCases.enumerated() {
                for (base, color) in [(CGFloat(140), NSColor.black), (CGFloat(0), NSColor.white)] {
                    BrandIcons.drawMenuIcon(status, in: NSRect(x: 32 + i * 140, y: Int(base) + 52, width: 72, height: 72), color: color)
                    BrandIcons.drawMenuIcon(status, in: NSRect(x: 56 + i * 140, y: Int(base) + 18, width: 18, height: 18), color: color)
                }
            }
        }
        try preview.write(to: folder.deletingLastPathComponent().appendingPathComponent("menu-states.png"))
    }
}
