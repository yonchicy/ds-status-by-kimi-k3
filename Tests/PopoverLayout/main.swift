import AppKit
import DeepSeekBarCore
import SwiftUI

// Deliberately replaces production AppState: no Keychain, network, timers or widget server.
@MainActor final class AppState: ObservableObject {
    @Published var balance: BalanceSnapshot?
    @Published var balanceError: String?
    @Published var hasAPIKey = true
    @Published var isRefreshing = false
    @Published var lastUpdated: Date? = Date()
    @Published var probe: ProbeStatus = .ok(latencyMs: 186)
    @Published var statusPage: StatusPageResult = .noIncident
    @Published var todayUsageSamples: [TodayUsageSample] = []
    @Published var usage: UsageSummary?
    @Published var usageState: UsageState = .available

    init() { populate(toolCount: 2) }

    func populate(toolCount: Int) {
        let now = Date()
        balance = .popoverFixture(at: now)
        balanceError = nil
        usage = .popoverFixture(at: now, toolCount: toolCount)
        usageState = .available
        todayUsageSamples = (0..<8).map {
            .init(timestamp: now.addingTimeInterval(Double($0 - 7) * 900), tokens: 48_000 + $0 * 14_900)
        }
    }

    func refreshForPresentation() {}
    func refresh() async {}

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return String(count)
    }
}

@main
struct PopoverLayoutTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
        func scrollViews(_ parent: NSView) -> [NSScrollView] {
            (parent as? NSScrollView).map { [$0] } ?? parent.subviews.flatMap(scrollViews)
        }

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let state = AppState()
            // Do not provide a height: MenuBarExtra first asks its content for an intrinsic size.
            let content = MenuPopoverView(refreshOnAppear: false)
                .environmentObject(state)
                .environment(\.colorScheme, scheme)
                .frame(width: 320)
            let hosting = NSHostingView(rootView: content)
            let first = hosting.fittingSize
            print("\(name) width-only initial fitting size: \(first.width)x\(first.height)")
            check(abs(first.width - 320) < 1 && first.height > 250,
                  "\(name): intrinsic size includes account content, not only the footer")

            // AppKit also asks for a compressed size when establishing a menu window's minimum.
            // A generous fittingSize alone misses ScrollView's ability to collapse to zero.
            let controller = NSHostingController(rootView: content)
            let compressed = controller.sizeThatFits(in: CGSize(width: 320, height: 0))
            print("\(name) compressed proposal result: \(compressed.width)x\(compressed.height)")
            check(compressed.height > 250,
                  "\(name): minimum-height negotiation cannot collapse to a footer-only menu")

            // After checking the unbounded root, emulate the menu adopting that measured size.
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000,
                                                     width: first.width, height: max(first.height, 1)),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFront(nil)
            pump()
            func settle() -> NSSize {
                for _ in 0..<3 {
                    window.setContentSize(hosting.fittingSize)
                    hosting.layoutSubtreeIfNeeded()
                    pump()
                }
                return hosting.fittingSize
            }
            let populated = settle()
            print("\(name) populated fitting size: \(populated.width)x\(populated.height)")
            check(populated.height > 400 && populated.height <= 761,
                  "\(name): populated popover remains visible within the screen cap")

            state.populate(toolCount: 30)
            let tall = settle()
            let scrolls = scrollViews(hosting)
            check(!scrolls.isEmpty && scrolls.allSatisfy { $0.contentView.bounds.height > 200 },
                  "\(name): long content retains a nonzero scroll viewport")
            check(tall.height <= 761 && scrolls.contains {
                ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 200
            }, "\(name): long tool list scrolls instead of expanding the whole menu")
            for scroll in scrolls {
                guard let document = scroll.documentView else { continue }
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                check(document.isFlipped ? abs(scroll.contentView.bounds.minY - bottom) < 2
                                         : abs(scroll.contentView.bounds.minY) < 2,
                      "\(name): bottom of long content can be reached")
            }

            state.usage = nil
            state.usageState = .idle
            let empty = settle()
            print("\(name) empty fitting size: \(empty.width)x\(empty.height)")
            check(empty.height > 150 && empty.height < populated.height,
                  "\(name): empty account shrinks without losing the content area")

            state.balance = nil
            state.balanceError = "账户暂时无法读取"
            state.usageState = .unavailable("用量暂时无法读取")
            let error = settle()
            check(error.height > 150 && error.height < populated.height,
                  "\(name): error messages have a visible intrinsic height")

            state.populate(toolCount: 2)
            let restored = settle()
            check(restored.height > empty.height && restored.height > 400,
                  "\(name): refreshed data expands the existing popover again")
            window.orderOut(nil)
        }
        print(failures == 0 ? "Popover layout tests passed" : "\(failures) popover layout failures")
        exit(failures == 0 ? 0 : 1)
    }
}
