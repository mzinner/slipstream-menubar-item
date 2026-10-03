import Foundation

/// The models the app offers, in setup and in Settings: `Resources/models.json`, bundled
/// with the app (and later fetchable from a server). Making a model available, or the
/// default, is an edit to that file, not to code.
public struct ModelManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public enum Availability: String, Codable, Sendable {
            case available
            /// Listed, dimmed and not selectable: e.g. a package not uploaded yet.
            case comingSoon
        }

        public var id: String
        /// Short, for setup's model list.
        public var name: String
        /// Full, for Settings.
        public var title: String
        /// Hugging Face `owner/repo`; none while it is coming soon.
        public var repository: String?
        public var kind: ModelSpec.Kind
        public var extraFiles: [ModelSpec.ExtraFile]
        /// The download, for display; the disk check asks the Hub for the exact size.
        public var sizeBytes: Int64
        public var minimumMemoryGiB: Int
        public var recommendedMemoryGiB: Int
        public var availability: Availability
        public var badge: String?
        public var isDefault: Bool
        /// Offered by setup; every available entry is offered in Settings.
        public var inSetup: Bool

        public init(id: String, name: String, title: String, repository: String?, kind: ModelSpec.Kind = .gguf,
                    extraFiles: [ModelSpec.ExtraFile] = [], sizeBytes: Int64, minimumMemoryGiB: Int = 64,
                    recommendedMemoryGiB: Int = 64, availability: Availability = .available,
                    badge: String? = nil, isDefault: Bool = false, inSetup: Bool = true) {
            self.id = id
            self.name = name
            self.title = title
            self.repository = repository
            self.kind = kind
            self.extraFiles = extraFiles
            self.sizeBytes = sizeBytes
            self.minimumMemoryGiB = minimumMemoryGiB
            self.recommendedMemoryGiB = recommendedMemoryGiB
            self.availability = availability
            self.badge = badge
            self.isDefault = isDefault
            self.inSetup = inSetup
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? name
            repository = try container.decodeIfPresent(String.self, forKey: .repository)
            kind = try container.decodeIfPresent(ModelSpec.Kind.self, forKey: .kind) ?? .gguf
            extraFiles = try container.decodeIfPresent([ModelSpec.ExtraFile].self, forKey: .extraFiles) ?? []
            sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
            minimumMemoryGiB = try container.decodeIfPresent(Int.self, forKey: .minimumMemoryGiB) ?? 64
            recommendedMemoryGiB = try container.decodeIfPresent(Int.self, forKey: .recommendedMemoryGiB)
                ?? minimumMemoryGiB
            availability = try container.decodeIfPresent(Availability.self, forKey: .availability) ?? .available
            badge = try container.decodeIfPresent(String.self, forKey: .badge)
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            inSetup = try container.decodeIfPresent(Bool.self, forKey: .inSetup) ?? true
        }

        /// Selectable and downloadable.
        public var isAvailable: Bool { availability == .available && repository != nil }

        public var spec: ModelSpec? {
            guard isAvailable, let repository else { return nil }
            return ModelSpec(repository: repository, title: title, extraFiles: extraFiles, kind: kind,
                             minimumMemoryGiB: minimumMemoryGiB, recommendedMemoryGiB: recommendedMemoryGiB)
        }

        public func fits(memoryGiB: Int) -> Bool { memoryGiB >= minimumMemoryGiB }

        /// "104.5 GB · Fits your Mac", "104.5 GB · Needs 64 GB memory", "Available soon".
        public func detail(memoryGiB: Int) -> String {
            guard availability == .available else { return "Available soon" }
            let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            return "\(size) · " + (fits(memoryGiB: memoryGiB) ? "Fits your Mac" : "Needs \(minimumMemoryGiB) GB memory")
        }
    }

    public var version: Int
    public var models: [Entry]

    public init(version: Int = 1, models: [Entry]) {
        self.version = version
        self.models = models
    }

    /// What setup lists, in the manifest's order.
    public var setupEntries: [Entry] { models.filter(\.inSetup) }

    /// The entry setup selects first: the available default, else the first available one.
    public var defaultEntry: Entry? {
        models.first { $0.isDefault && $0.isAvailable } ?? models.first { $0.isAvailable }
    }

    /// Every available model, for Settings and downloads.
    public var catalog: [ModelSpec] { models.compactMap(\.spec) }

    public func entry(id: String) -> Entry? { models.first { $0.id == id } }

    /// The app's `models.json`, or the copy compiled in when it is missing or unreadable
    /// (tests, `swift run`).
    public static let bundled: ModelManifest = {
        if let url = Bundle.main.url(forResource: "models", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
           !manifest.catalog.isEmpty {
            return manifest
        }
        return builtIn
    }()

    /// Must match `Resources/models.json` (a test compares them).
    public static let builtIn = ModelManifest(models: [
        Entry(id: "swift-v3", name: "Swift", title: "Swift-Qwen3.8-Flash-Next V3",
              repository: "nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF",
              extraFiles: [ModelSpec.mtpDraftHead], sizeBytes: 104_468_009_728,
              badge: "Recommended", isDefault: true),
        Entry(id: "qwen38-v3", name: "Qwen3.8-Flash-Next", title: "Qwen3.8-Flash-Next V3",
              repository: "nitinpanj/qwen38-flash-next-v3", sizeBytes: 104_475_874_048),
        Entry(id: "swift-v3-converted", name: "Swift (converted)", title: "Swift-Qwen3.8-Flash-Next V3 (converted)",
              repository: nil, kind: .package, sizeBytes: 107_189_682_176, availability: .comingSoon,
              badge: "Soon"),
    ])
}
