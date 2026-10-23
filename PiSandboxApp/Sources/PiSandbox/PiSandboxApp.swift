import SwiftUI

@main
struct PiSandboxApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Pi Sandbox", id: "main") {
            ContentView().environmentObject(state)
        }

        MenuBarExtra("Pi Sandbox", systemImage: "terminal") {
            MenuContent().environmentObject(state)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Launch Pi") { Task { await state.launch() } }
            .disabled(!state.canLaunch)
        Button("Stop all sandboxes (\(state.runningSandboxes))") { Task { await state.stopSandboxes() } }
            .disabled(state.runningSandboxes == 0)
        Divider()
        if state.machine == .running {
            Button("Stop podman machine") { Task { await state.stopMachine() } }
        } else if state.machine == .stopped {
            Button("Start podman machine") { Task { await state.startMachine() } }
        }
        Button("Open window…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
