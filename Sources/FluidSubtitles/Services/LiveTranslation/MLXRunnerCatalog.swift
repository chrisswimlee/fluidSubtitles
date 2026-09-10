import Foundation

struct MLXRunnerModel: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
    let repo: String
    let size: String
    let ramGB: Int
    let quality: String
    let languages: [String]
    let recommended: Bool
    let detail: String
    let localHints: [String]
    let source: String

    init(
        id: String,
        name: String,
        repo: String,
        size: String,
        ramGB: Int,
        quality: String,
        languages: [String],
        recommended: Bool,
        detail: String,
        localHints: [String] = [],
        source: String = "catalog"
    ) {
        self.id = id
        self.name = name
        self.repo = repo
        self.size = size
        self.ramGB = ramGB
        self.quality = quality
        self.languages = languages
        self.recommended = recommended
        self.detail = detail
        self.localHints = localHints
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.repo = try container.decode(String.self, forKey: .repo)
        self.size = try container.decode(String.self, forKey: .size)
        self.ramGB = try container.decode(Int.self, forKey: .ramGB)
        self.quality = try container.decode(String.self, forKey: .quality)
        self.languages = try container.decode([String].self, forKey: .languages)
        self.recommended = try container.decode(Bool.self, forKey: .recommended)
        self.detail = try container.decode(String.self, forKey: .detail)
        self.localHints = try container.decodeIfPresent([String].self, forKey: .localHints) ?? []
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "catalog"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, repo, size, ramGB, quality, languages, recommended, detail, localHints, source
    }

    var isLocalFolder: Bool {
        self.source == "local" || self.source == "lmstudio" || self.id.hasPrefix("local:")
    }

    var isDownloadable: Bool {
        !self.isLocalFolder
    }

    var languageLabel: String {
        self.languages
            .map { code in
                switch code {
                case "ko": return "Korean"
                case "en": return "English"
                case "th": return "Thai"
                default: return code
                }
            }
            .joined(separator: ", ")
    }

    var qualityLabel: String {
        switch self.quality {
        case "fast": return "Fast"
        case "recommended": return "Recommended"
        case "highest": return "Highest quality"
        case "korean": return "Korean-first"
        case "gemma4": return "Gemma 4"
        case "lmstudio": return "LM Studio"
        case "local": return "On this Mac"
        case "custom": return "Custom"
        default: return self.quality.capitalized
        }
    }

    var pickerTitle: String {
        let mark = self.recommended ? " · Recommended" : ""
        return "\(self.name)\(mark) · \(self.size)"
    }
}

struct MLXRunnerCatalogFile: Codable, Equatable {
    let defaultModelID: String
    let defaultPort: Int
    let models: [MLXRunnerModel]
}

enum MLXRunnerCatalog {
    static let defaultPort = 8080
    static let defaultModelID = "gemma4-e4b"

