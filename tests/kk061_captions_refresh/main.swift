import Foundation

@main
struct KK061CaptionRefreshTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(ShootSessionPolicy.meetingLocales(current: "en_US", existing: []) == ["en_US"],
               "empty list keeps the current language")
        expect(ShootSessionPolicy.meetingLocales(current: "en_US", existing: ["ja_JP"]) == ["en_US", "ja_JP"],
               "enabled languages are preserved after the current one")
        expect(ShootSessionPolicy.meetingLocales(current: "en_US", existing: ["en_US", "ja_JP"]) == ["en_US", "ja_JP"],
               "current language is not duplicated")
        expect(ShootSessionPolicy.meetingLocales(current: "en_US", existing: ["ja_JP", "en_US", "ko_KR"]) == ["en_US", "ja_JP", "ko_KR"],
               "current language moves to the front")
        expect(ShootSessionPolicy.meetingLocales(current: "en_US", existing: ["ja_JP", "ja_JP", "ko_KR"]) == ["en_US", "ja_JP", "ko_KR"],
               "duplicate enabled languages collapse")
        expect(ShootSessionPolicy.refreshesModelInstallation(offscreenRender: false),
               "shoot sessions refresh installed models")
        expect(!ShootSessionPolicy.refreshesModelInstallation(offscreenRender: true),
               "offscreen renders skip installed model refresh")
        print("PASS KK-061 caption refresh and shoot meeting languages")
    }
}
