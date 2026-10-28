import Foundation

/// Only the UI selection entry point records intent. Legacy values have no provenance.
enum CaptionSurfacePreference {
    static let valueKey = "captionSurface"
    static let explicitKey = "captionSurfaceUserSelected"
    static let migrationKey = "captionSurfaceNotchDefaultV1"

    static func load(from defaults: UserDefaults) -> String {
        if !defaults.bool(forKey: migrationKey) {
            // Pre-marker data cannot distinguish a default/program write from a click.
            if !defaults.bool(forKey: explicitKey) {
                defaults.set("island", forKey: valueKey)
            }
            defaults.set(true, forKey: migrationKey)
        }
        return defaults.string(forKey: valueKey) ?? "island"
    }

    static func select(_ value: String, in defaults: UserDefaults) {
        defaults.set(value, forKey: valueKey)
        defaults.set(true, forKey: explicitKey)
    }

    static func usesIsland(surface: String) -> Bool { surface == "island" }
}
