import SwiftUI

@main
struct GFNPresenceApp: App {
    @State private var controller: PresenceController

    init() {
        let controller = PresenceController()
        controller.start()
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(controller: controller)
        } label: {
            Label {
                Text("GFN Presence")
            } icon: {
                Image(systemName: menuBarSymbol)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if !controller.isEnabled {
            return "eye.slash"
        }
        if controller.isShowingPresence {
            return "gamecontroller.fill"
        }
        return "gamecontroller"
    }
}
