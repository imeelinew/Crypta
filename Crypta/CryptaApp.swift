import AppKit
import Sparkle
import SwiftUI

private enum CryptaRuntime {
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["CRYPTA_UI_TESTING"] == "1"
    }
}

@main
struct CryptaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = CryptaLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 520, minHeight: 360)
                .task {
                    guard !CryptaRuntime.isRunningTests else { return }
                    await library.load()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建保险箱") {
                    library.newGroupFormPresented = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(library.isRecoveryAccessRequired)
            }
            CommandGroup(replacing: .saveItem) { }
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard !CryptaRuntime.isRunningTests else { return }
        updaterController.startUpdater()
        try? DecryptedMediaSessionManager.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !CryptaRuntime.isRunningTests else { return }
        DecryptedMediaSessionManager.shared.shutdown()
    }
}
