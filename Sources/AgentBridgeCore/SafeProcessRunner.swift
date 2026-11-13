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
    /// Ends the process group if AgentBridge itself stops, for a run that can last
    /// minutes. Its timeout is enforced by AgentBridge, so without this a crashed or
    /// killed App or CLI would leave a provider running, and editing, with no limit.
    public let endsWithParent: Bool
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
        endsWithParent: Bool = false,
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
        self.endsWithParent = endsWithParent
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
            throw AgentBridgeError.invalidInput("Interactive mode must run in Terminal.")
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

    private static let interactiveLog = TerminalProcessDiagnostics.logger(
        subsystem: TerminalProcessDiagnostics.helperSubsystem,
        category: "interactive"
    )

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
            throw AgentBridgeError.processLaunchFailed("The executable is missing or is not executable.")
        }

        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        var inputPair = [Int32](repeating: -1, count: 2)
        if !interactive {
            guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0,
                  socketpair(AF_UNIX, SOCK_STREAM, 0, &inputPair) == 0 else {
                Self.closeAll(stdoutPipe + stderrPipe + inputPair)
                throw AgentBridgeError.processLaunchFailed("Could not create the child process I/O channel.")
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
            throw AgentBridgeError.processLaunchFailed("Could not initialize the run channel.")
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
            throw AgentBridgeError.processLaunchFailed("Could not configure child process isolation.")
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
        // An interactive TUI gets one too: when the CLI that started it in a Terminal is
        // killed, the shell takes the terminal back and the TUI would stay behind,
        // orphaned. Inside the App, closing the PTY already ends it.
        let watchdog = interactive || spec.endsWithParent ? Self.startParentWatchdog(parent: getpid(), group: processID) : nil
        defer {
            if let watchdog {
                _ = kill(watchdog, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(watchdog, &status, 0)
            }
        }

        var previousForegroundGroup: pid_t = -1
        if interactive {
            previousForegroundGroup = tcgetpgrp(STDIN_FILENO)
            guard previousForegroundGroup >= 0, Self.setForegroundProcessGroup(processID) else {
                _ = kill(-processID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(processID, &status, 0)
                throw AgentBridgeError.processLaunchFailed("Could not give Claude foreground control in Terminal.")
            }
            if let onLaunched, !onLaunched() {
                _ = kill(-processID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(processID, &status, 0)
                if previousForegroundGroup >= 0 { _ = Self.setForegroundProcessGroup(previousForegroundGroup) }
                throw AgentBridgeError.persistence("Could not record the interactive session startup state.")
            }
            _ = kill(processID, SIGCONT)
            interactiveLog.notice("Interactive child \(processID, privacy: .public) started in its own process group; helper \(getpid(), privacy: .public), terminal foreground group was \(previousForegroundGroup, privacy: .public).")
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
                if interactive {
                    interactiveLog.notice("Cancelling interactive child \(processID, privacy: .public): SIGTERM sent to its process group.")
                }
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
                if interactive, !groupCleanupEscalated {
                    interactiveLog.notice("Interactive child \(processID, privacy: .public) group still alive 0.75 s after cancelling; sending SIGKILL.")
                }
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
            // The leader is still unreaped here, so its group ID cannot be reused. When
            // nothing else is left in the group there is nothing to clean up, and the
            // grace period would only add its full length to every process that exits
            // cleanly.
            if childExited, !groupCleanupEscalated, Self.groupHasOnlyItsLeader(processID) {
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
        if interactive {
            // A process that left the child's group (for example a CLI that starts
            // itself again after updating) is not ended above; list what still
            // uses this terminal so such a survivor shows in the log.
            let others = TerminalProcessDiagnostics.describeRelated(
                toTerminal: TerminalProcessDiagnostics.terminalDevice(of: STDIN_FILENO),
                rootPID: nil,
                excluding: [getpid()]
            )
            interactiveLog.notice("Interactive child \(processID, privacy: .public) ended: exit code \(exitCode, privacy: .public), cancelled \(cancelled, privacy: .public). Other processes on this terminal: \(others, privacy: .public)")
        }
        truncated = truncated || lineFramer.didOverflow
        return ProcessResult(exitCode: exitCode, standardOutput: output, standardError: errorOutput, outputWasTruncated: truncated, wasCancelled: cancelled, timedOut: timedOut)
    }

    /// Starts a small shell, in a group of its own, that ends `group` once `parent` is
    /// gone and exits by itself once `group` is. It checks once a second, so an ended
    /// group's ID is not reused while it still watches it.
    static func startParentWatchdog(parent: pid_t, group: pid_t) -> pid_t? {
        let script = """
        while kill -0 "$1" 2>/dev/null; do
          kill -0 -- "-$2" 2>/dev/null || exit 0
          sleep 1
        done
        kill -TERM -- "-$2" 2>/dev/null
        sleep 2
        kill -KILL -- "-$2" 2>/dev/null
        """
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            _ = posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        _ = posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["/bin/sh", "-c", script, "agentbridge-watchdog", String(parent), String(group)]
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { environment.forEach { free($0) } }
        var watchdog: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(&watchdog, "/bin/sh", &actions, &attributes, argvBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
        return result == 0 ? watchdog : nil
    }

    /// True when no process other than the group leader itself is left in `group`.
    /// Returns false whenever that cannot be established, which keeps the full cleanup.
    private static func groupHasOnlyItsLeader(_ group: pid_t) -> Bool {
        var members = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(group),
            &members,
            Int32(members.count * MemoryLayout<pid_t>.stride)
        )
        guard bytes >= 0 else { return false }
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        // A full buffer means more members than were listed.
        guard count < members.count else { return false }
        return !members.prefix(count).contains { $0 != 0 && $0 != group }
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
