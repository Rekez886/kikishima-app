import Foundation
import SwiftUI
import AppKit

@main struct Checks {
    static func main() {
        for (width, expected) in [(2560.0, 800.0), (1440, 800), (1280, 800), (800, 776)] {
            let content = CaptionIslandLayout.notchContentSize(visibleFrame: CGRect(x: 100, y: 0, width: width, height: 900), widthLevel: .large, heightLevel: .medium)
            precondition(content.width + 30 == expected)
            let frame = CaptionScreenPolicy.floatingFrame(screenFrame: CGRect(x: 100, y: 0, width: width, height: 900), visibleFrame: CGRect(x: 100, y: 0, width: width, height: 876), size: CGSize(width: content.width + 30, height: 143))
            precondition(frame.midX == 100 + width / 2)
            precondition(frame.maxY == 868) // 900 - 24pt menu bar - 8pt gap
        }
        precondition(CaptionIslandLayout.compactWidth(notchWidth: 0) == 240)
        precondition(CaptionIslandLayout.compactWidth(notchWidth: 200) == 440)
        precondition(CaptionHierarchy.historyLimit(userSize: 18, showTranslation: true, showSource: false, banner: false) == 3)
        precondition(CaptionHierarchy.historyLimit(userSize: 18, showTranslation: true, showSource: true, banner: false) == 2)
        for size in [15.0, 18, 26] {
            let limit = CaptionHierarchy.historyLimit(userSize: size, showTranslation: true, showSource: true, banner: false)
            precondition((0...3).contains(limit))
            precondition(70 * size / 18 + 16 + Double(limit) * (25 * size / 18 + 4) <= 153)
        }
        precondition((1...3).map { CaptionHierarchy.opacity(age: $0) } == [0.85, 0.65, 0.50])
        precondition(CaptionHierarchy.maximumHistory == 3)
        precondition(CaptionHierarchy.currentSize == 17 && CaptionHierarchy.sourceSize == 13 && CaptionHierarchy.historySize == 15)
        for size in [15.0, 18, 26] {
            precondition(CaptionHierarchy.fontSize(current: true, userSize: size) > CaptionHierarchy.fontSize(current: false, userSize: size))
        }
        let palettes: [(Color, UInt32, UInt32)] = [
            (KKColor.brand, 0xF2603D, 0xC8401F), (KKColor.brandOn, 0x151515, 0xFFFFFF),
            (KKColor.surfaceBase, 0x151515, 0xFFFFFF), (KKColor.surfaceRaised, 0x202123, 0xF7F7F8),
            (KKColor.textPrimary, 0xF5F5F5, 0x1A1A1C), (KKColor.textSecondary, 0xA6A6A6, 0x6B6B70),
            (KKColor.textTertiary, 0x8A8A8A, 0x6B6B70), (KKColor.historyFloor, 0x808080, 0x808080),
            (KKColor.notchBackground, 0, 0),
            (KKColor.captionWindowBackground, 0, 0xFFFFFF),
            (KKColor.historyInk, 0xFFFFFF, 0x1A1A1C)
        ]
        for (name, dark) in [(NSAppearance.Name.darkAqua, true), (.aqua, false)] {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                for (token, darkHex, lightHex) in palettes {
                    let actual = NSColor(token).usingColorSpace(.sRGB)!
                    let expected = dark ? darkHex : lightHex
                    for (component, shift) in [(actual.redComponent, 16), (actual.greenComponent, 8), (actual.blueComponent, 0)] {
                        precondition(abs(component - CGFloat((expected >> shift) & 255) / 255) < 0.005)
                    }
                }
            }
        }
        print("PASS r2: adaptive palette, final capsule width/centering/top gap, history opacity and scaled type hierarchy")
    }
}
