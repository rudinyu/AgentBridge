import AppKit
import Darwin
import AgentBridgeCore
@preconcurrency import SwiftTerm
import SwiftUI

struct TerminalLaunchSpec: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String

    init(
        id: UUID = UUID(),
        title: String,
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) {
        self.id = id
        self.title = title
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// A local ANSI/VT100 view. OSC 52 clipboard requests and terminal links are denied.
private final class AgentBridgeTerminalView: TerminalView, @preconcurrency TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
    private var process: LocalProcess?
    private let usageCaptureLock = NSLock()
    private var usageCaptureEnabled = false
    private var usageCaptureStartedAt: Date?
    private var usageCaptureExpiresAt: Date?
    private var usageCaptureGeneration: UInt64 = 0
    private var usageSnapshotSequence: UInt64 = 0
    private var pendingUsageScreenSnapshot: DispatchWorkItem?
    var onTermination: (@MainActor (Int32?) -> Void)?
    var onUsageScreenSnapshot: (@MainActor (String, Date) -> Bool)?
    var allowsUsageScreenCapture = false

    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        configureProcess()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureProcess()
    }

    private func configureProcess() {
        terminalDelegate = self
        process = LocalProcess(delegate: self)
        linkReporting = .none
    }

    func start(_ launch: TerminalLaunchSpec) {
        guard let process else { return }
        process.startProcess(
            executable: launch.executablePath,
            args: launch.arguments,
            environment: launch.environment.keys.sorted().map { "\($0)=\(launch.environment[$0] ?? "")" },
            currentDirectory: launch.workingDirectory
        )
        updatePseudoTerminalSize()
        window?.makeFirstResponder(self)
    }

    // The terminal is what the user types into once it opens, so it takes the
    // keyboard; otherwise arrow keys and Enter went to the rest of the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // A TUI that turns on mouse reporting, as Claude Code does, gets the click and
    // SwiftTerm then leaves the keyboard where it was, so take it here first.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// Called when a view is removed without the helper having exited normally.
    /// Signal the provider's foreground group and the helper, then escalate after a bounded grace.
    func terminateWithEscalation() {
        guard let child = process, child.running else { return }
        let helperPID = child.shellPid
        nonisolated(unsafe) let escalatingChild = child
        let foregroundGroup = child.childfd >= 0 ? tcgetpgrp(child.childfd) : -1
        if foregroundGroup > 1, foregroundGroup != helperPID {
            _ = kill(-foregroundGroup, SIGTERM)
        }
        if helperPID > 1 { _ = kill(-helperPID, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(750)) {
            guard escalatingChild.running else { return }
            if foregroundGroup > 1, foregroundGroup != helperPID,
               escalatingChild.childfd >= 0, tcgetpgrp(escalatingChild.childfd) == foregroundGroup {
                _ = kill(-foregroundGroup, SIGKILL)
            }
            if helperPID > 1, escalatingChild.shellPid == helperPID { _ = kill(-helperPID, SIGKILL) }
            escalatingChild.terminate()
        }
    }

    /// Sends only the fixed provider usage command through the active PTY.
    func sendUsageCommand() {
        guard allowsUsageScreenCapture, let process, process.running else { return }
        pendingUsageScreenSnapshot?.cancel()
        pendingUsageScreenSnapshot = nil
        usageSnapshotSequence &+= 1
        let bytes = Array("/usage\r".utf8)
        usageCaptureLock.lock()
        usageCaptureEnabled = true
        usageCaptureGeneration &+= 1
        let generation = usageCaptureGeneration
        let startedAt = Date()
        usageCaptureStartedAt = startedAt
        let expiration = startedAt.addingTimeInterval(15)
        usageCaptureExpiresAt = expiration
        process.send(data: bytes[...])
        usageCaptureLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(15)) { [weak self] in
            self?.expireUsageScreenCapture(generation: generation)
        }
    }

    private func shouldCaptureUsageScreen(receivedAt: Date? = nil) -> Bool {
        usageCaptureLock.lock()
        defer { usageCaptureLock.unlock() }
        guard usageCaptureEnabled else { return false }
        if let receivedAt, let usageCaptureStartedAt, receivedAt < usageCaptureStartedAt {
            return false
        }
        if let usageCaptureExpiresAt, Date() >= usageCaptureExpiresAt {
            usageCaptureEnabled = false
            usageCaptureStartedAt = nil
            self.usageCaptureExpiresAt = nil
            usageCaptureGeneration &+= 1
            return false
        }
        return true
    }

    fileprivate func disableUsageScreenCapture() {
        usageCaptureLock.lock()
        usageCaptureEnabled = false
        usageCaptureStartedAt = nil
        usageCaptureExpiresAt = nil
        usageCaptureGeneration &+= 1
        usageCaptureLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.pendingUsageScreenSnapshot?.cancel()
            self?.pendingUsageScreenSnapshot = nil
        }
    }

    /// Copies only the currently visible SwiftTerm rows, with strict row,
    /// column, and byte bounds. The returned string is kept only for the
    /// short in-memory debounce before parsing.
    private func visibleScreenText() -> String {
        let terminal = self.terminal!
        let rowCount = min(max(terminal.rows, 0), 120)
        let columnCount = min(max(terminal.cols, 0), 240)
        let maximumBytes = ProviderUsageReportParser.maximumScreenBytes
        var lines: [String] = []
        var totalBytes = 0

        for row in 0..<rowCount {
            guard let line = terminal.getLine(row: row) else { continue }
            let rendered = line.translateToString(
                trimRight: true,
                startCol: 0,
                endCol: columnCount,
                skipNullCellsFollowingWide: true,
                characterProvider: { terminal.getCharacter(for: $0) }
            )
            var boundedLine = ""
            for character in rendered {
                let characterBytes = String(character).utf8.count
                guard totalBytes + characterBytes <= maximumBytes else { break }
                boundedLine.append(character)
                totalBytes += characterBytes
            }
            lines.append(boundedLine)
            guard totalBytes < maximumBytes else { break }
            totalBytes += 1 // newline separator
        }
        return lines.joined(separator: "\n")
    }

    private func scheduleUsageScreenSnapshot() {
        guard allowsUsageScreenCapture, shouldCaptureUsageScreen() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shouldCaptureUsageScreen() else { return }
            self.pendingUsageScreenSnapshot?.cancel()
            self.usageSnapshotSequence &+= 1
            let sequence = self.usageSnapshotSequence
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.usageSnapshotSequence == sequence,
                      self.shouldCaptureUsageScreen() else { return }
                self.pendingUsageScreenSnapshot = nil
                let screenText = self.visibleScreenText()
                let capturedAt = Date()
                let usageValuesRecognized = self.onUsageScreenSnapshot?(screenText, capturedAt) ?? false
                if usageValuesRecognized { self.disableUsageScreenCapture() }
            }
            self.pendingUsageScreenSnapshot = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800), execute: work)
        }
    }

    private func expireUsageScreenCapture(generation: UInt64) {
        usageCaptureLock.lock()
        guard usageCaptureGeneration == generation,
              usageCaptureEnabled,
              let expiration = usageCaptureExpiresAt,
              Date() >= expiration else {
            usageCaptureLock.unlock()
            return
        }
        usageCaptureEnabled = false
        usageCaptureStartedAt = nil
        usageCaptureExpiresAt = nil
        usageCaptureGeneration &+= 1
        usageCaptureLock.unlock()
        pendingUsageScreenSnapshot?.cancel()
        pendingUsageScreenSnapshot = nil
    }

    private func updatePseudoTerminalSize() {
        guard let process, process.running, process.childfd >= 0 else { return }
        var size = windowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    private func windowSize() -> winsize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let columns = max(1, min(Int(UInt16.max), terminal?.cols ?? 80))
        let rows = max(1, min(Int(UInt16.max), terminal?.rows ?? 25))
        let pixelWidth = max(0, min(Int(UInt16.max), Int(bounds.width * scale)))
        let pixelHeight = max(0, min(Int(UInt16.max), Int(bounds.height * scale)))
        return winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: UInt16(pixelWidth),
            ws_ypixel: UInt16(pixelHeight)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePseudoTerminalSize()
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        updatePseudoTerminalSize()
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { process?.send(data: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        disableUsageScreenCapture()
        guard let onTermination else { return }
        Task { @MainActor in onTermination(exitCode) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let receivedAt = Date()
        feed(byteArray: slice)
        if shouldCaptureUsageScreen(receivedAt: receivedAt) {
            scheduleUsageScreenSnapshot()
        }
    }

    func getWindowSize() -> winsize { windowSize() }
}

struct EmbeddedTerminalView: NSViewRepresentable {
    let launch: TerminalLaunchSpec
    let usageCommandRequest: Int
    let allowsUsageScreenCapture: Bool
    let onUsageScreenText: @MainActor (String, Date) -> Bool
    let onTermination: @MainActor (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTermination: onTermination,
            usageCommandRequest: usageCommandRequest,
            allowsUsageScreenCapture: allowsUsageScreenCapture,
            onUsageScreenText: onUsageScreenText
        )
    }

    func makeNSView(context: Context) -> NSView {
        let options = TerminalOptions(
            termName: "xterm-256color",
            scrollback: 2_000,
            enableSixelReported: false,
            kittyImageCacheLimitBytes: 0
        )
        let terminal = AgentBridgeTerminalView(frame: .zero, options: options)
        let coordinator = context.coordinator
        terminal.onTermination = { [weak coordinator] exitCode in
            coordinator?.processTerminated(exitCode)
        }
        terminal.allowsUsageScreenCapture = allowsUsageScreenCapture
        terminal.onUsageScreenSnapshot = { [weak coordinator] screenText, capturedAt in
            coordinator?.usageScreenDidUpdate(screenText, capturedAt: capturedAt) ?? false
        }
        coordinator.terminal = terminal
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else { return }
            terminal.start(launch)
        }
        return terminal
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTermination = onTermination
        coordinator.onUsageScreenText = onUsageScreenText
        coordinator.sendUsageCommandIfRequested(usageCommandRequest)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.terminal?.disableUsageScreenCapture()
        coordinator.terminal?.terminateWithEscalation()
        coordinator.terminal = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate weak var terminal: AgentBridgeTerminalView?
        var onTermination: @MainActor (Int32?) -> Void
        var onUsageScreenText: @MainActor (String, Date) -> Bool
        private var usageCommandRequest: Int
        private let allowsUsageScreenCapture: Bool

        init(
            onTermination: @escaping @MainActor (Int32?) -> Void,
            usageCommandRequest: Int,
            allowsUsageScreenCapture: Bool,
            onUsageScreenText: @escaping @MainActor (String, Date) -> Bool
        ) {
            self.onTermination = onTermination
            self.usageCommandRequest = usageCommandRequest
            self.allowsUsageScreenCapture = allowsUsageScreenCapture
            self.onUsageScreenText = onUsageScreenText
        }

        func sendUsageCommandIfRequested(_ request: Int) {
            guard allowsUsageScreenCapture, request != usageCommandRequest else { return }
            usageCommandRequest = request
            terminal?.sendUsageCommand()
        }

        func usageScreenDidUpdate(_ screenText: String, capturedAt: Date) -> Bool {
            onUsageScreenText(screenText, capturedAt)
        }

        func processTerminated(_ exitCode: Int32?) {
            onTermination(exitCode)
        }
    }
}
