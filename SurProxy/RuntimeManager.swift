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
    private var lastExitStatus: Int32?

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
        let yaml: String
        if fileManager.fileExists(atPath: paths.configFile.path),
           let existing = try? String(contentsOf: paths.configFile, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            yaml = Self.updatingManagedConfig(
                existing,
                authDirectory: paths.authDirectory.path,
                port: manifest.port,
                managementKey: manifest.managementKey
            )
        } else {
            yaml = Self.defaultConfig(
                authDirectory: paths.authDirectory.path,
                port: manifest.port,
                managementKey: manifest.managementKey
            )
        }

        try yaml.write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    func start(paths: RuntimePaths) throws {
        if isRunning {
            return
        }
        guard fileManager.fileExists(atPath: paths.activeBinary.path) else {
            throw RuntimeManagerError.activeBinaryMissing
        }

        capturedLog = ""
        lastExitStatus = nil
        appendLog("[SurProxy] launching runtime: \(paths.activeBinary.path) --config \(paths.configFile.path)\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", supervisorCommand(binaryPath: paths.activeBinary.path, configPath: paths.configFile.path)]
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
                self?.lastExitStatus = process.terminationStatus
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

    var recentExitStatus: Int32? {
        lastExitStatus
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

    private func supervisorCommand(binaryPath: String, configPath: String) -> String {
        let parentPID = ProcessInfo.processInfo.processIdentifier
        let escapedBinary = shellQuoted(binaryPath)
        let escapedConfig = shellQuoted(configPath)
        return """
        parent_pid=\(parentPID)
        \(escapedBinary) --config \(escapedConfig) &
        child_pid=$!
        trap 'kill "$child_pid" 2>/dev/null; wait "$child_pid" 2>/dev/null' TERM INT EXIT
        while kill -0 "$parent_pid" 2>/dev/null && kill -0 "$child_pid" 2>/dev/null; do
          sleep 1
        done
        kill "$child_pid" 2>/dev/null
        wait "$child_pid"
        """
    }

    private func shellQuoted(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func defaultConfig(authDirectory: String, port: Int, managementKey: String) -> String {
        """
        host: '127.0.0.1'
        port: \(port)
        auth-dir: '\(authDirectory)'
        remote-management:
          allow-remote: false
          secret-key: '\(managementKey)'
          disable-control-panel: true
        debug: false
        logging-to-file: true
        usage-statistics-enabled: true
        incognito-browser: true
        """
    }

    private static func updatingManagedConfig(_ yaml: String, authDirectory: String, port: Int, managementKey: String) -> String {
        var result = yaml
        result = upsertTopLevelScalar(key: "host", value: "'127.0.0.1'", in: result)
        result = upsertTopLevelScalar(key: "port", value: "\(port)", in: result)
        result = upsertTopLevelScalar(key: "auth-dir", value: "'\(authDirectory)'", in: result)
        result = upsertTopLevelScalar(key: "debug", value: "false", in: result)
        result = upsertTopLevelScalar(key: "logging-to-file", value: "true", in: result)
        result = upsertTopLevelScalar(key: "usage-statistics-enabled", value: "true", in: result)
        result = upsertTopLevelScalar(key: "incognito-browser", value: "true", in: result)
        result = upsertRemoteManagementBlock(in: result, managementKey: managementKey)
        if !result.hasSuffix("\n") {
            result.append("\n")
        }
        return result
    }

    private static func upsertTopLevelScalar(key: String, value: String, in yaml: String) -> String {
        var lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let prefix = "\(key):"
        if let index = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix(" ") && trimmed.hasPrefix(prefix)
        }) {
            lines[index] = "\(key): \(value)"
        } else {
            if !lines.isEmpty, !lines.last!.isEmpty {
                lines.append("")
            }
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }

    private static func upsertRemoteManagementBlock(in yaml: String, managementKey: String) -> String {
        var lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let block = [
            "remote-management:",
            "  allow-remote: false",
            "  secret-key: '\(managementKey)'",
            "  disable-control-panel: true"
        ]

        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("remote-management:")
        }) {
            lines[index] = "remote-management:"
            var endIndex = index + 1
            while endIndex < lines.count {
                let line = lines[endIndex]
                if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    break
                }
                endIndex += 1
            }
            lines.replaceSubrange(index..<endIndex, with: block)
        } else {
            if !lines.isEmpty, !lines.last!.isEmpty {
                lines.append("")
            }
            lines.append(contentsOf: block)
        }

        return lines.joined(separator: "\n")
    }
}
