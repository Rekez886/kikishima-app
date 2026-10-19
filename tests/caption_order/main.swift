import AppKit
import SwiftUI

@main struct CaptionOrderColors {
    static func rgb(_ color: Color, _ appearance: NSAppearance.Name) -> [Int] {
        var result: [Int] = []
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let value = NSColor(color).usingColorSpace(.sRGB)!
            result = [value.redComponent, value.greenComponent, value.blueComponent]
                .map { Int(($0 * 255).rounded()) }
        }
        return result
    }

    static func main() {
        let cases: [(Color, [Int], [Int])] = [
            (KKColor.surfaceRaised, [32, 33, 35], [247, 247, 248]),
            (KKColor.textPrimary, [245, 245, 245], [26, 26, 28]),
            (KKColor.brand, [242, 96, 61], [200, 64, 31]),
            (KKColor.brandOn, [21, 21, 21], [255, 255, 255])
        ]
        for (color, dark, light) in cases {
            precondition(rgb(color, .darkAqua) == dark, "dark token")
            precondition(rgb(color, .aqua) == light, "light token")
            precondition(rgb(color, .darkAqua) == dark, "appearance switches back")
        }
        print("PASS active and idle button tokens: exact dark/light values")
    }
}
