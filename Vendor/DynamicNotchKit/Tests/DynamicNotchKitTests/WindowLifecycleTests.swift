import XCTest
import SwiftUI
@testable import DynamicNotchKit

final class WindowLifecycleTests: XCTestCase {
    @MainActor
    func testExplicitHideWhileHovered() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let notch = DynamicNotch(hoverBehavior: [], style: .floating) { Text("Test captions") }
        await notch.expand(on: screen)
        notch.updateHoverState(true)
        XCTAssertTrue(notch.isHovering)
        // Use a bounded observation rather than waiting forever on a broken hide.
        let hide = Task { await notch.hide() }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(notch.state, .hidden)
        XCTAssertNil(notch.windowController)
        notch.updateHoverState(false)
        await hide.value
    }

    @MainActor
    func testConfigurationBeforeFirstDisplayAndOnRecreation() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let notch = DynamicNotch(hoverBehavior: [], style: .floating) { Text("Test captions") }
        var configuredWindows: [NSWindow] = []
        notch.configureWindow = { panel, target in
            XCTAssertFalse(panel.isVisible, "Policy must be applied before orderFront")
            XCTAssertEqual(target, screen)
            panel.level = .floating
            panel.sharingType = .none
            panel.ignoresMouseEvents = true
            panel.setFrame(NSRect(x: screen.frame.midX - 150, y: screen.frame.maxY - 100,
                                  width: 300, height: 100), display: false)
            configuredWindows.append(panel)
        }
        for _ in 0..<2 {
            await notch.expand(on: screen)
            let panel = try XCTUnwrap(notch.windowController?.window)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.level, .floating)
            XCTAssertEqual(panel.sharingType, .none)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertEqual(panel.frame.width, 300)
            await notch.hide()
            XCTAssertNil(notch.windowController)
        }
        XCTAssertEqual(configuredWindows.count, 2)
        XCTAssertFalse(configuredWindows[0] === configuredWindows[1])
    }
}
