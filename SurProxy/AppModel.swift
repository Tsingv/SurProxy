//
//  AppModel.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation

enum ProxyRuntimeState: String, CaseIterable, Identifiable {
    case starting
    case stopping
    case running
    case stopped
    case degraded

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .starting:
            return "Starting"
        case .stopping:
            return "Stopping"
        case .running:
            return "Running"
        case .stopped:
            return "Stopped"
        case .degraded:
            return "Degraded"
        }
    }
}

struct OAuthProfile: Identifiable, Hashable {
    let id: UUID
    var provider: String
    var displayName: String
    var fileName: String
    var isValid: Bool
    var isActive: Bool
    var statusDescription: String
    var detailDescription: String
    var email: String?
    var account: String?
    var note: String?
    var models: [AvailableModel]
}

struct AvailableModel: Identifiable, Hashable {
    let id: String
    var displayName: String?
    var type: String?
    var ownedBy: String?

    var subtitle: String {
        var parts: [String] = []
        if let displayName, !displayName.isEmpty, displayName != id {
            parts.append(displayName)
        }
        if let type, !type.isEmpty {
            parts.append(type)
        }
        if let ownedBy, !ownedBy.isEmpty {
            parts.append(ownedBy)
        }
        return parts.joined(separator: " · ")
    }
}

enum OAuthLoginProvider: String, CaseIterable, Identifiable {
    case codex
    case anthropic
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        }
    }

    var managementPath: String {
        switch self {
        case .codex:
            return "codex-auth-url"
        case .anthropic:
            return "anthropic-auth-url"
        case .gemini:
            return "gemini-cli-auth-url"
        }
    }
}

struct OAuthLoginSession {
    var provider: OAuthLoginProvider
    var authURL: String
    var state: String
}

struct ProviderRoute: Identifiable, Hashable {
    let id: String
    var stableKey: String
    var name: String
    var kindTitle: String
    var baseURL: String
    var modelCount: Int
    var isEnabled: Bool
    var isEditable: Bool
    var canRename: Bool
    var configKey: String
    var entryIndex: Int
    var selectedModels: Set<String>
    var models: [ProviderModel]
}

struct ProviderModel: Identifiable, Hashable {
    let id: String
    var displayName: String?
    var type: String?
    var ownedBy: String?
    var isEnabled: Bool
    var isDeprecated: Bool

    var subtitle: String {
        var parts: [String] = []
        if let displayName, !displayName.isEmpty, displayName != id {
            parts.append(displayName)
        }
        if let type, !type.isEmpty {
            parts.append(type)
        }
        if let ownedBy, !ownedBy.isEmpty {
            parts.append(ownedBy)
        }
        return parts.joined(separator: " · ")
    }
}

enum ProviderConfigurationKind: String, CaseIterable, Identifiable {
    case openAICompatibility = "openai-compatibility"
    case geminiAPIKey = "gemini-api-key"
    case claudeAPIKey = "claude-api-key"
    case codexAPIKey = "codex-api-key"
    case vertexAPIKey = "vertex-api-key"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatibility:
            return "OpenAI Compatibility"
        case .geminiAPIKey:
            return "Gemini API Key"
        case .claudeAPIKey:
            return "Claude API Key"
        case .codexAPIKey:
            return "Codex API Key"
        case .vertexAPIKey:
            return "Vertex API Key"
        }
    }

    nonisolated var configKey: String { rawValue }

    nonisolated var defaultBaseURL: String {
        switch self {
        case .openAICompatibility:
            return "https://api.openai.com/v1"
        case .geminiAPIKey:
            return "https://generativelanguage.googleapis.com"
        case .claudeAPIKey:
            return "https://api.anthropic.com"
        case .codexAPIKey:
            return "https://api.openai.com/v1"
        case .vertexAPIKey:
            return "https://aiplatform.googleapis.com"
        }
    }

    nonisolated var defaultModelName: String {
        switch self {
        case .openAICompatibility:
            return "gpt-4.1"
        case .geminiAPIKey:
            return "gemini-2.5-pro"
        case .claudeAPIKey:
            return "claude-sonnet-4-20250514"
        case .codexAPIKey:
            return "gpt-5-codex"
        case .vertexAPIKey:
            return "gemini-2.5-pro"
        }
    }

    nonisolated var supportsProviderName: Bool {
        switch self {
        case .openAICompatibility:
            return true
        case .geminiAPIKey, .claudeAPIKey, .codexAPIKey, .vertexAPIKey:
            return false
        }
    }
}

