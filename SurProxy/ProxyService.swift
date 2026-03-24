//
//  ProxyService.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation

protocol ProxyServicing {
    func loadSnapshot() async throws -> ProxyStatusSnapshot
    func setRuntimeState(_ state: ProxyRuntimeState) async throws -> ProxyStatusSnapshot
    func setOAuthProfile(id: UUID, isActive: Bool) async throws -> ProxyStatusSnapshot
    func deleteOAuthProfile(id: UUID) async throws -> ProxyStatusSnapshot
    func setProvider(id: String, isEnabled: Bool) async throws -> ProxyStatusSnapshot
    func setProviderModel(providerID: String, modelID: String, isEnabled: Bool) async throws -> ProxyStatusSnapshot
    func loadProviderModels(stableKey: String) async throws -> [ProviderModel]
    func saveProviderModelStates(_ changes: [String: Set<String>]) async throws -> ProxyStatusSnapshot
    func renameProvider(stableKey: String, newName: String) async throws -> ProxyStatusSnapshot
    func deleteProvider(stableKey: String) async throws -> ProxyStatusSnapshot
    func addProvider(_ draft: ProviderDraft) async throws -> ProxyStatusSnapshot
    func addAPIKey(_ value: String) async throws -> ProxyStatusSnapshot
    func deleteAPIKey(_ value: String) async throws -> ProxyStatusSnapshot
    func reloadConfiguration() async throws -> ProxyStatusSnapshot
    func reinstallBundledRuntime() async throws -> ProxyStatusSnapshot
    func startOAuthLogin(provider: OAuthLoginProvider, options: OAuthLoginRequestOptions) async throws -> OAuthLoginSession
    func pollOAuthLogin(state: String) async throws -> ProxyStatusSnapshot
    func shutdown()
}

final class ProxyService: ProxyServicing {
    private let runtimeManager: RuntimeManager
    private let apiClient: ManagementAPIClient
    private let fileManager: FileManager
    private let defaultPort = 8787
    private let managementBasePath = "v0/management"

    private var snapshot = ProxyStatusSnapshot.bootstrap()
    private var paths: RuntimePaths
    private var manifest: RuntimeManifest
    private var providerModelCache: [String: [ProviderModel]] = [:]

    private func debugLog(_ message: String) {
        print("[SurProxyDebug] \(message)")
    }

    init(
        runtimeManager: RuntimeManager = RuntimeManager(),
        apiClient: ManagementAPIClient = ManagementAPIClient(),
        fileManager: FileManager = .default
    ) {
        self.runtimeManager = runtimeManager
        self.apiClient = apiClient
        self.fileManager = fileManager

        let resolvedPaths = (try? RuntimePaths.resolve(fileManager: fileManager)) ?? {
            let home = fileManager.homeDirectoryForCurrentUser
            let appSupportDirectory = home.appendingPathComponent("Library/Application Support/SurProxy", isDirectory: true)
            let runtimeDirectory = appSupportDirectory.appendingPathComponent("runtime", isDirectory: true)
            let authDirectory = home.appendingPathComponent(".cli-proxy-api", isDirectory: true)
            return RuntimePaths(
                appSupportDirectory: appSupportDirectory,
                runtimeDirectory: runtimeDirectory,
                authDirectory: authDirectory,
                configFile: appSupportDirectory.appendingPathComponent("config.yaml"),
                manifestFile: appSupportDirectory.appendingPathComponent("runtime-manifest.json"),
                bundledBinary: nil,
                activeBinary: runtimeDirectory.appendingPathComponent("cliproxyapiplus")
            )
        }()

        self.paths = resolvedPaths
        self.manifest = ProxyService.loadOrBootstrapManifest(paths: resolvedPaths, runtimeManager: runtimeManager)
        self.snapshot = ProxyService.bootstrapSnapshot(paths: resolvedPaths, manifest: manifest)
    }

