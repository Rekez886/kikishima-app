// Only localization is stubbed. Typecheck the production controls without app state,
// window creation, stored preferences, or audio/session dependencies.
func tr(_ key: String) -> String { key }

// r16d: localization-only stub; production vocabulary is checked by kk033_offline.
@MainActor func captionDisplayText(_ key: String) -> String { key }
