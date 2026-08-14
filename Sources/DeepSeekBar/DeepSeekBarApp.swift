import DeepSeekBarCore
import SwiftUI
import AppKit

/// 菜单栏鲸鱼图标（DeepSeek 官方 logo，template 模式随系统外观自适应）
enum WhaleIcon {
    static let pointSize: CGFloat = 16

    static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "whale", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: pointSize, height: pointSize)
        img.isTemplate = true
        return img
    }()

    private static let warningImage = tintedImage(.systemOrange)
    private static let errorImage = tintedImage(.systemRed)

    static func coloredImage(for probe: ProbeStatus) -> NSImage? {
        switch probe {
        case .slow: return warningImage
        case .down: return errorImage
        case .unknown, .ok: return nil
        }
    }

    private static func tintedImage(_ color: NSColor) -> NSImage? {
        guard let mask = image?.copy() as? NSImage else { return nil }
        mask.isTemplate = false
        let sourceRect = NSRect(origin: .zero, size: mask.size)

        let tinted = NSImage(size: mask.size, flipped: false) { destinationRect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.imageInterpolation = .high

            color.setFill()
            destinationRect.fill()
            mask.draw(
                in: destinationRect,
                from: sourceRect,
                operation: .destinationIn,
                fraction: 1
            )
            return true
        }
        tinted.isTemplate = false
        tinted.cacheMode = .never
        return tinted
    }
}

@main
struct DeepSeekBarApp: App {
    @StateObject private var state = AppState()

    @ViewBuilder
    private var menuBarWhale: some View {
        if let colored = WhaleIcon.coloredImage(for: state.probe) {
            Image(nsImage: colored)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else if let whale = WhaleIcon.image {
            Image(nsImage: whale)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPopoverView()
                .environmentObject(state)
                .appAppearance(state.appearancePreference)
        } label: {
            // 不用 Label：NSImage 图标时 Label 在 MenuBarExtra 里可能只渲染图标
            HStack(spacing: 4) {
                menuBarWhale
                    .frame(width: WhaleIcon.pointSize, height: WhaleIcon.pointSize)
                    .id(state.probe.level)
                    .accessibilityLabel("API 探测状态")
                    .accessibilityValue(state.probe.label)
                Text(state.menuLabel)
            }
        }
        .menuBarExtraStyle(.window)

        Window("登录 DeepSeek 平台", id: "login") {
            LoginWindowView()
                .environmentObject(state)
                .appAppearance(state.appearancePreference)
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(state)
                .appAppearance(state.appearancePreference)
        }
    }
}
