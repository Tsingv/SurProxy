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
    func setProvider(id: UUID, isEnabled: Bool) async throws -> ProxyStatusSnapshot
    func reloadConfiguration() async throws -> ProxyStatusSnapshot
    func reinstallBundledRuntime() async throws -> ProxyStatusSnapshot
    func startOAuthLogin(provider: OAuthLoginProvider) async throws -> OAuthLoginSession
    func pollOAuthLogin(state: String) async throws -> ProxyStatusSnapshot
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
        case .running:
            try runtimeManager.start(paths: paths)
            try await waitForManagementReady()
        case .stopped:
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

    func setProvider(id: UUID, isEnabled: Bool) async throws -> ProxyStatusSnapshot {
        guard let provider = snapshot.providers.first(where: { $0.id == id }) else {
            return snapshot
        }
        throw NSError(
            domain: "SurProxy.Provider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(provider.name) is currently read-only in SurProxy. Update routing through CLIProxyAPIPlus config management first."]
        )
    }

    func reloadConfiguration() async throws -> ProxyStatusSnapshot {
        try prepareRuntime()
        if runtimeManager.isRunning {
            try await waitForManagementReady()
        }
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

    func startOAuthLogin(provider: OAuthLoginProvider) async throws -> OAuthLoginSession {
        try prepareRuntime()
        if !runtimeManager.isRunning {
            try runtimeManager.start(paths: paths)
            try await waitForManagementReady()
        }

        let response = try await apiClient.startOAuth(
            baseURL: managementBaseURL(),
            key: manifest.managementKey,
            provider: provider
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

    private func prepareRuntime() throws {
        manifest = try runtimeManager.prepareRuntime(paths: paths, manifest: manifest)
        try runtimeManager.ensureConfig(paths: paths, manifest: manifest)
        try runtimeManager.writeManifest(manifest, to: paths.manifestFile)
    }

    private func waitForManagementReady() async throws {
        let baseURL = managementBaseURL()
        let deadline = Date().addingTimeInterval(8)

        while Date() < deadline {
            if !runtimeManager.isRunning {
                let details = runtimeManager.recentLog.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty {
                    throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus exited before the management API became ready.")
                }
                throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus exited before the management API became ready.\n\(details)")
            }

            if await apiClient.healthCheck(baseURL: baseURL, key: manifest.managementKey) {
                return
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        if runtimeManager.isRunning {
            throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus did not become ready in time. Recent runtime log:\n\(runtimeManager.recentLog)")
        }

        throw RuntimeManagerError.runtimeExited("CLIProxyAPIPlus is not running. Recent runtime log:\n\(runtimeManager.recentLog)")
    }

    private func refreshSnapshot() async throws -> ProxyStatusSnapshot {
        var next = ProxyService.bootstrapSnapshot(paths: paths, manifest: manifest)
        let baseURL = managementBaseURL()

        let managementReachable = await apiClient.healthCheck(baseURL: baseURL, key: manifest.managementKey)
        if runtimeManager.isRunning && managementReachable {
            next.runtimeState = .running
        } else if runtimeManager.isRunning {
            next.runtimeState = .degraded
        } else {
            next.runtimeState = .stopped
        }

        if managementReachable {
            next.binary.latestVersion = try? await apiClient.latestVersion(baseURL: baseURL, key: manifest.managementKey)
            if let authFiles = try? await apiClient.authFiles(baseURL: baseURL, key: manifest.managementKey), !authFiles.isEmpty {
                next.oauthProfiles = authFiles.map(Self.mapAuthFile)
            } else {
                next.oauthProfiles = Self.loadAuthFilesFromDisk(at: paths.authDirectory, fileManager: fileManager)
            }
            if let config = try? await apiClient.getConfig(baseURL: baseURL, key: manifest.managementKey) {
                next.providers = Self.mapProviders(from: config)
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
            note: trimmed(file.note)
        )
    }

    private static func mapProviders(from config: [String: Any]) -> [ProviderRoute] {
        var providers: [ProviderRoute] = []

        func appendProvider(name: String, key: String) {
            guard let items = config[key] as? [[String: Any]], !items.isEmpty else { return }
            providers.append(
                ProviderRoute(
                    id: UUID(),
                    name: name,
                    baseURL: (items.first?["base-url"] as? String) ?? "Managed by CLIProxyAPIPlus",
                    modelCount: items.count,
                    isEnabled: true,
                    isEditable: false
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
