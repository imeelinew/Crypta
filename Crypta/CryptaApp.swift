import AppKit
import SwiftUI

@main
struct CryptaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = CryptaLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 520, minHeight: 360)
                .task {
                    await library.load()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建保险箱") {
                    library.newGroupFormPresented = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        try? CryptaPaths.cleanPlaybackCache()
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? CryptaPaths.cleanPlaybackCache()
    }
}
