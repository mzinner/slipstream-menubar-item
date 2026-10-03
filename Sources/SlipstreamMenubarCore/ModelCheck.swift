import Foundation

/// Decides whether a Hugging Face repository is something this Slipstream can serve,
/// from its file listing, its manifest and the header of its first GGUF shard.
public enum ModelCheck {
    /// Package formats the engine loads, with the manifest schema each must declare. The
    /// launcher's PACKAGE_FORMATS also lists Splash 1.0's `splash-packed-q4` (schema 3) and
    /// `splash-packed-q4-moe` (4), but the engine rejects them (ModelDescriptor.mm).
    public static let packageFormats: [String: Int] = [
        "splash-packed-q4-qwen4exp": 5,
    ]
    /// The only GGUF architecture the converter turns into a package.
    public static let ggufArchitecture = "qwen4exp"

    public enum Layout: Equatable, Sendable {
        /// A package; `manifest.json` still needs reading.
        case package
        /// GGUF shards; the first (sorted) one's header still needs reading. `hasMTP` says
        /// whether the repository ships `MTP/mtp-shared-Q4_K_M.gguf` itself.
        case gguf(firstShard: String, hasMTP: Bool)
        case unsupported(String)
    }

    /// What kind of repository the file listing (a Hub `tree`) describes, and its size.
    public static func layout(ofTree data: Data) -> (layout: Layout, size: Int64) {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (.unsupported("Hugging Face returned no file list for it"), 0)
        }
        let files = entries.filter { $0["type"] as? String == "file" }
        let paths = files.compactMap { $0["path"] as? String }
        let size = files.compactMap { ($0["size"] as? NSNumber)?.int64Value }.reduce(0, +)
        if paths.contains("manifest.json") { return (.package, size) }
        let ggufs = paths.filter { $0.hasSuffix(".gguf") && !$0.hasPrefix("MTP/") }
        // Collections (unsloth, AtomicChat, ...) keep one quantisation per sub-folder; the
        // converter takes one model's shards from the folder it is given.
        let shards = ggufs.filter { !$0.contains("/") }.sorted()
        if shards.isEmpty, !ggufs.isEmpty {
            return (.unsupported("it keeps several GGUF variants in sub-folders; Slipstream needs one "
                                 + "Qwen3.8-Flash-Next model at the top level of the repository"), size)
        }
        // One model: a single file, or one complete gguf-split set (<stem>-00001-of-0000N.gguf),
        // as Slipstream's `pull` requires; never a size limit, which bigger Macs outgrow.
        if shards.count > 1, let problem = splitProblem(shards) {
            return (.unsupported(problem), size)
        }
        if let first = shards.first {
            return (.gguf(firstShard: first, hasMTP: paths.contains(ModelSpec.mtpDraftHead.path)), size)
        }
        return (.unsupported("it holds neither a Slipstream package (manifest.json) nor GGUF files"), size)
    }

    /// Nil when the files are one model's complete set of split files, else why not.
    static func splitProblem(_ shards: [String]) -> String? {
        let pattern = #/^(?<stem>.+)-(?<index>\d{5})-of-(?<count>\d{5})\.gguf$/#
        let splits = shards.compactMap { try? pattern.wholeMatch(in: $0)?.output }
        let sets = Set(splits.map { "\($0.stem)|\($0.count)" })
        guard splits.count == shards.count, sets.count == 1, let count = Int(splits[0].count) else {
            return "it holds \(shards.count) GGUF files that are not one model's split files "
                + "(\(shards.prefix(3).joined(separator: ", "))\(shards.count > 3 ? ", …" : "")); "
                + "Slipstream converts one model per repository"
        }
        guard splits.compactMap({ Int($0.index) }) == Array(1...count) else {
            return "it is missing some of \(splits[0].stem)'s split GGUF files"
        }
        return nil
    }

    /// Nil when the manifest describes a package this launcher can serve, else why not.
    public static func problem(withManifest data: Data) -> String? {
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "its manifest.json is not valid JSON"
        }
        let format = (manifest["format"] as? [String: Any])?["name"] as? String
        guard let format, let schema = packageFormats[format] else {
            return "its package format \(format.map { "“\($0)”" } ?? "(none)") is not one the Slipstream engine loads "
                + "(only Qwen3.8-Flash-Next packages, splash-packed-q4-qwen4exp)"
        }
        guard manifest["schema_version"] as? Int == schema else {
            return "its manifest schema is not the one the \(format) format needs (\(schema))"
        }
        return nil
    }

    /// Nil when the GGUF architecture can be converted, else why not.
    public static func problem(withArchitecture architecture: String?) -> String? {
        guard let architecture else { return "the architecture of its GGUF files could not be read" }
        guard architecture == ggufArchitecture else {
            return "its GGUF files are “\(architecture)”; Slipstream converts only Qwen3.8-Flash-Next (\(ggufArchitecture))"
        }
        return nil
    }

    /// A model entry for a repository that passed the checks.
    public static func spec(repository: String, layout: Layout) -> ModelSpec? {
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        switch layout {
        case .package:
            // The only package format the engine loads is Qwen3.8-Flash-Next's.
            return ModelSpec(repository: repository, title: name, kind: .package)
        case .gguf(_, let hasMTP):
            return ModelSpec(repository: repository, title: name,
                             extraFiles: hasMTP ? [] : [ModelSpec.mtpDraftHead], kind: .gguf)
        case .unsupported:
            return nil
        }
    }
}

