import Foundation

private enum InjectedFailure: Error {
    case registration
    case unregistration
}

@main
@MainActor
struct LaunchAtLoginControllerTest {
    static func main() {
        var systemEnabled = false
        var failure: InjectedFailure? = .registration
        let controller = LaunchAtLoginController(
            status: { systemEnabled },
            register: {
                if failure == .registration { throw InjectedFailure.registration }
                systemEnabled = true
            },
            unregister: {
                if failure == .unregistration { throw InjectedFailure.unregistration }
                systemEnabled = false
            }
        )

        controller.setEnabled(true)
        precondition(!controller.isEnabled, "A failed registration must restore the previous toggle state")
        precondition(controller.errorMessage != nil, "A failed registration must expose an error")

        failure = nil
        controller.setEnabled(true)
        precondition(controller.isEnabled)
        precondition(controller.errorMessage == nil)

        failure = .unregistration
        controller.setEnabled(false)
        precondition(controller.isEnabled, "A failed unregistration must restore the previous toggle state")
        precondition(controller.errorMessage != nil)

        print("PASS: launch at login controller")
    }
}
