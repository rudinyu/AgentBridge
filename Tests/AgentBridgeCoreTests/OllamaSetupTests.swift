import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

/// The guided Ollama setup, with fake `ollama` and `open` programs and loopback
/// fixture servers. Nothing is downloaded and no real server is contacted.
final class OllamaSetupTests: XCTestCase {
    func testRecommendationFollowsPhysicalMemory() {
        let gib: UInt64 = 1 << 30
        XCTAssertEqual(OllamaSetup.recommendation(physicalMemoryBytes: 8 * gib).model, "qwen2.5-coder:3b")
        XCTAssertEqual(OllamaSetup.recommendation(physicalMemoryBytes: 12 * gib).model, "qwen2.5-coder:7b")
        XCTAssertEqual(OllamaSetup.recommendation(physicalMemoryBytes: 16 * gib).model, "qwen2.5-coder:7b")
        XCTAssertEqual(OllamaSetup.recommendation(physicalMemoryBytes: 32 * gib).model, "qwen2.5-coder:14b")
        XCTAssertEqual(OllamaSetup.recommendation(physicalMemoryBytes: 64 * gib).model, "qwen2.5-coder:32b")
        XCTAssertEqual(OllamaSetup.recommendation(physicalMemoryBytes: 0).model, "qwen2.5-coder:3b")
        XCTAssertEqual(OllamaSetup.recommendations.map(\.minimumMemoryGiB), OllamaSetup.recommendations.map(\.minimumMemoryGiB).sorted())
    }

    func testPullArgumentsAreOneValidatedArgument() throws {
        XCTAssertEqual(try OllamaSetup.pullArguments(model: "qwen2.5-coder:7b"), ["pull", "qwen2.5-coder:7b"])
        XCTAssertEqual(try OllamaSetup.pullArguments(model: "library/llama3.2:3b"), ["pull", "library/llama3.2:3b"])
        for bad in ["", "-rf", "a b", "../model", "model;rm", "gpt-oss:120b-cloud", "x:cloud", String(repeating: "a", count: 201)] {
            XCTAssertThrowsError(try OllamaSetup.pullArguments(model: bad), bad)
        }
    }

    func testPullProgressLinesAreParsed() {
        XCTAssertEqual(OllamaSetup.parsePullProgress("pulling manifest"), OllamaPullProgress(status: "pulling manifest", percent: nil))
        XCTAssertEqual(
            OllamaSetup.parsePullProgress("\u{1B}[?25l\u{1B}[1Gpulling 2bada8a74506...  45% ▕███████         ▏ 2.1 GB/4.7 GB  30 MB/s  1m20s\u{1B}[K"),
            OllamaPullProgress(status: "pulling 2bada8a74506...", percent: 45)
        )
        XCTAssertEqual(OllamaSetup.parsePullProgress("pulling 2bada8a74506... 100% ▕████▏ 4.7 GB")?.percent, 100)
        XCTAssertEqual(OllamaSetup.parsePullProgress("success"), OllamaPullProgress(status: "success", percent: nil))
        XCTAssertNil(OllamaSetup.parsePullProgress("\u{1B}[?25h  "))
        XCTAssertNil(OllamaSetup.parsePullProgress(""))
    }

    func testSetupStatesMissingInstalledAndRunning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let closed = try LoopbackHTTPServer { _ in .json(Data()) }
        let closedPort = closed.port
        closed.stop()
        try fixture.setEndpoint("http://127.0.0.1:\(closedPort)")

        var status = await fixture.service.ollamaSetupStatus(physicalMemoryBytes: 16 << 30)
        XCTAssertEqual(status.state, .notInstalled)
        XCTAssertNil(status.executablePath)
        XCTAssertNil(status.appBundlePath)
        XCTAssertEqual(status.recommendation.model, "qwen2.5-coder:7b")
        XCTAssertEqual(status.physicalMemoryGiB, 16)

        let executable = try fixture.installOllama(script: "#!/bin/sh\nexit 0\n")
        status = await fixture.service.ollamaSetupStatus(physicalMemoryBytes: 16 << 30)
        XCTAssertEqual(status.state, .installedNotRunning)
        XCTAssertEqual(status.executablePath, executable.path)

