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
        let shards = paths.filter { $0.hasSuffix(".gguf") && !$0.hasPrefix("MTP/") }.sorted()
        if let first = shards.first {
            return (.gguf(firstShard: first, hasMTP: paths.contains(ModelSpec.mtpDraftHead.path)), size)
        }
        return (.unsupported("it holds neither a Slipstream package (manifest.json) nor GGUF files"), size)
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
        let folder = "~/models/" + name.lowercased()
        switch layout {
        case .package:
            // The only package format the engine loads is Qwen3.8-Flash-Next's.
            return ModelSpec(repository: repository, folder: folder, title: name, kind: .package)
        case .gguf(_, let hasMTP):
            return ModelSpec(repository: repository, folder: folder, title: name,
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
