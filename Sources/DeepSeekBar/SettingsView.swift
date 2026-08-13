import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

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
