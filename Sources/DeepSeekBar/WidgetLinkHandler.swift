import AppKit
import DeepSeekBarWidgetShared
import SwiftUI

/// AppKit receives URLs even on a cold launch when no SwiftUI window is open yet.
final class WidgetAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var overviewRequested = false

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(WidgetSnapshot.openURL) else { return }
        overviewRequested = true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overviewRequested = true
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the overview/settings must not stop the widget's background data source.
        false
    }
}