    static let bundled = MLXRunnerCatalogFile(
        defaultModelID: Self.defaultModelID,
        defaultPort: Self.defaultPort,
        models: [
            MLXRunnerModel(
                id: "gemma4-e4b",
                name: "Gemma 4 E4B",
                repo: "mlx-community/gemma-4-e4b-it-4bit",
                size: "5.2 GB",
                ramGB: 10,
                quality: "recommended",
                languages: ["ko", "en", "th"],
                recommended: true,
                detail: "Smallest model that still works for Korean / English / Thai language exchange. About 5 GB.",
                localHints: []
            ),
            MLXRunnerModel(
                id: "gemma4-e2b",
                name: "Gemma 4 E2B",
                repo: "mlx-community/gemma-4-e2b-it-4bit",
                size: "2.5 GB",
                ramGB: 8,
                quality: "gemma4",
                languages: ["ko", "en", "th"],
                recommended: false,
                detail: "Smaller than E4B. Use only if you want the tiniest file; Korean/Thai get thinner.",
                localHints: []
            ),
            MLXRunnerModel(
                id: "gemma4-26b-a4b",
                name: "Gemma 4 26B A4B",
                repo: "lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
                size: "15 GB",
                ramGB: 24,
                quality: "gemma4",
                languages: ["ko", "en", "th"],
                recommended: false,
                detail: "Newer than Gemma 3. MoE, strong Korean / English / Thai. Reuses the copy already in LM Studio if present.",
                localHints: ["~/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit"]
            ),
            MLXRunnerModel(
                id: "gemma4-31b",
                name: "Gemma 4 31B",
                repo: "lmstudio-community/gemma-4-31B-it-MLX-4bit",
                size: "18 GB",
                ramGB: 32,
                quality: "gemma4",
                languages: ["ko", "en", "th"],
                recommended: false,
                detail: "Largest Gemma 4 text model. Comfortable on a 48 GB Mac. Reuses the LM Studio copy if present.",
                localHints: ["~/.lmstudio/models/lmstudio-community/gemma-4-31B-it-MLX-4bit"]
            ),
            MLXRunnerModel(
                id: "gemma3-4b",
                name: "Gemma 3 4B",
                repo: "mlx-community/gemma-3-text-4b-it-4bit",
                size: "2.5 GB",
                ramGB: 8,
                quality: "fast",
                languages: ["ko", "en", "th"],
                recommended: false,
                detail: "Fastest Gemma 3 download. Fine for short Korean and English captions; Thai is usable.",
                localHints: []
            ),
            MLXRunnerModel(
                id: "gemma3-12b",
                name: "Gemma 3 12B",
                repo: "mlx-community/gemma-3-12b-it-4bit-DWQ",
                size: "8 GB",
                ramGB: 16,
                quality: "larger",
                languages: ["ko", "en", "th"],
                recommended: false,
                detail: "Step up from E4B if short language-exchange lines still come out thin.",
                localHints: []
            ),
            MLXRunnerModel(
                id: "gemma3-27b",
                name: "Gemma 3 27B",
                repo: "mlx-community/gemma-3-27b-it-4bit-DWQ",
                size: "16 GB",
                ramGB: 32,
                quality: "highest",
                languages: ["ko", "en", "th"],
                recommended: false,
                detail: "Highest quality Gemma 3. Use Gemma 4 26B/31B instead if those are already on disk.",
                localHints: []
            ),
            MLXRunnerModel(
                id: "qwen3-8b",
                name: "Qwen3 8B",
                repo: "mlx-community/Qwen3-8B-4bit-DWQ",
                size: "4.6 GB",
                ramGB: 12,
                quality: "korean",
                languages: ["ko", "en", "th"],
                recommended: false,
                detail: "Strong Korean and English. Thai is weaker than Gemma 3 or 4.",
                localHints: []
            ),
        ]
    )

    static var models: [MLXRunnerModel] {
        self.load().models
    }

