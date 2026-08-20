import SwiftUI

struct WorkspaceHistoryView: View {
    @Bindable var model: WorkspaceHistoryViewModel
    let onClose: () -> Void
    var onWorkspaceChanged: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            if let error = model.errorMessage {
                messageStrip(error, warning: true)
            }
            if let notice = model.notice {
                messageStrip(notice, warning: false)
            }
            Group {
                switch model.section {
                case .history:
                    historySurface
                case .migration:
                    storageSurface
                }
            }
            .opacity(model.isLoading ? 0.65 : 1)
            .overlay {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Loading Workspace history")
                }
            }
        }
        .frame(width: 940, height: 640)
        .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Workspace History")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text(model.projectName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            Picker("History section", selection: $model.section) {
                ForEach(WorkspaceHistorySection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            Button("Close", action: onClose)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .frame(height: 70)
    }

    private var historySurface: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Search archived tickets", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.search() } }
                        .accessibilityLabel("Search Workspace history")
                    Button {
                        Task { await model.search() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Search history")
                }
                Text("Viewing history never restores ticket files.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if model.cards.isEmpty && !model.isLoading {
                            Text("No archived tickets match this search.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .padding(.top, 28)
                        }
                        ForEach(model.cards) { card in
                            historyCard(card)
                        }
                    }
                }
            }
            .padding(18)
            .frame(width: 330)

            Divider().overlay(Color.white.opacity(0.12))

            Group {
                if let card = model.selectedCard {
                    historyDetail(card)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.white.opacity(0.45))
                        Text("Select a historical ticket")
                            .foregroundStyle(Color.white.opacity(0.7))
                        Text("Search and detail use archive metadata and verified Git objects without silently recreating Markdown.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 390)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func historyCard(_ card: ArtifactHistoryCard) -> some View {
        let badge = WorkspaceHistoryBadge.resolve(state: card.state)
        return Button {
            Task { await model.select(card) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(card.ticketID)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer()
                    Text(card.status.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(badge.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(badge.isWarning ? Color.orange : Color.white.opacity(0.62))
                    .lineLimit(2)
                if card.attachmentCount > 0 {
                    Text("\(card.attachmentCount) attachment\(card.attachmentCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.48))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        model.selectedCard?.id == card.id
                            ? Color.white.opacity(0.13)
                            : Color.white.opacity(0.06)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.ticketID), \(card.title), \(badge.label)")
    }

    private func historyDetail(_ card: ArtifactHistoryCard) -> some View {
        let badge = WorkspaceHistoryBadge.resolve(
            state: card.state,
            availability: model.detail?.availability
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.ticketID)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(model.detail?.card?.title ?? card.title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                badgeView(badge)
            }

            if let detail = model.detail, detail.availability != "available" {
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail.recovery ?? unavailableExplanation(detail.availability))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                    if detail.availability == "needs_network" {
                        Toggle("Confirm access to the selected GitHub remote", isOn: $model.exposureConfirmed)
                            .font(.system(size: 12))
                        Button("Fetch verified detail") {
                            Task { await model.select(card, online: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.exposureConfirmed)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let markdown = model.detail?.markdown {
                            Text(markdown)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.78))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        dependencySummary
                        attachmentSummary
                    }
                }
                HStack {
                    Button("Restore detail") {
                        Task {
                            await model.restore(reopen: false)
                            onWorkspaceChanged()
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Explicitly rematerialize this terminal ticket and its verified attachments")
                    Button("Reopen in Backlog") {
                        Task {
                            await model.restore(reopen: true)
                            onWorkspaceChanged()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Move this ticket into the uncapped unfinished working set")
                    Spacer()
                }
                .disabled(model.detail?.availability != "available")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var dependencySummary: some View {
        if let dependencies = model.dependencies {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dependencies")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if dependencies.dependencies.isEmpty {
                    Text("No dependencies")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                ForEach(dependencies.dependencies) { dependency in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: dependency.satisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(dependency.satisfied ? Color.green : Color.orange)
                        Text(dependency.ticketID)
                        Text(dependency.availability.replacingOccurrences(of: "_", with: " ").capitalized)
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    .font(.system(size: 11))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentSummary: some View {
        if let attachments = model.detail?.attachments, !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Attachments")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                ForEach(attachments) { attachment in
                    HStack {
                        Image(systemName: "paperclip")
                        Text(attachment.displayName)
                        Spacer()
                        if let size = attachment.size { Text(formatBytes(size)) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.68))
                }
                Text("Available after verified detail retrieval; viewing does not restore files.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
        }
    }

    private var storageSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(WorkspaceHistoryViewModel.policySummary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text(WorkspaceHistoryViewModel.materializationDisclaimer)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))

                if let status = model.retentionStatus {
                    storageSummary(status)
                    exactSet(
                        title: "Unfinished tickets — kept without a cap",
                        ids: status.plan.nonterminalIDs
                    )
                    exactSet(
                        title: "Retained Done or Canceled — newest \(status.plan.limit)",
                        ids: status.plan.retainedTerminalIDs
                    )
                    exactSet(
                        title: "Deletion candidates after verification",
                        ids: status.plan.evictionCandidateIDs
                    )
                    if !status.plan.temporaryOverage.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Temporary safety overage")
                                .font(.system(size: 13, weight: .semibold))
                            ForEach(status.plan.temporaryOverage.keys.sorted(), id: \.self) { id in
                                Text("\(id): \(status.plan.temporaryOverage[id, default: []].joined(separator: ", "))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.orange)
                            }
                        }
                    }
                    recoverySummary(status)
                    applyControls(status)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func storageSummary(_ status: ArtifactRetentionStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Migration preview")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 24) {
                metric("Materialized files", "\(model.storage?.materialized.files ?? 0)")
                metric("Estimated file reduction", "\(status.plan.estimatedRemovedFileCount)")
                metric("Estimated reclaimable", formatBytes(model.storage?.reclaimableEstimateBytes ?? 0))
                metric("Reachable Git objects", formatBytes(model.storage?.reachableGitObjectsBytes ?? 0))
            }
            Text("Selected remote: \(status.remoteName ?? "None — Local Archive Only")")
                .font(.system(size: 12, weight: .medium))
            Text("Remote state: \(status.remote?.state ?? status.remoteMode)")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.58))
        }
    }

    private func recoverySummary(_ status: ArtifactRetentionStatus) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Before apply")
                .font(.system(size: 13, weight: .semibold))
            Text("Relay publishes and refetches the exact archive commit before any candidate file is removed. Before local adoption, rollback leaves the current materialization untouched; after publication, retry completes the journaled transaction forward. Offline, authentication, divergence, interruption, or integrity failures keep affected files materialized. Neither path purges Git history.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.62))
            ForEach(status.blockedReasons, id: \.self) { reason in
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
            }
            if let recovery = status.remote?.recovery, !recovery.isEmpty {
                Text(recovery)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
            }
            if let error = status.transaction.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
            }
        }
    }

    @ViewBuilder
    private func applyControls(_ status: ArtifactRetentionStatus) -> some View {
        let canSubmit = status.remoteMode == "enabled"
            && (!status.exposureConfirmationRequired || model.exposureConfirmed)
        if status.plan.evictionCandidateIDs.isEmpty {
            Text("No terminal files are currently eligible for cleanup.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green)
        } else {
            Toggle(
                "I confirm that Relay ticket content may be published to the selected GitHub remote before local cleanup.",
                isOn: $model.exposureConfirmed
            )
            .font(.system(size: 12))
            .accessibilityLabel("Confirm GitHub privacy exposure")
            HStack {
                if status.transaction.retryAvailable {
                    Button("Retry blocked migration") {
                        Task {
                            await model.applyRetention(retry: true)
                            onWorkspaceChanged()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                } else {
                    Button("Apply verified cleanup") {
                        Task {
                            await model.applyRetention()
                            onWorkspaceChanged()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
                Text("Candidate files remain local until remote verification succeeds.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    private func exactSet(title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(ids.count))")
                .font(.system(size: 13, weight: .semibold))
            Text(ids.isEmpty ? "None" : ids.joined(separator: ", "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.62))
                .textSelection(.enabled)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
    }

    private func badgeView(_ badge: WorkspaceHistoryBadge) -> some View {
        Text(badge.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(badge.isWarning ? Color.orange : Color.white.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .accessibilityLabel("Archive state: \(badge.label)")
    }

    private func messageStrip(_ message: String, warning: Bool) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(warning ? Color.orange : Color.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
    }

    private func unavailableExplanation(_ availability: String) -> String {
        switch availability {
        case "needs_network": "This Git object is not available locally. Confirm the selected GitHub remote to fetch and verify it."
        case "tampered": "Archive metadata or Git object identity failed verification. Restore and reopen are disabled."
        case "not_found": "This historical ticket is missing from the verified archive catalog."
        default: "Historical detail is unavailable."
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
