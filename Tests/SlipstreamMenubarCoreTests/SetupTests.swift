import Foundation
import XCTest
@testable import SlipstreamMenubarCore

final class ModelManifestTests: XCTestCase {
    private var resourceURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/models.json")
    }

    func testTheBundledFileMatchesTheCompiledInCopy() throws {
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual(decoded, ModelManifest.builtIn)
    }

    func testSwiftIsTheDefaultAndTheConvertedOneIsComingSoon() throws {
        let manifest = ModelManifest.builtIn
        XCTAssertEqual(manifest.defaultEntry?.id, "swift-v3")
        XCTAssertEqual(manifest.setupEntries.map(\.id), ["swift-v3", "qwen38-v3", "swift-v3-converted"])
        let converted = try XCTUnwrap(manifest.entry(id: "swift-v3-converted"))
        XCTAssertFalse(converted.isAvailable)
        XCTAssertNil(converted.spec)
        XCTAssertEqual(converted.detail(memoryGiB: 64), "Available soon")
        XCTAssertEqual(manifest.catalog, [ModelSpec.swiftQwen38FlashNext, ModelSpec.qwen38FlashNext],
                       "Settings offers what is available, in the manifest's order")
        XCTAssertEqual(ModelSpec.swiftQwen38FlashNext.extraFiles, [ModelSpec.mtpDraftHead])
    }

    func testMakingTheConvertedModelAvailableAndDefaultIsAManifestEdit() throws {
        var json = try String(contentsOf: resourceURL, encoding: .utf8)
        json = json.replacingOccurrences(of: #""isDefault": true"#, with: #""isDefault": false"#)
        json = json.replacingOccurrences(
            of: #""kind": "package","#,
            with: #""kind": "package", "repository": "someone/Swift-Splash", "isDefault": true,"#)
        json = json.replacingOccurrences(of: #""availability": "comingSoon""#, with: #""availability": "available""#)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.defaultEntry?.id, "swift-v3-converted")
        XCTAssertEqual(manifest.defaultEntry?.spec?.kind, .package)
        XCTAssertTrue(manifest.catalog.contains { $0.repository == "someone/Swift-Splash" })
    }

    func testMemoryDecidesTheMetadataLineButNotSelectability() throws {
        let swift = try XCTUnwrap(ModelManifest.builtIn.entry(id: "swift-v3"))
        let size = ByteCountFormatter.string(fromByteCount: swift.sizeBytes, countStyle: .file)
        XCTAssertEqual(swift.detail(memoryGiB: 64), "\(size) · Fits your Mac")
        XCTAssertEqual(swift.detail(memoryGiB: 32), "\(size) · Needs 64 GB memory")
        XCTAssertTrue(swift.isAvailable)
    }

    func testMissingOptionalKeysTakeDefaults() throws {
        let json = #"{"version": 1, "models": [{"id": "x", "name": "X", "repository": "a/b", "sizeBytes": 5}]}"#
        let entry = try XCTUnwrap(JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8)).models.first)
        XCTAssertEqual(entry.title, "X")
        XCTAssertEqual(entry.kind, .gguf)
        XCTAssertTrue(entry.isAvailable)
        XCTAssertTrue(entry.inSetup)
        XCTAssertFalse(entry.isDefault)
    }
}

final class SetupProgressTests: XCTestCase {
    func testSetupOpensOnlyWhileSomethingIsMissing() {
        let fresh = ServerConfig()
        XCTAssertTrue(SetupProgress.isNeeded(config: fresh, hasInstallation: false, modelPresent: false))
        XCTAssertTrue(SetupProgress.isNeeded(config: fresh, hasInstallation: true, modelPresent: false))
        XCTAssertFalse(SetupProgress.isNeeded(config: fresh, hasInstallation: true, modelPresent: true),
                       "an existing user never sees it")
        let done = ServerConfig(setupCompleted: true)
        XCTAssertFalse(SetupProgress.isNeeded(config: done, hasInstallation: false, modelPresent: false))
    }