        let server = try LoopbackHTTPServer { _ in .json(Data(#"{"models":[{"name":"qwen2.5-coder:7b"}]}"#.utf8)) }
        defer { server.stop() }
        try fixture.setEndpoint("http://127.0.0.1:\(server.port)")
        status = await fixture.service.ollamaSetupStatus(physicalMemoryBytes: 64 << 30)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.installedModels, ["qwen2.5-coder:7b"])
        XCTAssertEqual(status.endpoint, "http://127.0.0.1:\(server.port)")
        XCTAssertEqual(server.requests.map(\.method), ["GET"])
    }

    func testPullRunsOllamaWithArgvAndReportsProgress() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.setEndpoint("http://127.0.0.1:11999")
        let log = fixture.root.appendingPathComponent("ollama-calls.log")
        _ = try fixture.installOllama(script: """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\n' "$argument" >> '\(log.path)'; done
        printf 'host=%s\\n' "$OLLAMA_HOST" >> '\(log.path)'
        printf 'pulling manifest\\n' >&2
        printf '\\033[1Gpulling abc...  50%% ▕██  ▏ 1 GB/2 GB\\r' >&2
        printf '\\033[1Gpulling abc... 100%% ▕████▏ 2 GB/2 GB\\n' >&2
        printf 'success\\n' >&2
        exit 0
        """)
        let recorder = ProgressRecorder()
        try await fixture.service.pullOllamaModel("qwen2.5-coder:7b") { recorder.append($0) }
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(calls, "pull\nqwen2.5-coder:7b\nhost=http://127.0.0.1:11999\n")
        XCTAssertEqual(recorder.values.compactMap(\.percent), [50, 100])
        XCTAssertEqual(recorder.values.first?.status, "pulling manifest")
        XCTAssertEqual(recorder.values.last?.status, "success")
    }

    func testFailedPullReportsTheLastLine() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.installOllama(script: "#!/bin/sh\nprintf 'Error: pull model manifest: file does not exist\\n' >&2\nexit 1\n")
        do {
            try await fixture.service.pullOllamaModel("no-such-model:1b")
            XCTFail("A failed pull was reported as done.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertEqual(message, "The model download failed with exit code 1: Error: pull model manifest: file does not exist")
        }
    }

    func testPullIsCancellable() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.installOllama(script: "#!/bin/sh\nprintf 'pulling manifest\\n' >&2\nsleep 30\n")
        let cancellation = CancellationFlag()
        let recorder = ProgressRecorder()
        let service = fixture.service
        let task = Task { try await service.pullOllamaModel("qwen2.5-coder:3b", cancellation: cancellation) { recorder.append($0) } }
        let started = Date()
        while recorder.values.isEmpty && Date().timeIntervalSince(started) < 10 { try await Task.sleep(for: .milliseconds(50)) }
        cancellation.cancel()
        do {
            try await task.value
            XCTFail("A cancelled pull finished.")
        } catch AgentBridgeError.processCancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testPullWithoutOllamaIsRefusedBeforeRunningAnything() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            try await fixture.service.pullOllamaModel("qwen2.5-coder:7b")
            XCTFail("A pull started without ollama.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.hasPrefix("The ollama command was not found."))
        }
    }

    func testStartOpensTheAppBundleOrExplainsServe() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            try await fixture.service.startOllamaApp()
            XCTFail("Started without an app bundle.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.contains("ollama serve"))
        }

        let app = fixture.root.appendingPathComponent("Applications/Ollama.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        fixture.service.ollamaAppBundleCandidates = [app.path]
        let log = fixture.root.appendingPathComponent("open.log")
        let open = fixture.root.appendingPathComponent("bin/open")
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '\(log.path)'; done\n".utf8).write(to: open)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        fixture.service.openExecutablePath = open.path
        try await fixture.service.startOllamaApp()
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "-a\n\(app.path)\n")
        let closed = try LoopbackHTTPServer { _ in .json(Data()) }
        closed.stop()
        try fixture.setEndpoint("http://127.0.0.1:\(closed.port)")
        let status = await fixture.service.ollamaSetupStatus()
        XCTAssertEqual(status.appBundlePath, app.path)
    }

    // MARK: Fixture

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [OllamaPullProgress] = []
        var values: [OllamaPullProgress] { lock.lock(); defer { lock.unlock() }; return stored }
        func append(_ value: OllamaPullProgress) { lock.lock(); stored.append(value); lock.unlock() }
    }

    private struct Fixture {
        let root: URL
        let service: BridgeService

        func setEndpoint(_ endpoint: String) throws {
            var settings = try service.settings()
            settings.localModel = LocalModelSettings(backend: .ollama, endpoint: endpoint)
            try service.saveSettings(settings)
        }

        @discardableResult
        func installOllama(script: String) throws -> URL {
            let executable = root.appendingPathComponent("bin/ollama")
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return executable
        }
    }

    private func makeFixture() throws -> Fixture {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("AgentBridge-Ollama-\(UUID().uuidString.lowercased())", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        for directory in [bin, state, data] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let store = try AuditStore(rootURL: state, workspaceRootURL: data, managedWorkspaceRoots: [])
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "PATH": bin.path])
        service.ollamaExecutableCandidates = []
        service.ollamaAppBundleCandidates = []
        return Fixture(root: root, service: service)
    }
}
