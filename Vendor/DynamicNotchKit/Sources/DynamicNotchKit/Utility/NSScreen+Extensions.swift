//
//  NSScreen+Extensions.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2024-04-06.
//

import SwiftUI

#if SHOOT
/// Installed by the SHOOT host before DynamicNotch selects its presentation path.
public enum ShootNotchInjection {
    nonisolated(unsafe) public static var screen: NSScreen?
    nonisolated(unsafe) public static var size: NSSize?
    nonisolated(unsafe) public static var menuBarHeight: CGFloat?
    public static func menuBarHeight(for candidate: NSScreen) -> CGFloat? {
        candidate === screen ? menuBarHeight : nil
    }
    public static func size(for candidate: NSScreen) -> NSSize? {
        candidate === screen ? size : nil
    }
}
#endif

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screenWithMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) })

        return screenWithMouse
    }

    var hasNotch: Bool {
#if SHOOT
        if ShootNotchInjection.size(for: self) != nil { return true }
#endif
        if auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil { return true }
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 && safeAreaInsets.top > 0
    }

    var notchSize: NSSize? {
#if SHOOT
        if let size = ShootNotchInjection.size(for: self) { return size }
#endif
        guard
            let topLeftNotchpadding: CGFloat = auxiliaryTopLeftArea?.width,
            let topRightNotchpadding: CGFloat = auxiliaryTopRightArea?.width
        else {
            return nil
        }

        let notchHeight = safeAreaInsets.top
        let notchWidth = frame.width - topLeftNotchpadding - topRightNotchpadding
        return .init(width: notchWidth, height: notchHeight)
    }

    var notchFrame: NSRect? {
        guard let notchSize else { return nil }
        return .init(
            x: frame.midX - (notchSize.width / 2),
            y: frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    var menubarHeight: CGFloat {
#if SHOOT
        if let height = ShootNotchInjection.menuBarHeight(for: self) { return height }
#endif
        return frame.maxY - visibleFrame.maxY
    }

    var notchFrameWithMenubarAsBackup: NSRect {
        if let notchFrame {
            return notchFrame
        } else {
            let arbitraryNotchWidth: CGFloat = 300
            let arbitraryNotchHeight: CGFloat = menubarHeight

            let arbitraryNotchFrame = NSRect(
                x: frame.midX - (arbitraryNotchWidth / 2),
                y: frame.maxY - arbitraryNotchHeight,
                width: arbitraryNotchWidth,
                height: arbitraryNotchHeight
            )

            return arbitraryNotchFrame
        }
    }
}
