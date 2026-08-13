import DeepSeekBarCore
import SwiftUI

/// 平台登录窗口：用户在 WebView 里完成登录，自动捕获并校验平台 Token
struct LoginWindowView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    enum Phase { case waiting, verifying, success, failed(String) }
    @State private var phase: Phase = .waiting

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            PlatformLoginWebView { token in
                handleToken(token)
            }
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var statusColor: Color {
        switch phase {
        case .waiting: return .orange
        case .verifying: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch phase {
        case .waiting: return "请在下方完成 DeepSeek 平台登录，登录后自动获取用量凭证…"
        case .verifying: return "已捕获登录凭证，正在验证…"
        case .success: return "登录成功，已保存凭证"
        case .failed(let msg): return "验证失败：\(msg)。也可在设置中手动粘贴 Token。"
        }
    }

    private func handleToken(_ token: String) {
        phase = .verifying
        Task {
            do {
                let ok = try await DeepSeekClient.shared.validatePlatformToken(token)
                await MainActor.run {
                    if ok {
                        phase = .success
                        state.savePlatformToken(token)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            dismissWindow(id: "login")
                        }
                    } else {
                        phase = .failed("凭证无效或已过期")
                    }
                }
            } catch {
                await MainActor.run { phase = .failed(error.localizedDescription) }
            }
        }
    }
}
