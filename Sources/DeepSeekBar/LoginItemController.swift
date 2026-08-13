import Combine
import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol LoginItemServicing {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
struct SystemLoginItemService: LoginItemServicing {
    private var service: SMAppService { .mainApp }

    var state: LoginItemState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// 始终以 ServiceManagement 的实际状态为准，不单独保存一个可能过期的开关值。
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var state: LoginItemState = .notFound
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let service: any LoginItemServicing

    convenience init() {
        self.init(service: SystemLoginItemService())
    }

    init(service: any LoginItemServicing) {
        self.service = service
        refresh()
    }

    var isEnabled: Bool {
        state == .enabled || state == .requiresApproval
    }

    var canToggle: Bool {
        !isUpdating && state != .notFound
    }

    func refresh() {
        let refreshedState = service.state
        if refreshedState != state { errorMessage = nil }
        state = refreshedState
    }

    func setEnabled(_ shouldEnable: Bool) {
        guard !isUpdating else { return }
        errorMessage = nil
        isUpdating = true
        defer {
            isUpdating = false
            refresh()
        }

        do {
            switch (shouldEnable, state) {
            case (true, .notRegistered):
                try service.register()
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            case (true, .enabled), (true, .requiresApproval),
                 (false, .notRegistered), (_, .notFound):
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
