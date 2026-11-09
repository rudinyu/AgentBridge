import AppKit
import Darwin
import AgentBridgeCore
import Observation
@preconcurrency import SwiftTerm
import AgentBridgeTerminalCapture
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
    var processIsRunning: Bool { process?.running == true }
    private let usageCaptureLock = NSLock()
    private var usageCaptureEnabled = false
    private var usageCaptureStartedAt: Date?
    private var usageCaptureExpiresAt: Date?
    private var usageCaptureGeneration: UInt64 = 0
    private var usageSnapshotSequence: UInt64 = 0
    private var pendingUsageScreenSnapshot: DispatchWorkItem?
    private var usageCaptureFirstRow: Int?
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
        usageCaptureFirstRow = UsageScreenCapture.topRow(of: getTerminal())
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
                let screenText = UsageScreenCapture.text(of: self.getTerminal(), firstRow: self.usageCaptureFirstRow)
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
    let terminalModel: TerminalModel
    let launch: TerminalLaunchSpec
    let usageCommandRequest: Int
    let allowsUsageScreenCapture: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: terminalModel.windowController, launchID: launch.id)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        context.coordinator.controller.mountTerminal(
            in: container,
            launch: launch,
            usageCommandRequest: usageCommandRequest,
            allowsUsageScreenCapture: allowsUsageScreenCapture
        )
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller.mountTerminal(
            in: nsView,
            launch: launch,
            usageCommandRequest: usageCommandRequest,
            allowsUsageScreenCapture: allowsUsageScreenCapture
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.controller.embeddedContainerDidDismantle(nsView, launchID: coordinator.launchID)
    }

    @MainActor
    final class Coordinator {
        let controller: TerminalWindowController
        let launchID: UUID

        init(controller: TerminalWindowController, launchID: UUID) {
            self.controller = controller
            self.launchID = launchID
        }
    }
}

/// Retains the one live SwiftTerm view while SwiftUI panels appear and disappear.
/// Moving that view to the native window keeps its LocalProcess and screen state intact.
@MainActor
final class TerminalWindowController: NSObject, NSWindowDelegate {
    private weak var terminalModel: TerminalModel?
    private weak var appModel: AppModel?
    private var terminalView: AgentBridgeTerminalView?
    private var terminalLaunchID: UUID?
    private weak var embeddedContainer: NSView?
    private weak var mainWindow: NSWindow?
    private var detachedWindow: NSWindow?
    private var detachedWindowRoot: NSView?
    private var terminalConstraints: [NSLayoutConstraint] = []
    private var lastUsageCommandRequest = 0

    var hasRunningProcess: Bool { terminalView?.processIsRunning == true }

    func attach(terminalModel: TerminalModel, appModel: AppModel) {
        self.terminalModel = terminalModel
        self.appModel = appModel
    }

