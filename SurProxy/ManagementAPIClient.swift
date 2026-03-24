//
//  ManagementAPIClient.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation
import Darwin

struct ManagementAuthFile {
    let id: String?
    let name: String?
    let provider: String?
    let type: String?
    let label: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool?
    let unavailable: Bool?
    let authIndex: Int?
    let email: String?
    let accountType: String?
    let account: String?
    let source: String?
    let note: String?
    let priority: Int?
    let path: String?
    let runtimeOnly: Bool?
    let size: Int64?
    let createdAt: String?
    let modtime: String?
    let updatedAt: String?
    let lastRefresh: String?
    let nextRetryAfter: String?
    let idToken: [String: String]?
    let fields: [String: String]?
}

struct ManagementOAuthStartResponse: Decodable {
    let status: String?
    let url: String?
    let state: String?
}

struct ManagementOAuthStatusResponse: Decodable {
    let status: String?
    let error: String?
    let url: String?
}

struct ManagementAuthFileModel: Decodable {
    let id: String
    let displayName: String?
    let type: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case type
        case ownedBy = "owned_by"
    }
}

struct ManagementStaticModelDefinitionsResponse: Decodable {
    let channel: String
    let models: [ManagementAuthFileModel]
}

struct ManagementProviderEntry {
    let name: String?
    let baseURL: String?
    let apiKey: String?
    let headers: [String: String]
    let configuredModels: [ManagementAuthFileModel]
    let rawObject: [String: Any]
}

