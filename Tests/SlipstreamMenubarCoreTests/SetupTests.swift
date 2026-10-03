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
