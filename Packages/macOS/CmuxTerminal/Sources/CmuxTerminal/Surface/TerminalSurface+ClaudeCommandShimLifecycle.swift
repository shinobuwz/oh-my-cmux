import Foundation

extension TerminalSurface {
    @MainActor
    func claudeCommandShimForSurface() -> ClaudeCommandShim? {
        guard let wrapperURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-claude-wrapper") else {
            claudeCommandShimInstallCompleted = true
            return nil
        }

        if claudeCommandShimInstallCompleted {
            return claudeCommandShim
        }

        if claudeCommandShimInstallTask == nil {
            let surfaceId = id
            // Explicit captures and arguments: the region-based isolation
            // checker cannot analyze the legacy closure's implicit captures
            // and in-closure default-argument evaluation (same effective body).
            let runtimeFilesystem = runtimeFilesystem
            let temporaryDirectory = runtimeFilesystem.claudeCommandShimTemporaryDirectory
            #if compiler(>=6.2)
            let installOperation: @concurrent @Sendable () async -> ClaudeCommandShim? = {
                [wrapperURL, surfaceId, temporaryDirectory, runtimeFilesystem] in
                await runtimeFilesystem.installClaudeCommandShim(wrapperURL, surfaceId, temporaryDirectory)
            }
            #else
            let installOperation: @Sendable () async -> ClaudeCommandShim? = {
                [wrapperURL, surfaceId, temporaryDirectory, runtimeFilesystem] in
                await runtimeFilesystem.installClaudeCommandShim(wrapperURL, surfaceId, temporaryDirectory)
            }
            #endif
            let installTask = Task.detached(priority: .utility, operation: installOperation)
            claudeCommandShimInstallTask = installTask
            claudeCommandShimCompletionTask = Task { @MainActor [weak self] in
                let shim = await installTask.value
                guard !Task.isCancelled, let self else { return }
                self.claudeCommandShim = shim
                self.claudeCommandShimInstallCompleted = true
                self.claudeCommandShimInstallTask = nil
                self.claudeCommandShimCompletionTask = nil
            }
        }

        // Shim installation is auxiliary. Native PTY creation must never wait
        // for it; a completed shim is picked up by a later runtime creation.
        return nil
    }

    @MainActor
    func cancelClaudeCommandShimInstallLifecycle() {
        claudeCommandShimCompletionTask?.cancel()
        claudeCommandShimCompletionTask = nil
        claudeCommandShimInstallTask?.cancel()
        claudeCommandShimInstallTask = nil
    }

}