struct ProviderDraft {
    var kind: ProviderConfigurationKind = .openAICompatibility
    var providerName: String = ""
    var baseURL: String = ProviderConfigurationKind.openAICompatibility.defaultBaseURL
    var apiKey: String = ""
    var modelName: String = ProviderConfigurationKind.openAICompatibility.defaultModelName
    var modelAlias: String = ProviderConfigurationKind.openAICompatibility.defaultModelName

    mutating func applyKindDefaults() {
        baseURL = kind.defaultBaseURL
        modelName = kind.defaultModelName
        if modelAlias.isEmpty || modelAlias == providerName {
            modelAlias = kind.defaultModelName
        }
        if !kind.supportsProviderName {
            providerName = ""
        }
    }
}

struct ProviderDraftValidation {
    var providerName: String?
    var baseURL: String?
    var apiKey: String?
    var modelName: String?
    var modelAlias: String?

    var hasAnyError: Bool {
        providerName != nil || baseURL != nil || apiKey != nil || modelName != nil || modelAlias != nil
    }
}

struct PendingOAuthDeletion: Identifiable {
    let id: UUID
    let profileID: UUID
    let displayName: String
}

struct PendingProviderDeletion: Identifiable {
    let id: String
    let stableKey: String
    let displayName: String
}

enum PendingDeletionConfirmation: Identifiable {
    case oauth(PendingOAuthDeletion)
    case provider(PendingProviderDeletion)

    var id: String {
        switch self {
        case .oauth(let value):
            return "oauth:\(value.id.uuidString)"
        case .provider(let value):
            return "provider:\(value.id)"
        }
    }

    var title: String {
        switch self {
        case .oauth:
            return "Delete OAuth File?"
        case .provider:
            return "Delete Provider?"
        }
    }

    var message: String {
        switch self {
        case .oauth(let value):
            return "This will remove \(value.displayName) from CLIProxyAPIPlus auth storage."
        case .provider(let value):
            return "This will delete \(value.displayName) from CLIProxyAPIPlus config."
        }
    }
}

enum RuntimeBinarySource: String, CaseIterable, Identifiable, Codable {
    case bundled
    case downloaded
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundled:
            return "Bundled"
        case .downloaded:
            return "Downloaded"
        case .custom:
            return "Custom"
        }
    }
}

struct RuntimeBinaryStatus {
    var currentVersion: String
    var latestVersion: String?
    var source: RuntimeBinarySource
    var bundledBinaryPath: String
    var activeBinaryPath: String
    var releaseFeedURL: String
    var canSelfUpdate: Bool
}

struct ProxyStatusSnapshot {
    var runtimeState: ProxyRuntimeState
    var endpoint: String
    var activePort: Int
    var configPath: String
    var oauthDirectory: String
    var binary: RuntimeBinaryStatus
    var managementBaseURL: String
    var managementAPIDisabled: Bool
    var existingRuntimeDetected: Bool
    var runtimeNotice: String?
    var oauthProfiles: [OAuthProfile]
    var providers: [ProviderRoute]

    static func bootstrap() -> ProxyStatusSnapshot {
        ProxyStatusSnapshot(
            runtimeState: .stopped,
            endpoint: "http://127.0.0.1:8787",
            activePort: 8787,
            configPath: "~/.cli-proxy-api/config.yaml",
            oauthDirectory: "~/.cli-proxy-api",
            binary: RuntimeBinaryStatus(
                currentVersion: "bundled-dev",
                latestVersion: nil,
                source: .bundled,
                bundledBinaryPath: "SurProxy.app/Contents/Resources/cliproxyapiplus",
                activeBinaryPath: "~/Library/Application Support/SurProxy/runtime/cliproxyapiplus",
                releaseFeedURL: "https://api.github.com/repos/router-for-me/CLIProxyAPIPlus/releases/latest",
                canSelfUpdate: true
            ),
            managementBaseURL: "http://127.0.0.1:8787/v0/management",
            managementAPIDisabled: false,
            existingRuntimeDetected: false,
            runtimeNotice: nil,
            oauthProfiles: [],
            providers: []
        )
    }
}