    func testAReopenedSetupContinuesAtTheFirstIncompleteStep() {
        XCTAssertEqual(SetupProgress.firstIncompleteStep(hasInstallation: false, modelPresent: false), .welcome)
        XCTAssertEqual(SetupProgress.firstIncompleteStep(hasInstallation: true, modelPresent: false), .model)
        XCTAssertEqual(SetupProgress.firstIncompleteStep(hasInstallation: true, modelPresent: true), .server)
    }

    func testOlderSettingsHaveNotCompletedSetup() throws {
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"model": "a/b"}"#.utf8))
        XCTAssertFalse(config.setupCompleted)
        XCTAssertEqual(config.slipstreamPath, "")
    }
}

final class ChosenInstallationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeRelease(pull: Bool = true) throws -> URL {
        let release = root.appendingPathComponent("opt/26.10.4")
        try executable(release.appendingPathComponent("bin/slipstream"))
        try Data(#"{"version": "26.10.4"}"#.utf8).write(to: release.appendingPathComponent("release.json"))
        try FileManager.default.createDirectory(at: release.appendingPathComponent("install"), withIntermediateDirectories: true)
        try Data((pull ? #"commands.add_parser("pull")"# : "").utf8)
            .write(to: release.appendingPathComponent("install/launcher.py"))
        return release
    }

    func testAReleaseFolderOrItsCommandIsAccepted() throws {
        let release = try makeRelease()
        for url in [release, release.appendingPathComponent("bin/slipstream")] {
            let installation = try SlipstreamInstallation.chosen(url).get()
            XCTAssertEqual(installation.kind, .release)
            XCTAssertEqual(installation.version, "26.10.4")
        }
    }

    func testAChosenReleaseIsFoundBeforeTheDefaultLocation() throws {
        let release = try makeRelease()
        let installation = try SlipstreamInstallation.chosen(release).get()
        let config = installation.applied(to: ServerConfig(useCheckout: true))
        XCTAssertFalse(config.useCheckout)
        let found = InstallationLocator.find(config: config, searchPath: [],
                                             binDirectory: root.appendingPathComponent("empty"))
        XCTAssertEqual(found?.version, "26.10.4")
    }

    func testACheckoutIsRunAsACheckout() throws {
        let checkout = root.appendingPathComponent("checkout")
        try executable(checkout.appendingPathComponent("slipstream"))
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("install"), withIntermediateDirectories: true)
        try Data(#"commands.add_parser("pull")"#.utf8).write(to: checkout.appendingPathComponent("install/launcher.py"))
        let installation = try SlipstreamInstallation.chosen(checkout).get()
        let config = installation.applied(to: ServerConfig(slipstreamPath: "/old"))
        XCTAssertTrue(config.useCheckout)
        XCTAssertEqual(config.repoPath, checkout.path)
        XCTAssertEqual(config.slipstreamPath, "")
    }

    func testAnythingElseSaysWhatIsWrong() throws {
        XCTAssertEqual(SlipstreamInstallation.chosen(root).failure, .notFound)
        XCTAssertEqual(SlipstreamInstallation.chosen(root.appendingPathComponent("missing")).failure, .notFound)
        XCTAssertTrue(SlipstreamInstallation.ChoiceError.notFound.localizedDescription
            .hasPrefix("That folder doesn't contain Slipstream."))
        let old = try makeRelease(pull: false)
        XCTAssertEqual(SlipstreamInstallation.chosen(old).failure, .tooOld("Slipstream 26.10.4"))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

final class HubModelIDTests: XCTestCase {
    func testAnIdOrTheModelPageAddressIsAccepted() {
        let id = "nitinpanj/qwen38-flash-next-v3"
        for input in [id, "  \(id)\n", "https://huggingface.co/\(id)", "huggingface.co/\(id)",
                      "https://hf.co/\(id)", "https://huggingface.co/\(id)/", "https://huggingface.co/\(id)/tree/main",
                      "https://huggingface.co/\(id)/blob/main/README.md", "https://huggingface.co/\(id)?library=gguf",
                      "HTTPS://HuggingFace.co/\(id)"] {
            XCTAssertEqual(HubModelID.parse(input), id, input)
        }
    }

    func testAnythingElseIsRefused() {
        for input in ["", "qwen38-flash-next-v3", "https://huggingface.co/datasets/owner/name",
                      "https://huggingface.co/spaces/owner/name", "owner/name/extra", "owner name/x",
                      "https://example.com/owner/name", "/owner/name"] {
            XCTAssertNil(HubModelID.parse(input), input)
        }
    }
}

final class PullCheckTests: XCTestCase {
    func testSlipstreamsVerdictBecomesTheModelToDownload() throws {
        let output = Data("""
            make: Nothing to be done for `install-environment'.
            {"supported": true, "model": "nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF", "revision": "6d6b", \
            "kind": "gguf", "files": 3, "bytes": 104468009728, "mtp": "nitinpanj/qwen38-flash-next-v3"}

            """.utf8)
        guard case .supported(let spec, let bytes) = PullCheck.outcome(fromOutput: output) else {
            return XCTFail("no verdict")
        }
        XCTAssertEqual(spec.repository, "nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF")
        XCTAssertEqual(spec.title, "Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF")
        XCTAssertEqual(spec.kind, .gguf)
        XCTAssertEqual(spec.extraFiles, [ModelSpec.mtpDraftHead], "the MTP head comes from the base model")
        XCTAssertEqual(bytes, 104_468_009_728)

        let own = Data(#"{"supported": true, "model": "a/b", "kind": "gguf", "bytes": 5, "mtp": "a/b"}"#.utf8)
        guard case .supported(let base, _) = PullCheck.outcome(fromOutput: own) else { return XCTFail() }
        XCTAssertEqual(base.extraFiles, [], "a repository with its own MTP head needs no other")

        let package = Data(#"{"supported": true, "model": "a/b", "kind": "package", "bytes": 5}"#.utf8)
        guard case .supported(let ready, _) = PullCheck.outcome(fromOutput: package) else { return XCTFail() }
        XCTAssertEqual(ready.kind, .package)
    }

    func testARefusalCarriesSlipstreamsReason() {
        let output = Data(#"{"supported": false, "model": "a/b", "reason": "repository holds 3 GGUF files"}"#.utf8)
        XCTAssertEqual(PullCheck.outcome(fromOutput: output), .unsupported("repository holds 3 GGUF files"))
    }

    func testNoVerdictMeansTheAppChecksItself() {
        XCTAssertNil(PullCheck.outcome(fromOutput: Data("usage: slipstream pull ...\n".utf8)))
        XCTAssertNil(PullCheck.outcome(fromOutput: Data()))
    }
}

final class OneGGUFModelTests: XCTestCase {
    private func tree(_ files: [(String, Int64)]) -> Data {
        try! JSONSerialization.data(withJSONObject: files.map { ["type": "file", "path": $0.0, "size": $0.1] })
    }

    func testOneModelOfAnySizeIsAccepted() {
        // 300 GB of split files: a bigger Mac serves a bigger model; size is no criterion.
        let split = tree([("M-00001-of-00002.gguf", 150_000_000_000), ("M-00002-of-00002.gguf", 150_000_000_000)])
        XCTAssertEqual(ModelCheck.layout(ofTree: split).layout, .gguf(firstShard: "M-00001-of-00002.gguf", hasMTP: false))
        XCTAssertEqual(ModelCheck.layout(ofTree: tree([("M.gguf", 1)])).layout, .gguf(firstShard: "M.gguf", hasMTP: false))
    }

    func testSeveralModelsSideBySideAreRefused() {
        for files in [[("M.Q4_0.gguf", Int64(1)), ("M.Q8_0.gguf", 1)],
                      [("A-00001-of-00001.gguf", 1), ("B-00001-of-00001.gguf", 1)],
                      [("M-00001-of-00003.gguf", 1), ("M-00003-of-00003.gguf", 1)]] {
            guard case .unsupported = ModelCheck.layout(ofTree: tree(files)).layout else {
                return XCTFail("\(files) accepted")
            }
        }
    }
}
