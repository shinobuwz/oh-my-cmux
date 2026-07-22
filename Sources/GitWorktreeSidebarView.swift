import CmuxFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar view

/// Native sidebar for browsing git worktrees across registered repositories.
///
/// The only type here that touches ``GitWorktreeStore`` is this view itself —
/// repository headers and worktree rows receive plain value snapshots plus
/// closures, so the observable surface stays at the view boundary (no store
/// reference leaks into child rows).
struct GitWorktreeSidebarView: View {
    @ObservedObject var store: GitWorktreeStore

    /// Called with `(worktreePath, workspaceTitle)` when the user opens a
    /// worktree row. The title is the branch name when available, otherwise the
    /// directory's last path component — suitable as a new workspace's title.
    let onOpenWorktree: (_ path: String, _ title: String) -> Void

    @State private var isPresentingFolderPicker = false
    @State private var createSheetContext: CreateSheetContext?

    /// Identifies which repository the create-worktree sheet targets, so the
    /// sheet can compute a default destination without holding the store.
    private struct CreateSheetContext: Identifiable {
        let repositoryRoot: String
        var id: String { repositoryRoot }
    }

    var body: some View {
        List {
            ForEach(store.repositories) { repository in
                Section {
                    ForEach(repository.worktrees) { entry in
                        GitWorktreeRow(
                            entry: entry,
                            onOpen: { onOpenWorktree(entry.path, entry.displayName) },
                            onRemove: entry.isMainWorktree
                                ? nil
                                : { Task { await remove(repository: repository, entry: entry) } }
                        )
                    }
                } header: {
                    GitWorktreeRepositoryHeader(
                        repository: repository,
                        onRefresh: { Task { await store.refresh(repositoryRoot: repository.rootPath) } },
                        onRemove: { Task { await store.removeRepository(rootPath: repository.rootPath) } },
                        onAddWorktree: { createSheetContext = CreateSheetContext(repositoryRoot: repository.rootPath) }
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isPresentingFolderPicker = true
                } label: {
                    Label(
                        String(localized: "gitWorktrees.toolbar.addRepository", defaultValue: "Add Repository"),
                        systemImage: "folder.badge.plus"
                    )
                }
                .help(String(localized: "gitWorktrees.toolbar.addRepository.help", defaultValue: "Add a git repository"))
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label(
                        String(localized: "gitWorktrees.toolbar.refreshAll", defaultValue: "Refresh All"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .help(String(localized: "gitWorktrees.toolbar.refreshAll.help", defaultValue: "Refresh all worktrees"))
                .disabled(store.repositories.isEmpty)
            }
        }
        .overlay {
            if store.repositories.isEmpty {
                emptyState
            }
        }
        .sheet(item: $createSheetContext) { context in
            GitWorktreeCreateSheet(
                repositoryRoot: context.repositoryRoot,
                defaultDestination: GitWorktreeStore.defaultWorktreeDestination(
                    repositoryRoot: context.repositoryRoot,
                    branchName: defaultBranchPreview
                ),
                onCreate: { branch, destination in
                    let root = context.repositoryRoot
                    return Task { @MainActor in
                        try await store.createWorktree(
                            repositoryRoot: root,
                            branchName: branch,
                            destinationPath: destination
                        )
                    }
                },
                onOpenCreated: { createdPath, createdTitle in
                    createSheetContext = nil
                    onOpenWorktree(createdPath, createdTitle)
                },
                onDismiss: { createSheetContext = nil }
            )
        }
        .fileImporter(
            isPresented: $isPresentingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let path = url.standardizedFileURL.path
                Task { await store.addRepository(path: path) }
            case .failure:
                break
            }
        }
    }

    /// Branch-name preview used to seed the sheet's default destination label
    /// before the user types.
    private var defaultBranchPreview: String {
        String(localized: "gitWorktrees.create.branchPlaceholder", defaultValue: "feature")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(String(localized: "gitWorktrees.empty.title", defaultValue: "No Repositories"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(String(localized: "gitWorktrees.empty.subtitle",
                        defaultValue: "Add a git repository to browse its worktrees."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                isPresentingFolderPicker = true
            } label: {
                Label(
                    String(localized: "gitWorktrees.empty.addRepository", defaultValue: "Add Repository"),
                    systemImage: "folder.badge.plus"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listRowSeparator(.hidden)
    }

    private func remove(repository: GitWorktreeRepository, entry: GitWorktreeEntry) async {
        do {
            try await store.removeWorktree(repositoryRoot: repository.rootPath, path: entry.path)
        } catch {
            // `lastErrorMessage` is surfaced on the repository header; no alert here.
        }
    }
}

// MARK: - Repository header

/// Header row for one registered repository. Receives only a value snapshot
/// and closures — never the store.
private struct GitWorktreeRepositoryHeader: View {
    let repository: GitWorktreeRepository
    let onRefresh: () -> Void
    let onRemove: () -> Void
    let onAddWorktree: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(repository.rootPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let error = repository.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                    .help(error)
            }
            if repository.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
            Button(action: onAddWorktree) {
                Image(systemName: "plus")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "gitWorktrees.repo.addWorktree.help",
                         defaultValue: "Create worktree"))
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "gitWorktrees.repo.refresh.help",
                         defaultValue: "Refresh worktrees"))
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "gitWorktrees.repo.remove.help",
                         defaultValue: "Remove repository"))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Worktree row

/// One worktree row. Receives only a value snapshot and closures — never the
/// store.
private struct GitWorktreeRow: View {
    let entry: GitWorktreeEntry
    let onOpen: () -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
                    .imageScale(.small)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(entry.displayName)
                            .font(.subheadline.weight(entry.isMainWorktree ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if entry.lockedReason != nil {
                            Image(systemName: "lock.fill")
                                .imageScale(.small)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(entry.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "gitWorktrees.row.remove.help",
                                 defaultValue: "Remove worktree"))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var symbolName: String {
        if entry.isBare { return "shippingbox" }
        if entry.isDetached { return "tag" }
        if entry.isMainWorktree { return "house.fill" }
        return "arrow.triangle.branch"
    }

    private var symbolColor: Color {
        if entry.isLocked { return .orange }
        if entry.isMainWorktree { return .accentColor }
        return .secondary
    }
}

private extension GitWorktreeEntry {
    var isLocked: Bool { lockedReason != nil }
}

// MARK: - Create-worktree sheet

/// Sheet for creating a new worktree (`worktree add -b <branch> <path> HEAD`).
///
/// Branch name is required; the destination defaults to a sibling directory of
/// the repository root (see ``GitWorktreeStore.defaultWorktreeDestination``) and
/// stays editable. The create action is async and shows an inline spinner.
private struct GitWorktreeCreateSheet: View {
    let repositoryRoot: String
    let defaultDestination: String
    /// Builds (but does not await) the create task keyed on the current branch
    /// + destination. Returning a `Task` lets the sheet await completion and
    /// extract the created path before dismissing/opening.
    let onCreate: (_ branch: String, _ destination: String) -> Task<String, Error>
    let onOpenCreated: (_ path: String, _ title: String) -> Void
    let onDismiss: () -> Void

    @State private var branchName: String = ""
    @State private var destinationPath: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var trimmedBranch: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(String(localized: "gitWorktrees.create.title",
                            defaultValue: "New Worktree"))
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "gitWorktrees.create.branchLabel",
                            defaultValue: "Branch name"))
                    .font(.subheadline.weight(.medium))
                TextField(
                    String(localized: "gitWorktrees.create.branchPlaceholder",
                           defaultValue: "feature/my-branch"),
                    text: $branchName
                )
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "gitWorktrees.create.destinationLabel",
                            defaultValue: "Destination path"))
                    .font(.subheadline.weight(.medium))
                TextField(
                    String(localized: "gitWorktrees.create.destinationPlaceholder",
                           defaultValue: "Default: sibling of repository root"),
                    text: $destinationPath
                )
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
                Text(String(localized: "gitWorktrees.create.destinationHint",
                            defaultValue: "Leave blank to use the default sibling path."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(action: onDismiss) {
                    Text(String(localized: "gitWorktrees.create.cancel",
                                defaultValue: "Cancel"))
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
                Button(action: submit) {
                    Text(String(localized: "gitWorktrees.create.create",
                                defaultValue: "Create"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedBranch.isEmpty || isCreating)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if destinationPath.isEmpty {
                destinationPath = defaultDestination
            }
        }
    }

    private func submit() {
        let branch = trimmedBranch
        guard !branch.isEmpty else { return }
        let destination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = destination.isEmpty
            ? GitWorktreeStore.defaultWorktreeDestination(
                repositoryRoot: repositoryRoot,
                branchName: branch
              )
            : destination
        isCreating = true
        errorMessage = nil
        let task = onCreate(branch, resolved)
        Task {
            do {
                let path = try await task.value
                let title = branch
                await MainActor.run {
                    isCreating = false
                    onOpenCreated(path, title)
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
