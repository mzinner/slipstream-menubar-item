import Darwin
import Foundation
import XCTest
@testable import SlipstreamMenubarCore

final class PrometheusTextTests: XCTestCase {
    func testParsesSeriesLabelsAndSpecialValues() {
        let values = PrometheusText.parse("""
        # HELP x help text
        # TYPE x gauge
        plain_total 42
        labelled{state="a b",x="1"} 1.5 1700000000
        infinite +Inf
        not_a_number NaN
        broken
        """)
        XCTAssertEqual(values["plain_total"], 42)
        XCTAssertEqual(values["labelled{state=\"a b\",x=\"1\"}"], 1.5)
        XCTAssertEqual(values["infinite"], .infinity)
        XCTAssertTrue(values["not_a_number"]?.isNaN == true)
        XCTAssertNil(values["broken"])
        XCTAssertEqual(values.count, 4)
    }

    func testReadsARealSlipstreamCapture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "metrics", withExtension: "txt",
                                                  subdirectory: "Fixtures"))
        let metrics = PrometheusText.parse(try String(contentsOf: url, encoding: .utf8))
        let sample = try XCTUnwrap(EngineSample(metrics: metrics, time: Date()))
        XCTAssertEqual(sample.kvPagesTotal, 12032)
        XCTAssertEqual(sample.memoryLimitBytes, 59_957_743_453)
        XCTAssertEqual(sample.memoryPressure, "normal")
        XCTAssertEqual(sample.kvPagesActive + sample.kvPagesCached + sample.kvPagesFree, sample.kvPagesTotal)
    }

    func testNoSampleWithoutSlipstreamMetrics() {
        XCTAssertNil(EngineSample(metrics: ["other_metric": 1], time: Date()))
    }
}

final class EngineRatesTests: XCTestCase {
    private func sample(output: Double, prompt: Double, at seconds: Double) -> EngineSample {
        EngineSample(metrics: [
            "slipstream_v2_decode_output_tokens_total": output,
            "slipstream_v2_prefill_input_tokens_total": prompt,
        ], time: Date(timeIntervalSinceReferenceDate: seconds))!
    }

    func testRatesUseWallClockTime() throws {
        let rates = try XCTUnwrap(EngineRates.between(
            sample(output: 100, prompt: 1000, at: 0), sample(output: 180, prompt: 1700, at: 2)))
        XCTAssertEqual(rates.outputTokensPerSecond, 40)
        XCTAssertEqual(rates.promptTokensPerSecond, 350)
    }

    func testCounterResetOrClockSkewYieldsNoRate() {
        XCTAssertNil(EngineRates.between(sample(output: 500, prompt: 0, at: 0), sample(output: 10, prompt: 0, at: 1)))
        XCTAssertNil(EngineRates.between(sample(output: 0, prompt: 0, at: 5), sample(output: 1, prompt: 0, at: 5)))
    }

    func testTimeSeriesKeepsItsCapacity() {
        var series = TimeSeries(capacity: 3)
        for value in 1...5 { series.append(Double(value), at: Date(timeIntervalSinceReferenceDate: Double(value))) }
        XCTAssertEqual(series.points.map(\.value), [3, 4, 5])
        XCTAssertEqual(series.maximum, 5)
    }
}

final class LogProgressTests: XCTestCase {
    func testFollowsPreparationLoadingAndReady() {
        var log = "[Slipstream] Preparing GGUF model from /models/x...\n"
        log += "  [DONE] Layer  0 finished (1431.4 MB)\n  [DONE] Head finished (993.9 MB)\n"
        XCTAssertEqual(LogProgress.parse(log).phase, .preparing)
        XCTAssertEqual(LogProgress.parse(log).preparedParts, 2)
        log += "17:06:39 Loading · local/x\n"
        XCTAssertEqual(LogProgress.parse(log).phase, .loading)
        log += "17:06:52 Ready · local/x · context 256K · http://127.0.0.1:8090\n"
        XCTAssertEqual(LogProgress.parse(log).phase, .ready)
    }

    func testKeepsTheLastError() {
        let progress = LogProgress.parse("error: first\nother\nerror: preparing /m failed; see the output above\n")
        XCTAssertEqual(progress.lastError, "error: preparing /m failed; see the output above")
    }
}