/// Reads `general.architecture` from the start of a GGUF file, so a model can be checked
/// with a ranged request for its first bytes instead of downloading it.
public enum GGUFHeader {
    /// Bytes enough for the key/value header up to `general.architecture`, which writers
    /// put near the start (it precedes the large tokenizer arrays).
    public static let probeBytes = 256 * 1024

    public static func architecture(in data: Data) -> String? {
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("GGUF".utf8), let version = reader.u32(), version >= 2,
              reader.u64() != nil, let count = reader.u64() else { return nil }
        for _ in 0..<min(count, 10_000) {
            guard let key = reader.string(), let type = reader.u32() else { return nil }
            if key == "general.architecture", type == 8 { return reader.string() }
            guard reader.skipValue(type: type) else { return nil }
        }
        return nil
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + count)
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            guard let raw = bytes(MemoryLayout<T>.size) else { return nil }
            return raw.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }

        mutating func u32() -> UInt32? { integer(UInt32.self) }
        mutating func u64() -> UInt64? { integer(UInt64.self) }

        mutating func string() -> String? {
            guard let length = u64(), length < 1 << 20, let raw = bytes(Int(length)) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }

        /// GGUF value types: 0 u8, 1 i8, 2 u16, 3 i16, 4 u32, 5 i32, 6 f32, 7 bool,
        /// 8 string, 9 array, 10 u64, 11 i64, 12 f64.
        mutating func skipValue(type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7: return bytes(1) != nil
            case 2, 3: return bytes(2) != nil
            case 4, 5, 6: return bytes(4) != nil
            case 10, 11, 12: return bytes(8) != nil
            case 8: return string() != nil
            case 9:
                guard let elementType = u32(), let count = u64(), count < 10_000_000 else { return false }
                for _ in 0..<count where !skipValue(type: elementType) { return false }
                return true
            default: return false
            }
        }
    }
}

/// A Hugging Face model id from what a user pastes: `owner/name`, or the model's page
/// address (`https://huggingface.co/owner/name`, also `hf.co/…`, with or without
/// `/tree/main`, `/blob/main/<file>` or a query). Datasets and Spaces are not models.
public enum HubModelID {
    public static func parse(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^(https?://)?(www\.)?(huggingface\.co|hf\.co)/"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        text = String(text.prefix { $0 != "?" && $0 != "#" })
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !["datasets", "spaces", "models"].contains(parts[0].lowercased()),
              parts.count == 2 || ["tree", "blob", "resolve", ""].contains(parts[2]) else { return nil }
        let id = parts[0] + "/" + parts[1]
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#,
                       options: .regularExpression) != nil else { return nil }
        return id
    }
}

/// `slipstream pull <repo> --check --json`: Slipstream's own verdict on a repository, so the
/// app need not know its formats.
public enum PullCheck {
    public enum Outcome: Equatable, Sendable {
        case supported(ModelSpec, bytes: Int64)
        case unsupported(String)
    }

    /// The outcome from the command's output: its last line that is a JSON object
    /// (a checkout's launcher may print its environment setup first).
    public static func outcome(fromOutput data: Data) -> Outcome? {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).reversed()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let supported = object["supported"] as? Bool else { continue }
            guard supported else {
                return .unsupported(object["reason"] as? String ?? "Slipstream cannot serve it")
            }
            guard let model = object["model"] as? String,
                  let kind = (object["kind"] as? String).flatMap(ModelSpec.Kind.init(rawValue:)),
                  let bytes = (object["bytes"] as? NSNumber)?.int64Value else { continue }
            // The MTP head comes from the base model's repository when the model has none.
            let mtp = object["mtp"] as? String
            let extras = kind == .gguf && mtp != nil && mtp != model ? [ModelSpec.mtpDraftHead] : []
            let title = model.split(separator: "/").last.map(String.init) ?? model
            return .supported(ModelSpec(repository: model, title: title, extraFiles: extras, kind: kind), bytes: bytes)
        }
        return nil
    }
}
