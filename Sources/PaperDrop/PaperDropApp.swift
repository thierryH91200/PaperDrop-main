import SwiftUI

@main
struct PaperDropApp: App {
    @StateObject private var model = AppModel()

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("PaperDrop") {
            ContentView()
                .environmentObject(model)
        }
        // Hides the title text; the window keeps its name for the Window
        // menu and Mission Control.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Page") { model.scanPage() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.busy || model.selectedScanner == nil)
                Button("Save PDF…") { model.savePDF() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
                Button("Cancel Scan") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.scanning)
            }
        }
    }
}
