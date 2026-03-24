//
//  ContentView.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Runtime") {
                    Label(viewModel.snapshot.runtimeState.title, systemImage: runtimeIcon)
                    Label("\(viewModel.snapshot.activePort)", systemImage: "network")
                    Label("\(validOAuthCount) valid OAuth files", systemImage: "checkmark.seal")
                }

                Section("Paths") {
                    LabeledContent("Bundled Binary", value: viewModel.snapshot.binary.bundledBinaryPath)
                    LabeledContent("Active Binary", value: viewModel.snapshot.binary.activeBinaryPath)
                    LabeledContent("Config", value: viewModel.snapshot.configPath)
                    LabeledContent("OAuth", value: viewModel.snapshot.oauthDirectory)
                }
            }
            .navigationTitle("SurProxy")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    runtimeCard
                    runtimeBinaryCard
                    oauthLoginCard
                    oauthCard
                    providerCard
                }
                .padding(24)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var runtimeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Proxy Runtime")
                            .font(.title2.weight(.semibold))
                        Text("Bridge local macOS controls to CLIProxyAPIPlus process management and configuration reloads.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(viewModel.snapshot.runtimeState.title)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(runtimeTint.opacity(0.14))
                        .clipShape(Capsule())
                }

                HStack(spacing: 12) {
                    Button("Start") {
                        Task { await viewModel.startProxy() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.snapshot.runtimeState == .running || viewModel.isLoading)

                    Button("Stop") {
                        Task { await viewModel.stopProxy() }
                    }
                    .disabled(viewModel.snapshot.runtimeState == .stopped || viewModel.isLoading)

                    Button("Reload Config") {
                        Task { await viewModel.reloadConfiguration() }
                    }
                    .disabled(viewModel.isLoading)

                    Button("Install Bundled Runtime") {
                        Task { await viewModel.reinstallBundledRuntime() }
                    }
                    .disabled(viewModel.isLoading)
                }

                Divider()

                LabeledContent("Endpoint", value: viewModel.snapshot.endpoint)
                LabeledContent("Management API", value: viewModel.snapshot.managementBaseURL)
                LabeledContent("Port", value: "\(viewModel.snapshot.activePort)")
                LabeledContent("Runtime Source", value: viewModel.snapshot.binary.source.title)
                LabeledContent("Runtime Version", value: viewModel.snapshot.binary.currentVersion)
                if let lastErrorMessage = viewModel.lastErrorMessage {
                    Text(lastErrorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var runtimeBinaryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("CLIProxyAPIPlus Runtime")
                    .font(.title3.weight(.semibold))

                LabeledContent("Current Version", value: viewModel.snapshot.binary.currentVersion)
                LabeledContent("Latest Release", value: viewModel.snapshot.binary.latestVersion ?? "Unknown")
                LabeledContent("Source", value: viewModel.snapshot.binary.source.title)
                LabeledContent("Release Feed", value: viewModel.snapshot.binary.releaseFeedURL)

                Text("SurProxy should ship a compiled release binary, copy it to a writable runtime directory, and allow in-app replacement with downloaded or custom binaries.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var oauthCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("OAuth Files")
                    .font(.title3.weight(.semibold))

                if viewModel.snapshot.oauthProfiles.isEmpty {
                    Text("No OAuth files detected yet. Start a provider login above and CLIProxyAPIPlus will create the auth file in its managed auth directory.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.snapshot.oauthProfiles.enumerated()), id: \.element.id) { _, profile in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(profile.displayName)
                                        .font(.headline)
                                    Text(profile.provider)
                                        .foregroundStyle(.secondary)
                                }

                                Text(profile.fileName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text(profile.statusDescription)
                                    .font(.caption)
                                    .foregroundStyle(profile.isValid ? Color.secondary : Color.red)

                                Text(profile.detailDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle(
                                profile.isActive ? "Active" : "Disabled",
                                isOn: Binding(
                                    get: { profile.isActive },
                                    set: { newValue in
                                        Task { await viewModel.setOAuthProfile(id: profile.id, isActive: newValue) }
                                    }
                                )
                            )
                            .toggleStyle(.switch)
                            .disabled(viewModel.isLoading)
                        }
                        .padding(.vertical, 4)

                        if profile.id != viewModel.snapshot.oauthProfiles.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var oauthLoginCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("OAuth Login")
                    .font(.title3.weight(.semibold))

                Text("SurProxy delegates provider login to CLIProxyAPIPlus. Starting a login opens the upstream authorization URL in your browser, then SurProxy polls the management API and refreshes local state when the auth file is ready.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    ForEach(OAuthLoginProvider.allCases) { provider in
                        if provider == .codex {
                            Button(buttonTitle(for: provider)) {
                                viewModel.startOAuthLogin(provider: provider)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isLoading)
                        } else {
                            Button(buttonTitle(for: provider)) {
                                viewModel.startOAuthLogin(provider: provider)
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isLoading)
                        }
                    }
                }

                if let provider = viewModel.oauthInFlightProvider {
                    Text("\(provider.title) login is waiting for CLIProxyAPIPlus OAuth completion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var providerCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Provider Routing")
                    .font(.title3.weight(.semibold))

                if viewModel.snapshot.providers.isEmpty {
                    Text("No provider routing data has been loaded yet. Once CLIProxyAPIPlus returns config through the management API, SurProxy will show the discovered provider groups here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.snapshot.providers.enumerated()), id: \.element.id) { _, provider in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.name)
                                    .font(.headline)
                                Text(provider.baseURL)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("\(provider.modelCount) models discovered")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 6) {
                                Text(provider.isEnabled ? "Observed" : "Disabled")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(provider.isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))

                                if !provider.isEditable {
                                    Text("Read-only")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if provider.id != viewModel.snapshot.providers.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var runtimeIcon: String {
        switch viewModel.snapshot.runtimeState {
        case .running:
            return "play.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .degraded:
            return "exclamationmark.triangle.fill"
        }
    }

    private var runtimeTint: Color {
        switch viewModel.snapshot.runtimeState {
        case .running:
            return .green
        case .stopped:
            return .secondary
        case .degraded:
            return .orange
        }
    }

    private var validOAuthCount: Int {
        viewModel.snapshot.oauthProfiles.filter(\.isValid).count
    }

    private func buttonTitle(for provider: OAuthLoginProvider) -> String {
        if viewModel.oauthInFlightProvider == provider {
            return "Waiting for \(provider.title)"
        }
        return "Login \(provider.title)"
    }
}
