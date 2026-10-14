import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?

    @ObservationIgnored private let status: () -> Bool
    @ObservationIgnored private let register: () throws -> Void
    @ObservationIgnored private let unregister: () throws -> Void

    init(
        status: @escaping () -> Bool,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
        self.isEnabled = status()
    }

    func setEnabled(_ enabled: Bool) {
        let previous = isEnabled
        isEnabled = enabled
        errorMessage = nil
        do {
            if enabled { try register() } else { try unregister() }
            isEnabled = status()
        } catch {
            isEnabled = previous
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    static func live() -> LaunchAtLoginController {
        let service = SMAppService.mainApp
        return LaunchAtLoginController(
            status: { service.status == .enabled },
            register: { try service.register() },
            unregister: { try service.unregister() }
        )
    }
}
