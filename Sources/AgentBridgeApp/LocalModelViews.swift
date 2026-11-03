import AgentBridgeCore
import SwiftUI

struct LocalModelSettingsSection: View {
    @ObservedObject var model: AppModel

    private var localSettings: LocalModelSettings { model.settings.localModel }

    var body: some View {
        GroupBox(model.localized("Local model settings")) {
            VStack(alignment: .leading, spacing: 9) {
                Picker(model.localized("Backend"), selection: $model.settings.localModel.backend) {
                    Text(model.localized("Ollama")).tag(LocalModelBackend.ollama)
                    Text(model.localized("OpenAI-compatible · LM Studio")).tag(LocalModelBackend.openAICompatible)
                }
                .pickerStyle(.menu)

                TextField(model.localized("Loopback endpoint"), text: $model.settings.localModel.endpoint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint(model.localized("Use a numeric loopback address on this Mac."))

                TextField(model.localized("Model name"), text: $model.settings.localModel.model)
                    .textFieldStyle(.roundedBorder)

                if !model.localModelModels.isEmpty {
                    Picker(model.localized("Available models"), selection: $model.settings.localModel.model) {
                        ForEach(model.localModelModels) { descriptor in
                            Text(descriptor.name).tag(descriptor.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: 10) {
                    TextField(model.localized("Context window (tokens)"), value: $model.settings.localModel.contextWindowTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                    TextField(model.localized("Output reserve (tokens)"), value: $model.settings.localModel.maxOutputTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                .font(.caption)
                Text(model.localized("Context window: 1,024–131,072 tokens. Output reserve: 1–32,768 tokens, leaving at least 513 tokens for input and safety margin. Token estimates are approximate."))
                    .font(.caption2).foregroundStyle(.secondary)

                GroupBox(model.localized("Local run limits")) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let usage = model.localModelUsageStatistics {
                            Text(model.localizedFormat(
                                "Runs in the last rolling 24 hours: %d of %d",
                                usage.localDailyRuns,
                                LocalModelClient.defaultDailyRunLimit
                            ))
                            if model.hasSelectedLocalRunScope {
                                Text(model.localizedFormat(
                                    "Runs in the selected local chat/session: %d of %d",
                                    usage.localSessionRuns,
                                    LocalModelClient.defaultSessionRunLimit
                                ))
                            } else {
                                Text(model.localized("Select a local chat or project session to view its session count."))
                            }
                        } else {
                            Text(model.localized("Local run counts are not available until a workspace is selected."))
                        }
                        Text(model.localized("These are fixed AgentBridge request ceilings. Each authorized request attempt counts; they are app limits, not provider quota or billing."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button(model.localized("Save local model settings")) { model.saveLocalModelSettings() }
                        .buttonStyle(.borderedProminent)
                    Button(model.localized("Refresh models")) { model.refreshLocalModels() }
                        .disabled(model.isRefreshingLocalModels || model.isTestingLocalModel)
                    Button(model.localized("Test connection")) { model.testLocalModelConnectionFromUI() }
                        .disabled(model.isRefreshingLocalModels || model.isTestingLocalModel)
                }
                .controlSize(.small)

                Text(model.localized(model.localModelStatus))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.localModelError {
                    Label(model.localized(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(model.localized("Only explicit Refresh models and Test connection actions contact the configured loopback service. AgentBridge does not start it, download models, or use cloud fallback."), systemImage: "lock.shield")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
        .onChange(of: model.settings.localModel) { _, _ in
            model.localModelSettingsDidChange()
        }
    }
}

struct ContextPreviewSheet: View {
    @ObservedObject var model: AppModel
    let preview: ContextCompressionPreview
    let settings: LocalModelSettings?
    @Environment(\.dismiss) private var dismiss

    private var estimatedInputTokens: Int {
        Int((Double(preview.report.sentBytes) / 2.0).rounded(.up))
    }

    private var estimatedInputBudget: Int? {
        guard let settings else { return nil }
        return max(0, settings.contextWindowTokens - settings.maxOutputTokens - 512)
    }

    private var summaryLabel: String {
        if preview.requiresReview {
            return model.localized("No provider request was prepared because the context needs changes.")
        }
        if preview.report.compressionApplied {
            return model.localizedFormat(
                "Readable context: %d recent verbatim turns, %d excerpt sources, and %d omitted turns.",
                preview.report.recentVerbatimCount,
                preview.report.excerptSourceIDs.count,
                preview.report.omittedTurnCount
            )
        }
        return model.localizedFormat("Full context retained: %d turns remain verbatim.", preview.report.originalTurnCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.localized("Context preview"))
                        .font(.title2.weight(.semibold))
                    Text(summaryLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.localized("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if preview.report.refusalReason != nil {
                        Label(model.localized("Context needs changes before sending"), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.localized(settings == nil
                            ? "Some protected context cannot fit safely. Shorten the current prompt or pinned memory notes, then retry; no request was sent."
                            : "Some protected context cannot fit safely. Shorten the current prompt or pinned memory notes, or increase the configured context window; no request was sent."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if preview.report.compressionApplied {
                        Label(model.localized("Older context was compressed into readable excerpts; recent turns and the exact current request are preserved."), systemImage: "text.badge.plus")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Label(model.localized("No compression was needed. The current request remains unchanged."), systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        metric(model.localized("Bytes before"), value: String(preview.report.originalInputBytes))
                        metric(model.localized("Prepared input bytes"), value: String(preview.report.sentBytes))
                        metric(model.localized("Estimated input from bytes"), value: "≈ \(estimatedInputTokens) tokens")
                    }
                    if let settings, let estimatedInputBudget {
                        Text(model.localizedFormat("Estimated input budget: about %@ tokens after reserving %@ output tokens and a 512-token safety margin. The byte-based estimate is not an exact tokenizer count; tokenization varies by model and language.", String(estimatedInputBudget), String(settings.maxOutputTokens)))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(model.localized("The provider controls its context window and tokenizer. This byte-based input estimate is not an exact token count."))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    GroupBox(model.localized("Context sources")) {
                        VStack(alignment: .leading, spacing: 5) {
                            sourceCount(model.localized("Historical turns"), count: preview.report.originalTurnCount)
                            sourceCount(model.localized("Recent verbatim turns"), count: preview.report.recentVerbatimCount)
                            sourceCount(model.localized("Historical excerpts"), count: preview.report.excerptSourceIDs.count)
                            sourceCount(model.localized("Omitted turns"), count: preview.report.omittedTurnCount)
                            if !preview.report.omittedTurnIDs.isEmpty {
                                Text(model.localizedFormat("Omitted turn IDs: %@", preview.report.omittedTurnIDs.joined(separator: ", ")))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(model.localized("Readable context prepared for the request"))
                        .font(.headline)
                    if preview.sections.isEmpty {
                        Text(preview.compressedPrompt ?? model.localized("No provider prompt was composed."))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(preview.sections.enumerated()), id: \.offset) { _, section in
                            GroupBox(model.localized(section.title)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(section.text.isEmpty ? model.localized("No text in this section.") : section.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if !section.sourceIDs.isEmpty {
                                        Text(model.localizedFormat("Sources: %@", section.sourceIDs.joined(separator: ", ")))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sourceCount(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(count)).font(.caption.monospacedDigit())
        }
        .font(.caption)
    }
}