final class StatusResolverTests: XCTestCase {
    func testNoProcessIsStoppedUnlessSomethingAnswersThePort() {
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: false, healthOK: false, readyOK: false)), .stopped)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: false, healthOK: true, readyOK: true)), .running)
    }

    func testAnUnexpectedExitIsAFailureWithTheLoggedError() {
        var log = LogProgress()
        log.lastError = "error: model download failed"
        let status = StatusResolver.resolve(.init(processAlive: false, healthOK: false, readyOK: false,
                                                  logProgress: log, exitDescription: "Server exited with status 1"))
        XCTAssertEqual(status, .failed("error: model download failed"))
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: false, healthOK: false, readyOK: false,
                                                    stopping: true, exitDescription: "signal 15")), .stopped)
    }

    func testStartupPhases() {
        var log = LogProgress()
        log.phase = .preparing
        log.preparedParts = 7
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: false, readyOK: false,
                                                    logProgress: log)), .preparing(parts: 7))
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: false)), .loading)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: false, readyOK: false)), .starting)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: true)), .running)
    }

    func testARunningServerTurnsUnresponsiveOnlyAfterRepeatedFailures() {
        let blip = StatusObservation(processAlive: true, healthOK: false, readyOK: false,
                                     previous: .running, healthFailures: 1)
        XCTAssertEqual(StatusResolver.resolve(blip), .running)
        var lasting = blip
        lasting.healthFailures = StatusResolver.unresponsiveAfter
        XCTAssertEqual(StatusResolver.resolve(lasting), .unresponsive)
        XCTAssertEqual(StatusResolver.resolve(.init(processAlive: true, healthOK: true, readyOK: false,
                                                    stopping: true, previous: .running)), .stopping)
    }
}

final class ServerConfigTests: XCTestCase {
    func testServeArgumentsIncludeOnlySetOptions() {
        var config = ServerConfig(repoPath: "/repo", model: "/models/m", port: 8091)
        XCTAssertEqual(config.serveArguments(), ["serve", "--model", "/models/m", "--port", "8091"])
        config.maxContext = "100K"
        config.maxMemory = " 48G "
        config.allowedHosts = ["mac.local", " ", "10.0.0.2"]
        config.noWebUI = true
        XCTAssertEqual(config.serveArguments(), [
            "serve", "--model", "/models/m", "--port", "8091", "--max-context", "100K", "--max-memory", "48G",
            "--allowed-host", "mac.local", "--allowed-host", "10.0.0.2", "--no-webui",
        ])
    }

    func testValidation() {
        let config = ServerConfig(repoPath: "/nonexistent", model: "", port: 0, maxContext: "lots", maxMemory: "48G")
        let errors = config.validationErrors()
        XCTAssertEqual(errors.count, 4, "\(errors)")
    }

    func testRoundTripsThroughTheStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("menubar.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConfigStore(url: url)
        let config = ServerConfig(repoPath: "/r", model: "/m", port: 9000, allowedHosts: ["a"], startServerOnLaunch: true)
        try store.save(config)
        XCTAssertEqual(store.load(), config)
        XCTAssertEqual(ConfigStore(url: url.appendingPathExtension("missing")).load(), ServerConfig())
    }
}

final class ProcessInspectorTests: XCTestCase {
    func testReadsOwnArguments() throws {
        let arguments = try XCTUnwrap(ServerProcessInspector.arguments(of: getpid()))
        XCTAssertEqual(arguments.count, CommandLine.arguments.count)
        XCTAssertTrue(ServerProcessInspector.isAlive(getpid()))
        XCTAssertFalse(ServerProcessInspector.isSlipstreamServer(getpid()))
    }

    func testDeadPid() {
        XCTAssertFalse(ServerProcessInspector.isAlive(0))
        XCTAssertFalse(ServerProcessInspector.isAlive(Int32.max))
    }

    func testReadsTheLock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"pid": 70756, "model": "/m", "port": 8090}"#.utf8).write(to: url)
        XCTAssertEqual(ServeLock.read(from: url), ServeLock(pid: 70756, model: "/m", port: 8090))
        try Data().write(to: url)
        XCTAssertNil(ServeLock.read(from: url))
    }
}

final class SystemSamplerTests: XCTestCase {
    func testSamplesPlausibleValues() {
        let sampler = SystemSampler()
        let first = sampler.sample()
        XCTAssertNil(first.cpuUsage, "needs two readings")
        usleep(200_000)
        let second = sampler.sample()
        XCTAssertNotNil(second.cpuUsage)
        XCTAssertTrue((0...1).contains(second.cpuUsage ?? -1))
        XCTAssertGreaterThan(second.memoryUsedBytes, 0)
        XCTAssertLessThanOrEqual(second.memoryUsedBytes, second.memoryTotalBytes)
        if let gpu = second.gpuUsage { XCTAssertTrue((0...1).contains(gpu)) }
    }
}
