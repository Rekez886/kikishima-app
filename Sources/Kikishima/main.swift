// 入口：正常启动 macOS app。
import AppKit

#if SHOOT || DEBUG
let shootProcessStart = DispatchTime.now().uptimeNanoseconds
ShootDiagnosticLog.start(at: shootProcessStart)
MainActor.assumeIsolated {
    ShootWindowLog.start()
    if ShootSimulation.requestedOpenMenu || ShootDiagnosticLog.shared?.enabled == true {
        ShootOpenMenu.shared.start(openMenu: ShootSimulation.requestedOpenMenu)
    }
}
#endif

#if SHOOT
MainActor.assumeIsolated { _ = ShootNotch.configuration }
#endif

#if SHOOT && SCREENSHOT_DIFF
MainActor.assumeIsolated { if ShootRender.runIfRequested() { exit(0) } }
#endif
#if SHOOT || DEBUG
MainActor.assumeIsolated {
#if SHOOT || DEBUG
if ShootSimulation.runIfRequested() { exit(0) }
#endif
}
#endif

// Sparkle follows the app's AppleLanguages preference, while Kikishima's own UI follows uiLanguage.
// Existing installs need one early relaunch after the two preferences are synchronized.
_ = AppLanguagePreference.processLanguage
if let selectedLanguage = AppLanguagePreference.synchronizeSavedLanguage(),
   AppLanguagePreference.requiresRelaunch(for: selectedLanguage),
   AppRelauncher.launchNewInstance() {
    exit(0)
}
KikishimaApp.main()
