import SwiftUI

@main
struct GameChatTranslatorApp: App {
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

