import Foundation

/// A code model suggested for Macs with at least `minimumMemoryGiB` of memory.
public struct OllamaModelRecommendation: Equatable, Sendable {
    public let minimumMemoryGiB: Int
    public let model: String
    /// About how much `ollama pull` downloads, for the button's label.
    public let approximateDownloadGB: Double

    public init(minimumMemoryGiB: Int, model: String, approximateDownloadGB: Double) {
        self.minimumMemoryGiB = minimumMemoryGiB
        self.model = model
        self.approximateDownloadGB = approximateDownloadGB
    }
}

public enum OllamaSetupState: String, Equatable, Sendable {
    case notInstalled
    case installedNotRunning
    case running
}

/// What the guided setup found. Checking reads the file system and asks the
/// configured loopback endpoint for its model list; it installs and starts nothing.
public struct OllamaSetupStatus: Equatable, Sendable {
    public let executablePath: String?
    public let appBundlePath: String?
    public let endpoint: String
    public let serverRunning: Bool
    public let installedModels: [String]
    public let physicalMemoryBytes: UInt64
    public let recommendation: OllamaModelRecommendation

    public init(executablePath: String?, appBundlePath: String?, endpoint: String, serverRunning: Bool, installedModels: [String], physicalMemoryBytes: UInt64, recommendation: OllamaModelRecommendation) {
        self.executablePath = executablePath
        self.appBundlePath = appBundlePath
        self.endpoint = endpoint
        self.serverRunning = serverRunning
        self.installedModels = installedModels
        self.physicalMemoryBytes = physicalMemoryBytes
        self.recommendation = recommendation
    }

    public var state: OllamaSetupState {
        if serverRunning { return .running }
        return executablePath != nil || appBundlePath != nil ? .installedNotRunning : .notInstalled
    }

    public var physicalMemoryGiB: Int { Int(physicalMemoryBytes / (1 << 30)) }
}

/// One line of `ollama pull` progress.
public struct OllamaPullProgress: Equatable, Sendable {
    public let status: String
    public let percent: Int?

    public init(status: String, percent: Int?) {
        self.status = status
        self.percent = percent
    }
}

public enum OllamaSetup {
    /// Ollama's official download page. The user installs Ollama from there.
    public static let downloadPageURL = URL(string: "https://ollama.com/download")!

    /// The only model table. Check every name against the Ollama library
    /// (https://ollama.com/library) before each release: a renamed or removed tag
    /// makes `ollama pull` fail. Sizes are approximate.
    public static let recommendations: [OllamaModelRecommendation] = [
        OllamaModelRecommendation(minimumMemoryGiB: 0, model: "qwen2.5-coder:3b", approximateDownloadGB: 1.9),
        OllamaModelRecommendation(minimumMemoryGiB: 12, model: "qwen2.5-coder:7b", approximateDownloadGB: 4.7),
        OllamaModelRecommendation(minimumMemoryGiB: 24, model: "qwen2.5-coder:14b", approximateDownloadGB: 9.0),
        OllamaModelRecommendation(minimumMemoryGiB: 48, model: "qwen2.5-coder:32b", approximateDownloadGB: 20)
    ]

    /// The largest suggestion this Mac's memory allows.
    public static func recommendation(physicalMemoryBytes: UInt64) -> OllamaModelRecommendation {
        let gib = Int(physicalMemoryBytes / (1 << 30))
        return recommendations.last { gib >= $0.minimumMemoryGiB } ?? recommendations[0]
    }

    /// A model name `ollama pull` can take as one argument: no option, no path
    /// traversal and no cloud or remote tag.
    public static func validateModelName(_ name: String) throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#
        guard name.range(of: pattern, options: .regularExpression) != nil, !name.contains("..") else {
            throw AgentBridgeError.invalidInput("Type a model name such as qwen2.5-coder:7b: letters, digits and . _ : / - only, up to 200 characters.")
        }
        try LocalModelClient.requireLocalModelName(name)
    }

    /// The arguments for `ollama`, passed without a shell.
    public static func pullArguments(model: String) throws -> [String] {
        try validateModelName(model)
        return ["pull", model]
    }

    /// Reads one line of `ollama pull` output: terminal control sequences and
    /// progress-bar characters are dropped, and a percentage is kept if there is one.
    public static func parsePullProgress(_ line: String) -> OllamaPullProgress? {
        var text = line.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        text = String(text.unicodeScalars.filter { scalar in
            !(0x2580...0x259F).contains(scalar.value) && !(0x2800...0x28FF).contains(scalar.value)
                && !(scalar.value < 0x20 && scalar.value != 0x09)
        }.map(Character.init))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let match = text.range(of: #"(\d{1,3})%"#, options: .regularExpression) else {
            return OllamaPullProgress(status: String(text.prefix(200)), percent: nil)
        }
        let percent = Int(text[match].dropLast()).map { min(100, $0) }
        let status = text[..<match.lowerBound].trimmingCharacters(in: .whitespaces)
        return OllamaPullProgress(status: String((status.isEmpty ? text : status).prefix(200)), percent: percent)
    }

    /// `OLLAMA_HOST` for the configured loopback endpoint: its scheme, host and port only.
    static func hostValue(endpoint: String) throws -> String {
        try LocalModelClient.validateSettings(LocalModelSettings(backend: .ollama, endpoint: endpoint))
        guard let components = URLComponents(string: endpoint), let host = components.host else {
            throw AgentBridgeError.invalidInput("Local model settings are invalid. Check the endpoint, model name, context window, and output limit.")
        }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return "http://\(shownHost):\(components.port ?? 11_434)"
    }
}

