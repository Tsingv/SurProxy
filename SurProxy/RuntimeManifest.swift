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

    static func bootstrap(paths: RuntimePaths, managementKey: String, port: Int) -> RuntimeManifest {
        RuntimeManifest(
            activeVersion: "bundled-dev",
            source: .bundled,
            installedAt: .now,
            activeBinaryPath: paths.activeBinary.path,
            bundledBinaryPath: paths.bundledBinary?.path,
            managementKey: managementKey,
            port: port
        )
    }
}
