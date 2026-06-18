import Foundation
import LocalAuthentication
import Security

enum APIKeyStore {
    enum Provider: String {
        case groq
        case openAI = "openai"
        case custom
    }

    private static let service = "dev.pfrommer.gamechattranslator"
    private static let groqAccount = "groq-api-key"
    private static let directoryName = "GameChatTranslator"

    static func loadKey(for provider: Provider) -> String {
        if let storedKey = loadFileKey(for: provider) {
            return storedKey
        }

        // Migrate an already-authorized legacy item without ever showing a
        // Keychain password dialog. If access needs UI, this simply returns nil.
        if provider == .groq, let legacyKey = loadLegacyKeyWithoutPrompt() {
            saveFileKey(legacyKey, for: provider)
            return legacyKey
        }

        return ""
    }

    static func saveKey(_ key: String, for provider: Provider) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            try? FileManager.default.removeItem(at: keyFileURL(for: provider))
            return
        }
        saveFileKey(trimmedKey, for: provider)
    }

    private static func keyFileURL(for provider: Provider) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-api-key", isDirectory: false)
    }

    private static func loadFileKey(for provider: Provider) -> String? {
        guard let data = try? Data(contentsOf: keyFileURL(for: provider)),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    private static func saveFileKey(_ key: String, for provider: Provider) {
        let fileURL = keyFileURL(for: provider)
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            try Data(key.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // The UI remains usable with the in-memory key for this run.
        }
    }

    private static func loadLegacyKeyWithoutPrompt() -> String? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: groqAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }
}
