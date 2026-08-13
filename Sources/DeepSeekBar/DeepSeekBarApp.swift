import SwiftUI
import AppKit

/// 菜单栏鲸鱼图标（DeepSeek 官方 logo，template 模式随系统外观自适应）
enum WhaleIcon {
    static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "whale", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = true
        return img
    }()
}

@main
struct DeepSeekBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuPopoverView()
                .environmentObject(state)
        } label: {
            // 不用 Label：NSImage 图标时 Label 在 MenuBarExtra 里可能只渲染图标
            HStack(spacing: 4) {
                if let whale = WhaleIcon.image {
                    Image(nsImage: whale)
                }
                Text(state.menuLabel)
            }
        }
        .menuBarExtraStyle(.window)

        Window("登录 DeepSeek 平台", id: "login") {
            LoginWindowView()
                .environmentObject(state)
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}
