import AppKit

/// Visual state only: does not change capture, translation or session controls.
enum CaptionMenuStatus: String, CaseIterable {
    case idle, starting, running, paused, translationPaused

    static func resolve(running: Bool, starting: Bool, paused: Bool,
                        translationPaused: Bool, resuming: Bool, switchingLanguage: Bool) -> Self {
        if starting || resuming || switchingLanguage { return .starting }
        guard running else { return .idle }
        if paused { return .paused }
        return translationPaused ? .translationPaused : .running
    }
}

/// C · キ, reconstructed from DESIGN.md and the approved icon-C reference.
/// Shared vector geometry keeps the build-time app icon and runtime templates aligned.
@MainActor
enum BrandIcons {
    private static func stem() -> NSBezierPath {
        NSBezierPath(rect: NSRect(x: 456, y: 184, width: 112, height: 656))
    }

    private static func bar(width: CGFloat, centerY: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(rect: NSRect(x: -width / 2, y: -52, width: width, height: 104))
        let transform = NSAffineTransform()
        transform.translateX(by: 512, yBy: centerY)
        transform.rotate(byDegrees: 8)
        path.transform(using: transform as AffineTransform)
        return path
    }

    private static func bars() -> NSBezierPath {
        let path = bar(width: 512, centerY: 632)
        path.append(bar(width: 608, centerY: 424))
        return path
    }

    private static func glyph() -> NSBezierPath {
        let path = stem()
        path.append(bars())
        return path
    }

    static func drawAppIcon(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let t = NSAffineTransform()
        t.translateX(by: rect.minX, yBy: rect.minY)
        t.scaleX(by: rect.width / 1024, yBy: rect.height / 1024)
        t.concat()
        NSColor(srgbRed: 1, green: 59.0 / 255, blue: 31.0 / 255, alpha: 1).setFill()
        // Legacy .icns carries its own rounded silhouette, matching the approved preview.
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                     xRadius: 232, yRadius: 232).fill()
        NSColor.white.setFill()
        glyph().fill()
    }

    static func drawMenuIcon(_ status: CaptionMenuStatus, in rect: NSRect, color: NSColor = .black) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let outer = NSAffineTransform()
        outer.translateX(by: rect.minX, yBy: rect.minY)
        outer.scaleX(by: rect.width / 18, yBy: rect.height / 18)
        outer.concat()
        if status == .paused {
            color.setFill()
            NSBezierPath(rect: NSRect(x: 4.5, y: 2, width: 3, height: 14)).fill()
            NSBezierPath(rect: NSRect(x: 10.5, y: 2, width: 3, height: 14)).fill()
            return
        }
        let glyphTransform = NSAffineTransform()
        glyphTransform.translateX(by: 9, yBy: 9)
        glyphTransform.scale(by: 18.0 / 832)
        glyphTransform.translateX(by: -512, yBy: -512)
        if status == .starting {
            let path = bars(); path.transform(using: glyphTransform as AffineTransform)
            color.withAlphaComponent(0.35).setFill(); path.fill()
            let solid = stem(); solid.transform(using: glyphTransform as AffineTransform)
            color.setFill(); solid.fill()
        } else {
            let path = glyph(); path.transform(using: glyphTransform as AffineTransform)
            color.withAlphaComponent(status == .idle ? 0.45 : 1).setFill()
            path.fill()
        }
        if status == .translationPaused {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13.25, y: 13.25, width: 4.5, height: 4.5)).fill()
        }
    }

    static let appImage = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        drawAppIcon(in: rect)
        return true
    }

    private static let templates: [CaptionMenuStatus: NSImage] = Dictionary(uniqueKeysWithValues:
        CaptionMenuStatus.allCases.map { status in
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                drawMenuIcon(status, in: rect)
                return true
            }
            image.isTemplate = true
            return (status, image)
        }
    )

    static func menuImage(_ status: CaptionMenuStatus) -> NSImage { templates[status]! }
}
