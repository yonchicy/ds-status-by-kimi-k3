import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var apiKeyInput = ""
    @State private var tokenInput = ""
    @State private var savedHint = false

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
