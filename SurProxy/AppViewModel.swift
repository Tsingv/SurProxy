//
//  AppViewModel.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation
import Combine
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot = ProxyStatusSnapshot.bootstrap()
    @Published var isLoading = false
    @Published var lastErrorMessage: String?
    @Published var providerSaveNotice: String?
    @Published var oauthInFlightProvider: OAuthLoginProvider?
    @Published var providerDraft = ProviderDraft()
    @Published var providerDraftValidation = ProviderDraftValidation()
    @Published var apiKeyDraft = ""
    @Published var pendingProviderSelectedModels: [String: Set<String>] = [:]
    @Published var providerModelLoadingKeys: Set<String> = []
    @Published var providerNameDrafts: [String: String] = [:]
    @Published var pendingDeletionConfirmation: PendingDeletionConfirmation?

    private let service: ProxyServicing
    private var providerModelLoadGeneration: Int = 0

    private func debugLog(_ message: String) {
        print("[SurProxyDebug] \(message)")
    }

    init(service: ProxyServicing) {
        self.service = service

        Task {
            await bootstrap()
        }
    }

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }

        do {
            snapshot = try await service.setRuntimeState(.running)
            pendingProviderSelectedModels = [:]
            syncProviderNameDrafts()
            lastErrorMessage = nil
            providerSaveNotice = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            do {
                snapshot = try await service.loadSnapshot()
                pendingProviderSelectedModels = [:]
                syncProviderNameDrafts()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func refresh() async {
        await performMutation { [self] in
            try await self.service.loadSnapshot()
        }
    }

    func startProxy() async {
        snapshot.runtimeState = .starting
        await performMutation { [self] in
            try await self.service.setRuntimeState(.running)
        }
    }

    func stopProxy() async {
        snapshot.runtimeState = .stopping
        await performMutation { [self] in
            try await self.service.setRuntimeState(.stopped)
        }
    }

    func toggleProxy() async {
        switch snapshot.runtimeState {
        case .running, .starting:
            await stopProxy()
        case .stopped, .stopping, .degraded:
            await startProxy()
        }
    }

    func reloadConfiguration() async {
        await performMutation { [self] in
            try await self.service.reloadConfiguration()
        }
    }

    func reinstallBundledRuntime() async {
        await performMutation { [self] in
            try await self.service.reinstallBundledRuntime()
        }
    }

    func startOAuthLogin(provider: OAuthLoginProvider) {
        Task {
            isLoading = true
            oauthInFlightProvider = provider
            defer {
                isLoading = false
                oauthInFlightProvider = nil
            }

            do {
                let session = try await service.startOAuthLogin(provider: provider)
                if let url = URL(string: session.authURL) {
                    NSWorkspace.shared.open(url)
                }
                snapshot = try await service.pollOAuthLogin(state: session.state)
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func setOAuthProfile(id: UUID, isActive: Bool) async {
        await performMutation { [self] in
            try await self.service.setOAuthProfile(id: id, isActive: isActive)
        }
    }

    func setProvider(id: String, isEnabled: Bool) async {
        await performMutation { [self] in
            try await self.service.setProvider(id: id, isEnabled: isEnabled)
        }
    }

    func setProviderModel(providerID: String, modelID: String, isEnabled: Bool) async {
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            return
        }

        var selected = pendingProviderSelectedModels[provider.stableKey] ?? provider.selectedModels
        if isEnabled {
            selected.insert(modelID)
        } else {
            selected.remove(modelID)
        }
        pendingProviderSelectedModels[provider.stableKey] = selected
        snapshot.providers = snapshot.providers.map { route in
            guard route.id == providerID else { return route }
            var updated = route
            updated.selectedModels = selected
            updated.models = route.models.map { model in
                var updatedModel = model
                if updatedModel.id == modelID {
                    updatedModel.isEnabled = isEnabled
                }
                return updatedModel
            }
            return updated
        }
    }

    func saveProviderChanges() async {
        let changes = pendingProviderSelectedModels
        guard !changes.isEmpty else { return }
        providerModelLoadGeneration += 1
        let generation = providerModelLoadGeneration
        debugLog("saveProviderChanges pending=\(changes.mapValues { Array($0).sorted() }) generation=\(generation)")
        providerSaveNotice = nil

        await performMutation { [self] in
            try await self.service.saveProviderModelStates(changes)
        }
        if generation == providerModelLoadGeneration {
            pendingProviderSelectedModels = [:]
        }
        if lastErrorMessage == nil {
            providerSaveNotice = "Provider changes have been saved. CLIProxyAPIPlus may take a few seconds to reflect the final model state. Re-expand the model list to refresh if needed."
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if providerSaveNotice != nil {
                    providerSaveNotice = nil
                }
            }
        }
        debugLog("saveProviderChanges finished generation=\(generation) providers=\(snapshot.providers.map { "\($0.stableKey)=\($0.selectedModels.sorted())" })")
    }

    var hasPendingProviderChanges: Bool {
        !pendingProviderSelectedModels.isEmpty
    }

    func loadProviderModels(stableKey: String) {
        guard !providerModelLoadingKeys.contains(stableKey) else { return }
        providerModelLoadingKeys.insert(stableKey)
        let generation = providerModelLoadGeneration

        Task {
            defer { providerModelLoadingKeys.remove(stableKey) }
            do {
                let models = try await service.loadProviderModels(stableKey: stableKey)
                guard generation == providerModelLoadGeneration else {
                    return
                }
                if let providerIndex = snapshot.providers.firstIndex(where: { $0.stableKey == stableKey }) {
                    var provider = snapshot.providers[providerIndex]
                    let selected = pendingProviderSelectedModels[stableKey] ?? Set(models.filter(\.isEnabled).map(\.id))
                    provider.selectedModels = selected
                    provider.models = models.map { model in
                        var updated = model
                        updated.isEnabled = selected.contains(model.id)
                        return updated
                    }
                    provider.modelCount = provider.models.count
                    snapshot.providers[providerIndex] = provider
                    debugLog("loadProviderModels applied stableKey=\(stableKey) selected=\(selected.sorted())")
                }
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func setProviderKind(_ kind: ProviderConfigurationKind) {
        providerDraft.kind = kind
        providerDraft.applyKindDefaults()
        providerDraftValidation = ProviderDraftValidation()
    }

    func addProvider() async {
        providerDraftValidation = validate(providerDraft)
        guard !providerDraftValidation.hasAnyError else { return }

        await performMutation { [self] in
            try await self.service.addProvider(self.providerDraft)
        }
    }

    func addAPIKey() async {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await performMutation { [self] in
            try await self.service.addAPIKey(trimmed)
        }

        if lastErrorMessage == nil {
            apiKeyDraft = ""
        }
    }

    func clearProviderValidation() {
        providerDraftValidation = ProviderDraftValidation()
    }

    func setProviderNameDraft(stableKey: String, value: String) {
        providerNameDrafts[stableKey] = value
    }

    func saveProviderName(stableKey: String) async {
        guard let provider = snapshot.providers.first(where: { $0.stableKey == stableKey }) else {
            return
        }
        let draft = (providerNameDrafts[stableKey] ?? provider.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, draft != provider.name else { return }

        await performMutation { [self] in
            try await self.service.renameProvider(stableKey: stableKey, newName: draft)
        }
    }

    func confirmDeleteOAuth(id: UUID) {
        guard let profile = snapshot.oauthProfiles.first(where: { $0.id == id }) else { return }
        pendingDeletionConfirmation = .oauth(
            PendingOAuthDeletion(id: id, profileID: id, displayName: profile.displayName)
        )
    }

    func confirmDeleteProvider(stableKey: String) {
        guard let provider = snapshot.providers.first(where: { $0.stableKey == stableKey }) else { return }
        pendingDeletionConfirmation = .provider(
            PendingProviderDeletion(id: stableKey, stableKey: stableKey, displayName: provider.name)
        )
    }

    func confirmDeleteAPIKey(_ value: String) {
        pendingDeletionConfirmation = .apiKey(
            PendingAPIKeyDeletion(id: value, value: value)
        )
    }

    func deleteConfirmedItem(_ pendingDeletionConfirmation: PendingDeletionConfirmation) async {
        self.pendingDeletionConfirmation = nil
        switch pendingDeletionConfirmation {
        case .oauth(let pendingOAuthDeletion):
            await performMutation { [self] in
                return try await self.service.deleteOAuthProfile(id: pendingOAuthDeletion.profileID)
            }
        case .provider(let pendingProviderDeletion):
            await performMutation { [self] in
                return try await self.service.deleteProvider(stableKey: pendingProviderDeletion.stableKey)
            }
        case .apiKey(let pendingAPIKeyDeletion):
            await performMutation { [self] in
                return try await self.service.deleteAPIKey(pendingAPIKeyDeletion.value)
            }
        }
    }

    func shutdown() {
        service.shutdown()
    }

    func copyModelID(_ modelID: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(modelID, forType: .string)
    }

    func copyAPIKey(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func performMutation(_ operation: @escaping () async throws -> ProxyStatusSnapshot) async {
        isLoading = true
        defer { isLoading = false }

        do {
            snapshot = try await operation()
            pendingProviderSelectedModels = [:]
            syncProviderNameDrafts()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func syncProviderNameDrafts() {
        providerNameDrafts = Dictionary(uniqueKeysWithValues: snapshot.providers.map { ($0.stableKey, $0.name) })
    }

    private func validate(_ draft: ProviderDraft) -> ProviderDraftValidation {
        let trimmedProviderName = draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelAlias = draft.modelAlias.trimmingCharacters(in: .whitespacesAndNewlines)

        var validation = ProviderDraftValidation()

        if draft.kind.supportsProviderName && trimmedProviderName.isEmpty {
            validation.providerName = "Provider name is required."
        }
        if trimmedBaseURL.isEmpty {
            validation.baseURL = "Base URL is required."
        } else if URL(string: trimmedBaseURL) == nil {
            validation.baseURL = "Enter a valid URL."
        }
        if trimmedAPIKey.isEmpty {
            validation.apiKey = "API key is required."
        }
        if trimmedModelName.isEmpty {
            validation.modelName = "Model name is required."
        }
        if trimmedModelAlias.isEmpty {
            validation.modelAlias = "Model alias is required."
        }

        return validation
    }
}