final class ManagementAPIClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 4
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func latestVersion(baseURL: URL, key: String) async throws -> String? {
        struct Response: Decodable {
            let latestVersion: String?

            enum CodingKeys: String, CodingKey {
                case latestVersion = "latest-version"
            }
        }

        let response: Response = try await request(
            baseURL: baseURL,
            path: "latest-version",
            queryItems: [],
            key: key,
            method: "GET",
            body: nil,
            timeoutInterval: 15
        )
        return response.latestVersion
    }

    func authFiles(baseURL: URL, key: String) async throws -> [ManagementAuthFile] {
        let data = try await requestData(
            baseURL: baseURL,
            path: "auth-files",
            queryItems: [],
            key: key,
            method: "GET",
            body: nil
        )
        let object = try JSONSerialization.jsonObject(with: data)
        guard let wrapper = object as? [String: Any], let files = wrapper["files"] as? [[String: Any]] else {
            return []
        }
        return files.map(Self.parseAuthFile)
    }

    func startOAuth(baseURL: URL, key: String, provider: OAuthLoginProvider) async throws -> ManagementOAuthStartResponse {
        try await request(
            baseURL: baseURL,
            path: provider.managementPath,
            queryItems: [URLQueryItem(name: "is_webui", value: "true")],
            key: key,
            method: "GET",
            body: nil
        )
    }

    func authStatus(baseURL: URL, key: String, state: String) async throws -> ManagementOAuthStatusResponse {
        try await request(
            baseURL: baseURL,
            path: "get-auth-status",
            queryItems: [URLQueryItem(name: "state", value: state)],
            key: key,
            method: "GET",
            body: nil
        )
    }

    func authFileModels(baseURL: URL, key: String, name: String) async throws -> [ManagementAuthFileModel] {
        struct Response: Decodable {
            let models: [ManagementAuthFileModel]
        }

        let response: Response = try await request(
            baseURL: baseURL,
            path: "auth-files/models",
            queryItems: [URLQueryItem(name: "name", value: name)],
            key: key,
            method: "GET",
            body: nil
        )
        return response.models
    }

    func staticModelDefinitions(baseURL: URL, key: String, channel: String) async throws -> [ManagementAuthFileModel] {
        let response: ManagementStaticModelDefinitionsResponse = try await request(
            baseURL: baseURL,
            path: "model-definitions/\(channel)",
            queryItems: [],
            key: key,
            method: "GET",
            body: nil
        )
        return response.models
    }

    func providerEntries(baseURL: URL, key: String, configKey: String) async throws -> [ManagementProviderEntry] {
        let data = try await requestData(
            baseURL: baseURL,
            path: configKey,
            queryItems: [],
            key: key,
            method: "GET",
            body: nil
        )
        let object = try JSONSerialization.jsonObject(with: data)
        guard let wrapper = object as? [String: Any], let items = wrapper[configKey] as? [[String: Any]] else {
            return []
        }
        return items.map(Self.parseProviderEntry)
    }

    func putProviderEntries(baseURL: URL, key: String, configKey: String, entries: [[String: Any]]) async throws {
        let body = try JSONSerialization.data(withJSONObject: entries)
        let _: EmptyResponse = try await request(
            baseURL: baseURL,
            path: configKey,
            queryItems: [],
            key: key,
            method: "PUT",
            body: body
        )
    }

    func patchProviderEntry(baseURL: URL, key: String, configKey: String, index: Int, value: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "index": index,
            "value": value
        ])
        let _: EmptyResponse = try await request(
            baseURL: baseURL,
            path: configKey,
            queryItems: [],
            key: key,
            method: "PATCH",
            body: body
        )
    }

    func patchProviderModels(baseURL: URL, key: String, configKey: String, index: Int, models: [[String: Any]]) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "index": index,
            "value": [
                "models": models
            ]
        ])
        let _: EmptyResponse = try await request(
            baseURL: baseURL,
            path: configKey,
            queryItems: [],
            key: key,
            method: "PATCH",
            body: body
        )
    }

    func fetchOfficialProviderModels(configKey: String, entry: ManagementProviderEntry) async throws -> [ManagementAuthFileModel] {
        guard let baseURLString = entry.baseURL, let baseURL = URL(string: baseURLString) else {
            return []
        }

        switch configKey {
        case "openai-compatibility", "codex-api-key":
            return try await fetchOpenAIStyleModels(baseURL: baseURL, bearerToken: entry.apiKey, extraHeaders: entry.headers)
        case "claude-api-key":
            return try await fetchClaudeModels(baseURL: baseURL, apiKey: entry.apiKey, extraHeaders: entry.headers)
        case "gemini-api-key":
            return try await fetchGeminiModels(baseURL: baseURL, apiKey: entry.apiKey, extraHeaders: entry.headers)
        default:
            return []
        }
    }

    func toggleAuthFile(baseURL: URL, key: String, name: String, disabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "disabled": disabled])
        let _: EmptyResponse = try await request(
            baseURL: baseURL,
            path: "auth-files/status",
            queryItems: [],
            key: key,
            method: "PATCH",
            body: body
        )
    }

    func deleteAuthFile(baseURL: URL, key: String, name: String) async throws {
        let _: EmptyResponse = try await request(
            baseURL: baseURL,
            path: "auth-files",
            queryItems: [URLQueryItem(name: "name", value: name)],
            key: key,
            method: "DELETE",
            body: nil
        )
    }

    func deleteProviderEntry(baseURL: URL, key: String, configKey: String, index: Int) async throws {
        let _: EmptyResponse = try await request(
            baseURL: baseURL,
            path: configKey,
            queryItems: [URLQueryItem(name: "index", value: String(index))],
            key: key,
            method: "DELETE",
            body: nil
        )
    }

    func getConfig(baseURL: URL, key: String) async throws -> [String: Any] {
        let data = try await requestData(
            baseURL: baseURL,
            path: "config",
            queryItems: [],
            key: key,
            method: "GET",
            body: nil
        )
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    func getConfigYAML(baseURL: URL, key: String) async throws -> String {
        let data = try await requestData(
            baseURL: baseURL,
            path: "config.yaml",
            queryItems: [],
            key: key,
            method: "GET",
            body: nil
        )
        return String(decoding: data, as: UTF8.self)
    }

    func putConfigYAML(baseURL: URL, key: String, yaml: String) async throws {
        let data = Data(yaml.utf8)
        let _: EmptyResponse = try await request(
            baseURL: baseURL,
            path: "config.yaml",
            queryItems: [],
            key: key,
            method: "PUT",
            body: data,
            contentType: "application/yaml; charset=utf-8"
        )
    }

    func healthCheck(baseURL: URL, key: String) async -> Bool {
        guard isPortReachable(baseURL: baseURL) else {
            return false
        }
        do {
            let _: [String: Any] = try await getConfig(baseURL: baseURL, key: key)
            return true
        } catch {
            return false
        }
    }

    private func request<T: Decodable>(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem],
        key: String,
        method: String,
        body: Data?,
        contentType: String? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        let data = try await requestData(
            baseURL: baseURL,
            path: path,
            queryItems: queryItems,
            key: key,
            method: method,
            body: body,
            contentType: contentType,
            timeoutInterval: timeoutInterval
        )
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestData(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem],
        key: String,
        method: String,
        body: Data?,
        contentType: String? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Data {
        let url = try makeURL(baseURL: baseURL, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "SurProxy.ManagementAPI",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Management API request failed."]
            )
        }
        return data
    }

    private func makeURL(baseURL: URL, path: String, queryItems: [URLQueryItem]) throws -> URL {
        let pathURL = baseURL.appending(path: path)
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func isPortReachable(baseURL: URL) -> Bool {
        guard let host = baseURL.host, let port = baseURL.port else {
            return false
        }

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        if socketFD < 0 {
            return false
        }
        defer { close(socketFD) }

        var timeout = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)

        let conversionResult = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard conversionResult == 1 else {
            return false
        }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
            }
        }
    }

    nonisolated private static func parseProviderEntry(_ object: [String: Any]) -> ManagementProviderEntry {
        let name = trimmedStringValue(object["name"])
        let baseURL = trimmedStringValue(object["base-url"])
        let headers = stringDictionary(object["headers"]) ?? [:]
        let rawModels = object["models"] as? [[String: Any]] ?? []
        let configuredModels = rawModels.compactMap(parseProviderModel)
        let apiKeyEntries = object["api-key-entries"] as? [[String: Any]] ?? []
        let apiKey = trimmedStringValue(object["api-key"]) ?? apiKeyEntries.compactMap { trimmedStringValue($0["api-key"]) }.first

        return ManagementProviderEntry(
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            headers: headers,
            configuredModels: configuredModels,
            rawObject: object
        )
    }

    nonisolated private static func parseProviderModel(_ object: [String: Any]) -> ManagementAuthFileModel? {
        let upstreamName = trimmedStringValue(object["name"])
        let alias = trimmedStringValue(object["alias"])
        guard let id = upstreamName ?? alias else {
            return nil
        }
        return ManagementAuthFileModel(
            id: id,
            displayName: alias,
            type: trimmedStringValue(object["type"]),
            ownedBy: nil
        )
    }

    nonisolated private static func trimmedStringValue(_ raw: Any?) -> String? {
        guard let value = stringValue(raw) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fetchOpenAIStyleModels(baseURL: URL, bearerToken: String?, extraHeaders: [String: String]) async throws -> [ManagementAuthFileModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: String
                let ownedBy: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case ownedBy = "owned_by"
                }
            }

            let data: [Entry]
        }

        let requestURL = makeOpenAIModelsURL(from: baseURL)
        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.data.map { ManagementAuthFileModel(id: $0.id, displayName: nil, type: "model", ownedBy: $0.ownedBy) }
    }

    private func fetchClaudeModels(baseURL: URL, apiKey: String?, extraHeaders: [String: String]) async throws -> [ManagementAuthFileModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: String
                let displayName: String?
                let type: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                    case type
                }
            }

            let data: [Entry]
        }

        let requestURL = makeClaudeModelsURL(from: baseURL)
        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.data.map { ManagementAuthFileModel(id: $0.id, displayName: $0.displayName, type: $0.type, ownedBy: "Anthropic") }
    }

    private func fetchGeminiModels(baseURL: URL, apiKey: String?, extraHeaders: [String: String]) async throws -> [ManagementAuthFileModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let name: String
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case name
                    case displayName = "displayName"
                }
            }

            let models: [Entry]
        }

        guard let apiKey, !apiKey.isEmpty else {
            return []
        }

        guard var components = URLComponents(url: makeGeminiModelsURL(from: baseURL), resolvingAgainstBaseURL: false) else {
            return []
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
        guard let requestURL = components.url else {
            return []
        }

        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.models.map {
            let modelID = $0.name.replacingOccurrences(of: "models/", with: "")
            return ManagementAuthFileModel(id: modelID, displayName: $0.displayName, type: "model", ownedBy: "Google")
        }
    }

    private func makeOpenAIModelsURL(from baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("models") {
            return baseURL
        }
        if normalizedPath.hasSuffix("v1") {
            return baseURL.appendingPathComponent("models")
        }
        return baseURL.appendingPathComponent("v1").appendingPathComponent("models")
    }

    private func makeClaudeModelsURL(from baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("models") {
            return baseURL
        }
        if normalizedPath.hasSuffix("v1") {
            return baseURL.appendingPathComponent("models")
        }
        return baseURL.appendingPathComponent("v1").appendingPathComponent("models")
    }

    private func makeGeminiModelsURL(from baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("models") {
            return baseURL
        }
        if normalizedPath.contains("v1beta") || normalizedPath.contains("v1") {
            return baseURL.appendingPathComponent("models")
        }
        return baseURL.appendingPathComponent("v1beta").appendingPathComponent("models")
    }

    private static func parseAuthFile(_ payload: [String: Any]) -> ManagementAuthFile {
        let fieldsPayload = payload["fields"] as? [String: Any]
        let fields = fieldsPayload?.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            } else if let number = entry.value as? NSNumber {
                result[entry.key] = number.stringValue
            } else if !(entry.value is NSNull) {
                result[entry.key] = String(describing: entry.value)
            }
        }

        return ManagementAuthFile(
            id: payload["id"] as? String,
            name: payload["name"] as? String,
            provider: payload["provider"] as? String,
            type: payload["type"] as? String,
            label: payload["label"] as? String,
            status: payload["status"] as? String,
            statusMessage: payload["status_message"] as? String,
            disabled: payload["disabled"] as? Bool,
            unavailable: payload["unavailable"] as? Bool,
            authIndex: intValue(payload["auth_index"]),
            email: payload["email"] as? String,
            accountType: payload["account_type"] as? String,
            account: payload["account"] as? String,
            source: payload["source"] as? String,
            note: payload["note"] as? String,
            priority: intValue(payload["priority"]),
            path: payload["path"] as? String,
            runtimeOnly: payload["runtime_only"] as? Bool,
            size: int64Value(payload["size"]),
            createdAt: stringValue(payload["created_at"]),
            modtime: stringValue(payload["modtime"]),
            updatedAt: stringValue(payload["updated_at"]),
            lastRefresh: stringValue(payload["last_refresh"]),
            nextRetryAfter: stringValue(payload["next_retry_after"]),
            idToken: stringDictionary(payload["id_token"]),
            fields: fields
        )
    }

    private static func intValue(_ raw: Any?) -> Int? {
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

    private static func int64Value(_ raw: Any?) -> Int64? {
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

    nonisolated private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    nonisolated private static func stringDictionary(_ raw: Any?) -> [String: String]? {
        guard let payload = raw as? [String: Any] else {
            return nil
        }
        return payload.reduce(into: [String: String]()) { result, entry in
            if let value = stringValue(entry.value) {
                result[entry.key] = value
            }
        }
    }

}

private struct EmptyResponse: Decodable {}
