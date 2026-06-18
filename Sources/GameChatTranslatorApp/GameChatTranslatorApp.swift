import AppKit
import SwiftUI

@main
struct GameChatTranslatorApp: App {
    init() {
        if let iconURL = Bundle.main.url(forResource: "GameChatTranslator", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            TranslatorWindow()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
