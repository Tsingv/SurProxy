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
    @Published var oauthInFlightProvider: OAuthLoginProvider?
    @Published var providerDraft = ProviderDraft()
    @Published var providerDraftValidation = ProviderDraftValidation()

    private let service: ProxyServicing

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
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            do {
                snapshot = try await service.loadSnapshot()
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
        await performMutation { [self] in
            try await self.service.setRuntimeState(.running)
        }
    }

    func stopProxy() async {
        await performMutation { [self] in
            try await self.service.setRuntimeState(.stopped)
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

    func setProvider(id: UUID, isEnabled: Bool) async {
        await performMutation { [self] in
            try await self.service.setProvider(id: id, isEnabled: isEnabled)
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

    func clearProviderValidation() {
        providerDraftValidation = ProviderDraftValidation()
    }

    func shutdown() {
        service.shutdown()
    }

    func copyModelID(_ modelID: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(modelID, forType: .string)
    }

    private func performMutation(_ operation: @escaping () async throws -> ProxyStatusSnapshot) async {
        isLoading = true
        defer { isLoading = false }

        do {
            snapshot = try await operation()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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