extension BridgeService {
    static let ollamaFallbackExecutables = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama"
    ]
    static let ollamaFallbackAppBundles = ["/Applications/Ollama.app"]

    /// What is installed and whether the server answers at the Ollama endpoint:
    /// the configured one when the backend is Ollama, else Ollama's default.
    public func ollamaSetupStatus(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) async -> OllamaSetupStatus {
        let endpoint = ollamaEndpoint()
        let models = try? await localModelClient.models(settings: LocalModelSettings(backend: .ollama, endpoint: endpoint))
        return OllamaSetupStatus(
            executablePath: ollamaExecutablePath(),
            appBundlePath: ollamaAppBundlePath(),
            endpoint: endpoint,
            serverRunning: models != nil,
            installedModels: models?.map(\.id) ?? [],
            physicalMemoryBytes: physicalMemoryBytes,
            recommendation: OllamaSetup.recommendation(physicalMemoryBytes: physicalMemoryBytes)
        )
    }

    /// Opens the Ollama app with `open -a`, as if the user opened it: it runs on
    /// its own, not as a child of AgentBridge. Without the app bundle, the user
    /// runs `ollama serve` in Terminal instead.
    public func startOllamaApp() async throws {
        guard let app = ollamaAppBundlePath() else {
            throw AgentBridgeError.invalidInput("The Ollama app was not found. Run `ollama serve` in Terminal to start the server.")
        }
        let result = try await runner.run(ProcessSpec(
            executableURL: URL(fileURLWithPath: openExecutablePath),
            arguments: ["-a", app],
            environment: ["PATH": "/usr/bin:/bin", "HOME": baseEnvironment["HOME"] ?? NSHomeDirectory()],
            timeout: 30,
            outputLimit: 64 * 1_024
        ))
        guard result.exitCode == 0, !result.wasCancelled else {
            throw AgentBridgeError.invalidInput("Could not open the Ollama app (exit code \(result.exitCode)).")
        }
    }

    /// Runs `ollama pull MODEL` against the Ollama endpoint, reporting its
    /// progress lines, until it ends or is cancelled. Only on the user's request.
    public func pullOllamaModel(
        _ model: String,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (OllamaPullProgress) -> Void)? = nil
    ) async throws {
        let arguments = try OllamaSetup.pullArguments(model: model)
        guard let executable = ollamaExecutablePath() else {
            throw AgentBridgeError.invalidInput("The ollama command was not found. Install Ollama from https://ollama.com/download first.")
        }
        let host = try OllamaSetup.hostValue(endpoint: ollamaEndpoint())
        let handler: @Sendable (String) -> Void = { line in
            if let progress = OllamaSetup.parsePullProgress(line) { onProgress?(progress) }
        }
        try? store.appendEvent(AuditEvent(
            sessionID: LocalModelHelper.usageStreamID,
            kind: "local.setup.pull_started",
            message: "model=\(OutputRedactor.redact(model)); executable=\(executable); started on the user's request."
        ))
        let result = try await runner.run(ProcessSpec(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: [
                "HOME": baseEnvironment["HOME"] ?? NSHomeDirectory(),
                "PATH": "/usr/bin:/bin",
                "OLLAMA_HOST": host,
                "TERM": "dumb",
                "NO_COLOR": "1"
            ],
            timeout: 6 * 60 * 60,
            outputLimit: 256 * 1_024,
            endsWithParent: true,
            standardOutputLineHandler: handler,
            standardErrorLineHandler: handler
        ), cancellation: cancellation)
        try? store.appendEvent(AuditEvent(
            sessionID: LocalModelHelper.usageStreamID,
            kind: "local.setup.pull_finished",
            message: "model=\(OutputRedactor.redact(model)); exit_code=\(result.exitCode); cancelled=\(result.wasCancelled); timed_out=\(result.timedOut)."
        ))
        if result.timedOut { throw AgentBridgeError.processTimedOut }
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        guard result.exitCode == 0 else {
            let output = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
            let lastLine = output.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                .compactMap { OllamaSetup.parsePullProgress($0)?.status }
                .last ?? ""
            throw AgentBridgeError.invalidInput("The model download failed with exit code \(result.exitCode): \(OutputRedactor.redact(lastLine))")
        }
    }

    func ollamaEndpoint() -> String {
        if let local = try? store.loadSettings().localModel, local.backend == .ollama { return local.endpoint }
        return LocalModelSettings().endpoint
    }

    func ollamaExecutablePath() -> String? {
        let pathDirectories = (baseEnvironment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        let candidates = pathDirectories.map { ($0 as NSString).appendingPathComponent("ollama") } + ollamaExecutableCandidates
        return candidates.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    func ollamaAppBundlePath() -> String? {
        ollamaAppBundleCandidates.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
