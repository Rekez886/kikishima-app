// 入口：正常启动 macOS app。
import AppKit

// Sparkle follows the app's AppleLanguages preference, while Kikishima's own UI follows uiLanguage.
// Existing installs need one early relaunch after the two preferences are synchronized.
_ = AppLanguagePreference.processLanguage
if let selectedLanguage = AppLanguagePreference.synchronizeSavedLanguage(),
   AppLanguagePreference.requiresRelaunch(for: selectedLanguage),
   AppRelauncher.launchNewInstance() {
    exit(0)
}
KikishimaApp.main()
