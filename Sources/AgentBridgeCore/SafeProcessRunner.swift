import Darwin
import Foundation

public struct ProcessSpec: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL?
    public let standardInput: Data
    public let timeout: TimeInterval
    public let outputLimit: Int
    public let cancellationRequestURL: URL?
    let standardOutputLineHandler: (@Sendable (String) -> Void)?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL? = nil,
        standardInput: Data = Data(),
        timeout: TimeInterval = 300,
        outputLimit: Int = 1_048_576,
        cancellationRequestURL: URL? = nil,
        standardOutputLineHandler: (@Sendable (String) -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.standardInput = standardInput
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.cancellationRequestURL = cancellationRequestURL
        self.standardOutputLineHandler = standardOutputLineHandler
    }
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let outputWasTruncated: Bool
    public let wasCancelled: Bool
    public let timedOut: Bool
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public final class SafeProcessRunner: Sendable {
    public init() {}

    public func run(_ spec: ProcessSpec, cancellation: CancellationFlag = CancellationFlag()) async throws -> ProcessResult {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.execute(spec, cancellation: cancellation, interactive: false)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func runInteractive(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL,
        cancellationRequestURL: URL?,
        cancellation: CancellationFlag = CancellationFlag(),
        onLaunched: (@Sendable () -> Bool)? = nil
    ) async throws -> ProcessResult {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw AgentBridgeError.invalidInput("互動模式需要在 Terminal 中執行。")
        }
        let spec = ProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: workingDirectoryURL,
            standardInput: Data(),
            timeout: 0,
            outputLimit: 0,
            cancellationRequestURL: cancellationRequestURL
        )
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.execute(spec, cancellation: cancellation, interactive: true, onLaunched: onLaunched)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(
        _ spec: ProcessSpec,
        cancellation: CancellationFlag,
        interactive: Bool,
        onLaunched: (@Sendable () -> Bool)? = nil
    ) throws -> ProcessResult {
        if cancellation.isCancelled {
            throw AgentBridgeError.processCancelled
        }
        if let request = spec.cancellationRequestURL, FileManager.default.fileExists(atPath: request.path) {
            try? FileManager.default.removeItem(at: request)
            throw AgentBridgeError.processCancelled
        }
        guard spec.executableURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: spec.executableURL.path) else {
            throw AgentBridgeError.processLaunchFailed("執行檔不存在或不可執行。")
        }

        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        var inputPair = [Int32](repeating: -1, count: 2)
        if !interactive {
            guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0,
                  socketpair(AF_UNIX, SOCK_STREAM, 0, &inputPair) == 0 else {
                Self.closeAll(stdoutPipe + stderrPipe + inputPair)
                throw AgentBridgeError.processLaunchFailed("無法建立子程序 I/O 通道。")
            }
            var noSignal: Int32 = 1
            _ = setsockopt(inputPair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(stdoutPipe[0], F_SETFL, fcntl(stdoutPipe[0], F_GETFL) | O_NONBLOCK)
            _ = fcntl(stderrPipe[0], F_SETFL, fcntl(stderrPipe[0], F_GETFL) | O_NONBLOCK)
            _ = fcntl(inputPair[0], F_SETFL, fcntl(inputPair[0], F_GETFL) | O_NONBLOCK)
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            Self.closeAll(stdoutPipe + stderrPipe + inputPair)
            throw AgentBridgeError.processLaunchFailed("無法初始化執行通道。")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        if !interactive {
            _ = posix_spawn_file_actions_adddup2(&actions, inputPair[1], STDIN_FILENO)
            _ = posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
            _ = posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
            for fd in [inputPair[0], inputPair[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
                _ = posix_spawn_file_actions_addclose(&actions, fd)
            }
        } else {
            _ = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO)
            _ = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDOUT_FILENO)
            _ = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO)
        }
        if let directory = spec.workingDirectoryURL {
            #if os(macOS)
            _ = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            #endif
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            Self.closeAll(stdoutPipe + stderrPipe + inputPair)
            throw AgentBridgeError.processLaunchFailed("無法設定子程序隔離。")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGPIPE)
        sigaddset(&defaultSignals, SIGQUIT)
        sigaddset(&defaultSignals, SIGHUP)
        sigemptyset(&emptyMask)
        var spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if interactive { spawnFlags |= Int16(POSIX_SPAWN_START_SUSPENDED) }
        _ = posix_spawnattr_setflags(&attributes, spawnFlags)
        _ = posix_spawnattr_setpgroup(&attributes, 0)
        _ = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        _ = posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let allArguments = [spec.executableURL.path] + spec.arguments
        var argv = allArguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        let environmentItems = spec.environment.keys.sorted().map { "\($0)=\(spec.environment[$0] ?? "")" }
        var envp = environmentItems.map { strdup($0) }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var processID: pid_t = 0
        let spawnResult = allArguments[0].withCString { executable in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(&processID, executable, &actions, &attributes, argvBuffer.baseAddress!, envBuffer.baseAddress!)
                }
            }
        }
        guard spawnResult == 0 else {
            Self.closeAll(stdoutPipe + stderrPipe + inputPair)
            throw AgentBridgeError.processLaunchFailed(String(cString: strerror(spawnResult)))
        }

        if !interactive {
            _ = close(inputPair[1]); inputPair[1] = -1
            _ = close(stdoutPipe[1]); stdoutPipe[1] = -1
            _ = close(stderrPipe[1]); stderrPipe[1] = -1
        }

        var previousForegroundGroup: pid_t = -1
        if interactive {
            previousForegroundGroup = tcgetpgrp(STDIN_FILENO)
            guard previousForegroundGroup >= 0, Self.setForegroundProcessGroup(processID) else {
                _ = kill(-processID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(processID, &status, 0)
                throw AgentBridgeError.processLaunchFailed("無法把 Terminal 前景控制權交給 Claude。")
            }
            if let onLaunched, !onLaunched() {
                _ = kill(-processID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(processID, &status, 0)
                if previousForegroundGroup >= 0 { _ = Self.setForegroundProcessGroup(previousForegroundGroup) }
                throw AgentBridgeError.persistence("無法記錄互動工作階段的啟動狀態。")
            }
            _ = kill(processID, SIGCONT)
        }

        defer {
            if interactive, previousForegroundGroup >= 0 {
                _ = Self.setForegroundProcessGroup(previousForegroundGroup)
            }
            Self.closeAll(stdoutPipe + stderrPipe + inputPair)
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let timeoutNanos = spec.timeout > 0 ? UInt64(spec.timeout * 1_000_000_000) : UInt64.max
        var output = Data()
        var errorOutput = Data()
        var truncated = false
        let lineFramer = StandardOutputLineFramer(maximumLineBytes: 65_536, handler: spec.standardOutputLineHandler)
        var inputOffset = 0
        var inputClosed = interactive || spec.standardInput.isEmpty
        if inputClosed, !interactive, inputPair[0] >= 0 {
            _ = shutdown(inputPair[0], SHUT_WR)
            _ = close(inputPair[0]); inputPair[0] = -1
        }
        var stdoutOpen = !interactive
        var stderrOpen = !interactive
        var childExited = false
        var cancellationSentAt: UInt64?
        var cancelled = false
        var timedOut = false
        var exitPipeDeadline: UInt64?
        var forcedPipeCloseDeadline: UInt64?
        var groupCleanupStartedAt: UInt64?
        var groupCleanupEscalated = false
        let bufferSize = 16_384

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if let request = spec.cancellationRequestURL,
               FileManager.default.fileExists(atPath: request.path) {
                try? FileManager.default.removeItem(at: request)
                cancellation.cancel()
            }
            if cancellation.isCancelled && cancellationSentAt == nil {
                cancelled = true
                cancellationSentAt = now
                _ = kill(-processID, SIGTERM)
                if !inputClosed, inputPair[0] >= 0 {
                    _ = shutdown(inputPair[0], SHUT_WR)
                    _ = close(inputPair[0]); inputPair[0] = -1
                    inputClosed = true
                }
            }
            if !childExited && timeoutNanos != UInt64.max && now - started >= timeoutNanos {
                timedOut = true
                cancelled = true
                if cancellationSentAt == nil {
                    cancellationSentAt = now
                    _ = kill(-processID, SIGTERM)
                }
            }
            if let sentAt = cancellationSentAt, now - sentAt >= 750_000_000 {
                _ = kill(-processID, SIGKILL)
                groupCleanupEscalated = true
            }

            if !childExited {
                var information = siginfo_t()
                let waitResult = waitid(P_PID, id_t(processID), &information, WEXITED | WNOHANG | WNOWAIT)
                if waitResult == 0, information.si_pid != 0 {
                    childExited = true
                    groupCleanupStartedAt = now
                    _ = kill(-processID, SIGTERM)
                    if stdoutOpen || stderrOpen {
                        exitPipeDeadline = now + 750_000_000
                    }
                }
            }

            if let groupCleanupStartedAt, !groupCleanupEscalated, now - groupCleanupStartedAt >= 750_000_000 {
                _ = kill(-processID, SIGKILL)
                groupCleanupEscalated = true
            }
            if childExited, let deadline = exitPipeDeadline, now >= deadline, (stdoutOpen || stderrOpen) {
                _ = kill(-processID, SIGKILL)
                forcedPipeCloseDeadline = now + 500_000_000
                exitPipeDeadline = nil
            }
            if childExited, let deadline = forcedPipeCloseDeadline, now >= deadline, (stdoutOpen || stderrOpen) {
                if stdoutOpen { _ = close(stdoutPipe[0]); stdoutPipe[0] = -1; stdoutOpen = false }
                if stderrOpen { _ = close(stderrPipe[0]); stderrPipe[0] = -1; stderrOpen = false }
            }

            if childExited, !stdoutOpen, !stderrOpen, groupCleanupEscalated { break }

            var descriptors: [pollfd] = []
            if !interactive, stdoutOpen { descriptors.append(pollfd(fd: stdoutPipe[0], events: Int16(POLLIN | POLLHUP), revents: 0)) }
            if !interactive, stderrOpen { descriptors.append(pollfd(fd: stderrPipe[0], events: Int16(POLLIN | POLLHUP), revents: 0)) }
            if !interactive, !inputClosed, inputPair[0] >= 0 { descriptors.append(pollfd(fd: inputPair[0], events: Int16(POLLOUT | POLLHUP), revents: 0)) }
            if !descriptors.isEmpty {
                _ = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 50) }
                for descriptor in descriptors where descriptor.revents != 0 {
                    if descriptor.fd == stdoutPipe[0], stdoutOpen {
                        Self.drain(fd: stdoutPipe[0], destination: &output, limit: spec.outputLimit, truncated: &truncated, open: &stdoutOpen, onChunk: { lineFramer.append($0) })
                        if !stdoutOpen { _ = close(stdoutPipe[0]); stdoutPipe[0] = -1 }
                    } else if descriptor.fd == stderrPipe[0], stderrOpen {
                        Self.drain(fd: stderrPipe[0], destination: &errorOutput, limit: min(spec.outputLimit, 128_000), truncated: &truncated, open: &stderrOpen, onChunk: nil)
                        if !stderrOpen { _ = close(stderrPipe[0]); stderrPipe[0] = -1 }
                    } else if descriptor.fd == inputPair[0], !inputClosed {
                        let remaining = spec.standardInput.count - inputOffset
                        if remaining <= 0 || descriptor.revents & Int16(POLLHUP | POLLERR) != 0 {
                            _ = shutdown(inputPair[0], SHUT_WR)
                            _ = close(inputPair[0]); inputPair[0] = -1
                            inputClosed = true
                        } else {
                            let amount = min(remaining, bufferSize)
                            let sent = spec.standardInput.withUnsafeBytes { bytes -> Int in
                                guard let base = bytes.baseAddress else { return 0 }
                                return Darwin.send(inputPair[0], base.advanced(by: inputOffset), amount, 0)
                            }
                            if sent > 0 { inputOffset += sent }
                            else if sent < 0 && errno != EAGAIN && errno != EINTR {
                                _ = shutdown(inputPair[0], SHUT_WR)
                                _ = close(inputPair[0]); inputPair[0] = -1
                                inputClosed = true
                            }
                            if inputOffset >= spec.standardInput.count, !inputClosed {
                                _ = shutdown(inputPair[0], SHUT_WR)
                                _ = close(inputPair[0]); inputPair[0] = -1
                                inputClosed = true
                            }
                        }
                    }
                }
            } else {
                usleep(10_000)
            }
        }

        let exitCode: Int32
        var reapedStatus: Int32 = 0
        _ = waitpid(processID, &reapedStatus, 0)
        let terminationSignal = reapedStatus & 0x7f
        if terminationSignal == 0 { exitCode = (reapedStatus >> 8) & 0xff }
        else if terminationSignal != 0x7f { exitCode = 128 + terminationSignal }
        else { exitCode = 1 }
        truncated = truncated || lineFramer.didOverflow
        return ProcessResult(exitCode: exitCode, standardOutput: output, standardError: errorOutput, outputWasTruncated: truncated, wasCancelled: cancelled, timedOut: timedOut)
    }

    private static func drain(fd: Int32, destination: inout Data, limit: Int, truncated: inout Bool, open: inout Bool, onChunk: ((Data) -> Void)?) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var reads = 0
        while reads < 16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                reads += 1
                onChunk?(Data(buffer.prefix(count)))
                let available = max(0, limit - destination.count)
                let retained = min(count, available)
                if retained > 0 { destination.append(contentsOf: buffer.prefix(retained)) }
                if retained < count { truncated = true }
            } else if count == 0 {
                open = false
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                open = false
                return
            }
        }
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { _ = close(descriptor) }
    }

    private static func setForegroundProcessGroup(_ group: pid_t) -> Bool {
        var blocked = sigset_t()
        var old = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTTOU)
        _ = pthread_sigmask(SIG_BLOCK, &blocked, &old)
        defer { _ = pthread_sigmask(SIG_SETMASK, &old, nil) }
        return tcsetpgrp(STDIN_FILENO, group) == 0
    }
}

private final class StandardOutputLineFramer {
    private let maximumLineBytes: Int
    private let handler: (@Sendable (String) -> Void)?
    private var current = Data()
    private var dropping = false
    private(set) var didOverflow = false

    init(maximumLineBytes: Int, handler: (@Sendable (String) -> Void)?) {
        self.maximumLineBytes = maximumLineBytes
        self.handler = handler
    }

    func append(_ data: Data) {
        guard handler != nil else { return }
        for byte in data {
            if byte == 0x0A {
                if !dropping, let line = String(data: current, encoding: .utf8), !line.isEmpty { handler?(line) }
                current.removeAll(keepingCapacity: true)
                dropping = false
            } else if !dropping {
                current.append(byte)
                if current.count > maximumLineBytes {
                    current.removeAll(keepingCapacity: true)
                    dropping = true
                    didOverflow = true
                }
            }
        }
    }
}
