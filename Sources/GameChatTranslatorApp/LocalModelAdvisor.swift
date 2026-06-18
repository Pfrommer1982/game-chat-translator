import Foundation

enum WhisperModelTier: Int, Comparable {
    case tiny
    case base
    case small
    case medium
    case large
    case unknown

    static func < (lhs: WhisperModelTier, rhs: WhisperModelTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(fileName: String) {
        let name = fileName.lowercased()
        if name.contains("tiny") {
            self = .tiny
        } else if name.contains("base") {
            self = .base
        } else if name.contains("small") {
            self = .small
        } else if name.contains("medium") {
            self = .medium
        } else if name.contains("large") || name.contains("turbo") {
            self = .large
        } else {
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .unknown: return "Custom"
        }
    }

    var performanceNote: String {
        switch self {
        case .tiny: return "Fastest, lower accuracy"
        case .base: return "Fast, balanced for gameplay"
        case .small: return "More accurate, slower"
        case .medium: return "High accuracy, high latency"
        case .large: return "Best quality, not suited to Battle Mode"
        case .unknown: return "Custom Whisper model"
        }
    }
}

struct LocalModelOption: Identifiable, Hashable {
    let url: URL
    let tier: WhisperModelTier
    let fileSize: Int64?

    var id: String { url.standardizedFileURL.path }
    var path: String { url.standardizedFileURL.path }

    var title: String {
        let englishOnly = url.lastPathComponent.lowercased().contains(".en.") ? " English" : ""
        return tier.displayName + englishOnly
    }

    var detail: String {
        guard let fileSize else { return tier.performanceNote }
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        return "\(tier.performanceNote) · \(size)"
    }
}

enum LocalModelAdvisor {
    static var processorCount: Int {
        ProcessInfo.processInfo.processorCount
    }

    static var memoryGB: Int {
        Int((ProcessInfo.processInfo.physicalMemory + 536_870_911) / 1_073_741_824)
    }

    static var hardwareSummary: String {
        "\(processorCount)-core Mac · \(memoryGB) GB memory"
    }

    static var recommendedTier: WhisperModelTier {
        if processorCount <= 4 || memoryGB <= 8 {
            return .tiny
        }
        if processorCount >= 12 && memoryGB >= 24 {
            return .small
        }
        return .base
    }

    static var recommendationReason: String {
        switch recommendedTier {
        case .tiny:
            return "Recommended for the lowest latency on this Mac."
        case .base:
            return "Recommended balance of battle speed and recognition accuracy."
        case .small:
            return "This Mac has enough headroom for better accuracy without extreme latency."
        default:
            return "Recommended for this Mac."
        }
    }

    static func discoverModels(currentPath: String?) -> [LocalModelOption] {
        let fileManager = FileManager.default
        var candidateURLs: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidateURLs.append(resourceURL.appendingPathComponent("models", isDirectory: true))
        }
        candidateURLs.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("models", isDirectory: true)
        )
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidateURLs.append(
                applicationSupport
                    .appendingPathComponent("GameChatTranslator", isDirectory: true)
                    .appendingPathComponent("models", isDirectory: true)
            )
        }

        var modelURLs: [URL] = []
        for directory in candidateURLs {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            modelURLs.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "bin" })
        }

        if let currentPath, !currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let currentURL = URL(fileURLWithPath: (currentPath as NSString).expandingTildeInPath)
            if fileManager.fileExists(atPath: currentURL.path) {
                modelURLs.append(currentURL)
            }
        }

        var seenPaths = Set<String>()
        return modelURLs
            .compactMap { url -> LocalModelOption? in
                let standardizedURL = url.standardizedFileURL
                guard seenPaths.insert(standardizedURL.path).inserted else { return nil }
                let values = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile != false else { return nil }
                return LocalModelOption(
                    url: standardizedURL,
                    tier: WhisperModelTier(fileName: standardizedURL.lastPathComponent),
                    fileSize: values?.fileSize.map(Int64.init)
                )
            }
            .sorted {
                if $0.tier != $1.tier { return $0.tier < $1.tier }
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
    }

    static func recommendedModel(in models: [LocalModelOption]) -> LocalModelOption? {
        if let exact = models.first(where: { $0.tier == recommendedTier && !$0.url.lastPathComponent.contains(".en.") }) {
            return exact
        }
        return models.min { lhs, rhs in
            abs(lhs.tier.rawValue - recommendedTier.rawValue) < abs(rhs.tier.rawValue - recommendedTier.rawValue)
        }
    }
}
