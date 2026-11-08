import AgentBridgeCore
import AgentBridgeTerminalCapture
import Darwin
import Foundation

/// Runs `usage-tui` in the user's own terminal and still feeds the App's usage card.
/// Claude reads the terminal directly there, so nothing in between sees its screen.
/// The proxy starts a second `usage-tui` on a pseudo-terminal it owns, passes every
/// byte through unchanged both ways, and replays the output into a headless copy of
/// the terminal. Whenever the copy shows recognized limits, only the parsed report is
/// saved, for the App to show; the screen text is never written.
enum UsageTerminalProxy {
    /// Passed to the inner `usage-tui`, which then takes the pseudo-terminal as its
    /// controlling terminal so it can hand the foreground to the provider's TUI.
    static let attachedTerminalFlag = "--attached-terminal"
    private static let quietInterval: UInt64 = 300_000_000
    private static let resaveInterval: TimeInterval = 30

    /// Makes the inner `usage-tui` the leader of a new session whose controlling
    /// terminal is the pseudo-terminal on its standard input.
    static func attachToTerminal() throws {
        guard setsid() >= 0, ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0 else {
            throw AgentBridgeError.processLaunchFailed("Could not attach the usage terminal.")
        }
    }

    /// Returns the inner `usage-tui`'s exit status.
    static func run(provider: AgentProvider, profile: AccountProfile, service: BridgeService) throws -> Int32 {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw AgentBridgeError.invalidInput("Interactive mode must run in Terminal.")
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            throw AgentBridgeError.processLaunchFailed("Could not find the agentbridge executable.")
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw AgentBridgeError.processLaunchFailed("Could not read the terminal settings.")
        }
        var size = currentSize()

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw AgentBridgeError.processLaunchFailed("Could not open a pseudo-terminal.") }
        defer { _ = close(master) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            throw AgentBridgeError.processLaunchFailed("Could not prepare the pseudo-terminal.")
        }
        let follower = open(name, O_RDWR | O_NOCTTY)
        guard follower >= 0 else { throw AgentBridgeError.processLaunchFailed("Could not open the pseudo-terminal.") }
        _ = tcsetattr(follower, TCSANOW, &original)
        _ = ioctl(follower, TIOCSWINSZ, &size)

        let processID: pid_t
        do {
            processID = try spawn(
                executable: executable,
                arguments: [
                    "usage-tui", "--provider", provider.rawValue,
                    "--profile", profile.id.uuidString.lowercased(), attachedTerminalFlag
                ],
                terminal: follower
            )
        } catch {
            _ = close(follower)
            throw error
        }
        // Only the inner process keeps the follower open, so reading the master ends
        // once it and everything it started have exited.
        _ = close(follower)

        // Keys go to the TUI as they are typed; Control-C reaches it as a byte.
        var raw = original
        cfmakeraw(&raw)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }

        let stopRequested = StopRequest()
        let signalSources = [SIGTERM, SIGHUP, SIGINT, SIGQUIT].map { signalNumber in
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { stopRequested.set() }
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }

        let recorder = UsageTerminalRecorder(columns: Int(size.ws_col), rows: Int(size.ws_row))
        var saver = ReportSaver(provider: provider, profile: profile, service: service)
        var inputOpen = true
        var outputOpen = true
        var stopSent = false
        var lastOutput: UInt64?
        var exitStatus: Int32?
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while outputOpen {
            if stopRequested.isSet, !stopSent {
                // The inner usage-tui ends the TUI and cleans up after it.
                _ = kill(processID, SIGTERM)
                stopSent = true
            }
            let newSize = currentSize()
            if newSize.ws_col != size.ws_col || newSize.ws_row != size.ws_row {
                size = newSize
                _ = ioctl(master, TIOCSWINSZ, &size)
                recorder.resize(columns: Int(size.ws_col), rows: Int(size.ws_row))
            }

            var descriptors = [pollfd(fd: master, events: Int16(POLLIN), revents: 0)]
            if inputOpen { descriptors.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0, errno != EINTR { break }

            if inputOpen, descriptors.count > 1, descriptors[1].revents != 0 {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    writeAll(master, buffer[0..<count])
                    recorder.recordInput(buffer[0..<count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    // The user's terminal went away; end the TUI rather than leave it orphaned.
                    inputOpen = false
                    stopRequested.set()
                }
            }
            if descriptors[0].revents != 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    writeAll(STDOUT_FILENO, buffer[0..<count])
                    recorder.recordOutput(buffer[0..<count])
                    lastOutput = DispatchTime.now().uptimeNanoseconds
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    outputOpen = false
                }
            }

            if let last = lastOutput, DispatchTime.now().uptimeNanoseconds - last >= quietInterval {
                saver.saveIfRecognized(recorder)
                lastOutput = nil
            }
            if exitStatus == nil, let status = reap(processID, blocking: false) {
                exitStatus = status
            }
        }
        saver.saveIfRecognized(recorder)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        if let failure = saver.failure {
            FileHandle.standardError.write(Data("\r\nThe usage report could not be saved for the App: \(failure)\n".utf8))
        }
        return exitStatus ?? reap(processID, blocking: true) ?? 1
    }

    private static func currentSize() -> winsize {
        var size = winsize()
        if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_col == 0 || size.ws_row == 0 {
            size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
        return size
    }

    private static func spawn(executable: String, arguments: [String], terminal: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw AgentBridgeError.processLaunchFailed("Could not prepare the usage terminal.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for target in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            _ = posix_spawn_file_actions_adddup2(&actions, terminal, target)
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AgentBridgeError.processLaunchFailed("Could not prepare the usage terminal.")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // Every other descriptor, the master included, stays out of the child. The
        // signals this process ignores are reset there.
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in [SIGTERM, SIGHUP, SIGINT, SIGQUIT, SIGPIPE] { sigaddset(&defaultSignals, signalNumber) }
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        _ = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        var argv = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var processID: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            posix_spawn(&processID, executable, &actions, &attributes, argvBuffer.baseAddress!, environ)
        }
        guard result == 0 else { throw AgentBridgeError.processLaunchFailed(String(cString: strerror(result))) }
        return processID
    }

    private static func writeAll(_ descriptor: Int32, _ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private static func reap(_ processID: pid_t, blocking: Bool) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, blocking ? 0 : WNOHANG)
            if result < 0, errno == EINTR { continue }
            guard result == processID else { return nil }
            break
        }
        // WIFEXITED / WEXITSTATUS / WTERMSIG are C macros, so decode the status here.
        let signalNumber = status & 0x7f
        return signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber
    }

    private final class StopRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Saves a report when what it shows changes, and again every so often so the
    /// card's capture time stays current while the screen is left open.
    private struct ReportSaver {
        let provider: AgentProvider
        let profile: AccountProfile
        let service: BridgeService
        private var lastSaved: ProviderUsageReport?
        private(set) var failure: String?

        init(provider: AgentProvider, profile: AccountProfile, service: BridgeService) {
            self.provider = provider
            self.profile = profile
            self.service = service
        }

        mutating func saveIfRecognized(_ recorder: UsageTerminalRecorder) {
            guard let parsed = recorder.usageReport(
                provider: provider,
                accountProfileID: profile.id,
                accountName: profile.name
            ) else { return }
            let report = ProviderUsageReport(
                provider: parsed.provider,
                accountProfileID: parsed.accountProfileID,
                accountName: parsed.accountName,
                plan: parsed.plan,
                usageWindows: parsed.usageWindows,
                capturedAt: parsed.capturedAt,
                source: ProviderUsageReportParser.externalTerminalSource(for: provider),
                status: parsed.status
            )
            if let lastSaved, lastSaved.plan == report.plan, lastSaved.usageWindows == report.usageWindows,
               report.capturedAt.timeIntervalSince(lastSaved.capturedAt) < UsageTerminalProxy.resaveInterval {
                return
            }
            do {
                try service.saveProviderUsageReport(report)
                lastSaved = report
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
