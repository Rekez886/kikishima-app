import Foundation

@main
struct ShootNotchTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--validate") { _ = ShootNotch.configuration; return }
        let frame = NotchMeasurement.required(NotchMeasurement.frame, "frame")
        let top = NotchMeasurement.required(NotchMeasurement.safeAreaTop, "safeAreaTop")
        let left = NotchMeasurement.required(NotchMeasurement.auxiliaryTopLeftArea, "auxiliaryTopLeftArea")
        let right = NotchMeasurement.required(NotchMeasurement.auxiliaryTopRightArea, "auxiliaryTopRightArea")
        let menuHeight = NotchMeasurement.required(NotchMeasurement.menuBarHeight, "menuBarHeight")
        let raw = "top=\(top),left=\(left.width),right=\(right.width),screen=\(frame.width),menubar=\(menuHeight)"
        let config = try ShootNotchConfiguration.parse(raw)
        precondition(config.top == top && config.left == left.width && config.right == right.width)
        precondition(config.screen == frame.width && config.radius == 8)
        precondition(config.width == frame.width - left.width - right.width)
        precondition(config.menubar == 33 && config.top == 32)
        // Geometry uses only width, height and position; no measured radius is assumed.
        let window = CaptionIslandLayout.notchedWindowFrame(screenFrame: frame,
            notchHeight: config.menubar, contentSize: CGSize(width: 390, height: 100))
        precondition(window.width == 420 && window.height == 100 + 33 + 15)
        precondition(window.midX == frame.midX && window.maxY == frame.maxY)
        precondition(config.width == 185 && config.top == 32) // mask dimensions
        let base = raw.split(separator: ",").filter { !$0.hasPrefix("menubar=") }.joined(separator: ",")
        let defaults = try ShootNotchConfiguration.parse(base)
        precondition(defaults.menubar == top && defaults.radius == 8)
        for radius in [0, 12, 32] {
            let explicit = try ShootNotchConfiguration.parse(raw + ",radius=\(radius)")
            precondition(explicit.radius == CGFloat(radius) && explicit.menubar == 33)
        }
        let radiusOnly = try ShootNotchConfiguration.parse(base + ",radius=12")
        precondition(radiusOnly.radius == 12 && radiusOnly.menubar == top)
        let environment = ["KIKISHIMA_SHOOT_NOTCH": raw]
        let fromEnvironment = try ShootNotchConfiguration.requested(arguments: [], environment: environment)
        precondition(fromEnvironment == config)
        let fromArgument = try ShootNotchConfiguration.requested(arguments: ["-KikishimaShootNotch", raw],
            environment: ["KIKISHIMA_SHOOT_NOTCH": "invalid"])
        precondition(fromArgument == config)
        let absent = try ShootNotchConfiguration.requested(arguments: [], environment: [:])
        precondition(absent == nil)
        func rejects(_ bad: String) {
            do { _ = try ShootNotchConfiguration.parse(bad); fatalError("accepted invalid input: \(bad)") }
            catch ShootNotchConfiguration.Invalid.configuration { }
            catch { fatalError("unexpected error: \(error)") }
        }
        let parts = (raw + ",radius=8").split(separator: ",").map(String.init)
        for key in ["top", "left", "right", "screen"] {
            rejects(parts.filter { !$0.hasPrefix(key + "=") }.joined(separator: ","))
        }
        for key in ["top", "left", "right", "screen", "radius", "menubar"] {
            for value in ["bad", "-1", "nan", "inf"] {
                rejects(parts.map { $0.hasPrefix(key + "=") ? key + "=" + value : $0 }.joined(separator: ","))
            }
            rejects(parts.joined(separator: ",") + "," + key + "=0")
        }
        for bad in [raw + ",radius=33", raw + ",other=0", raw + ",", "",
                    "top=0,left=0,right=0,screen=100",
                    "top=32,left=50,right=50,screen=100",
                    "top=32,left=49,right=49,screen=100,radius=2"] {
            rejects(bad)
        }
        do {
            _ = try ShootNotchConfiguration.requested(arguments: ["-KikishimaShootNotch"], environment: environment)
            fatalError("missing argument fell back to environment")
        } catch ShootNotchConfiguration.Invalid.configuration { }
        print("PASS SHOOT parser: fixture, optional defaults/overrides, precedence, absence, missing, negative, nonfinite, malformed, corner bounds")
    }
}