    func mountTerminal(
        in container: NSView,
        launch: TerminalLaunchSpec,
        usageCommandRequest: Int,
        allowsUsageScreenCapture: Bool
    ) {
        embeddedContainer = container
        if let window = container.window { mainWindow = window }
        guard let terminal = terminalView(for: launch) else { return }
        configure(terminal, usageCommandRequest: usageCommandRequest, allowsUsageScreenCapture: allowsUsageScreenCapture)
        guard terminalModel?.terminalIsDetached != true else { return }
        guard terminal.superview !== container else { return }

        detachTerminalFromCurrentParent()
        container.addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalConstraints = [
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        NSLayoutConstraint.activate(terminalConstraints)
    }

    func embeddedContainerDidDismantle(_ container: NSView, launchID: UUID) {
        guard terminalLaunchID == launchID else { return }
        if embeddedContainer === container { embeddedContainer = nil }
        guard terminalModel?.terminalIsDetached != true, terminalView?.superview === container else { return }
        detachTerminalFromCurrentParent()
    }

    func openWindow() {
        guard let terminalModel,
              let launch = terminalModel.terminalLaunch,
              let appModel,
              let terminal = terminalView(for: launch) else { return }
        if mainWindow == nil { mainWindow = NSApp.keyWindow }
        if let detachedWindow {
            detachedWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        terminalModel.terminalIsDetached = true
        detachTerminalFromCurrentParent()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appModel.localized(launch.title)
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let toolbarModel = DetachedTerminalToolbarModel(terminalModel: terminalModel, appModel: appModel)
        let toolbar = NSHostingView(rootView: DetachedTerminalToolbar(model: toolbarModel))
        root.addSubview(toolbar)
        root.addSubview(terminal)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalConstraints = [
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
            terminal.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            terminal.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ]
        NSLayoutConstraint.activate(terminalConstraints)

        detachedWindowRoot = root
        detachedWindow = window
        window.contentView = root
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func returnToConversation() {
        guard let terminalModel else { return }
        if let window = detachedWindow {
            window.delegate = nil
            detachTerminalFromCurrentParent()
            window.contentView = nil
            window.close()
        }
        detachedWindow = nil
        detachedWindowRoot = nil
        terminalModel.terminalIsDetached = false
        mountTerminalIntoEmbeddedContainerIfPossible()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func discardTerminal(launchID: UUID?) {
        guard let launchID, terminalLaunchID == launchID else { return }
        guard !hasRunningProcess else { return }

        if let window = detachedWindow {
            window.delegate = nil
            detachTerminalFromCurrentParent()
            window.contentView = nil
            window.close()
        } else {
            detachTerminalFromCurrentParent()
        }
        detachedWindow = nil
        detachedWindowRoot = nil
        terminalView?.disableUsageScreenCapture()
        terminalView?.onTermination = nil
        terminalView?.onUsageScreenSnapshot = nil
        terminalView = nil
        terminalLaunchID = nil
        embeddedContainer = nil
        terminalModel?.terminalIsDetached = false
        lastUsageCommandRequest = 0
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === detachedWindow else { return }
        detachedWindow = nil
        detachedWindowRoot = nil
        detachTerminalFromCurrentParent()
        terminalModel?.detachedWindowDidClose()
        mountTerminalIntoEmbeddedContainerIfPossible()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func terminalView(for launch: TerminalLaunchSpec) -> AgentBridgeTerminalView? {
        if terminalLaunchID == launch.id { return terminalView }
        guard !hasRunningProcess else { return nil }
        if let oldLaunchID = terminalLaunchID { discardTerminal(launchID: oldLaunchID) }

        let options = TerminalOptions(
            termName: "xterm-256color",
            scrollback: 2_000,
            enableSixelReported: false,
            kittyImageCacheLimitBytes: 0
        )
        let terminal = AgentBridgeTerminalView(frame: .zero, options: options)
        terminalLaunchID = launch.id
        terminalView = terminal
        lastUsageCommandRequest = 0
        terminal.onTermination = { [weak self] exitCode in
            guard let self, self.terminalLaunchID == launch.id else { return }
            self.terminalModel?.terminalDidTerminate(launchID: launch.id, exitCode: exitCode)
        }
        terminal.onUsageScreenSnapshot = { [weak self] screenText, capturedAt in
            guard let self, self.terminalLaunchID == launch.id else { return false }
            return self.terminalModel?.usageScreenDidUpdate(
                screenText,
                capturedAt: capturedAt,
                launchID: launch.id
            ) ?? false
        }
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let self, self.terminalLaunchID == launch.id, let terminal else { return }
            terminal.start(launch)
        }
        return terminal
    }

    private func configure(
        _ terminal: AgentBridgeTerminalView,
        usageCommandRequest: Int,
        allowsUsageScreenCapture: Bool
    ) {
        terminal.allowsUsageScreenCapture = allowsUsageScreenCapture
        guard usageCommandRequest != lastUsageCommandRequest else { return }
        lastUsageCommandRequest = usageCommandRequest
        if allowsUsageScreenCapture { terminal.sendUsageCommand() }
    }

    private func mountTerminalIntoEmbeddedContainerIfPossible() {
        guard terminalModel?.terminalIsDetached != true,
              let terminal = terminalView,
              let container = embeddedContainer else { return }
        if let window = container.window { mainWindow = window }
        guard terminal.superview !== container else { return }
        detachTerminalFromCurrentParent()
        container.addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalConstraints = [
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        NSLayoutConstraint.activate(terminalConstraints)
    }

    private func detachTerminalFromCurrentParent() {
        NSLayoutConstraint.deactivate(terminalConstraints)
        terminalConstraints = []
        terminalView?.removeFromSuperview()
    }
}

@MainActor
@Observable
private final class DetachedTerminalToolbarModel {
    @ObservationIgnored private weak var terminalModel: TerminalModel?
    @ObservationIgnored private weak var appModel: AppModel?

    init(terminalModel: TerminalModel, appModel: AppModel) {
        self.terminalModel = terminalModel
        self.appModel = appModel
    }

    var title: String { appModel?.localized(terminalModel?.terminalTitle ?? "") ?? "" }
    var isRunning: Bool { terminalModel?.terminalRunning == true }
    var isProfileLogin: Bool { terminalModel?.terminalIsProfileLogin == true }
    var sessionID: UUID? { terminalModel?.terminalSessionIDForView }
    var canSendUsageCommand: Bool { terminalModel?.canSendUsageCommand == true }
    var closeTitle: String {
        guard let terminalModel else { return "Close terminal" }
        return terminalModel.terminalRunning
            ? (terminalModel.terminalNeedsManualStop ? "End the CLI, then close" : "Cancel and close")
            : "Close terminal"
    }
    var closeIsDisabled: Bool {
        terminalModel?.terminalRunning == true && terminalModel?.terminalNeedsManualStop == true
    }

    func localized(_ key: String) -> String { appModel?.localized(key) ?? key }
    func cancelSession() {
        guard let sessionID else { return }
        appModel?.cancelSession(sessionID)
    }
    func requestUsageCommand() { terminalModel?.requestUsageCommand() }
    func closeTerminal() { terminalModel?.closeEmbeddedTerminal() }
    func returnToConversation() { terminalModel?.returnTerminalToConversation() }
}

private struct DetachedTerminalToolbar: View {
    @Bindable var model: DetachedTerminalToolbarModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
            Text(model.title).font(.subheadline.weight(.semibold))
            if model.isRunning { ProgressView().controlSize(.small) }
            Spacer()
            if model.isRunning && !model.isProfileLogin, model.sessionID != nil {
                Button(model.localized("Cancel session")) { model.cancelSession() }
            }
            if model.canSendUsageCommand {
                Button(model.localized("Send /usage")) { model.requestUsageCommand() }
                    .help(model.localized("Only the fixed /usage command and Enter are sent after the CLI is ready."))
            }
            Button(model.localized(model.closeTitle)) {
                model.closeTerminal()
            }
            .disabled(model.closeIsDisabled)
            Button(model.localized("Return to Conversation")) {
                model.returnToConversation()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
