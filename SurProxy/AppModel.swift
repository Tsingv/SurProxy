//
//  AppModel.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation

enum ProxyRuntimeState: String, CaseIterable, Identifiable {
    case running
    case stopped
    case degraded

    var id: String { rawValue }

    var title: String {
        switch self {
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
    let id: UUID
    var name: String
    var baseURL: String
    var modelCount: Int
    var isEnabled: Bool
    var isEditable: Bool
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
            oauthProfiles: [],
            providers: []
        )
    }
}
