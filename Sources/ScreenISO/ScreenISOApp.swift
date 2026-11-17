import SwiftUI

struct ScreenISOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.isSessionRunning ? "lock.shield.fill" : "lock.shield")
            .accessibilityLabel("ScreenISO")
    }
}