    func loadSnapshot() async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        return try await refreshSnapshot()
    }

    func setRuntimeState(_ state: ProxyRuntimeState) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()

        switch state {
        case .starting, .running:
            if !runtimeManager.isRunning, await apiClient.healthCheck(baseURL: managementBaseURL(), key: manifest.managementKey) {
                return try await refreshSnapshot()
            }
            try runtimeManager.start(paths: paths)
            try await waitForManagementReady()
        case .stopping, .stopped:
            runtimeManager.stop()
        case .degraded:
            break
        }

        return try await refreshSnapshot()
    }

    func setOAuthProfile(id: UUID, isActive: Bool) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        if let profile = snapshot.oauthProfiles.first(where: { $0.id == id }) {
            try await apiClient.toggleAuthFile(
                baseURL: managementBaseURL(),
                key: manifest.managementKey,
                name: profile.fileName,
                disabled: !isActive
            )
        }
        return try await refreshSnapshot()
    }

    func deleteOAuthProfile(id: UUID) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        try await ensureManagementReady()
        guard let profile = snapshot.oauthProfiles.first(where: { $0.id == id }) else {
            return snapshot
        }
        try await apiClient.deleteAuthFile(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            name: profile.fileName
        )
        return try await refreshSnapshot()
    }

    func setProvider(id: String, isEnabled: Bool) async throws -> ProxyStatusSnapshot {
        guard let provider = snapshot.providers.first(where: { $0.id == id }) else {
            return snapshot
        }
        throw NSError(
            domain: "SurProxy.Provider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(provider.name) is currently read-only in SurProxy. Update routing through CLIProxyAPIPlus config management first."]
        )
    }

    func setProviderModel(providerID: String, modelID: String, isEnabled: Bool) async throws -> ProxyStatusSnapshot {
        _ = providerID
        _ = modelID
        _ = isEnabled
        return snapshot
    }

    func loadProviderModels(stableKey: String) async throws -> [ProviderModel] {
        try prepareRuntime()
        try await ensureManagementReady()

        guard let provider = snapshot.providers.first(where: { $0.stableKey == stableKey }) else {
            return []
        }

        let resolved = try await resolveProviderState(
            baseURL: managementBaseURL(),
            configKey: provider.configKey,
            entryIndex: provider.entryIndex
        )
        debugLog("loadProviderModels stableKey=\(stableKey) selected=\(resolved.selectedModels.sorted()) models=\(resolved.models.map { $0.id })")
        let models = resolved.models
        let selectedModels = resolved.selectedModels
        providerModelCache[stableKey] = models

        if let snapshotIndex = snapshot.providers.firstIndex(where: { $0.stableKey == stableKey }) {
            snapshot.providers[snapshotIndex].selectedModels = selectedModels
            snapshot.providers[snapshotIndex].models = models
            snapshot.providers[snapshotIndex].modelCount = models.count
        }

        return models
    }

    func saveProviderModelStates(_ changes: [String: Set<String>]) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        try await ensureManagementReady()

        var expectedSelections: [String: Set<String>] = [:]
        debugLog("saveProviderModelStates changes=\(changes.mapValues { Array($0).sorted() })")

        let grouped = Dictionary(grouping: changes.keys.compactMap { stableKey in
            snapshot.providers.first(where: { $0.stableKey == stableKey })
        }, by: \.configKey)

        for (configKey, providers) in grouped {
            var entries = try await apiClient.providerEntries(
                baseURL: managementBaseURL(),
                key: manifest.managementKey,
                configKey: configKey
            )
            if configKey == "gemini-api-key" {
                for provider in providers {
                    guard provider.entryIndex >= 0, provider.entryIndex < entries.count else { continue }
                    let selectedModels = changes[provider.stableKey] ?? provider.selectedModels
                    expectedSelections[provider.stableKey] = selectedModels
                    debugLog("save start stableKey=\(provider.stableKey) configKey=\(configKey) entryIndex=\(provider.entryIndex) target=\(selectedModels.sorted())")
                    var raw = entries[provider.entryIndex].rawObject
                    raw["models"] = Self.providerModelsPayload(from: selectedModels)
                    raw.removeValue(forKey: "excluded-models")
                    let name = entries[provider.entryIndex].name
                    let baseURL = entries[provider.entryIndex].baseURL
                    let apiKey = entries[provider.entryIndex].apiKey
                    let headers = entries[provider.entryIndex].headers
                    entries[provider.entryIndex] = ManagementProviderEntry(
                        name: name,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        headers: headers,
                        configuredModels: Self.providerConfiguredModels(from: selectedModels),
                        rawObject: raw
                    )
                }

                try await apiClient.putProviderEntries(
                    baseURL: managementBaseURL(),
                    key: manifest.managementKey,
                    configKey: configKey,
                    entries: entries.map(\.rawObject)
                )
            } else {
                for provider in providers {
                    guard provider.entryIndex >= 0, provider.entryIndex < entries.count else { continue }
                    let selectedModels = changes[provider.stableKey] ?? provider.selectedModels
                    expectedSelections[provider.stableKey] = selectedModels
                    debugLog("patch models stableKey=\(provider.stableKey) configKey=\(configKey) entryIndex=\(provider.entryIndex) target=\(selectedModels.sorted())")
                    try await apiClient.patchProviderModels(
                        baseURL: managementBaseURL(),
                        key: manifest.managementKey,
                        configKey: configKey,
                        index: provider.entryIndex,
                        models: Self.providerModelsPayload(from: selectedModels)
                    )
                }
            }

            let updatedEntries = try await apiClient.providerEntries(
                baseURL: managementBaseURL(),
                key: manifest.managementKey,
                configKey: configKey
            )
            debugLog("providerEntries after save configKey=\(configKey) entries=\(updatedEntries.enumerated().map { "#\($0.offset)=\($0.element.configuredModels.map { $0.id })" })")
            for provider in providers {
                guard provider.entryIndex >= 0, provider.entryIndex < updatedEntries.count else { continue }
                let expected = expectedSelections[provider.stableKey] ?? []
                let resolved = try await waitForProviderState(
                    baseURL: managementBaseURL(),
                    configKey: configKey,
                    entryIndex: provider.entryIndex,
                    expectedSelectedModels: expected
                )
                debugLog("resolved provider state stableKey=\(provider.stableKey) expected=\(expected.sorted()) actual=\(resolved.selectedModels.sorted())")
                providerModelCache[provider.stableKey] = resolved.models
                if let snapshotIndex = snapshot.providers.firstIndex(where: { $0.stableKey == provider.stableKey }) {
                    snapshot.providers[snapshotIndex].selectedModels = resolved.selectedModels
                    snapshot.providers[snapshotIndex].models = resolved.models
                    snapshot.providers[snapshotIndex].modelCount = resolved.models.count
                    debugLog("snapshot provider updated stableKey=\(provider.stableKey) selected=\(snapshot.providers[snapshotIndex].selectedModels.sorted())")
                }
            }
        }

        return try await refreshSnapshot()
    }

    func renameProvider(stableKey: String, newName: String) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        try await ensureManagementReady()

        guard let provider = snapshot.providers.first(where: { $0.stableKey == stableKey }) else {
            return snapshot
        }
        guard provider.canRename else {
            throw NSError(
                domain: "SurProxy.Provider",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "\(provider.kindTitle) entries do not expose a configurable name in CLIProxyAPIPlus."]
            )
        }

        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(
                domain: "SurProxy.Provider",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Provider name cannot be empty."]
            )
        }

        var entries = try await apiClient.providerEntries(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            configKey: provider.configKey
        )
        guard provider.entryIndex >= 0, provider.entryIndex < entries.count else {
            return snapshot
        }

        var raw = entries[provider.entryIndex].rawObject
        raw["name"] = trimmedName
        let entry = entries[provider.entryIndex]
        entries[provider.entryIndex] = ManagementProviderEntry(
            name: trimmedName,
            baseURL: entry.baseURL,
            apiKey: entry.apiKey,
            headers: entry.headers,
            configuredModels: entry.configuredModels,
            rawObject: raw
        )

        try await apiClient.putProviderEntries(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            configKey: provider.configKey,
            entries: entries.map(\.rawObject)
        )
        return try await refreshSnapshot()
    }

    func deleteProvider(stableKey: String) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        try await ensureManagementReady()
        guard let provider = snapshot.providers.first(where: { $0.stableKey == stableKey }) else {
            return snapshot
        }
        try await apiClient.deleteProviderEntry(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            configKey: provider.configKey,
            index: provider.entryIndex
        )
        return try await refreshSnapshot()
    }

    func addProvider(_ draft: ProviderDraft) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        if !runtimeManager.isRunning {
            try runtimeManager.start(paths: paths)
            try await waitForManagementReady()
        }

        let yaml = try await apiClient.getConfigYAML(baseURL: managementBaseURL(), key: manifest.managementKey)
        let updatedYAML = try Self.appendingProvider(draft, to: yaml)
        try await apiClient.putConfigYAML(baseURL: managementBaseURL(), key: manifest.managementKey, yaml: updatedYAML)
        try await Task.sleep(for: .milliseconds(400))
        return try await refreshSnapshot()
    }

    func addAPIKey(_ value: String) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        try await ensureManagementReady()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snapshot }
        try await apiClient.patchAPIKeys(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            oldValue: nil,
            newValue: trimmed
        )
        return try await refreshSnapshot()
    }

    func deleteAPIKey(_ value: String) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        try await ensureManagementReady()
        try await apiClient.deleteAPIKey(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            value: value
        )
        return try await refreshSnapshot()
    }

    func reloadConfiguration() async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        try await ensureManagementReady()
        return try await refreshSnapshot()
    }

    func reinstallBundledRuntime() async throws -> ProxyStatusSnapshot {
        manifest = try runtimeManager.installBundledRuntime(paths: paths, manifest: manifest)
        try runtimeManager.ensureConfig(paths: paths, manifest: manifest)
        try runtimeManager.writeManifest(manifest, to: paths.manifestFile)

        try runtimeManager.start(paths: paths)
        try await waitForManagementReady()
        return try await refreshSnapshot()
    }

    func startOAuthLogin(provider: OAuthLoginProvider, options: OAuthLoginRequestOptions) async throws -> OAuthLoginSession {
        try prepareRuntime()
        if !runtimeManager.isRunning {
            try runtimeManager.start(paths: paths)
            try await waitForManagementReady()
        }

        if provider == .gitlab, (options.gitLabMode ?? .oauth) == .personalAccessToken {
            var payload: [String: Any] = [
                "personal_access_token": options.gitLabPersonalAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ]
            let baseURL = options.gitLabBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !baseURL.isEmpty {
                payload["base_url"] = baseURL
            }
            try await apiClient.submitOAuthForm(
                baseURL: managementBaseURL(),
                key: manifest.managementKey,
                provider: provider,
                payload: payload
            )
            return OAuthLoginSession(provider: provider, authURL: "", state: "")
        }

        if provider == .iflow, (options.iflowMode ?? .browser) == .cookie {
            try await apiClient.submitOAuthForm(
                baseURL: managementBaseURL(),
                key: manifest.managementKey,
                provider: provider,
                payload: [
                    "cookie": options.iflowCookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                ]
            )
            return OAuthLoginSession(provider: provider, authURL: "", state: "")
        }

        var queryItems: [URLQueryItem] = []
        switch provider {
        case .gitlab:
            let baseURL = options.gitLabBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clientID = options.gitLabClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clientSecret = options.gitLabClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !baseURL.isEmpty {
                queryItems.append(URLQueryItem(name: "base_url", value: baseURL))
            }
            if !clientID.isEmpty {
                queryItems.append(URLQueryItem(name: "client_id", value: clientID))
            }
            if !clientSecret.isEmpty {
                queryItems.append(URLQueryItem(name: "client_secret", value: clientSecret))
            }
        case .kiro:
            queryItems.append(URLQueryItem(name: "method", value: (options.kiroMethod ?? .google).rawValue))
        default:
            break
        }

        let response = try await apiClient.startOAuth(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            provider: provider,
            queryItems: queryItems
        )

        guard let authURL = response.url, let state = response.state else {
            throw NSError(
                domain: "SurProxy.OAuth",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CLIProxyAPIPlus did not return an OAuth URL."]
            )
        }

        return OAuthLoginSession(provider: provider, authURL: authURL, state: state)
    }

    func pollOAuthLogin(state: String) async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        let deadline = Date().addingTimeInterval(300)

        while Date() < deadline {
            let status = try await apiClient.authStatus(
                baseURL: managementBaseURL(),
                key: manifest.managementKey,
                state: state
            )

            switch status.status {
            case "wait", "device_code", "auth_url":
                try await Task.sleep(for: .seconds(2))
            case "error":
                throw NSError(
                    domain: "SurProxy.OAuth",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: status.error ?? "OAuth login failed."]
                )
            default:
                return try await refreshSnapshot()
            }
        }

        throw NSError(
            domain: "SurProxy.OAuth",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "OAuth login timed out."]
        )
    }

    func shutdown() {
        runtimeManager.stop()
    }

    private func prepareRuntime() throws {
        manifest = try runtimeManager.prepareRuntime(paths: paths, manifest: manifest)
        try runtimeManager.ensureConfig(paths: paths, manifest: manifest)
        try runtimeManager.writeManifest(manifest, to: paths.manifestFile)
    }

    private func ensureManagementReady() async throws {
        let baseURL = managementBaseURL()
        if await apiClient.healthCheck(baseURL: baseURL, key: manifest.managementKey) {
            return
        }
        if !runtimeManager.isRunning {
            try runtimeManager.start(paths: paths)
        }
        try await waitForManagementReady()
    }

    private func waitForManagementReady() async throws {
        let baseURL = managementBaseURL()
        let deadline = Date().addingTimeInterval(8)

        while Date() < deadline {
            if !runtimeManager.isRunning {
                let details = runtimeManager.recentLog.trimmingCharacters(in: .whitespacesAndNewlines)
                let exitDetails = runtimeManager.recentExitStatus.map { " Exit status: \($0)." } ?? ""
                if details.isEmpty {
                    throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus exited before the management API became ready.\(exitDetails)")
                }
                throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus exited before the management API became ready.\(exitDetails)\n\(details)")
            }

            if await apiClient.healthCheck(baseURL: baseURL, key: manifest.managementKey) {
                return
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        if runtimeManager.isRunning {
            throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus did not become ready in time. Recent runtime log:\n\(runtimeManager.recentLog)")
        }

        let exitDetails = runtimeManager.recentExitStatus.map { " Exit status: \($0)." } ?? ""
        throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus is not running.\(exitDetails) Recent runtime log:\n\(runtimeManager.recentLog)")
    }

    private func refreshSnapshot() async throws -> ProxyStatusSnapshot {
        var next = ProxyService.bootstrapSnapshot(paths: paths, manifest: manifest)
        next.binary.latestVersion = snapshot.binary.latestVersion
        let baseURL = managementBaseURL()

        let managementReachable = await apiClient.healthCheck(baseURL: baseURL, key: manifest.managementKey)
        let existingRuntimeDetected = managementReachable && !runtimeManager.isRunning
        if runtimeManager.isRunning && managementReachable {
            next.runtimeState = .running
        } else if runtimeManager.isRunning {
            next.runtimeState = .degraded
        } else if existingRuntimeDetected {
            next.runtimeState = .running
        } else {
            next.runtimeState = .stopped
        }
        next.existingRuntimeDetected = existingRuntimeDetected
        next.runtimeNotice = existingRuntimeDetected ? "Detected an already running CLIProxyAPIPlus instance on this port. SurProxy is connected to it instead of launching a second runtime." : nil

        if managementReachable {
            next.binary.latestVersion = try? await apiClient.latestVersion(baseURL: baseURL, key: manifest.managementKey)
            if let apiKeys = try? await apiClient.apiKeys(baseURL: baseURL, key: manifest.managementKey) {
                next.apiKeys = apiKeys.map { APIKeyEntry(id: $0, value: $0) }
            }
            if let authFiles = try? await apiClient.authFiles(baseURL: baseURL, key: manifest.managementKey), !authFiles.isEmpty {
                next.oauthProfiles = try await enrichAuthProfiles(authFiles, baseURL: baseURL)
            } else {
                next.oauthProfiles = Self.loadAuthFilesFromDisk(at: paths.authDirectory, fileManager: fileManager)
            }
            let configObject = try? await apiClient.getConfig(baseURL: baseURL, key: manifest.managementKey)
            let configYAML = try? await apiClient.getConfigYAML(baseURL: baseURL, key: manifest.managementKey)
            next.providers = await enrichProviders(baseURL: baseURL, configObject: configObject, configYAML: configYAML)
            if next.providers.isEmpty, let configYAML {
                next.providers = Self.mapProviders(fromYAML: configYAML)
            }
        } else {
            next.managementAPIDisabled = false
            next.oauthProfiles = Self.loadAuthFilesFromDisk(at: paths.authDirectory, fileManager: fileManager)
        }

        snapshot = next
        return snapshot
    }

    private func managementBaseURL() -> URL {
        URL(string: "http://127.0.0.1:\(manifest.port)/\(managementBasePath)/")!
    }

    private func enrichAuthProfiles(_ authFiles: [ManagementAuthFile], baseURL: URL) async throws -> [OAuthProfile] {
        var profiles: [OAuthProfile] = []
        profiles.reserveCapacity(authFiles.count)

        for file in authFiles {
            var profile = Self.mapAuthFile(file)
            if let name = file.name, !name.isEmpty {
                if let models = try? await apiClient.authFileModels(baseURL: baseURL, key: manifest.managementKey, name: name), !models.isEmpty {
                    profile.models = Self.mapAvailableModels(models)
                } else {
                    let channels = Self.modelDefinitionCandidates(for: file)
                    for channel in channels {
                        if let fallbackModels = try? await apiClient.staticModelDefinitions(baseURL: baseURL, key: manifest.managementKey, channel: channel),
                           !fallbackModels.isEmpty {
                            profile.models = Self.mapAvailableModels(fallbackModels)
                            break
                        }
                    }
                }
            }
            profiles.append(profile)
        }

        return profiles
    }

    private func enrichProviders(baseURL: URL, configObject: [String: Any]?, configYAML: String?) async -> [ProviderRoute] {
        let providerKinds: [(configKey: String, title: String)] = [
            ("gemini-api-key", "Gemini API Keys"),
            ("claude-api-key", "Claude API Keys"),
            ("codex-api-key", "Codex API Keys"),
            ("openai-compatibility", "OpenAI Compatibility"),
            ("vertex-api-key", "Vertex API Keys")
        ]

        var routes: [ProviderRoute] = []
        for item in providerKinds {
            guard let entries = try? await apiClient.providerEntries(
                baseURL: baseURL,
                key: manifest.managementKey,
                configKey: item.configKey
            ) else {
                continue
            }

            for (index, entry) in entries.enumerated() {
                let stableKey = Self.providerStableKey(configKey: item.configKey, entryIndex: index)
                let configConfiguredModels = configObject.flatMap { Self.providerConfiguredModels(from: $0, configKey: item.configKey, entryIndex: index) } ?? []
                let effectiveConfiguredModels = entry.configuredModels.isEmpty ? configConfiguredModels : entry.configuredModels
                let routeName = Self.providerRouteName(
                    configKey: item.configKey,
                    kindTitle: item.title,
                    entryName: entry.name,
                    baseURL: entry.baseURL,
                    index: index
                )
                let cachedModels = cachedProviderModels(for: stableKey, configuredModels: effectiveConfiguredModels)
                routes.append(
                    ProviderRoute(
                        id: stableKey,
                        stableKey: stableKey,
                        name: routeName,
                        kindTitle: item.title,
                        baseURL: entry.baseURL ?? "Managed by CLIProxyAPIPlus",
                        modelCount: cachedModels.count,
                        isEnabled: true,
                        isEditable: false,
                        canRename: item.configKey == "openai-compatibility",
                        configKey: item.configKey,
                        entryIndex: index,
                        selectedModels: Set(effectiveConfiguredModels.map(\.id)),
                        models: cachedModels
                    )
                )
            }
        }

        return routes
    }

    private func resolveProviderState(baseURL: URL, configKey: String, entryIndex: Int) async throws -> (selectedModels: Set<String>, models: [ProviderModel]) {
        let entries = try await apiClient.providerEntries(
            baseURL: baseURL,
            key: manifest.managementKey,
            configKey: configKey
        )
        guard entryIndex >= 0, entryIndex < entries.count else {
            return ([], [])
        }

        let entry = entries[entryIndex]
        let configuredModels = entry.configuredModels
        let discoveredModels = await Self.resolveProviderModels(entry: entry, configKey: configKey, apiClient: apiClient)
        let mergedModels = Self.mergeProviderModels(
            discoveredModels: discoveredModels,
            configuredModels: configuredModels
        )
        return (Set(configuredModels.map(\.id)), mergedModels)
    }

    private func waitForProviderState(
        baseURL: URL,
        configKey: String,
        entryIndex: Int,
        expectedSelectedModels: Set<String>
    ) async throws -> (selectedModels: Set<String>, models: [ProviderModel]) {
        let deadline = Date().addingTimeInterval(6)
        var lastResolved = try await resolveProviderState(
            baseURL: baseURL,
            configKey: configKey,
            entryIndex: entryIndex
        )
        debugLog("waitForProviderState initial configKey=\(configKey) entryIndex=\(entryIndex) expected=\(expectedSelectedModels.sorted()) actual=\(lastResolved.selectedModels.sorted())")
        if lastResolved.selectedModels == expectedSelectedModels {
            return lastResolved
        }

        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            lastResolved = try await resolveProviderState(
                baseURL: baseURL,
                configKey: configKey,
                entryIndex: entryIndex
            )
            debugLog("waitForProviderState retry configKey=\(configKey) entryIndex=\(entryIndex) expected=\(expectedSelectedModels.sorted()) actual=\(lastResolved.selectedModels.sorted())")
            if lastResolved.selectedModels == expectedSelectedModels {
                return lastResolved
            }
        }

        return lastResolved
    }

    private static func loadOrBootstrapManifest(paths: RuntimePaths, runtimeManager: RuntimeManager) -> RuntimeManifest {
        if let manifest = try? runtimeManager.readManifest(from: paths.manifestFile) {
            return manifest
        }
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return RuntimeManifest.bootstrap(paths: paths, managementKey: key, port: 8787)
    }

    private static func bootstrapSnapshot(paths: RuntimePaths, manifest: RuntimeManifest) -> ProxyStatusSnapshot {
        var snapshot = ProxyStatusSnapshot.bootstrap()
        snapshot.endpoint = "http://127.0.0.1:\(manifest.port)"
        snapshot.activePort = manifest.port
        snapshot.configPath = paths.configFile.path
        snapshot.oauthDirectory = paths.authDirectory.path
        snapshot.binary.currentVersion = manifest.activeVersion
        snapshot.binary.source = manifest.source
        snapshot.binary.bundledBinaryPath = paths.bundledBinary?.path ?? "Missing bundled runtime"
        snapshot.binary.activeBinaryPath = paths.activeBinary.path
        snapshot.managementBaseURL = "http://127.0.0.1:\(manifest.port)/v0/management"
        snapshot.managementAPIDisabled = false
        snapshot.existingRuntimeDetected = false
        snapshot.runtimeNotice = nil
        return snapshot
    }

    nonisolated private static func mapAuthFile(_ file: ManagementAuthFile) -> OAuthProfile {
        let disabled = file.disabled ?? false
        let fileName = file.name ?? "unknown-auth-file"
        let providerKey = normalizedProvider(file)
        let provider = providerDisplayName(providerKey)
        let email = trimmed(file.email)
        let account = trimmed(file.account)
        let displayName = file.label.flatMap(trimmed) ?? email ?? account ?? fileName.replacingOccurrences(of: ".json", with: "")
        let unavailable = file.unavailable ?? false
        let status = trimmed(file.status)?.lowercased()
        let statusMessage = trimmed(file.statusMessage)
        let isValid = !unavailable && !disabled && status != "error"

        let statusDescription: String
        if disabled {
            statusDescription = "Disabled"
        } else if unavailable {
            statusDescription = "Unavailable"
        } else if let status, !status.isEmpty {
            statusDescription = status.replacingOccurrences(of: "_", with: " ").capitalized
        } else {
            statusDescription = "Active"
        }

        var detailParts: [String] = []
        if let statusMessage, !statusMessage.isEmpty {
            detailParts.append(statusMessage)
        }
        if let email, !email.isEmpty {
            detailParts.append(email)
        }
        if let account, !account.isEmpty, account != email {
            detailParts.append(account)
        }
        if let note = trimmed(file.note), !note.isEmpty {
            detailParts.append("Note: \(note)")
        }
        if let plan = file.idToken?["plan_type"], !plan.isEmpty {
            detailParts.append("Plan: \(plan)")
        }
        if let source = trimmed(file.source), source != "file" {
            detailParts.append("Source: \(source)")
        }
        if detailParts.isEmpty {
            detailParts.append(fileName)
        }

        return OAuthProfile(
            id: UUID(),
            provider: provider,
            displayName: displayName,
            fileName: fileName,
            isValid: isValid,
            isActive: !disabled,
            statusDescription: statusDescription,
            detailDescription: detailParts.joined(separator: " · "),
            email: email,
            account: account,
            note: trimmed(file.note),
            models: []
        )
    }

    nonisolated private static func mapAvailableModels(_ models: [ManagementAuthFileModel]) -> [AvailableModel] {
        models.map {
            AvailableModel(
                id: $0.id,
                displayName: $0.displayName,
                type: $0.type,
                ownedBy: $0.ownedBy
            )
        }
    }

    nonisolated private static func mergeProviderModels(discoveredModels: [ManagementAuthFileModel], configuredModels: [ManagementAuthFileModel]) -> [ProviderModel] {
        let selected = Set(configuredModels.map(\.id))
        let discoveredIDs = Set(discoveredModels.map(\.id))
        var merged: [String: ProviderModel] = [:]

        for model in discoveredModels {
            merged[model.id] = ProviderModel(
                id: model.id,
                displayName: model.displayName,
                type: model.type,
                ownedBy: model.ownedBy,
                isEnabled: selected.contains(model.id),
                isDeprecated: false
            )
        }

        for model in configuredModels {
            if var existing = merged[model.id] {
                existing.isEnabled = true
                merged[model.id] = existing
            } else {
                merged[model.id] = ProviderModel(
                    id: model.id,
                    displayName: model.displayName,
                    type: model.type,
                    ownedBy: model.ownedBy,
                    isEnabled: true,
                    isDeprecated: !discoveredIDs.isEmpty
                )
            }
        }

        return merged.values.sorted { $0.id < $1.id }
    }

    nonisolated private static func modelDefinitionCandidates(for file: ManagementAuthFile) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ raw: String?) {
            guard let raw else { return }
            let normalized = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return }
            if seen.insert(normalized).inserted {
                candidates.append(normalized)
            }
        }

        append(file.provider)
        append(file.type)
        append(file.id)
        append(file.accountType)

        if let fileName = trimmed(file.name) {
            let base = fileName.replacingOccurrences(of: ".json", with: "")
            append(base)
            append(base.split(separator: "-").first.map(String.init))
        }

        if let email = trimmed(file.email), !email.isEmpty {
            append(email.split(separator: "@").first.map(String.init))
        }

        return candidates
    }

    private static func mapProviders(from config: [String: Any]) -> [ProviderRoute] {
        var providers: [ProviderRoute] = []

        func appendProvider(name: String, key: String) {
            guard let items = config[key] as? [[String: Any]], !items.isEmpty else { return }
            providers.append(
                ProviderRoute(
                    id: providerStableKey(configKey: key, entryIndex: 0),
                    stableKey: providerStableKey(configKey: key, entryIndex: 0),
                    name: name,
                    kindTitle: name,
                    baseURL: (items.first?["base-url"] as? String) ?? "Managed by CLIProxyAPIPlus",
                    modelCount: items.count,
                    isEnabled: true,
                    isEditable: false,
                    canRename: key == "openai-compatibility",
                    configKey: key,
                    entryIndex: 0,
                    selectedModels: [],
                    models: []
                )
            )
        }

        appendProvider(name: "Gemini API Keys", key: "gemini-api-key")
        appendProvider(name: "Claude API Keys", key: "claude-api-key")
        appendProvider(name: "Codex API Keys", key: "codex-api-key")
        appendProvider(name: "OpenAI Compatibility", key: "openai-compatibility")
        appendProvider(name: "Vertex API Keys", key: "vertex-api-key")

        return providers.isEmpty ? ProxyStatusSnapshot.bootstrap().providers : providers
    }

    private static func mapProviders(fromYAML yaml: String) -> [ProviderRoute] {
        let keys: [(String, String)] = [
            ("gemini-api-key", "Gemini API Keys"),
            ("claude-api-key", "Claude API Keys"),
            ("codex-api-key", "Codex API Keys"),
            ("openai-compatibility", "OpenAI Compatibility"),
            ("vertex-api-key", "Vertex API Keys")
        ]

        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var providers: [ProviderRoute] = []

        for (key, name) in keys {
            guard let keyIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\(key):")
            }) else {
                continue
            }

            var itemCount = 0
            var firstBaseURL: String?
            var index = keyIndex + 1

            while index < lines.count {
                let line = lines[index]
                if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    break
                }

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    itemCount += 1
                }
                if firstBaseURL == nil, trimmed.hasPrefix("base-url:") {
                    firstBaseURL = trimmed
                        .replacingOccurrences(of: "base-url:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
                index += 1
            }

            guard itemCount > 0 else { continue }
            providers.append(
                ProviderRoute(
                    id: providerStableKey(configKey: key, entryIndex: providers.count),
                    stableKey: providerStableKey(configKey: key, entryIndex: providers.count),
                    name: name,
                    kindTitle: name,
                    baseURL: firstBaseURL ?? "Managed by CLIProxyAPIPlus",
                    modelCount: itemCount,
                    isEnabled: true,
                    isEditable: false,
                    canRename: key == "openai-compatibility",
                    configKey: key,
                    entryIndex: 0,
                    selectedModels: [],
                    models: []
                )
            )
        }

        return providers
    }

    nonisolated private static func appendingProvider(_ draft: ProviderDraft, to yaml: String) throws -> String {
        let trimmedAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelAlias = draft.modelAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProviderName = draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAPIKey.isEmpty else {
            throw NSError(domain: "SurProxy.Provider", code: 2, userInfo: [NSLocalizedDescriptionKey: "API key is required."])
        }
        guard !trimmedBaseURL.isEmpty else {
            throw NSError(domain: "SurProxy.Provider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Base URL is required."])
        }
        guard !trimmedModelName.isEmpty, !trimmedModelAlias.isEmpty else {
            throw NSError(domain: "SurProxy.Provider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Model name and alias are required."])
        }
        if draft.kind.supportsProviderName && trimmedProviderName.isEmpty {
            throw NSError(domain: "SurProxy.Provider", code: 5, userInfo: [NSLocalizedDescriptionKey: "Provider name is required for OpenAI compatibility entries."])
        }

        let block = providerBlock(for: draft.kind, providerName: trimmedProviderName, baseURL: trimmedBaseURL, apiKey: trimmedAPIKey, modelName: trimmedModelName, modelAlias: trimmedModelAlias)
        return appendYAMLBlock(block, forTopLevelKey: draft.kind.configKey, to: yaml)
    }

    nonisolated private static func providerBlock(for kind: ProviderConfigurationKind, providerName: String, baseURL: String, apiKey: String, modelName: String, modelAlias: String) -> [String] {
        switch kind {
        case .openAICompatibility:
            return [
                "  - name: '\(escapeYAML(providerName))'",
                "    base-url: '\(escapeYAML(baseURL))'",
                "    api-key-entries:",
                "      - api-key: '\(escapeYAML(apiKey))'",
                "    models:",
                "      - name: '\(escapeYAML(modelName))'",
                "        alias: '\(escapeYAML(modelAlias))'"
            ]
        case .geminiAPIKey, .claudeAPIKey, .codexAPIKey, .vertexAPIKey:
            return [
                "  - api-key: '\(escapeYAML(apiKey))'",
                "    base-url: '\(escapeYAML(baseURL))'",
                "    models:",
                "      - name: '\(escapeYAML(modelName))'",
                "        alias: '\(escapeYAML(modelAlias))'"
            ]
        }
    }

    nonisolated private static func appendYAMLBlock(_ block: [String], forTopLevelKey key: String, to yaml: String) -> String {
        var lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let keyLine = "\(key):"

        if let keyIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(keyLine)
        }) {
            if lines[keyIndex].trimmingCharacters(in: .whitespacesAndNewlines) != keyLine {
                lines[keyIndex] = keyLine
            }
            var insertIndex = keyIndex + 1
            while insertIndex < lines.count {
                let line = lines[insertIndex]
                if line.isEmpty {
                    insertIndex += 1
                    continue
                }
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    break
                }
                insertIndex += 1
            }
            lines.insert(contentsOf: block, at: insertIndex)
        } else {
            if !lines.isEmpty, !lines.last!.isEmpty {
                lines.append("")
            }
            lines.append(keyLine)
            lines.append(contentsOf: block)
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    nonisolated private static func escapeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    nonisolated private static func loadAuthFilesFromDisk(at directory: URL, fileManager: FileManager) -> [OAuthProfile] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }

                let authFile = ManagementAuthFile(
                    id: nil,
                    name: url.lastPathComponent,
                    provider: stringFromDisk(object["provider"]),
                    type: stringFromDisk(object["type"]),
                    label: stringFromDisk(object["label"]),
                    status: stringFromDisk(object["status"]),
                    statusMessage: nil,
                    disabled: boolFromDisk(object["disabled"]),
                    unavailable: nil,
                    authIndex: intFromDisk(object["auth_index"]),
                    email: stringFromDisk(object["email"]),
                    accountType: stringFromDisk(object["account_type"]),
                    account: stringFromDisk(object["account"]),
                    source: "file",
                    note: stringFromDisk(object["note"]),
                    priority: intFromDisk(object["priority"]),
                    path: url.path,
                    runtimeOnly: nil,
                    size: int64FromDisk(object["size"]),
                    createdAt: nil,
                    modtime: nil,
                    updatedAt: nil,
                    lastRefresh: nil,
                    nextRetryAfter: nil,
                    idToken: nil,
                    fields: nil
                )
                return mapAuthFile(authFile)
            }
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated private static func normalizedProvider(_ file: ManagementAuthFile) -> String {
        if let provider = trimmed(file.provider) {
            return provider
        }
        if let type = trimmed(file.type) {
            return type
        }
        if let name = trimmed(file.name) {
            return name.split(separator: "-").first.map(String.init) ?? "unknown"
        }
        return "unknown"
    }

    nonisolated private static func providerDisplayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "github-copilot":
            return "GitHub Copilot"
        case "codex":
            return "Codex"
        case "gemini":
            return "Gemini"
        case "anthropic":
            return "Anthropic"
        case "antigravity":
            return "Antigravity"
        case "vertex":
            return "Vertex"
        case "qwen":
            return "Qwen"
        default:
            return provider.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    nonisolated private static func providerRouteName(configKey: String, kindTitle: String, entryName: String?, baseURL: String?, index: Int) -> String {
        if let entryName = trimmed(entryName) {
            return entryName
        }
        if configKey == "openai-compatibility", let host = hostDisplay(from: baseURL) {
            return host
        }
        if let host = hostDisplay(from: baseURL) {
            return "\(kindTitle) \(index + 1) · \(host)"
        }
        return "\(kindTitle) \(index + 1)"
    }

    nonisolated private static func hostDisplay(from rawURL: String?) -> String? {
        guard let rawURL = trimmed(rawURL), let url = URL(string: rawURL) else {
            return nil
        }
        return url.host ?? rawURL
    }

    nonisolated private static func providerStableKey(configKey: String, entryIndex: Int) -> String {
        "\(configKey)#\(entryIndex)"
    }

    private static func resolveProviderModels(entry: ManagementProviderEntry, configKey: String, apiClient: ManagementAPIClient) async -> [ManagementAuthFileModel] {
        if let onlineModels = try? await apiClient.fetchOfficialProviderModels(configKey: configKey, entry: entry), !onlineModels.isEmpty {
            return onlineModels
        }
        return entry.configuredModels
    }

    nonisolated private static func providerModelsPayload(from selectedModels: Set<String>) -> [[String: Any]] {
        selectedModels.sorted().map { modelID in
            [
                "name": modelID,
                "alias": modelID
            ]
        }
    }

    nonisolated private static func providerConfiguredModels(from selectedModels: Set<String>) -> [ManagementAuthFileModel] {
        selectedModels.sorted().map { modelID in
            ManagementAuthFileModel(id: modelID, displayName: nil, type: "model", ownedBy: nil)
        }
    }

    nonisolated private static func providerConfiguredModels(from config: [String: Any], configKey: String, entryIndex: Int) -> [ManagementAuthFileModel] {
        guard let entries = config[configKey] as? [[String: Any]], entryIndex >= 0, entryIndex < entries.count else {
            return []
        }
        let models = entries[entryIndex]["models"] as? [[String: Any]] ?? []
        let configuredModels = models.compactMap { model -> ManagementAuthFileModel? in
            let alias = (model["alias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (model["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let upstreamName = name?.isEmpty == false ? name : nil
            let clientAlias = alias?.isEmpty == false ? alias : nil
            guard let id = upstreamName ?? clientAlias, !id.isEmpty else {
                return nil
            }
            return ManagementAuthFileModel(id: id, displayName: clientAlias, type: model["type"] as? String, ownedBy: nil)
        }
        return configuredModels
    }

    private func cachedProviderModels(for stableKey: String, configuredModels: [ManagementAuthFileModel]) -> [ProviderModel] {
        guard let cached = providerModelCache[stableKey], !cached.isEmpty else {
            return Self.mergeProviderModels(discoveredModels: [], configuredModels: configuredModels)
        }
        let discoveredModels = cached.map {
            ManagementAuthFileModel(id: $0.id, displayName: $0.displayName, type: $0.type, ownedBy: $0.ownedBy)
        }
        return Self.mergeProviderModels(discoveredModels: discoveredModels, configuredModels: configuredModels)
    }

    nonisolated private static func stringFromDisk(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            return trimmed(value)
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    nonisolated private static func boolFromDisk(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return Bool(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    nonisolated private static func intFromDisk(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    nonisolated private static func int64FromDisk(_ raw: Any?) -> Int64? {
        switch raw {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
