import AppKit
import Darwin
import SwiftTerm
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
private final class AgentBridgeTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    private var process: LocalProcess?
    var onTermination: (@MainActor (Int32?) -> Void)?

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
    }

    /// Called when a view is removed without the helper having exited normally.
    /// Signal the provider's foreground group and the helper, then escalate after a bounded grace.
    func terminateWithEscalation() {
        guard let child = process, child.running else { return }
        let helperPID = child.shellPid
        let foregroundGroup = child.childfd >= 0 ? tcgetpgrp(child.childfd) : -1
        if foregroundGroup > 1, foregroundGroup != helperPID {
            _ = kill(-foregroundGroup, SIGTERM)
        }
        if helperPID > 1 { _ = kill(-helperPID, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(750)) {
            guard child.running else { return }
            if foregroundGroup > 1, foregroundGroup != helperPID,
               child.childfd >= 0, tcgetpgrp(child.childfd) == foregroundGroup {
                _ = kill(-foregroundGroup, SIGKILL)
            }
            if helperPID > 1, child.shellPid == helperPID { _ = kill(-helperPID, SIGKILL) }
            child.terminate()
        }
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
        guard let onTermination else { return }
        Task { @MainActor in onTermination(exitCode) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        feed(byteArray: slice)
    }

    func getWindowSize() -> winsize { windowSize() }
}

struct EmbeddedTerminalView: NSViewRepresentable {
    let launch: TerminalLaunchSpec
    let onTermination: @MainActor (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTermination: onTermination)
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
        coordinator.terminal = terminal
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else { return }
            terminal.start(launch)
        }
        return terminal
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onTermination = onTermination
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.terminal?.terminateWithEscalation()
        coordinator.terminal = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate weak var terminal: AgentBridgeTerminalView?
        var onTermination: @MainActor (Int32?) -> Void

        init(onTermination: @escaping @MainActor (Int32?) -> Void) {
            self.onTermination = onTermination
        }

        func processTerminated(_ exitCode: Int32?) {
            onTermination(exitCode)
        }
    }
}
