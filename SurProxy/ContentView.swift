//
//  ContentView.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import SwiftUI

private enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case status
    case oauth
    case providers
    case apiKeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:
            return "Status"
        case .oauth:
            return "OAuth"
        case .providers:
            return "Provider"
        case .apiKeys:
            return "API Keys"
        }
    }

    var icon: String {
        switch self {
        case .status:
            return "waveform.path.ecg"
        case .oauth:
            return "person.badge.key"
        case .providers:
            return "point.3.connected.trianglepath.dotted"
        case .apiKeys:
            return "key.horizontal"
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var expandedModelGroups: Set<UUID> = []
    @State private var expandedProviderModelGroups: Set<String> = []
    @State private var selectedSection: SidebarSection? = .status

    var body: some View {
        ZStack {
            NavigationSplitView {
                List(SidebarSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
                .navigationTitle("SurProxy")
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedSection ?? .status {
                        case .status:
                            runtimeCard
                            runtimeBinaryCard
                        case .oauth:
                            oauthLoginCard
                            oauthCard
                        case .providers:
                            providerCard
                        case .apiKeys:
                            apiKeysCard
                        }
                    }
                    .padding(24)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            if viewModel.isLoading {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if let providerSaveNotice = viewModel.providerSaveNotice {
                VStack {
                    Spacer()
                    Text(providerSaveNotice)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert(item: Binding(
            get: { viewModel.pendingDeletionConfirmation },
            set: { viewModel.pendingDeletionConfirmation = $0 }
        )) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await viewModel.deleteConfirmedItem(item) }
                },
                secondaryButton: .cancel {
                    viewModel.pendingDeletionConfirmation = nil
                }
            )
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
                    Button(runtimeActionTitle) {
                        Task { await viewModel.toggleProxy() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoading || isRuntimeTransitioning)

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
                LabeledContent("OAuth Files", value: "\(validOAuthCount) valid / \(viewModel.snapshot.oauthProfiles.count) total")
                if let runtimeNotice = viewModel.snapshot.runtimeNotice {
                    Text(runtimeNotice)
                        .foregroundStyle(.orange)
                }
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
                LabeledContent("Bundled Binary", value: viewModel.snapshot.binary.bundledBinaryPath)
                LabeledContent("Active Binary", value: viewModel.snapshot.binary.activeBinaryPath)
                LabeledContent("Config", value: viewModel.snapshot.configPath)
                LabeledContent("OAuth Directory", value: viewModel.snapshot.oauthDirectory)
                LabeledContent("Release Feed", value: viewModel.snapshot.binary.releaseFeedURL)
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

    private var oauthCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("OAuth Files")
                    .font(.title3.weight(.semibold))

                if let lastErrorMessage = viewModel.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if viewModel.snapshot.oauthProfiles.isEmpty {
                    Text("No OAuth files detected yet. Start a provider login above and CLIProxyAPIPlus will create the auth file in its managed auth directory.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(viewModel.snapshot.oauthProfiles) { profile in
                            oauthProfileCard(profile)
                        }
                    }
                }
            }
        }
    }

    private func oauthProfileCard(_ profile: OAuthProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

                Spacer(minLength: 8)

                Toggle(
                    profile.isActive ? "Active" : "Disabled",
                    isOn: Binding(
                        get: { profile.isActive },
                        set: { newValue in
                            Task { await viewModel.setOAuthProfile(id: profile.id, isActive: newValue) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(viewModel.isLoading)

                Button(role: .destructive) {
                    viewModel.confirmDeleteOAuth(id: profile.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isLoading)
            }

            if !profile.models.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedModelGroups.contains(profile.id) },
                        set: { isExpanded in
                            if isExpanded {
                                expandedModelGroups.insert(profile.id)
                            } else {
                                expandedModelGroups.remove(profile.id)
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(profile.models) { model in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.id)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                    if !model.subtitle.isEmpty {
                                        Text(model.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 8)

                                Button("Copy") {
                                    viewModel.copyModelID(model.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(viewModel.isLoading)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Available Models (\(profile.models.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var providerCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Provider Routing")
                    .font(.title3.weight(.semibold))

                if let lastErrorMessage = viewModel.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if viewModel.snapshot.providers.isEmpty {
                    Text("No provider configuration exists yet. Add a provider below and SurProxy will write it into CLIProxyAPIPlus config.yaml, then show the discovered routing groups here.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(viewModel.snapshot.providers) { provider in
                            providerRouteCard(provider)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Pending changes are saved together into CLIProxyAPIPlus config.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Provider Changes") {
                            Task { await viewModel.saveProviderChanges() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isLoading || !viewModel.hasPendingProviderChanges)
                    }

                    Text("Add Provider")
                        .font(.headline)

                    Picker("Type", selection: Binding(
                        get: { viewModel.providerDraft.kind },
                        set: { viewModel.setProviderKind($0) }
                    )) {
                        ForEach(ProviderConfigurationKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    if viewModel.providerDraft.kind.supportsProviderName {
                        TextField("Provider Name", text: $viewModel.providerDraft.providerName)
                            .textFieldStyle(.roundedBorder)
                        if let message = viewModel.providerDraftValidation.providerName {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    TextField("Base URL", text: $viewModel.providerDraft.baseURL)
                        .textFieldStyle(.roundedBorder)
                    if let message = viewModel.providerDraftValidation.baseURL {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    SecureField("API Key", text: $viewModel.providerDraft.apiKey)
                        .textFieldStyle(.roundedBorder)
                    if let message = viewModel.providerDraftValidation.apiKey {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    TextField("Upstream Model Name", text: $viewModel.providerDraft.modelName)
                        .textFieldStyle(.roundedBorder)
                    if let message = viewModel.providerDraftValidation.modelName {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    TextField("Client Model Alias", text: $viewModel.providerDraft.modelAlias)
                        .textFieldStyle(.roundedBorder)
                    if let message = viewModel.providerDraftValidation.modelAlias {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Add Provider") {
                            Task { await viewModel.addProvider() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isLoading)
                    }
                }
            }
        }
    }

    private var apiKeysCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("API Keys")
                    .font(.title3.weight(.semibold))

                Text("These keys are served by CLIProxyAPIPlus for downstream applications calling your local proxy.")
                    .foregroundStyle(.secondary)

                if let lastErrorMessage = viewModel.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    TextField("New API Key", text: $viewModel.apiKeyDraft)
                        .textFieldStyle(.roundedBorder)

                    Button("Add API Key") {
                        Task { await viewModel.addAPIKey() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoading || viewModel.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if viewModel.snapshot.apiKeys.isEmpty {
                    Text("No downstream API keys configured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.snapshot.apiKeys) { entry in
                            HStack(spacing: 12) {
                                Text(entry.value)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)

                                Spacer(minLength: 8)

                                Button("Copy") {
                                    viewModel.copyAPIKey(entry.value)
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) {
                                    viewModel.confirmDeleteAPIKey(entry.value)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(viewModel.isLoading)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var validOAuthCount: Int {
        viewModel.snapshot.oauthProfiles.filter(\.isValid).count
    }

    private func providerRouteCard(_ provider: ProviderRoute) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if provider.canRename {
                        HStack(spacing: 8) {
                            TextField(
                                "Provider Name",
                                text: Binding(
                                    get: { viewModel.providerNameDrafts[provider.stableKey] ?? provider.name },
                                    set: { viewModel.setProviderNameDraft(stableKey: provider.stableKey, value: $0) }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.headline)

                            Button("Save Name") {
                                Task { await viewModel.saveProviderName(stableKey: provider.stableKey) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(
                                viewModel.isLoading ||
                                (viewModel.providerNameDrafts[provider.stableKey] ?? provider.name)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty ||
                                (viewModel.providerNameDrafts[provider.stableKey] ?? provider.name)
                                    .trimmingCharacters(in: .whitespacesAndNewlines) == provider.name
                            )
                        }
                    } else {
                        Text(provider.name)
                            .font(.headline)
                    }
                    Text(provider.kindTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(provider.baseURL)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(provider.modelCount) models discovered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(provider.isEnabled ? "Observed" : "Disabled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(provider.isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))

                    if !provider.isEditable {
                        Text("Read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        viewModel.confirmDeleteProvider(stableKey: provider.stableKey)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isLoading)
                }
            }

            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedProviderModelGroups.contains(provider.id) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedProviderModelGroups.insert(provider.id)
                            viewModel.loadProviderModels(stableKey: provider.stableKey)
                        } else {
                            expandedProviderModelGroups.remove(provider.id)
                        }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    if viewModel.providerModelLoadingKeys.contains(provider.stableKey) {
                        ProgressView()
                            .controlSize(.small)
                    } else if provider.models.isEmpty {
                        Text("No models loaded yet. Expand to refresh the live model list for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(provider.models) { model in
                        HStack(spacing: 8) {
                            Toggle(
                                isOn: Binding(
                                    get: { provider.selectedModels.contains(model.id) },
                                    set: { newValue in
                                        Task { await viewModel.setProviderModel(providerID: provider.id, modelID: model.id, isEnabled: newValue) }
                                    }
                                )
                            ) {
                                EmptyView()
                            }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(viewModel.isLoading)

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(model.id)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                    if model.isDeprecated {
                                        Text("Deprecated")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.14))
                                            .clipShape(Capsule())
                                    }
                                }
                                if !model.subtitle.isEmpty {
                                    Text(model.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 8)

                            Button("Copy") {
                                viewModel.copyModelID(model.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(viewModel.isLoading)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Available Models (\(provider.models.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var runtimeIcon: String {
        switch viewModel.snapshot.runtimeState {
        case .starting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .stopping:
            return "arrow.triangle.2.circlepath.circle"
        case .running:
            return "play.circle.fill"
        case .stopped:
            return "stop.circle"
        case .degraded:
            return "exclamationmark.triangle.fill"
        }
    }

    private var runtimeTint: Color {
        switch viewModel.snapshot.runtimeState {
        case .starting:
            return .blue
        case .stopping:
            return .orange
        case .running:
            return .green
        case .stopped:
            return .secondary
        case .degraded:
            return .orange
        }
    }

    private func buttonTitle(for provider: OAuthLoginProvider) -> String {
        "Login \(provider.title)"
    }

    private var runtimeActionTitle: String {
        switch viewModel.snapshot.runtimeState {
        case .running, .starting:
            return "Stop"
        case .stopped, .stopping, .degraded:
            return "Start"
        }
    }

    private var isRuntimeTransitioning: Bool {
        switch viewModel.snapshot.runtimeState {
        case .starting, .stopping:
            return true
        case .running, .stopped, .degraded:
            return false
        }
    }
}
