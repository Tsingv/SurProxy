//
//  RuntimeManifest.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation

struct RuntimeManifest: Codable {
    var activeVersion: String
    var source: RuntimeBinarySource
    var installedAt: Date
    var activeBinaryPath: String
    var bundledBinaryPath: String?
    var managementKey: String
    var port: Int
    var authDirectoryPath: String

    enum CodingKeys: String, CodingKey {
        case activeVersion
        case source
        case installedAt
        case activeBinaryPath
        case bundledBinaryPath
        case managementKey
        case port
        case authDirectoryPath
    }

    init(
        activeVersion: String,
        source: RuntimeBinarySource,
        installedAt: Date,
        activeBinaryPath: String,
        bundledBinaryPath: String?,
        managementKey: String,
        port: Int,
        authDirectoryPath: String
    ) {
        self.activeVersion = activeVersion
        self.source = source
        self.installedAt = installedAt
        self.activeBinaryPath = activeBinaryPath
        self.bundledBinaryPath = bundledBinaryPath
        self.managementKey = managementKey
        self.port = port
        self.authDirectoryPath = authDirectoryPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeVersion = try container.decode(String.self, forKey: .activeVersion)
        source = try container.decode(RuntimeBinarySource.self, forKey: .source)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        activeBinaryPath = try container.decode(String.self, forKey: .activeBinaryPath)
        bundledBinaryPath = try container.decodeIfPresent(String.self, forKey: .bundledBinaryPath)
        managementKey = try container.decode(String.self, forKey: .managementKey)
        port = try container.decode(Int.self, forKey: .port)
        authDirectoryPath = try container.decodeIfPresent(String.self, forKey: .authDirectoryPath)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api", isDirectory: true).path
    }

    static func bootstrap(paths: RuntimePaths, managementKey: String, port: Int) -> RuntimeManifest {
        RuntimeManifest(
            activeVersion: "bundled-dev",
            source: .bundled,
            installedAt: .now,
            activeBinaryPath: paths.activeBinary.path,
            bundledBinaryPath: paths.bundledBinary?.path,
            managementKey: managementKey,
            port: port,
            authDirectoryPath: paths.authDirectory.path
        )
    }
}