    static func model(id: String, extras: [MLXRunnerModel] = []) -> MLXRunnerModel? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extra = extras.first(where: { $0.id == trimmed }) {
            return extra
        }
        if let catalog = self.models.first(where: { $0.id == trimmed }) {
            return catalog
        }
        let spec = self.parseSpec(trimmed)
        return spec.kind == .unknown ? nil : spec.asModel()
    }

    static func resolvedModelID(_ raw: String, extras: [MLXRunnerModel] = []) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return self.load().defaultModelID
        }
        if let model = self.model(id: trimmed, extras: extras) {
            return model.id
        }
        let spec = self.parseSpec(trimmed)
        if spec.kind != .unknown {
            return spec.id
        }
        return self.load().defaultModelID
    }

    static func parseSpec(_ raw: String) -> MLXRunnerSpec {
        MLXRunnerSpec.parse(raw, catalog: self.load())
    }

    static func load(from url: URL? = Self.catalogURL) -> MLXRunnerCatalogFile {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? Self.decoder.decode(MLXRunnerCatalogFile.self, from: data),
              !decoded.models.isEmpty
        else {
            return self.bundled
        }
        return decoded
    }

    static var catalogURL: URL? {
        if let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "mlx_runner")
            ?? Bundle.main.url(forResource: "catalog", withExtension: "json")
        {
            return bundled
        }
        return self.sourceCatalogURL
    }

    static var runnerScriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "mlx_runner", withExtension: "py", subdirectory: "mlx_runner")
            ?? Bundle.main.url(forResource: "mlx_runner", withExtension: "py")
        {
            return bundled
        }
        return self.sourceCatalogURL?.deletingLastPathComponent().appendingPathComponent("mlx_runner.py")
    }

    static var sourceCatalogURL: URL? {
        let here = URL(fileURLWithPath: #filePath)
        let candidate = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/mlx_runner/catalog.json")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

enum MLXRunnerSpecKind: String, Equatable {
    case catalog
    case huggingface
    case local
    case lmstudio
    case unknown
}

struct MLXRunnerSpec: Equatable {
    var id: String
    var kind: MLXRunnerSpecKind
    var name: String
    var repo: String
    var pathHint: String?

    func asModel() -> MLXRunnerModel {
        let isFolder = self.kind == .local || self.kind == .lmstudio
        return MLXRunnerModel(
            id: self.id,
            name: self.name,
            repo: self.repo,
            size: isFolder ? "On disk" : "Hugging Face",
            ramGB: 0,
            quality: self.kind.rawValue,
            languages: ["ko", "en", "th"],
            recommended: false,
            detail: self.kind == .lmstudio
                ? "Already downloaded in LM Studio. The runner uses this folder as-is."
                : isFolder
                    ? "Built MLX folder on this Mac. The runner uses this folder as-is."
                    : "Pasted Hugging Face MLX repo. Download it, then Start.",
            localHints: self.pathHint.map { [$0] } ?? [],
            source: self.kind == .catalog ? "catalog" : self.kind.rawValue
        )
    }

    static func parse(_ raw: String, catalog: MLXRunnerCatalogFile) -> MLXRunnerSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if trimmed.isEmpty {
            return Self.unknown(raw)
        }
        if let model = catalog.models.first(where: { $0.id == trimmed }) {
            return MLXRunnerSpec(
                id: model.id,
                kind: .catalog,
                name: model.name,
                repo: model.repo,
                pathHint: model.localHints.first
            )
        }
        if trimmed.hasPrefix("local:") {
            return Self.folderSpec(String(trimmed.dropFirst(6)), catalog: catalog)
        }
        if trimmed.hasPrefix("hf:") {
            return Self.huggingfaceSpec(String(trimmed.dropFirst(3)), catalog: catalog)
        }
        if let repo = Self.huggingFaceRepo(from: trimmed) {
            return Self.huggingfaceSpec(repo, catalog: catalog)
        }

        let expanded = Self.expandPath(trimmed)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || FileManager.default.fileExists(atPath: expanded) {
            return Self.folderSpec(expanded, catalog: catalog)
        }
        return Self.unknown(trimmed)
    }

    private static func unknown(_ raw: String) -> MLXRunnerSpec {
        MLXRunnerSpec(id: raw, kind: .unknown, name: raw, repo: raw, pathHint: nil)
    }

    private static func huggingfaceSpec(_ repo: String, catalog: MLXRunnerCatalogFile) -> MLXRunnerSpec {
        if let model = catalog.models.first(where: { $0.repo == repo }) {
            return MLXRunnerSpec(
                id: model.id,
                kind: .catalog,
                name: model.name,
                repo: model.repo,
                pathHint: model.localHints.first
            )
        }
        return MLXRunnerSpec(id: "hf:\(repo)", kind: .huggingface, name: repo, repo: repo, pathHint: nil)
    }

    private static func folderSpec(_ raw: String, catalog: MLXRunnerCatalogFile) -> MLXRunnerSpec {
        let folder = Self.mlxFolder(from: raw) ?? Self.expandPath(raw)
        if let model = Self.catalogModel(matchingPath: folder, catalog: catalog) {
            return MLXRunnerSpec(
                id: model.id,
                kind: .catalog,
                name: model.name,
                repo: model.repo,
                pathHint: folder
            )
        }
        let kind: MLXRunnerSpecKind = folder.contains("/.lmstudio/models") ? .lmstudio : .local
        return MLXRunnerSpec(
            id: "local:\(folder)",
            kind: kind,
            name: URL(fileURLWithPath: folder).lastPathComponent,
            repo: folder,
            pathHint: folder
        )
    }

    private static func catalogModel(matchingPath path: String, catalog: MLXRunnerCatalogFile) -> MLXRunnerModel? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return catalog.models.first { model in
            model.localHints.contains { hint in
                URL(fileURLWithPath: Self.expandPath(hint)).standardizedFileURL.path == standardized
            }
        }
    }

    static func huggingFaceRepo(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value),
           let host = url.host?.lowercased(),
           ["huggingface.co", "www.huggingface.co", "hf.co", "www.hf.co"].contains(host)
        {
            let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            let filtered = parts.filter { !["tree", "blob", "resolve"].contains($0) }
            if filtered.count >= 2 {
                value = "\(filtered[0])/\(filtered[1])"
            }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) } })
        else {
            return nil
        }
        return value
    }

    static func expandPath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }

    static func mlxFolder(from raw: String) -> String? {
        let expanded = Self.expandPath(raw)
        var url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            url.deleteLastPathComponent()
        }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) {
            return url.standardizedFileURL.path
        }
        return nil
    }
}
