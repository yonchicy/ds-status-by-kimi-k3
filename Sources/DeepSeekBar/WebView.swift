import SwiftUI
import WebKit

/// 内嵌浏览器：打开 platform.deepseek.com 让用户登录，
/// 注入 JS 轮询 localStorage.userToken 并 hook 出站请求的 Authorization 头，
/// 捕获到平台 Token 后通过 onToken 回调传出。
struct PlatformLoginWebView: NSViewRepresentable {
    var onToken: (String) -> Void

    /// 注入脚本：双通道捕获 token
    private static let hookScript = """
    (function () {
      if (window.__dsHookInstalled) return;
      window.__dsHookInstalled = true;

      function deliver(t) {
        try {
          if (t && typeof t === 'string' && t.length > 10) {
            window.webkit.messageHandlers.dsToken.postMessage(t);
          }
        } catch (e) {}
      }
      function fromLocalStorage() {
        try {
          var raw = localStorage.getItem('userToken');
          if (!raw) return;
          var parsed = JSON.parse(raw);
          var v = (parsed && parsed.value) ? parsed.value : parsed;
          if (typeof v === 'string') deliver(v);
        } catch (e) {}
      }
      // 通道一：轮询 localStorage（页面脚本随时可能写入，轮询最稳）
      setInterval(fromLocalStorage, 600);
      fromLocalStorage();

      // 通道二：hook fetch / XHR 的 Authorization 头
      function extractAuth(headers) {
        try {
          if (!headers) return null;
          if (headers instanceof Headers) return headers.get('authorization') || headers.get('Authorization');
          if (Array.isArray(headers)) {
            for (var i = 0; i < headers.length; i++) {
              if (String(headers[i][0]).toLowerCase() === 'authorization') return headers[i][1];
            }
            return null;
          }
          for (var k in headers) {
            if (String(k).toLowerCase() === 'authorization') return headers[k];
          }
        } catch (e) {}
        return null;
      }
      var of = window.fetch;
      window.fetch = function (input, init) {
        try {
          var h = (init && init.headers) || (input && input.headers);
          var auth = extractAuth(h);
          if (auth) deliver(String(auth).replace(/^Bearer\\s+/i, ''));
        } catch (e) {}
        return of.apply(this, arguments);
      };
      var osh = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try {
          if (String(name).toLowerCase() === 'authorization') {
            deliver(String(value).replace(/^Bearer\\s+/i, ''));
          }
        } catch (e) {}
        return osh.apply(this, arguments);
      };
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // 保留登录态，下次打开无需重登
        let userScript = WKUserScript(source: Self.hookScript,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: "dsToken")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: URL(string: "https://platform.deepseek.com/")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onToken: (String) -> Void
        private var delivered = false

        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard !delivered, let token = message.body as? String, token.count > 10 else { return }
            delivered = true
            DispatchQueue.main.async { self.onToken(token) }
        }
    }
}
