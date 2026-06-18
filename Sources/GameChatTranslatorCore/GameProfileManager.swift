import Foundation
import CoreGraphics

public struct GameProfile: Codable, Equatable, Identifiable {
    public var id: String { appName }
    public var appName: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var ocrFPS: Double
    public var staleThreshold: Double
    public var attributionConfidenceThreshold: Double
    public var usernameRegex: String
    public var speakerHoldTime: Double
    
    public var ocrRegion: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Double(newValue.origin.x)
            y = Double(newValue.origin.y)
            width = Double(newValue.size.width)
            height = Double(newValue.size.height)
        }
    }
    
    public init(
        appName: String,
        ocrRegion: CGRect = CGRect(x: 100, y: 100, width: 400, height: 100),
        ocrFPS: Double = 3.0,
        staleThreshold: Double = 8.0,
        attributionConfidenceThreshold: Double = 0.7,
        usernameRegex: String = ".*",
        speakerHoldTime: Double = 2.0
    ) {
        self.appName = appName
        self.x = Double(ocrRegion.origin.x)
        self.y = Double(ocrRegion.origin.y)
        self.width = Double(ocrRegion.size.width)
        self.height = Double(ocrRegion.size.height)
        self.ocrFPS = ocrFPS
        self.staleThreshold = staleThreshold
        self.attributionConfidenceThreshold = attributionConfidenceThreshold
        self.usernameRegex = usernameRegex
        self.speakerHoldTime = speakerHoldTime
    }
}

public final class GameProfileManager: ObservableObject {
    public static let shared = GameProfileManager()
    
    @Published public var profiles: [GameProfile] = []
    @Published public var activeProfile: GameProfile
    
    private let fileManager = FileManager.default
    private var profilesDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("GameChatTranslator", isDirectory: true)
        let profilesFolder = appFolder.appendingPathComponent("Profiles", isDirectory: true)
        return profilesFolder
    }
    
    private init() {
        // Default initial profile
        let defaultProfile = GameProfile(
            appName: "Default Game",
            ocrRegion: CGRect(x: 50, y: 200, width: 350, height: 80),
            ocrFPS: 3.0,
            staleThreshold: 8.0,
            attributionConfidenceThreshold: 0.7,
            usernameRegex: ".*",
            speakerHoldTime: 2.0
        )
        self.activeProfile = defaultProfile
        
        createProfilesDirectoryIfNeeded()
        loadProfiles()
        
        if profiles.isEmpty {
            // Prepopulate with a couple of useful profiles
            let arcRaiders = GameProfile(
                appName: "ARC Raiders",
                ocrRegion: CGRect(x: 40, y: 500, width: 300, height: 60),
                ocrFPS: 3.0,
                staleThreshold: 8.0,
                attributionConfidenceThreshold: 0.7,
                usernameRegex: "([a-zA-Z0-9_\\s\\-]+)",
                speakerHoldTime: 2.0
            )
            saveProfile(defaultProfile)
            saveProfile(arcRaiders)
            loadProfiles()
        }
        
        if let storedActiveName = UserDefaults.standard.string(forKey: "ActiveProfileName"),
           let found = profiles.first(where: { $0.appName == storedActiveName }) {
            self.activeProfile = found
        } else if let first = profiles.first {
            self.activeProfile = first
        }
    }
    
    private func createProfilesDirectoryIfNeeded() {
        do {
            try fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create profiles directory: \(error)")
        }
    }
    
    public func loadProfiles() {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil)
            var loaded: [GameProfile] = []
            let decoder = JSONDecoder()
            for url in fileURLs where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let profile = try? decoder.decode(GameProfile.self, from: data) {
                    loaded.append(profile)
                }
            }
            // Sort alphabetically by name
            self.profiles = loaded.sorted(by: { $0.appName < $1.appName })
        } catch {
            print("Failed to load profiles: \(error)")
        }
    }
    
    public func saveProfile(_ profile: GameProfile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(profile)
            let fileURL = profilesDirectory.appendingPathComponent("\(profile.appName).json")
            try data.write(to: fileURL)
            
            // Reload
            loadProfiles()
            
            // If it is the active profile, update activeProfile
            if activeProfile.appName == profile.appName {
                activeProfile = profile
            }
        } catch {
            print("Failed to save profile \(profile.appName): \(error)")
        }
    }
    
    public func selectProfile(named name: String) {
        if let found = profiles.first(where: { $0.appName == name }) {
            activeProfile = found
            UserDefaults.standard.set(name, forKey: "ActiveProfileName")
        }
    }
    
    public func deleteProfile(named name: String) {
        let fileURL = profilesDirectory.appendingPathComponent("\(name).json")
        try? fileManager.removeItem(at: fileURL)
        loadProfiles()
        
        if activeProfile.appName == name {
            if let first = profiles.first {
                activeProfile = first
                UserDefaults.standard.set(first.appName, forKey: "ActiveProfileName")
            } else {
                let fallback = GameProfile(appName: "Default Game")
                activeProfile = fallback
                saveProfile(fallback)
            }
        }
    }
}
