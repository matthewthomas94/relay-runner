import AppKit
import SwiftUI

struct PersonalStorageStatus: Decodable {
    struct Destination: Decodable {
        let fullName: String
        let htmlURL: String
        private enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case htmlURL = "html_url"
        }
    }
    struct Usage: Decodable {
        let totalBytes: Int64
        let protectedBytes: Int64
        let unsyncedBytes: Int64
        let gitObjectBytes: Int64
        let evictableBytes: Int64
        let metadataBytes: Int64
        let unmanagedBytes: Int64
        private enum CodingKeys: String, CodingKey {
            case totalBytes = "total_bytes"
            case protectedBytes = "protected_bytes"
            case unsyncedBytes = "unsynced_bytes"
            case gitObjectBytes = "git_object_bytes"
            case evictableBytes = "evictable_bytes"
            case metadataBytes = "metadata_bytes"
            case unmanagedBytes = "unmanaged_bytes"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            totalBytes = try values.decode(Int64.self, forKey: .totalBytes)
            protectedBytes = try values.decode(Int64.self, forKey: .protectedBytes)
            unsyncedBytes = try values.decode(Int64.self, forKey: .unsyncedBytes)
            gitObjectBytes = try values.decode(Int64.self, forKey: .gitObjectBytes)
            evictableBytes = try values.decodeIfPresent(Int64.self, forKey: .evictableBytes) ?? 0
            metadataBytes = try values.decodeIfPresent(Int64.self, forKey: .metadataBytes) ?? 0
            unmanagedBytes = try values.decodeIfPresent(Int64.self, forKey: .unmanagedBytes) ?? 0
        }
    }
    let state: String
    let message: String?
    let connected: Bool
    let destination: Destination?
    let filesRoot: String
    let budgetBytes: Int64
    let retentionDays: Int
    let usage: Usage
    let overBudget: Bool
    let overageReasons: [String]
    let disclosure: String
    private enum CodingKeys: String, CodingKey {
        case state, message, connected, destination, usage, disclosure
        case filesRoot = "files_root"
        case budgetBytes = "budget_bytes"
        case retentionDays = "retention_days"
        case overBudget = "over_budget"
        case overageReasons = "overage_reasons"
    }
}

@MainActor
final class PersonalFileStorageModel: ObservableObject {
    @Published var status: PersonalStorageStatus?
    @Published var error: String?
    @Published var busy = false
    @Published var repositoryName = ""
    @Published var accountLogin: String?
    @Published var deviceCode: String?
    @Published var budgetMB = 256
    @Published var retentionDays = 30

    private struct Account: Decodable {
        let login: String
        let suggestedRepository: String
        private enum CodingKeys: String, CodingKey {
            case login
            case suggestedRepository = "suggested_repository"
        }
    }
    private struct Login: Decodable {
        let deviceCode: String?
        let url: String
        private enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case url
        }
    }
    private struct Failure: Decodable { let error: String? }

    var stateLabel: String {
        switch status?.state {
        case "local_only": return "Local only"
        case "pending": return "Pending sync"
        case "synced": return "Synced"
        case "conflict": return "Conflict — files preserved"
        case "auth_failure": return "Sign in required"
        case "disconnected": return "Disconnected"
        default: return "Local files"
        }
    }

    private func request<Response: Decodable>(_ route: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Response {
        let portText = try? String(contentsOfFile: "/tmp/relay_orchestrator.port", encoding: .utf8)
        let port = portText.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 7634
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/personal-storage/\(route)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 600
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Start Relay Runner services to access personal file storage."
            throw NSError(domain: "PersonalFileStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func refresh() async {
        await perform {
            let state: PersonalStorageStatus = try await self.request("status")
            self.status = state
            self.budgetMB = max(1, Int(state.budgetBytes / (1024 * 1024)))
            self.retentionDays = state.retentionDays
        }
    }

    func checkAccount() async {
        await perform {
            let account: Account = try await self.request("account")
            self.accountLogin = account.login
            if self.repositoryName.isEmpty { self.repositoryName = account.suggestedRepository }
            self.deviceCode = nil
        }
    }

    func signIn() async {
        await perform {
            let login: Login = try await self.request("sign-in", method: "POST", body: [:])
            self.deviceCode = login.deviceCode
            if let url = URL(string: login.url) { NSWorkspace.shared.open(url) }
        }
    }

    func configure() async {
        await mutate("configure", body: ["confirm": true, "repository_name": repositoryName, "create": true])
    }

    func mutate(_ route: String, body: [String: Any] = [:]) async {
        await perform {
            self.status = try await self.request(route, method: "POST", body: body)
        }
    }

    func savePolicy() async {
        await mutate("policy", body: ["budget_bytes": budgetMB * 1024 * 1024, "retention_days": retentionDays])
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await action() } catch { self.error = error.localizedDescription }
    }

    func revealFolder() {
        let root = status?.filesRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/relay-runner/files").path
        NSWorkspace.shared.open(URL(fileURLWithPath: root).deletingLastPathComponent())
    }
}

struct PersonalFileStorageSettingsView: View {
    @StateObject private var model = PersonalFileStorageModel()
    @State private var confirmConnect = false
    @State private var confirmUpload = false

