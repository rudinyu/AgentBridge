import AgentBridgeCore
import Foundation

/// What one row of the Skills & MCP list shows. Kept apart from the view so
/// the status line and the row's main button can be tested without SwiftUI.
enum ExtensionRowKind: Equatable {
    case skill
    case mcp
    case macControl

    init(_ configuration: ActiveExtensionConfigurationSummary) {
        if configuration.macControlTargetBundleID != nil {
            self = .macControl
        } else {
            self = configuration.kind == .skill ? .skill : .mcp
        }
    }

    var systemImage: String {
        switch self {
        case .skill: "doc.text"
        case .mcp: "server.rack"
        case .macControl: "desktopcomputer"
        }
    }

    /// Both MCP servers and Mac Control presets start a program, so both must
    /// pass Test Connection before they can be reviewed.
    var needsConnectionTest: Bool { self != .skill }
}

/// The row's title. A Mac Control preset also names its target app and its
/// access mode, so two presets for different apps or modes can be told apart.
enum ExtensionRowTitle {
    static func title(
        name: String,
        macControlTargetBundleID: String?,
        macControlAccessMode: MacControlAccessMode?,
        language: AppLanguage
    ) -> String {
        guard let target = macControlTargetBundleID else { return name }
        var parts = [name, target]
        switch macControlAccessMode {
        case .observe: parts.append(AppLocalization.display("Observe", language: language))
        case .control: parts.append(AppLocalization.display("Control", language: language))
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    static func title(_ configuration: ActiveExtensionConfigurationSummary, language: AppLanguage) -> String {
        title(
            name: configuration.name,
            macControlTargetBundleID: configuration.macControlTargetBundleID,
            macControlAccessMode: configuration.macControlAccessMode,
            language: language
        )
    }
}

/// The trust notice in the review sheet. The core's warning is mostly about
/// MCP processes, so a Skill, which runs nothing, gets its own sentence. The
/// core's warning itself is unchanged, since its version is part of the review digest.
enum ExtensionTrustNotice {
    static let skill = "Skill content is instructions only and cannot grant additional tools or change AgentBridge approvals. Referenced scripts, hooks and installers are never run."

    static func text(for kind: ExtensionKind, trustWarning: String) -> String {
        kind == .skill ? skill : trustWarning
    }
}

enum ExtensionRowAction: Equatable {
    case testConnection
    case reviewAndEnable
    case disable
    case stopControl

    var title: String {
        switch self {
        case .testConnection: "Test connection"
        case .reviewAndEnable: "Review and enable"
        case .disable: "Disable"
        case .stopControl: "Stop Control"
        }
    }
}

struct ExtensionRowState: Equatable {
    let kind: ExtensionRowKind
    /// Tested for its current configuration digest. Always true for a Skill.
    let isTested: Bool
    /// Enabled for the screen's current project, provider and profile.
    let isEnabled: Bool
    let isControlMode: Bool
    let toolCount: Int

    init(kind: ExtensionRowKind, isTested: Bool, isEnabled: Bool, isControlMode: Bool = false, toolCount: Int = 0) {
        self.kind = kind
        self.isTested = kind.needsConnectionTest ? isTested : true
        self.isEnabled = isEnabled
        self.isControlMode = isControlMode
        self.toolCount = toolCount
    }

    init(configuration: ActiveExtensionConfigurationSummary, isTested: Bool, isEnabled: Bool) {
        let kind = ExtensionRowKind(configuration)
        self.init(
            kind: kind,
            isTested: isTested,
            isEnabled: isEnabled,
            isControlMode: configuration.macControlAccessMode == .control,
            toolCount: kind == .macControl ? configuration.macControlActionNames.count : configuration.allowedTools.count
        )
    }

    var primaryAction: ExtensionRowAction {
        if isEnabled { return kind == .macControl && isControlMode ? .stopControl : .disable }
        if kind.needsConnectionTest && !isTested { return .testConnection }
        return .reviewAndEnable
    }

    /// One short line in the app language.
    func statusLine(language: AppLanguage) -> String {
        func text(_ source: String) -> String { AppLocalization.display(source, language: language) }
        if isEnabled {
            guard kind != .skill else { return text("Enabled") }
            return String(format: text("Enabled · %@ tools"), locale: language.locale, arguments: [String(toolCount)])
        }
        if kind.needsConnectionTest && !isTested { return text("Not tested") }
        return kind == .skill ? text("Imported · not enabled") : text("Tested · not enabled")
    }
}

/// When the review sheet's Enable button is available. The consent toggles are
/// the confirmation, so each required one must be on; the core checks them again.
enum ExtensionEnableRules {
    struct Inputs: Equatable {
        var kind: ExtensionRowKind
        var isControlMode = false
        var executionConsent = false
        var screenCaptureConsent = false
        var inputControlConsent = false
        /// The configuration digest the shown review was made for.
        var reviewedConfigurationDigest: String
        /// The configuration's current digest.
        var configurationDigest: String
        /// The digest of the last Test Connection, if any.
        var testedConfigurationDigest: String?
        var hasActiveWorkflow = false
        var canStartWorkflow = true
    }

    static func canEnable(_ inputs: Inputs) -> Bool {
        guard inputs.executionConsent else { return false }
        switch inputs.kind {
        case .skill:
            return !inputs.hasActiveWorkflow
        case .mcp:
            return !inputs.hasActiveWorkflow && inputs.testedConfigurationDigest == inputs.reviewedConfigurationDigest
        case .macControl:
            return inputs.canStartWorkflow
                && inputs.screenCaptureConsent
                && inputs.reviewedConfigurationDigest == inputs.configurationDigest
                && (!inputs.isControlMode || inputs.inputControlConsent)
        }
    }
}

/// Which session the Skills & MCP screen grants for. A grant is bound to a
/// session's project, provider and profile, so the scope is always a session.
enum ExtensionScopeResolver {
    /// Local-model sessions cannot use Skills or MCP.
    static func isValidScope(_ session: SessionRecord) -> Bool {
        session.provider != .local
    }

    /// Sessions for this repository, provider and profile, as the scope
    /// session picker lists them.
    static func matchingSessions(
        _ sessions: [SessionRecord],
        repositoryPath: String,
        provider: AgentProvider,
        profileID: UUID?
    ) -> [SessionRecord] {
        guard !repositoryPath.isEmpty, let profileID else { return [] }
        let path = URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL.path
        return sessions.filter {
            let sessionProfileID = $0.accountProfileID ?? AccountProfile.defaultID(for: $0.provider)
            return URL(fileURLWithPath: $0.sourceRepositoryPath, isDirectory: true).standardizedFileURL.path == path
                && $0.provider == provider
                && sessionProfileID == profileID
        }
    }

    /// A scope the user picked under Change… wins; otherwise the selected
    /// project session; otherwise the first session matching the repository
    /// path and the default provider and profile, as the screen did before.
    static func resolve(
        chosenSessionID: UUID?,
        selectedSession: SessionRecord?,
        fallback: [SessionRecord],
        sessions: [SessionRecord]
    ) -> SessionRecord? {
        if let chosenSessionID,
           let chosen = sessions.first(where: { $0.id == chosenSessionID }),
           isValidScope(chosen) {
            return chosen
        }
        if let selectedSession, isValidScope(selectedSession) { return selectedSession }
        return fallback.first(where: isValidScope)
    }
}

/// The Skill ID, name and summary offered after a SKILL.md is chosen. The user
/// can edit all three before importing.
struct SkillImportDraft: Identifiable, Equatable {
    let id = UUID()
    let fileURL: URL
    var skillID: String
    var name: String
    var summary: String

    static func == (lhs: SkillImportDraft, rhs: SkillImportDraft) -> Bool {
        lhs.fileURL == rhs.fileURL && lhs.skillID == rhs.skillID && lhs.name == rhs.name && lhs.summary == rhs.summary
    }

    /// Uses the file's front matter `name` and `description` when it has them,
    /// else the folder the SKILL.md is in.
    static func prefill(fileURL: URL, contents: String?) -> SkillImportDraft {
        let frontMatter = contents.map(Self.frontMatter) ?? [:]
        let folderName = fileURL.deletingLastPathComponent().lastPathComponent
        let name = frontMatter["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folderName
        return SkillImportDraft(
            fileURL: fileURL,
            skillID: slug(name).isEmpty ? slug(folderName) : slug(name),
            name: name,
            summary: frontMatter["description"] ?? ""
        )
    }

    /// Lowercase ASCII letters and digits joined by single hyphens: always a
    /// valid extension ID when not empty, and at most 160 bytes.
    static func slug(_ text: String) -> String {
        var result = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen && !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        if result.utf8.count > 160 {
            result = String(result.prefix(160))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result
    }

    /// Simple `key: value` lines between leading `---` markers. Anything more
    /// elaborate is ignored; the fields stay editable.
    static func frontMatter(_ contents: String) -> [String: String] {
        var lines = contents.components(separatedBy: .newlines)[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines = lines.dropFirst()
        var values: [String: String] = [:]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return values }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if values[key] == nil { values[key] = value }
        }
        // No closing marker: not front matter.
        return [:]
    }
}
