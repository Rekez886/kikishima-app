import Foundation
import CoreGraphics

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

let environment = ProcessInfo.processInfo.environment
let suitePrefix = environment["KK_NOTCH_TEST_PREFIX"] ?? ""
let scratchRoot = environment["KK_TEST_NOTCH_ROOT"] ?? ""
precondition(suitePrefix.range(of: #"^kikishima-notch-default-test-[A-Za-z0-9]{6}-$"#,
                               options: .regularExpression) != nil, "missing safe run prefix")
let preferences = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")

func removeSuite(_ defaults: UserDefaults, _ name: String) {
    precondition(name.hasPrefix(suitePrefix) && UUID(uuidString: String(name.dropFirst(suitePrefix.count))) != nil,
                 "refusing suite outside this run")
    let file = preferences.appendingPathComponent(name + ".plist")
    let manager = FileManager.default
    // lstat semantics: a dangling symlink must also be rejected.
    if let attributes = try? manager.attributesOfItem(atPath: file.path) {
        precondition(attributes[.type] as? FileAttributeType == .typeRegular, "unsafe preference file")
    }
    defaults.removePersistentDomain(forName: name)
    precondition(defaults.synchronize(), "preference cleanup did not synchronize")
    do {
        let attributes = try manager.attributesOfItem(atPath: file.path)
        precondition(attributes[.type] as? FileAttributeType == .typeRegular, "unsafe preference file")
        try manager.removeItem(at: file)
    } catch let error as NSError {
        precondition(error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError,
                     "cannot remove own preference plist: \(error)")
    }
}

func withDefaults(_ body: (UserDefaults, String) -> Void) {
    let name = suitePrefix + UUID().uuidString
    // Register ownership before UserDefaults can create a persistent domain.
    let registration = URL(fileURLWithPath: scratchRoot).appendingPathComponent("suites/" + name)
    try! Data().write(to: registration, options: .withoutOverwriting)
    let defaults = UserDefaults(suiteName: name)!
    defer { removeSuite(defaults, name) }
    if let fault = environment["KK_NOTCH_TEST_FAULT"], !fault.isEmpty {
        defaults.set("fault fixture", forKey: "testFault")
        precondition(defaults.synchronize(), "fault fixture did not synchronize")
        if fault == "fail" {
            check(false, "injected notch default failure")
        } else if fault.hasPrefix("wait:") {
            try! Data(name.utf8).write(to: URL(fileURLWithPath: String(fault.dropFirst(5))))
            while true { Thread.sleep(forTimeInterval: 1) }
        } else {
            preconditionFailure("unknown notch test fault")
        }
    }
    body(defaults, name)
}

withDefaults { defaults, _ in
    check(CaptionSurfacePreference.load(from: defaults) == "island", "fresh install")
    check(defaults.bool(forKey: CaptionSurfacePreference.migrationKey), "migration recorded")
    check(!defaults.bool(forKey: CaptionSurfacePreference.explicitKey), "default is not a user choice")
}
for legacy in [nil, "window", "island"] as [String?] {
    withDefaults { defaults, _ in
        defaults.set("0.38", forKey: "testInstalledVersion")
        defaults.set(legacy, forKey: CaptionSurfacePreference.valueKey)
        check(CaptionSurfacePreference.load(from: defaults) == "island", "legacy unmarked value migrates")
    }
}
for selected in ["window", "island", "attached"] {
    withDefaults { defaults, _ in
        CaptionSurfacePreference.select(selected, in: defaults)
        check(CaptionSurfacePreference.load(from: defaults) == selected, "explicit selection preserved")
        check(defaults.bool(forKey: CaptionSurfacePreference.explicitKey), "intent recorded")
    }
}
withDefaults { defaults, name in
    defaults.set("window", forKey: CaptionSurfacePreference.valueKey)
    check(CaptionSurfacePreference.load(from: defaults) == "island", "first launch migrates")
    CaptionSurfacePreference.select("window", in: defaults)
    let restarted = UserDefaults(suiteName: name)!
    check(CaptionSurfacePreference.load(from: restarted) == "window", "restart keeps later desktop choice")
}
withDefaults { defaults, name in
    _ = CaptionSurfacePreference.load(from: defaults)
    // A program write is not intent; one-shot migration must nevertheless stay done.
    defaults.set("window", forKey: CaptionSurfacePreference.valueKey)
    check(!defaults.bool(forKey: CaptionSurfacePreference.explicitKey), "program write has no user marker")
    check(CaptionSurfacePreference.load(from: UserDefaults(suiteName: name)!) == "window", "migration only once")
}

typealias Display = CaptionScreenPolicy.Display
let external = Display(isBuiltIn: false, hasNotch: false)
let builtInNotch = Display(isBuiltIn: true, hasNotch: true)
let builtInFlat = Display(isBuiltIn: true, hasNotch: false)
check(CaptionScreenPolicy.islandIndex(displays: [external, external]) == 0, "external-only menu bar")
check(CaptionScreenPolicy.islandIndex(displays: [external, builtInNotch]) == 1, "notched built-in beats external primary")
check(CaptionScreenPolicy.islandIndex(displays: [external, builtInFlat]) == 0, "flat built-in does not beat primary")
for display in [external, builtInFlat, builtInNotch] {
    check(CaptionScreenPolicy.islandIndex(displays: [display]) == 0, "single display")
}
check(CaptionScreenPolicy.islandIndex(displays: []) == nil, "no display")
check(CaptionScreenPolicy.islandIndex(displays: [Display(isBuiltIn: false, hasNotch: true), builtInNotch]) == 1,
      "built-in is required for priority")
for screen in [CGRect(x: 0, y: 0, width: 1920, height: 1080),
               CGRect(x: -1920, y: 400, width: 1920, height: 1080)] {
    for size in [CGSize(width: 180, height: 35), CGSize(width: 560, height: 191)] {
        let visible = CGRect(x: screen.minX + 60, y: screen.minY, width: screen.width - 60, height: screen.height - 25)
        let frame = CaptionScreenPolicy.floatingFrame(screenFrame: screen, visibleFrame: visible, size: size)
        check(frame.maxY == visible.maxY - 8, "capsule top is menu bar bottom minus 8pt")
        check(frame.midX == screen.midX, "capsule centered in compact and expanded states")
    }
}
check(CaptionSurfacePreference.usesIsland(surface: "island"), "island independent of scene/engine")
check(!CaptionSurfacePreference.usesIsland(surface: "window"), "desktop choice stays desktop")
print("PASS notch default: migration, explicit intent, restart, display selection, capsule geometry")
