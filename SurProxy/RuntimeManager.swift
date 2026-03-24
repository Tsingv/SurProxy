//
//  RuntimeManager.swift
//  SurProxy
//
//  Created by clearain on 2026/3/24.
//

import Foundation

enum RuntimeManagerError: LocalizedError {
    case bundledBinaryMissing
    case activeBinaryMissing
    case runtimeExited(String)

    var errorDescription: String? {
        switch self {
        case .bundledBinaryMissing:
            return "Bundled CLIProxyAPIPlus binary is missing. Add a compiled release binary to the app resources."
        case .activeBinaryMissing:
            return "Active CLIProxyAPIPlus runtime binary is missing."
        case .runtimeExited(let message):
            return message
        }
    }
}

final class RuntimeManager {
    private let fileManager: FileManager
    private var process: Process?
    private var outputPipe: Pipe?
    private var capturedLog = ""

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepareRuntime(paths: RuntimePaths, manifest: RuntimeManifest) throws -> RuntimeManifest {
        try fileManager.createDirectory(at: paths.appSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.runtimeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)

        var nextManifest = manifest

        if !fileManager.fileExists(atPath: paths.activeBinary.path) {
            guard let bundledBinary = paths.bundledBinary, fileManager.fileExists(atPath: bundledBinary.path) else {
                throw RuntimeManagerError.bundledBinaryMissing
            }

            if fileManager.fileExists(atPath: paths.activeBinary.path) {
                try fileManager.removeItem(at: paths.activeBinary)
            }
            try fileManager.copyItem(at: bundledBinary, to: paths.activeBinary)
            try makeExecutable(at: paths.activeBinary)
            nextManifest.activeBinaryPath = paths.activeBinary.path
            nextManifest.bundledBinaryPath = bundledBinary.path
            nextManifest.installedAt = .now
        }

        return nextManifest
    }

    func installBundledRuntime(paths: RuntimePaths, manifest: RuntimeManifest) throws -> RuntimeManifest {
        guard let bundledBinary = paths.bundledBinary, fileManager.fileExists(atPath: bundledBinary.path) else {
            throw RuntimeManagerError.bundledBinaryMissing
        }

        stop()
        try fileManager.createDirectory(at: paths.runtimeDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: paths.activeBinary.path) {
            try fileManager.removeItem(at: paths.activeBinary)
        }

        try fileManager.copyItem(at: bundledBinary, to: paths.activeBinary)
        try makeExecutable(at: paths.activeBinary)

        var nextManifest = manifest
        nextManifest.activeBinaryPath = paths.activeBinary.path
        nextManifest.bundledBinaryPath = bundledBinary.path
        nextManifest.source = .bundled
        nextManifest.installedAt = .now
        return nextManifest
    }

    func bundledBinaryExists(paths: RuntimePaths) -> Bool {
        guard let bundledBinary = paths.bundledBinary else { return false }
        return fileManager.fileExists(atPath: bundledBinary.path)
    }

    func writeManifest(_ manifest: RuntimeManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    func readManifest(from url: URL) throws -> RuntimeManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RuntimeManifest.self, from: data)
    }

    func ensureConfig(paths: RuntimePaths, manifest: RuntimeManifest) throws {
        let yaml = """
        host: '127.0.0.1'
        port: \(manifest.port)
        auth-dir: '\(paths.authDirectory.path)'
        remote-management:
          allow-remote: false
          secret-key: '\(manifest.managementKey)'
          disable-control-panel: true
        debug: false
        logging-to-file: true
        usage-statistics-enabled: true
        incognito-browser: true
        """

        try yaml.write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    func start(paths: RuntimePaths) throws {
        if isRunning {
            return
        }
        guard fileManager.fileExists(atPath: paths.activeBinary.path) else {
            throw RuntimeManagerError.activeBinaryMissing
        }

        let process = Process()
        process.executableURL = paths.activeBinary
        process.arguments = ["--config", paths.configFile.path]
        process.currentDirectoryURL = paths.appSupportDirectory

        let outputPipe = Pipe()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.appendLog(chunk)
            }
        }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self?.outputPipe = nil
                self?.process = nil
                self?.appendLog("\n[SurProxy] runtime exited with status \(process.terminationStatus)\n")
            }
        }

        try process.run()
        self.process = process
        self.outputPipe = outputPipe
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        self.process = nil
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    var recentLog: String {
        capturedLog
    }

    private func appendLog(_ chunk: String) {
        capturedLog.append(chunk)
        if capturedLog.count > 12000 {
            capturedLog = String(capturedLog.suffix(12000))
        }
    }

    private func makeExecutable(at url: URL) throws {
        var attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        let desiredPermissions = permissions | 0o755
        attributes[.posixPermissions] = NSNumber(value: desiredPermissions)
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
