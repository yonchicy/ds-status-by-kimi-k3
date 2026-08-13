import AppKit
import SwiftUI

/// 应用外观：跟随系统，或强制浅色 / 深色。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// `nil` 表示不覆盖，SwiftUI / AppKit 会随系统外观自动切换。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func applyToApp() {
        NSApp.appearance = nsAppearance
    }

    static let storageKey = "appearancePreference"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: storageKey),
              let value = Self(rawValue: raw) else {
            return .system
        }
        return value
    }
}

extension View {
    func appAppearance(_ preference: AppearancePreference) -> some View {
        modifier(AppAppearanceModifier(preference: preference))
    }
}

private struct AppAppearanceModifier: ViewModifier {
    let preference: AppearancePreference

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preference.colorScheme)
            .onAppear { preference.applyToApp() }
            .onChange(of: preference) { _, newValue in
                newValue.applyToApp()
            }
    }
}
