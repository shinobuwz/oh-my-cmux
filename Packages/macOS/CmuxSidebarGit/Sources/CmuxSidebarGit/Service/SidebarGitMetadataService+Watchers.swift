import Foundation

// MARK: - Filesystem watchers on each tracked directory's git paths.

extension SidebarGitMetadataService {
    func updateWorkspaceGitMetadataWatcher(
        for key: WorkspaceGitProbeKey,
        directory: String
    ) {
        guard sidebarGitMetadataActivePollingEnabled else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatcherSourceDirectoryByKey[key] == directory,
           let watchedPathsKey = workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key],
           workspaceGitMetadataWatcherSubscriptionsByWatchedPathsKey[watchedPathsKey] != nil {
            if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory != directory {
                workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            }
            return
        }

        if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory == directory {
            return
        }

        workspaceGitMetadataWatcherDescriptorGeneration &+= 1
        let request = WorkspaceGitMetadataWatcherDescriptorRequest(
            generation: workspaceGitMetadataWatcherDescriptorGeneration,
            directory: directory
        )
        workspaceGitMetadataWatcherDescriptorRequestsByKey[key] = request

        Task { [weak self] in
            guard let gitMetadataService = self?.gitMetadataService,
                  let registry = self?.workspaceGitMetadataWatcherRegistry else { return }
            let watchedPaths = await gitMetadataService.watchedPaths(for: directory)
            // Subscribe via the shared registry before re-entering the main
            // actor. The subscribe call is async (the registry is an actor);
            // doing it here keeps the synchronous @MainActor apply path
            // unchanged (no async ripple) while still sharing sources across
            // every window's service. If the source factory fails (returns
            // nil) the apply path falls back to source-directory-only
            // tracking with no watcher, exactly as the old
            // RecursivePathWatcher(paths:) nil branch did.
            let subscription: WorkspaceGitMetadataWatcherSubscriptionResult?
            if let watchedPaths {
                subscription = await registry.subscribe(paths: watchedPaths)
            } else {
                subscription = nil
            }
            let applied = await MainActor.run { [weak self] in
                guard let self else { return false }
                self.applyWorkspaceGitMetadataWatcherDescriptor(
                    watchedPaths,
                    subscription: subscription,
                    for: key,
                    request: request
                )
                return true
            }
            if !applied, let subscription {
                await registry.release(subscription.token)
            }
        }
    }

    private func applyWorkspaceGitMetadataWatcherDescriptor(
        _ watchedPaths: [String]?,
        subscription: WorkspaceGitMetadataWatcherSubscriptionResult?,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) {
        // A stale request (the directory changed while paths were being
        // resolved / subscribed) is dropped. Release the subscription if one
        // was created so the shared source refcounts correctly.
        guard workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request else {
            releaseSubscriptionIfPresent(subscription)
            return
        }
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)

        guard sidebarGitMetadataActivePollingEnabled,
              workspaceGitTrackedDirectoryByKey[key] == request.directory,
              let watchedPaths else {
            stopWorkspaceGitMetadataWatcher(for: key)
            releaseSubscriptionIfPresent(subscription)
            return
        }

        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: watchedPaths)
        if workspaceGitMetadataWatcherSubscriptionsByWatchedPathsKey[watchedPathsKey] != nil {
            // Another probe key already subscribed to this path set while we
            // were resolving; attach to the existing subscription and release
            // the redundant one.
            setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            releaseSubscriptionIfPresent(subscription)
            return
        }

        stopWorkspaceGitMetadataWatcher(for: key)
        guard let subscription else {
            // The source factory could not create a watcher for these paths
            // (e.g. RecursivePathWatcher rejected them). Track the source
            // directory for cache eligibility but install no watcher.
            setWorkspaceGitMetadataWatcherSourceDirectory(request.directory, for: key)
            setWorkspaceGitMetadataWatcherWatchedPathsKey(nil, for: key)
            return
        }

        // Install the shared subscription: one listener task pumps registry
        // events into the per-probe-key fan-out. The task is cancelled
        // synchronously by stop/deinit; its defer releases the token
        // asynchronously without capturing self (only the Sendable registry
        // actor and the Sendable token).
        let registry = workspaceGitMetadataWatcherRegistry
        let token = subscription.token
        let events = subscription.events
        let listenerTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                let keys = self.recordWorkspaceGitMetadataFilesystemEvent(
                    forWatchedPathsKey: watchedPathsKey
                )
                for key in keys {
                    self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId,
                        panelId: key.panelId,
                        reason: "filesystemEvent"
                    )
                }
            }
            // Listener exited (stream finished or self gone). Release the
            // token asynchronously without capturing self.
            Task { await registry.release(token) }
        }
        workspaceGitMetadataWatcherSubscriptionsByWatchedPathsKey[watchedPathsKey] = WorkspaceGitMetadataWatcherSubscription(
            listenerTask: listenerTask,
            token: token
        )
        setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
        moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
    }

    /// Releases a registry subscription asynchronously without capturing
    /// `self`. Called when a subscription was created but never installed
    /// (stale request, setting disabled, or another probe key already held
    /// the shared subscription).
    private func releaseSubscriptionIfPresent(_ subscription: WorkspaceGitMetadataWatcherSubscriptionResult?) {
        guard let subscription else { return }
        let registry = workspaceGitMetadataWatcherRegistry
        let token = subscription.token
        Task { await registry.release(token) }
    }

    func workspaceGitSnapshotCacheGeneration(directory: String) -> UInt64? {
        workspaceGitSnapshotCacheGenerationByDirectory[directory]
    }

    func markWorkspaceGitSnapshotCacheEligible(directory: String) {
        workspaceGitMetadataFilesystemEventGeneration &+= 1
        workspaceGitSnapshotCacheGenerationByDirectory[directory] = workspaceGitMetadataFilesystemEventGeneration
    }

    func moveWorkspaceGitSnapshotCacheEligibility(for key: WorkspaceGitProbeKey, to directory: String) {
        let previousDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: key)
        guard previousDirectory != directory else {
            if workspaceGitSnapshotCacheGenerationByDirectory[directory] == nil {
                markWorkspaceGitSnapshotCacheEligible(directory: directory)
            }
            return
        }
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: previousDirectory)
        markWorkspaceGitSnapshotCacheEligible(directory: directory)
    }

    func setWorkspaceGitMetadataWatcherSourceDirectory(_ directory: String?, for key: WorkspaceGitProbeKey) {
        if let previousDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey.removeValue(forKey: key) {
            workspaceGitMetadataWatcherKeysBySourceDirectory[previousDirectory]?.remove(key)
            if workspaceGitMetadataWatcherKeysBySourceDirectory[previousDirectory]?.isEmpty == true {
                workspaceGitMetadataWatcherKeysBySourceDirectory.removeValue(forKey: previousDirectory)
            }
        }
        guard let directory else { return }
        workspaceGitMetadataWatcherSourceDirectoryByKey[key] = directory
        workspaceGitMetadataWatcherKeysBySourceDirectory[directory, default: []].insert(key)
    }

    func setWorkspaceGitMetadataWatcherWatchedPathsKey(
        _ watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey?,
        for key: WorkspaceGitProbeKey
    ) {
        if let previousWatchedPathsKey = workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key],
           previousWatchedPathsKey == watchedPathsKey {
            return
        }
        if let previousWatchedPathsKey = workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.removeValue(forKey: key) {
            workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[previousWatchedPathsKey]?.remove(key)
            if workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[previousWatchedPathsKey]?.isEmpty == true {
                workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey.removeValue(forKey: previousWatchedPathsKey)
                // Last probe key detached: cancel the listener task and
                // asynchronously release the registry token (without
                // capturing self). The registry stops the underlying
                // RecursivePathWatcher when the last subscriber for this
                // path set releases.
                if let subscription = workspaceGitMetadataWatcherSubscriptionsByWatchedPathsKey
                    .removeValue(forKey: previousWatchedPathsKey) {
                    subscription.listenerTask.cancel()
                    let registry = workspaceGitMetadataWatcherRegistry
                    let token = subscription.token
                    Task { await registry.release(token) }
                }
            }
        }
        guard let watchedPathsKey else { return }
        workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key] = watchedPathsKey
        workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey, default: []].insert(key)
    }

    func recordWorkspaceGitMetadataFilesystemEvent(for key: WorkspaceGitProbeKey) {
        guard let directory = workspaceGitMetadataWatcherSourceDirectoryByKey[key] ??
            workspaceGitTrackedDirectoryByKey[key] else {
            return
        }
        recordWorkspaceGitMetadataFilesystemEvent(directory: directory)
    }

    @discardableResult
    func recordWorkspaceGitMetadataFilesystemEvent(
        forWatchedPathsKey watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey
    ) -> [WorkspaceGitProbeKey] {
        let keys = Array(workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey] ?? [])
        let directories = Set(keys.compactMap { workspaceGitMetadataWatcherSourceDirectoryByKey[$0] })
        advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directories: directories)
        return keys
    }

    func advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directory: String) {
        guard workspaceGitSnapshotCacheGenerationByDirectory[directory] != nil else {
            return
        }
        workspaceGitMetadataFilesystemEventGeneration &+= 1
        workspaceGitSnapshotCacheGenerationByDirectory[directory] = workspaceGitMetadataFilesystemEventGeneration
    }

    private func advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directories: Set<String>) {
        let eligibleDirectories = directories.filter {
            workspaceGitSnapshotCacheGenerationByDirectory[$0] != nil
        }
        guard !eligibleDirectories.isEmpty else {
            return
        }
        workspaceGitMetadataFilesystemEventGeneration &+= 1
        let generation = workspaceGitMetadataFilesystemEventGeneration
        for directory in eligibleDirectories {
            workspaceGitSnapshotCacheGenerationByDirectory[directory] = generation
        }
    }

    private func recordWorkspaceGitMetadataFilesystemEvent(directory: String) {
        advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directory: directory)
    }

    private func removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: String?) {
        guard let directory else { return }
        if workspaceGitMetadataWatcherKeysBySourceDirectory[directory]?.isEmpty != false {
            workspaceGitSnapshotCacheGenerationByDirectory.removeValue(forKey: directory)
        }
    }

    func stopWorkspaceGitMetadataWatcher(for key: WorkspaceGitProbeKey) {
        let stoppedDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        setWorkspaceGitMetadataWatcherSourceDirectory(nil, for: key)
        setWorkspaceGitMetadataWatcherWatchedPathsKey(nil, for: key)
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: stoppedDirectory)
    }

    func stopWorkspaceGitMetadataWatchers(workspaceId: UUID) {
        let keys = Set(workspaceGitMetadataWatcherSourceDirectoryByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitMetadataWatcherDescriptorRequestsByKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    func stopAllWorkspaceGitMetadataWatchers() {
        // Cancel every listener task and asynchronously release each registry
        // token without capturing self. The registry stops the underlying
        // RecursivePathWatcher for each path set when its last subscriber
        // releases.
        let registry = workspaceGitMetadataWatcherRegistry
        for subscription in workspaceGitMetadataWatcherSubscriptionsByWatchedPathsKey.values {
            subscription.listenerTask.cancel()
            let token = subscription.token
            Task { await registry.release(token) }
        }
        workspaceGitMetadataWatcherSubscriptionsByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherKeysBySourceDirectory.removeAll()
        workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.removeAll()
        workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
        workspaceGitSnapshotCacheGenerationByDirectory.removeAll()
    }
}