    var body: some View {
        SettingsSection("Personal files", badge: model.stateLabel) {
            SettingsRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes and general task files stay in Relay Runner’s app folder. GitHub storage is optional and can be connected at any time.")
                    Text(model.status?.disclosure ?? "Only approved personal files are synchronized to a private repository in your GitHub account.")
                        .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    if let destination = model.status?.destination {
                        Link(destination.fullName, destination: URL(string: destination.htmlURL)!)
                    }
                    if let message = model.status?.message { Text(message).foregroundStyle(SettingsSurfaceColor.secondaryText) }
                    if let error = model.error { Text(error).foregroundStyle(SettingsSurfaceColor.error) }
                    if let code = model.deviceCode {
                        Text("GitHub sign-in code: \(code)").textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if model.busy { ProgressView().controlSize(.small) }
                        SettingsActionButton(title: "Open local files", systemImage: "folder", isEnabled: !model.busy, action: model.revealFolder)
                        SettingsActionButton(title: "Refresh", systemImage: "arrow.clockwise", isEnabled: !model.busy) { Task { await model.refresh() } }
                    }
                }
            }
            SettingsDivider()
            if model.status?.connected != true {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            SettingsActionButton(title: "Sign in to GitHub", systemImage: "person.crop.circle", isEnabled: !model.busy) { Task { await model.signIn() } }
                            SettingsActionButton(title: "Check signed-in account", systemImage: "arrow.clockwise", isEnabled: !model.busy) { Task { await model.checkAccount() } }
                        }
                        if let login = model.accountLogin {
                            Text("Signed in as \(login)").foregroundStyle(SettingsSurfaceColor.secondaryText)
                            TextField("Private repository name", text: $model.repositoryName)
                                .textFieldStyle(.plain)
                                .font(AppTypography.font(.field))
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(BoardDarkSurfaceBackground(cornerRadius: SettingsLayout.sidebarCornerRadius,
                                                                       fill: BoardDarkSurfaceStyle.contentFill))
                            SettingsActionButton(title: "Connect private repository…", systemImage: "link",
                                                 isEnabled: !model.busy && !model.repositoryName.isEmpty) { confirmConnect = true }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } else {
                SettingsRow {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        SettingsActionButton(title: "Approve and sync personal files…", systemImage: "arrow.triangle.2.circlepath", isEnabled: !model.busy) { confirmUpload = true }
                        SettingsActionButton(title: "Retry approved files", systemImage: "arrow.clockwise", isEnabled: !model.busy) { Task { await model.mutate("sync") } }
                        SettingsActionButton(title: "Disconnect", systemImage: "xmark", isEnabled: !model.busy) { Task { await model.mutate("disconnect") } }
                    }
                }
            }
            SettingsDivider()
            SettingsControlRow("Local cache budget", description: "Default 256 MB. Unsynced, pinned and active files are preserved if the cache exceeds this amount.") {
                SettingsStepper(title: "Local cache budget", value: $model.budgetMB, range: 1...100_000, unit: "MB")
            }
            SettingsControlRow("Keep recently used files", description: "Synced files older than this can be retrieved from GitHub when opened. Default 30 days.") {
                SettingsStepper(title: "Keep recently used files", value: $model.retentionDays, range: 0...3650, unit: "days")
            }
            SettingsRow {
                VStack(alignment: .leading, spacing: 6) {
                    if let status = model.status {
                        Text("\(ByteCountFormatter.string(fromByteCount: status.usage.totalBytes, countStyle: .file)) used locally, including history and metadata")
                        storageUsage("Synced files available to clear", bytes: status.usage.evictableBytes)
                        storageUsage("Protected local files", bytes: status.usage.protectedBytes)
                        storageUsage("Unsynced files", bytes: status.usage.unsyncedBytes)
                        storageUsage("Git history", bytes: status.usage.gitObjectBytes)
                        storageUsage("Storage catalog and metadata", bytes: status.usage.metadataBytes)
                        if status.usage.unmanagedBytes > 0 {
                            Text("Unsynced files include \(ByteCountFormatter.string(fromByteCount: status.usage.unmanagedBytes, countStyle: .file)) of other local files. Open the folder to export or delete files you no longer need.")
                                .foregroundStyle(SettingsSurfaceColor.secondaryText)
                        }
                        ForEach(status.overageReasons, id: \.self) { Text($0).foregroundStyle(SettingsSurfaceColor.secondaryText) }
                    }
                    SettingsActionButton(title: "Apply storage policy", systemImage: "checkmark", isEnabled: !model.busy) { Task { await model.savePolicy() } }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .disabled(model.busy)
        .task { await model.refresh() }
        .alert("Connect private GitHub storage?", isPresented: $confirmConnect) {
            Button("Connect") { Task { await model.configure() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Relay Runner will create or validate \(model.repositoryName) in your signed-in GitHub account. Files are uploaded only when approved. Local sessions remain available without GitHub.")
        }
        .alert("Upload these personal files?", isPresented: $confirmUpload) {
            Button("Approve and sync") { Task { await model.mutate("sync", body: ["approve": true]) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This approves all eligible personal notes, their version history, general project files and reviewed documents. Anyone granted access to your private repository can read them. Active recordings remain local until completed.")
        }
    }

    private func storageUsage(_ label: String, bytes: Int64) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .monospacedDigit()
        }
        .foregroundStyle(SettingsSurfaceColor.secondaryText)
    }
}
