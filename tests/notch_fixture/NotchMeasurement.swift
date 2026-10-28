import Foundation

// 来源：2026-10-21 12:29:19 JST，MacBookPro18,3（14 寸）开盖后用 NSScreen 读取。
// Built-in Retina Display；按 HANDOFF 原样转录，未重新读取硬件或取整。
enum NotchMeasurement {
    static let frame: CGRect? = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let backingScaleFactor: CGFloat? = 2.0
    static let visibleFrame: CGRect? = CGRect(x: 0, y: 47, width: 1512, height: 902)
    static var menuBarHeight: CGFloat? {
        guard let frame, let visibleFrame else { return nil }
        return frame.maxY - visibleFrame.maxY // 33pt，独立于物理刘海高 32pt
    }
    static let safeAreaTop: CGFloat? = 32
    static let safeAreaLeft: CGFloat? = 0
    static let safeAreaRight: CGFloat? = 0
    static let safeAreaBottom: CGFloat? = 0
    static let auxiliaryTopLeftArea: CGRect? = CGRect(x: 0, y: 950, width: 663.5, height: 32)
    static let auxiliaryTopRightArea: CGRect? = CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
    static let notchBottomRadius: CGFloat? = nil // 无实测来源，no measured source yet

    static func required<T>(_ value: T?, _ field: String) -> T {
        guard let value else {
            fputs("NOTCH MEASUREMENT MISSING: \(field) in tests/notch_fixture/NotchMeasurement.swift\n", stderr)
            exit(1)
        }
        return value
    }
}
