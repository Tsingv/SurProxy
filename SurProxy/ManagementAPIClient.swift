//
//  ManagementAPIClient.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation

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

final class ManagementAPIClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 4
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
            body: nil
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

    func healthCheck(baseURL: URL, key: String) async -> Bool {
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
        body: Data?
    ) async throws -> T {
        let data = try await requestData(
            baseURL: baseURL,
            path: path,
            queryItems: queryItems,
            key: key,
            method: method,
            body: body
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
        body: Data?
    ) async throws -> Data {
        let url = try makeURL(baseURL: baseURL, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func stringDictionary(_ raw: Any?) -> [String: String]? {
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
