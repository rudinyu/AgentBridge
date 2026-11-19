import AgentBridgeCore
import SwiftUI

/// One confirmation for removing several sessions: what is safe, what may lose
/// work, and what cannot be removed now.
struct SessionBulkRemovalSheet: View {
    @Bindable var model: AppModel
    let review: SessionBulkRemovalReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.localizedFormat("Remove %@ sessions?", String(review.removable.count)))
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !review.mayLoseWork.isEmpty { mayLoseWorkSection }
                    if !review.safe.isEmpty { safeSection }
                    if !review.blocked.isEmpty { blockedSection }
                    Text("AgentBridge deletes each removed session's isolated workspace. Their audit events and usage records are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(model.localized("Cancel"), role: .cancel) { model.cancelBulkSessionRemoval() }
                    .keyboardShortcut(.cancelAction)
                Button(model.localizedFormat("Remove %@ Sessions", String(review.removable.count)), role: .destructive) {
                    model.confirmBulkSessionRemoval()
                }
                .disabled(review.removable.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private var mayLoseWorkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.localizedFormat("May lose work (%@)", String(review.mayLoseWork.count)),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline).foregroundStyle(.orange)
            Text("Anything listed here is lost. Removal cannot be undone.")
                .font(.callout.weight(.semibold))
            ForEach(review.mayLoseWork) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.bulkRemovalLabel(for: item.session)).font(.callout.weight(.medium))
                    ForEach(Array(model.sessionRemovalDetails(item.preview).enumerated()), id: \.offset) { _, detail in
                        Text(verbatim: detail)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var safeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.localizedFormat("Safe to remove (%@)", String(review.safe.count)), systemImage: "checkmark.circle")
                .font(.headline)
            Text("Nothing in these workspaces is missing from the source repository.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(review.safe) { item in
                Text(verbatim: "• " + model.bulkRemovalLabel(for: item.session)).font(.callout)
            }
        }
    }

    private var blockedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.localizedFormat("Cannot be removed now (%@)", String(review.blocked.count)), systemImage: "nosign")
                .font(.headline)
            Text("These sessions are not removed.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(review.blocked) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "• " + model.bulkRemovalLabel(for: item.session)).font(.callout)
                    Text(verbatim: model.localized(item.reason))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 12)
                }
            }
        }
    }
}
