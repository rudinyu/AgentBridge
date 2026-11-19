import AgentBridgeCore
import SwiftUI

/// "New Session Like This": the source's provider, repository and access mode,
/// with its model, effort, account and commit as editable starting values.
struct SessionCopySheet: View {
    let model: AppModel
    @State var draft: SessionCopyDraft
    let onCreated: @MainActor (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session Like This")
                .font(.title3.weight(.semibold))
            Text(model.localizedFormat(
                "%@ · %@",
                draft.provider.rawValue.capitalized,
                model.localized(MainWindowView.accessModeLabel(draft.accessMode))
            ))
            .font(.callout).foregroundStyle(.secondary)

            if ProviderModelOptions.supportsModelChoice(draft.provider) {
                GroupBox("Model") {
                    ModelChoiceFields(model: model, provider: draft.provider, choice: $draft.modelChoice)
                        .padding(.vertical, 2)
                }
            }

            let accounts = model.accountProfiles[draft.provider] ?? []
            if !accounts.isEmpty {
                Picker(draft.provider == .local ? "Memory account" : "Account", selection: Binding(
                    get: { draft.accountProfileID ?? accounts[0].id },
                    set: { draft.accountProfileID = $0 }
                )) {
                    ForEach(accounts) { account in
                        Text(model.displayName(of: account)).tag(account.id)
                    }
                }
            }

            Picker("Commit", selection: $draft.commit) {
                Text(model.localizedFormat(SessionCopyPresentation.sameCommitFormat, String(draft.sourceCommit.prefix(12))))
                    .tag(SessionCommitChoice.sameAsSource)
                Text(model.localized(SessionCopyPresentation.sourceHeadLabel))
                    .tag(SessionCommitChoice.sourceHead)
            }
            .pickerStyle(.radioGroup)

            Label(model.localized(SessionCopyPresentation.notCopiedNote), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelNewSessionLike() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCreatingSessionCopy)
                Button {
                    model.sessionCopyDraft = draft
                    model.createSessionFromCopyDraft(onCreated: onCreated)
                } label: {
                    if model.isCreatingSessionCopy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create Session")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCreatingSessionCopy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
