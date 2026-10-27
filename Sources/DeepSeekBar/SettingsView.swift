import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showMenuBar") private var showMenuBar = true

    @State private var apiKeyInput = ""
    @State private var tokenInput = ""
    @State private var savedHint = false
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        Form {
            Section {
                SecureField("sk-...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                Text("在 platform.deepseek.com 的「API keys」页创建。用于查询账户余额。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("API Key（余额查询）")
            }

            Section {
                HStack {
                    Button("打开登录窗口自动获取") {
                        openWindow(id: "login")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    if state.hasPlatformToken {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("已配置").font(.caption).foregroundStyle(.secondary)
                    }
                }
                SecureField("或手动粘贴平台 Token", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                Text("浏览器登录 platform.deepseek.com 后按 F12，在 Console 执行 JSON.parse(localStorage.userToken).value 获取。用于查询消费与用量明细。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("平台登录凭证（消费明细）")
            }

            Section("刷新") {
                Stepper("每 \(state.refreshIntervalMinutes) 分钟自动刷新",
                        value: $state.refreshIntervalMinutes, in: 1...60)
            }

            Section("菜单栏") {
                Toggle("显示菜单栏图标和用量", isOn: $showMenuBar)
                Text("关闭后，应用仍在后台刷新桌面小组件。点击小组件或重新打开 DeepSeekBar，再点击账户概览底部的设置按钮，即可恢复显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("桌面小组件") {
                if state.supportsDesktopWidgets {
                    Text("右键点击桌面 → 编辑小组件 → 搜索 DeepSeekBar，选择小号或中号添加。")
                        .font(.callout)
                    Text("请保持应用在后台运行以同步数据。系统会安排小组件的实际刷新时间；点击小组件可打开账户概览。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = state.widgetSyncError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    } else if let date = state.widgetLastSynced {
                        Text("数据已同步：\(date, style: .time)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("刷新并同步小组件") { Task { await state.refresh() } }
                        .disabled(state.isRefreshing)
                } else {
                    Text("当前版本未包含桌面小组件，请重新构建并安装完整版应用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("外观", selection: $state.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("跟随系统时，会随 macOS 浅色 / 深色外观自动切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("外观")
            }

            Section("启动") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }))
                    .disabled(!loginItem.canToggle)

                switch loginItem.state {
                case .requiresApproval:
                    Text("已注册，但需要在系统设置的“登录项”中允许。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("打开系统登录项设置") {
                        loginItem.openSystemSettings()
                    }
                case .notFound:
                    Text("请先完成打包，并从 DeepSeekBar.app 启动后再开启此选项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .enabled:
                    Text("已加入 macOS 系统登录项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .notRegistered:
                    EmptyView()
                }

                if let error = loginItem.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                    if savedHint {
                        Text("已保存").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    Button("清除全部凭据", role: .destructive) {
                        state.clearCredentials()
                        apiKeyInput = ""
                        tokenInput = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .onAppear {
            apiKeyInput = state.apiKey ?? ""
            loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private func save() {
        if !apiKeyInput.isEmpty { state.saveAPIKey(apiKeyInput) }
        if !tokenInput.isEmpty { state.savePlatformToken(tokenInput) }
        tokenInput = ""
        savedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedHint = false }
    }
}
