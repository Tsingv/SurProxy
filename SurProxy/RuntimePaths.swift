//
//  RuntimePaths.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation

struct RuntimePaths {
    let appSupportDirectory: URL
    let runtimeDirectory: URL
    let authDirectory: URL
    let configFile: URL
    let manifestFile: URL
    let bundledBinary: URL?
    let activeBinary: URL

    static func resolve(fileManager: FileManager = .default) throws -> RuntimePaths {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appSupportDirectory = appSupportRoot.appendingPathComponent("SurProxy", isDirectory: true)
        let runtimeDirectory = appSupportDirectory.appendingPathComponent("runtime", isDirectory: true)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let authDirectory = homeDirectory.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        let configFile = appSupportDirectory.appendingPathComponent("config.yaml")
        let manifestFile = appSupportDirectory.appendingPathComponent("runtime-manifest.json")
        let activeBinary = runtimeDirectory.appendingPathComponent("cliproxyapiplus")

        let resourceURL = Bundle.main.resourceURL
        let nestedBundledBinary = resourceURL?
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("cliproxyapiplus")
        let rootBundledBinary = resourceURL?
            .appendingPathComponent("cliproxyapiplus")
        let bundledBinary: URL?

        if let nestedBundledBinary, fileManager.fileExists(atPath: nestedBundledBinary.path) {
            bundledBinary = nestedBundledBinary
        } else {
            bundledBinary = rootBundledBinary
        }

        return RuntimePaths(
            appSupportDirectory: appSupportDirectory,
            runtimeDirectory: runtimeDirectory,
            authDirectory: authDirectory,
            configFile: configFile,
            manifestFile: manifestFile,
            bundledBinary: bundledBinary,
            activeBinary: activeBinary
        )
    }
}
