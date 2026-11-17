import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panelWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
        showPanelWindow()
    }

    // The app has no Dock icon: opening it again from Finder or Spotlight must still show something.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanelWindow()
        return false
    }

    func showPanelWindow() {
        let window = panelWindow ?? makePanelWindow()
        panelWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        AppLog.app.info("panel_window_shown")
    }

    private func makePanelWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: PanelView(model: model))
        // The panel is a ScrollView with no intrinsic height: left to SwiftUI, the window collapses to its title bar.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "ScreenISO"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: PanelView.width, height: PanelView.idealHeight))
        window.contentMinSize = NSSize(width: PanelView.width, height: PanelView.minHeight)
        window.contentMaxSize = NSSize(width: PanelView.width, height: PanelView.maxHeight)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
