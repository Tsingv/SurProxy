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

    private let service: ProxyServicing

    init(service: ProxyServicing) {
        self.service = service

        Task {
            await refresh()
            if snapshot.runtimeState != .running {
                await startProxy()
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
}
