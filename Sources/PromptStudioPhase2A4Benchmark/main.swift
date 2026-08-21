import CryptoKit
import Darwin
import Foundation
import PromptStudioCore
import SQLite3

/// Phase 2A.4.1 item-sequence/createdAt migration golden and performance harness.
///
/// This executable intentionally lives outside the app targets. It opens the
/// source database read-only, records its bytes before and after the run, and
/// creates every mutable fixture through SQLite's online backup API. No asset
/// or thumbnail path is ever resolved.

private let performanceRoot = URL(
    fileURLWithPath: "/Users/guruocen/Documents/PromptStudio Performance Fixtures",
    isDirectory: true
)

private let defaultSourceRoot = performanceRoot.appendingPathComponent("phase2a1-20260817", isDirectory: true)

/// Returns a canonical path even when the final output component does not
/// exist yet. `resolvingSymlinksInPath()` only resolves existing components;
/// walking to the first existing ancestor closes that gap for a new output
/// directory and makes overlap checks fail closed.
private func canonicalURL(_ url: URL) -> URL {
    let standardized = url.standardizedFileURL
    let manager = FileManager.default
    var existingPath = standardized.path
    var suffix: [String] = []
    while !manager.fileExists(atPath: existingPath) {
        let parent = URL(fileURLWithPath: existingPath).deletingLastPathComponent().path
        guard parent != existingPath else { break }
        suffix.insert(URL(fileURLWithPath: existingPath).lastPathComponent, at: 0)
        existingPath = parent
    }
    var resolved = URL(fileURLWithPath: existingPath).resolvingSymlinksInPath().standardizedFileURL
    for component in suffix {
        resolved.appendPathComponent(component, isDirectory: false)
    }
    return resolved.standardizedFileURL
}

private func pathContains(_ parent: URL, _ child: URL) -> Bool {
    let parentComponents = canonicalURL(parent).pathComponents
    let childComponents = canonicalURL(child).pathComponents
    guard parentComponents.count <= childComponents.count else { return false }
    return zip(parentComponents, childComponents).allSatisfy { $0 == $1 }
}

private func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    pathContains(lhs, rhs) || pathContains(rhs, lhs)
}

private func validateNoPathOverlap(sourceRoot: URL, outputRoot: URL) throws {
    let source = canonicalURL(sourceRoot)
    let output = canonicalURL(outputRoot)
    let realLibrary = URL(fileURLWithPath: "/Users/guruocen/Documents/PromptStudio Library", isDirectory: true)
    guard !pathsOverlap(source, output) else {
        throw BenchmarkError.unsafePath("source/output overlap: \(source.path) ↔ \(output.path)")
    }
    guard !pathsOverlap(source, realLibrary), !pathsOverlap(output, realLibrary) else {
        throw BenchmarkError.unsafePath("real PromptStudio Library path intersection")
    }
}

private struct Arguments {
    let sourceRoot: URL
    let outputRoot: URL
    let scales: [Int]
    let iterations: Int
    let pages: Int
    let batchSize: Int
    let pageSizes: [Int]
    let browserState: Bool

    static func parse() throws -> Arguments? {
        let values = Array(CommandLine.arguments.dropFirst())
        if values.contains("--help") || values.isEmpty {
            print("Usage: PromptStudioPhase2A4Benchmark --output-root <path> [--source-root <phase2a1-root>] [--scales 15959,50000,100000] [--iterations 30] [--pages 10] [--batch-size 500] [--page-sizes 300,301,600,601] [--browser-state]")
            return nil
        }
        func value(_ flag: String) -> String? {
            guard let index = values.firstIndex(of: flag), index + 1 < values.count else { return nil }
            return values[index + 1]
        }
        guard let outputValue = value("--output-root") else { throw BenchmarkError.invalidArguments }
        let sourceURL = canonicalURL(URL(fileURLWithPath: value("--source-root") ?? defaultSourceRoot.path, isDirectory: true))
        let outputURL = canonicalURL(URL(fileURLWithPath: outputValue, isDirectory: true))
        let scales = (value("--scales") ?? "15959,50000,100000")
            .split(separator: ",")
            .compactMap { Int($0) }
        guard !scales.isEmpty,
              scales.allSatisfy({ [15_959, 50_000, 100_000].contains($0) }) else {
            throw BenchmarkError.invalidArguments
        }
        let iterations = Int(value("--iterations") ?? "30") ?? 30
        let pages = Int(value("--pages") ?? "10") ?? 10
        let batchSize = Int(value("--batch-size") ?? "500") ?? 500
        let pageSizes = (value("--page-sizes") ?? "300,301,600,601")
            .split(separator: ",")
            .compactMap { Int($0) }
        guard iterations >= 30, pages >= 1, batchSize > 0,
              !pageSizes.isEmpty, pageSizes.allSatisfy({ $0 > 0 }) else { throw BenchmarkError.invalidArguments }
        try validateFixtureRoot(sourceURL, allowSourceRoot: true)
        try validateOutputRoot(outputURL)
        try validateNoPathOverlap(sourceRoot: sourceURL, outputRoot: outputURL)
        return Arguments(
            sourceRoot: sourceURL,
            outputRoot: outputURL,
            scales: scales,
            iterations: iterations,
            pages: pages,
            batchSize: batchSize,
            pageSizes: pageSizes,
            browserState: values.contains("--browser-state")
        )
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case invalidArguments
    case unsafePath(String)
    case missingFixture(String)
    case malformedFixture(String)
    case goldenMismatch(String)
    case explainContract(String)
    case sourceMutated(String)
    case sqliteBusyLocked(String)
    case timingInvariant(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "invalid benchmark arguments"
        case .unsafePath(let path): return "unsafe fixture path: \(path)"
        case .missingFixture(let path): return "missing fixture: \(path)"
        case .malformedFixture(let field): return "malformed fixture: \(field)"
        case .goldenMismatch(let field): return "migration golden mismatch: \(field)"
        case .explainContract(let detail): return "latest-version EXPLAIN contract failed: \(detail)"
        case .sourceMutated(let path): return "source database changed: \(path)"
        case .sqliteBusyLocked(let message): return "SQLite BUSY/LOCKED: \(message)"
        case .timingInvariant(let message): return "benchmark timing invariant failed: \(message)"
        case .unsupported(let message): return "unsupported fixture: \(message)"
        }
    }
}

private final class SQLiteErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = 0
    private var locked = 0

    func record(_ error: Error) {
        guard let sqliteError = error as? SQLiteError,
              let code = sqliteError.resultCode else { return }
        let primary = code & 0xff
        lock.lock()
        if primary == SQLITE_BUSY { busy += 1 }
        if primary == SQLITE_LOCKED { locked += 1 }
        lock.unlock()
    }

    var values: (busy: Int, locked: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (busy, locked)
    }
}

private func validateFixtureRoot(_ root: URL, allowSourceRoot: Bool = false) throws {
    let canonical = canonicalURL(root)
    let path = canonical.path
    let expectedParent = canonicalURL(performanceRoot).path
    guard !path.contains("PromptStudio Library"),
          path != "/Users/guruocen/Documents/PromptStudio Library" else {
        throw BenchmarkError.unsafePath(path)
    }
    if allowSourceRoot {
        guard URL(fileURLWithPath: path).deletingLastPathComponent().path == expectedParent,
              canonical.lastPathComponent.hasPrefix("phase2a1-") else {
            throw BenchmarkError.unsafePath(path)
        }
    } else {
        guard path == expectedParent || URL(fileURLWithPath: path).deletingLastPathComponent().path == expectedParent else {
            throw BenchmarkError.unsafePath(path)
        }
    }
}

private func validateOutputRoot(_ root: URL) throws {
    let path = canonicalURL(root).path
    let expectedParent = canonicalURL(performanceRoot).path
    guard !path.contains("PromptStudio Library"),
          URL(fileURLWithPath: path).deletingLastPathComponent().path == expectedParent,
          canonicalURL(root).lastPathComponent.hasPrefix("phase2a4-1-") else {
        throw BenchmarkError.unsafePath(path)
    }
}

private let restartProbeScales: Set<Int> = [15_959, 50_000, 100_000]
private let realPromptStudioLibraryPath = "/Users/guruocen/Documents/PromptStudio Library"

private final class RestartProbePhase2FileSystemCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock(); calls += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

private let restartProbePhase2FileSystemCounter = RestartProbePhase2FileSystemCounter()

private struct RestartProbeLexicalPaths {
    let probeRootPath: String
    let databasePath: String
    let outputPath: String
    let markerPath: String
    let walPath: String
    let shmPath: String
    let scale: Int
}

private struct RestartProbePaths {
    let probeRoot: URL
    let database: URL
    let output: URL
    let marker: URL
    let scale: Int
}

/// Phase 1 is deliberately pure: it only splits and normalizes path
/// components supplied as strings. It must not call URL path resolution,
/// canonicalURL, FileManager, stat, read, list, or SQLite.
private func restartProbeLexicalComponents(_ rawPath: String, label: String) throws -> [String] {
    guard rawPath.hasPrefix("/") else {
        throw BenchmarkError.unsafePath("restart probe \(label) must be absolute")
    }
    var components: [String] = []
    for rawComponent in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
        let component = String(rawComponent)
        guard component != ".", component != "..",
              !component.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw BenchmarkError.unsafePath("restart probe \(label) has an illegal path component")
        }
        components.append(component)
    }
    guard !components.isEmpty else {
        throw BenchmarkError.unsafePath("restart probe \(label) is empty")
    }
    return components
}

private func restartProbeLexicalPath(_ components: [String]) -> String {
    "/" + components.joined(separator: "/")
}

private func restartProbeLexicalPrefix(_ path: [String], _ prefix: [String]) -> Bool {
    path.count >= prefix.count && Array(path.prefix(prefix.count)) == prefix
}

private func validateRestartProbeLexicalPaths(
    databasePath: String,
    outputPath: String,
    probeRootPath: String,
    probeToken: String
) throws -> RestartProbeLexicalPaths {
    let root = try restartProbeLexicalComponents(probeRootPath, label: "probe root")
    let database = try restartProbeLexicalComponents(databasePath, label: "database")
    let output = try restartProbeLexicalComponents(outputPath, label: "output")
    let performance = try restartProbeLexicalComponents(performanceRoot.path, label: "performance root")
    let realLibrary = try restartProbeLexicalComponents(realPromptStudioLibraryPath, label: "real Library")
    guard !restartProbeLexicalPrefix(root, realLibrary), !restartProbeLexicalPrefix(database, realLibrary), !restartProbeLexicalPrefix(output, realLibrary) else {
        throw BenchmarkError.unsafePath("restart probe path intersects the real PromptStudio Library")
    }
    guard !root.contains(where: { $0.hasPrefix("phase2a1-") }),
          !database.contains(where: { $0.hasPrefix("phase2a1-") }),
          !output.contains(where: { $0.hasPrefix("phase2a1-") }) else {
        throw BenchmarkError.unsafePath("restart probe path names a source fixture")
    }
    guard root.count == performance.count + 1,
          Array(root.prefix(performance.count)) == performance,
          root.last?.hasPrefix("phase2a4-1-") == true else {
        throw BenchmarkError.unsafePath("restart probe root is not a generated phase2a4-1 output")
    }
    guard UUID(uuidString: probeToken) != nil else {
        throw BenchmarkError.unsafePath("restart probe marker token is invalid")
    }
    guard database.count == root.count + 3,
          Array(database.prefix(root.count)) == root,
          database[root.count].hasPrefix("stability-"),
          let scale = Int(database[root.count].dropFirst("stability-".count)),
          restartProbeScales.contains(scale),
          database[root.count + 1] == "database",
          database[root.count + 2] == "promptstudio.sqlite" else {
        throw BenchmarkError.unsafePath("restart probe database must be stability-<allowed scale>/database/promptstudio.sqlite")
    }
    let expectedOutput = root + ["stability-\(scale)-process-restart.json"]
    let expectedMarker = root + [".phase2a4-restart-probe-\(probeToken).marker"]
    guard output == expectedOutput else {
        throw BenchmarkError.unsafePath("restart probe output must be the expected stability report")
    }
    let databaseDirectory = Array(database.dropLast())
    let wal = databaseDirectory + ["promptstudio.sqlite-wal"]
    let shm = databaseDirectory + ["promptstudio.sqlite-shm"]
    guard restartProbeLexicalPrefix(wal, root), restartProbeLexicalPrefix(shm, root),
          !wal.contains(".."), !shm.contains("..") else {
        throw BenchmarkError.unsafePath("restart probe database sidecar escapes probe root")
    }
    return RestartProbeLexicalPaths(
        probeRootPath: restartProbeLexicalPath(root),
        databasePath: restartProbeLexicalPath(database),
        outputPath: restartProbeLexicalPath(output),
        markerPath: restartProbeLexicalPath(expectedMarker),
        walPath: restartProbeLexicalPath(wal),
        shmPath: restartProbeLexicalPath(shm),
        scale: scale
    )
}

private func lexicalPathContains(_ parentPath: String, _ childPath: String) -> Bool {
    let parent = parentPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let child = childPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard parent.count <= child.count else { return false }
    return zip(parent, child).allSatisfy { $0.0 == $0.1 }
}

private func hasSymlinkComponent(_ url: URL) -> Bool {
    let standardized = url.standardizedFileURL
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in standardized.pathComponents.dropFirst() {
        current.appendPathComponent(component, isDirectory: false)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
            return true
        }
    }
    return false
}

private func validateRestartProbeChild(
    databasePath: String,
    outputPath: String,
    probeRootPath: String,
    probeToken: String
) throws -> RestartProbePaths {
    // Complete containment/layout validation must finish before Phase 2 can
    // inspect any path. This call is pure string/component work.
    let lexical = try validateRestartProbeLexicalPaths(databasePath: databasePath, outputPath: outputPath, probeRootPath: probeRootPath, probeToken: probeToken)
    restartProbePhase2FileSystemCounter.record()
    let probeRootInput = URL(fileURLWithPath: lexical.probeRootPath, isDirectory: true)
    guard !hasSymlinkComponent(probeRootInput) else {
        throw BenchmarkError.unsafePath("restart probe root contains a symlink")
    }
    try validateOutputRoot(probeRootInput)
    let probeRoot = canonicalURL(probeRootInput)
    guard probeRoot.path == lexical.probeRootPath else {
        throw BenchmarkError.unsafePath("restart probe root canonical path differs from lexical root")
    }
    var rootIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: probeRoot.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
        throw BenchmarkError.unsafePath("restart probe root is not an existing directory")
    }

    let marker = URL(fileURLWithPath: lexical.markerPath, isDirectory: false)
    let databaseInput = URL(fileURLWithPath: lexical.databasePath)
    let outputInput = URL(fileURLWithPath: lexical.outputPath)
    guard !hasSymlinkComponent(outputInput) else {
        throw BenchmarkError.unsafePath("restart probe output contains a symlink")
    }
    guard !hasSymlinkComponent(marker) else {
        throw BenchmarkError.unsafePath("restart probe marker contains a symlink")
    }
    let markerAttributes = try? FileManager.default.attributesOfItem(atPath: marker.path)
    guard markerAttributes?[.type] as? FileAttributeType == .typeRegular,
          let markerData = try? Data(contentsOf: marker),
          String(data: markerData, encoding: .utf8) == probeToken else {
        throw BenchmarkError.unsafePath("restart probe marker is missing or invalid")
    }

    guard !hasSymlinkComponent(databaseInput) else {
        throw BenchmarkError.unsafePath("restart probe database contains a symlink")
    }
    let database = canonicalURL(databaseInput)
    let expectedOutput = URL(fileURLWithPath: lexical.outputPath, isDirectory: false)
    guard !FileManager.default.fileExists(atPath: expectedOutput.path) else {
        throw BenchmarkError.unsafePath("restart probe output already exists")
    }
    let databaseAttributes = try? FileManager.default.attributesOfItem(atPath: database.path)
    guard databaseAttributes?[.type] as? FileAttributeType == .typeRegular else {
        throw BenchmarkError.unsafePath("restart probe database is not a regular file")
    }
    for sidecar in [URL(fileURLWithPath: lexical.walPath), URL(fileURLWithPath: lexical.shmPath)] {
        guard !hasSymlinkComponent(sidecar) else {
            throw BenchmarkError.unsafePath("restart probe database sidecar contains a symlink")
        }
        if FileManager.default.fileExists(atPath: sidecar.path) {
            guard lexicalPathContains(probeRoot.path, canonicalURL(sidecar).path) else {
                throw BenchmarkError.unsafePath("restart probe database sidecar escapes probe root")
            }
        }
    }
    return RestartProbePaths(probeRoot: probeRoot, database: database, output: expectedOutput, marker: marker, scale: lexical.scale)
}

private func databaseURL(for library: URL) -> URL {
    library.appendingPathComponent("database/promptstudio.sqlite")
}

/// Selects the only safe source-open mode for an offline fixture. A WAL or
/// SHM sidecar may contain committed frames that are not in the main file, so
/// an immutable URI is forbidden whenever either sidecar exists. When both
/// sidecars are absent the fixture is a closed snapshot and immutable mode
/// prevents SQLite from creating a new `-shm`/`-wal` while opening it.
private struct BenchmarkSourceOpenSpec {
    let path: String
    let flags: Int32
}

private func benchmarkSourceOpenSpec(databaseURL: URL) -> BenchmarkSourceOpenSpec {
    let fileManager = FileManager.default
    let walExists = fileManager.fileExists(atPath: databaseURL.path + "-wal")
    let shmExists = fileManager.fileExists(atPath: databaseURL.path + "-shm")
    guard !walExists, !shmExists else {
        // Keep the raw pathname when either sidecar exists so SQLite can read
        // the complete WAL snapshot. If that snapshot is inconsistent SQLite
        // fails the open; we never silently fall back to data-losing immutable
        // mode.
        return BenchmarkSourceOpenSpec(
            path: databaseURL.path,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
    }
    return BenchmarkSourceOpenSpec(
        path: databaseURL.absoluteString + "?immutable=1",
        flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
    )
}

private func sqliteMessage(_ handle: OpaquePointer?) -> String {
    guard let handle, let message = sqlite3_errmsg(handle) else {
        return "SQLite source open failed"
    }
    return String(cString: message)
}

/// Opens a fixture source without ever allowing SQLite to create sidecars.
/// This helper is intentionally benchmark-local: production SQLiteDatabase
/// behavior and APIs remain unchanged.
private func openBenchmarkSource(databaseURL: URL) throws -> OpaquePointer {
    let spec = benchmarkSourceOpenSpec(databaseURL: databaseURL)
    var handle: OpaquePointer?
    let result = spec.path.withCString {
        sqlite3_open_v2($0, &handle, spec.flags, nil)
    }
    guard result == SQLITE_OK, let handle else {
        let message = sqliteMessage(handle)
        let extended = handle.map(sqlite3_extended_errcode) ?? result
        sqlite3_close(handle)
        throw SQLiteError.openFailed(message, resultCode: result, extendedCode: extended)
    }
    sqlite3_extended_result_codes(handle, 1)
    let timeoutResult = sqlite3_busy_timeout(handle, SQLiteReadConnection.defaultBusyTimeoutMilliseconds)
    guard timeoutResult == SQLITE_OK else {
        let message = sqliteMessage(handle)
        let extended = sqlite3_extended_errcode(handle)
        sqlite3_close(handle)
        throw SQLiteError.openFailed(message, resultCode: timeoutResult, extendedCode: extended)
    }
    return handle
}

/// Minimal synchronous read wrapper for source-only queries. Unlike
/// SQLiteReadConnection this can pass SQLITE_OPEN_URI for immutable fixtures.
private final class BenchmarkSourceReadConnection {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL) throws {
        handle = try openBenchmarkSource(databaseURL: databaseURL)
    }

    deinit {
        sqlite3_close(handle)
    }

    func querySync(_ sql: String, values: [SQLiteValue] = []) throws -> [[String: String?]] {
        guard let handle else {
            throw SQLiteError.openFailed("SQLite source connection is closed", resultCode: SQLITE_MISUSE, extendedCode: SQLITE_MISUSE)
        }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(sqliteMessage(handle), resultCode: prepareResult, extendedCode: sqlite3_extended_errcode(handle))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch value {
            case .text(let text):
                bindResult = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .int(let integer):
                bindResult = sqlite3_bind_int64(statement, index, integer)
            case .double(let double):
                bindResult = sqlite3_bind_double(statement, index, double)
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            }
            guard bindResult == SQLITE_OK else {
                throw SQLiteError.bindFailed(sqliteMessage(handle), resultCode: bindResult, extendedCode: sqlite3_extended_errcode(handle))
            }
        }

        let columnCount = Int(sqlite3_column_count(statement))
        var rows: [[String: String?]] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { return rows }
            guard stepResult == SQLITE_ROW else {
                throw SQLiteError.stepFailed(sqliteMessage(handle), resultCode: stepResult, extendedCode: sqlite3_extended_errcode(handle))
            }
            var row: [String: String?] = [:]
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, Int32(index)))
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_NULL:
                    row[name] = nil
                case SQLITE_INTEGER:
                    row[name] = String(sqlite3_column_int64(statement, Int32(index)))
                case SQLITE_FLOAT:
                    row[name] = String(sqlite3_column_double(statement, Int32(index)))
                default:
                    guard let bytes = sqlite3_column_text(statement, Int32(index)) else {
                        row[name] = nil
                        continue
                    }
                    let count = Int(sqlite3_column_bytes(statement, Int32(index)))
                    row[name] = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
                }
            }
            rows.append(row)
        }
    }
}

private struct FileHash: Codable {
    let path: String
    let exists: Bool
    let bytes: Int
    let sha256: String?
}

private func fileHash(_ url: URL) throws -> FileHash {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else {
        return FileHash(path: url.path, exists: false, bytes: 0, sha256: nil)
    }
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return FileHash(path: url.path, exists: true, bytes: data.count, sha256: digest)
}

private struct SourceSnapshot: Codable {
    let main: FileHash
    let wal: FileHash
    let shm: FileHash

    func equal(to other: SourceSnapshot) -> Bool {
        [main, wal, shm].map(\.sha256) == [other.main, other.wal, other.shm].map(\.sha256)
            && [main, wal, shm].map(\.exists) == [other.main, other.wal, other.shm].map(\.exists)
            && [main, wal, shm].map(\.bytes) == [other.main, other.wal, other.shm].map(\.bytes)
    }

    var json: [String: Any] {
        ["main": main.json, "wal": wal.json, "shm": shm.json]
    }
}

private extension FileHash {
    var json: [String: Any] {
        ["path": path, "exists": exists, "bytes": bytes, "sha256": sha256 ?? NSNull()]
    }
}

private func sourceSnapshot(_ database: URL) throws -> SourceSnapshot {
    SourceSnapshot(
        main: try fileHash(database),
        wal: try fileHash(URL(fileURLWithPath: database.path + "-wal")),
        shm: try fileHash(URL(fileURLWithPath: database.path + "-shm"))
    )
}

private let canonicalFramedManifest = "relative-path-sorted-length-framed-v1"

/// Hashes every regular file in a fixture tree with a length-framed relative
/// path.  The database snapshot is intentionally included alongside
/// golden-results.json/manifests so accidental source additions/removals are
/// visible even when the SQLite main file itself is unchanged.
private func sourceTreeManifest(_ root: URL) throws -> (hash: String, entries: [[String: Any]]) {
    let manager = FileManager.default
    let canonical = canonicalURL(root)
    guard let enumerator = manager.enumerator(
        at: canonical,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
        options: []
    ) else { throw BenchmarkError.missingFixture(canonical.path) }
    var framedEntries: [(relativePath: String, type: String, line: String)] = []
    var entries: [[String: Any]] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        let relative = url.path.replacingOccurrences(of: canonical.path + "/", with: "")
        if values.isSymbolicLink == true {
            let target = try? manager.destinationOfSymbolicLink(atPath: url.path)
            entries.append(["type": "symlink", "relativePath": relative, "target": target ?? NSNull()])
            throw BenchmarkError.unsafePath("symlink inside source fixture: \(url.path)")
        }
        if values.isDirectory == true {
            entries.append(["type": "directory", "relativePath": relative])
            framedEntries.append((relative, "directory", "directory:\(relative.count):\(relative)\n"))
            continue
        }
        guard values.isRegularFile == true else { continue }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        entries.append(["type": "file", "relativePath": relative, "bytes": data.count, "sha256": digest])
        framedEntries.append((relative, "file", "file:\(relative.count):\(relative):\(data.count):\(digest)\n"))
    }
    entries.sort {
        let left = ($0["relativePath"] as? String ?? "", $0["type"] as? String ?? "")
        let right = ($1["relativePath"] as? String ?? "", $1["type"] as? String ?? "")
        return left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
    }
    var framed = Data()
    for entry in framedEntries.sorted(by: {
        if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
        return $0.type < $1.type
    }) {
        framed.append(Data(entry.line.utf8))
    }
    return (SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined(), entries)
}

private func sourceTreeHash(_ root: URL) throws -> String {
    try sourceTreeManifest(root).hash
}

private func sourceOpenMode(_ database: URL) -> String {
    let spec = benchmarkSourceOpenSpec(databaseURL: database)
    return spec.flags & SQLITE_OPEN_URI != 0 ? "immutable-uri" : "readonly"
}

private func optionalString(_ row: [String: String?], _ key: String) -> String? {
    row[key] ?? nil
}

private func requiredString(_ row: [String: String?], _ key: String) -> String {
    optionalString(row, key) ?? ""
}

private func integer(_ row: [String: String?], _ key: String) -> Int {
    Int(requiredString(row, key)) ?? 0
}

private func integer64(_ row: [String: String?], _ key: String) -> Int64 {
    Int64(requiredString(row, key)) ?? 0
}

private func parseISO(_ string: String) -> Date? {
    guard !string.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: string)
}

private func dateMicros(_ date: Date) -> Int64 {
    let value = (date.timeIntervalSince1970 * 1_000_000).rounded()
    guard value.isFinite,
          value >= Double(Int64.min),
          value <= Double(Int64.max) else {
        return value.sign == .minus ? Int64.min : Int64.max
    }
    return Int64(value)
}

private let itemOrderHashAlgorithm = "item-order-v1-length-framed-sha256"

private func itemOrderHash(_ ids: [String]) -> String {
    var bytes = Data("item-order-v1\n\(ids.count)\n".utf8)
    for id in ids {
        let encoded = Data(id.utf8)
        bytes.append(Data("\(encoded.count):".utf8))
        bytes.append(encoded)
        bytes.append(10)
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// Public benchmark view of the Core classifier: canonical RFC3339 first,
/// then the Foundation ISO8601 legacy parser, with a nil result meaning the
/// injected observation clock must be consumed by the real repository.
private func benchmarkCreatedAtObservation(_ raw: String) -> (date: Date, sortKey: Int64)? {
    if let date = PromptItemCreatedAtSupport.date(from: raw) {
        return (date, PromptItemCreatedAtSupport.sortKey(from: raw) ?? dateMicros(date))
    }
    guard !raw.isEmpty, let date = ISO8601DateFormatter().date(from: raw) else { return nil }
    return (date, dateMicros(date))
}

private func framedSHA256(_ lines: [String]) -> String {
    var data = Data()
    for line in lines {
        let bytes = Data(line.utf8)
        data.append(Data("\(bytes.count):".utf8))
        data.append(bytes)
        data.append(10)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Business fingerprint deliberately excludes SQLite rowid and artifact
/// bytes. It is the stability oracle across VACUUM/reopen/online-backup.
private func businessFingerprint(databaseURL: URL) throws -> String {
    let read = try SQLiteReadConnection(url: databaseURL)
    var lines: [String] = ["business-fingerprint-v1"]
    let itemRows = try read.querySync("SELECT id,title,type,assetKind,modelId,modelName,folderId,folderName,category,assetPath,thumbnailPath,aspectRatio,width,height,format,fileSize,favorite,pinnedAt,deletedAt,createdAt,updatedAt,lastUsedAt,sortOrder,tagsJSON,referencesJSON,description,captureId,captureSourceJSON,itemCreatedAtSortKey,itemLastUsedAtSortKey,itemSequence FROM prompt_items ORDER BY id COLLATE BINARY ASC;")
    for row in itemRows {
        lines.append("item|" + ["id","title","type","assetKind","modelId","modelName","folderId","folderName","category","assetPath","thumbnailPath","aspectRatio","width","height","format","fileSize","favorite","pinnedAt","deletedAt","createdAt","updatedAt","lastUsedAt","sortOrder","tagsJSON","referencesJSON","description","captureId","captureSourceJSON","itemCreatedAtSortKey","itemLastUsedAtSortKey","itemSequence"].map { field in
            let value = row[field] ?? nil
            return "\(field)=\(value.map { "value:\($0.count):\($0)" } ?? "NULL")"
        }.joined(separator: "|"))
    }
    let versionRows = try read.querySync("SELECT id,promptItemId,version,prompt,negativePrompt,parametersJSON,note,createdAt,versionCreatedAtSortKey,versionSequence FROM prompt_versions ORDER BY id COLLATE BINARY ASC;")
    for row in versionRows {
        lines.append("version|" + ["id","promptItemId","version","prompt","negativePrompt","parametersJSON","note","createdAt","versionCreatedAtSortKey","versionSequence"].map { field in
            let value = row[field] ?? nil
            return "\(field)=\(value.map { "value:\($0.count):\($0)" } ?? "NULL")"
        }.joined(separator: "|"))
    }
    let tagRows = try read.querySync("SELECT promptItemId,ordinal,tagName,tagKey,isFirstOccurrence,isDeleted,sortOrder,createdAt,lastUsedAt FROM prompt_item_tags ORDER BY promptItemId COLLATE BINARY ASC,ordinal ASC;")
    for row in tagRows {
        lines.append("relation|" + ["promptItemId","ordinal","tagName","tagKey","isFirstOccurrence","isDeleted","sortOrder","createdAt","lastUsedAt"].map { field in
            "\(field)=\(row[field].flatMap { $0 } ?? "NULL")"
        }.joined(separator: "|"))
    }
    return framedSHA256(lines)
}

private func itemSequenceStateJSON(databaseURL: URL) throws -> [String: Any] {
    let read = try SQLiteReadConnection(url: databaseURL)
    guard let row = try read.querySync("SELECT * FROM item_sequence_migration WHERE id=1;").first else {
        return ["phase": "notStarted", "present": false]
    }
    var result: [String: Any] = ["present": true]
    for (key, value) in row { result[key] = value ?? nil ?? NSNull() }
    return result
}

private func itemSequenceInvariants(databaseURL: URL) throws -> [String: Any] {
    let read = try SQLiteReadConnection(url: databaseURL)
    let rows = try read.querySync("SELECT id,itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey FROM prompt_items ORDER BY itemSequence ASC;")
    let sequences = rows.compactMap { Int64(optionalString($0, "itemSequence") ?? "") }
    let nullCount = rows.count - sequences.count
    let distinct = Set(sequences)
    let duplicateCount = sequences.count - distinct.count
    let maxSequence = sequences.max() ?? 0
    let gapCount: Int
    if sequences.isEmpty { gapCount = 0 } else {
        let expected = Set((1...maxSequence).map { Int64($0) })
        gapCount = expected.subtracting(distinct).count
    }
    let contiguous = nullCount == 0 && duplicateCount == 0 && gapCount == 0 && (maxSequence == 0 ? sequences.isEmpty : sequences.sorted() == (1...maxSequence).map { Int64($0) })
    let rowByID = Dictionary(uniqueKeysWithValues: rows.map { (requiredString($0, "id"), $0) })
    return [
        "count": rows.count,
        "nullCount": nullCount,
        "duplicateCount": duplicateCount,
        "gapCount": gapCount,
        "contiguous": contiguous,
        "sequenceDirection": "ascending",
        "minSequence": sequences.min() ?? 0,
        "maxSequence": maxSequence,
        "sequenceByID": rowByID.mapValues { integer64($0, "itemSequence") }
    ]
}

/// Raw prompt-item/version fields are the opaque compatibility surface.  This
/// fingerprint deliberately excludes rowid and all migration-owned columns so
/// it can be compared before/after backfill, VACUUM and online backup.
private func rawBusinessFingerprint(databaseURL: URL) throws -> String {
    let read = try SQLiteReadConnection(url: databaseURL)
    var lines: [String] = ["raw-business-fingerprint-v1"]
    let items = try read.querySync("SELECT id,title,type,assetKind,modelId,modelName,folderId,folderName,category,assetPath,thumbnailPath,aspectRatio,width,height,format,fileSize,favorite,pinnedAt,deletedAt,createdAt,updatedAt,lastUsedAt,sortOrder,tagsJSON,referencesJSON,description,captureId,captureSourceJSON FROM prompt_items ORDER BY id COLLATE BINARY ASC;")
    let itemFields = ["id","title","type","assetKind","modelId","modelName","folderId","folderName","category","assetPath","thumbnailPath","aspectRatio","width","height","format","fileSize","favorite","pinnedAt","deletedAt","createdAt","updatedAt","lastUsedAt","sortOrder","tagsJSON","referencesJSON","description","captureId","captureSourceJSON"]
    for row in items {
        lines.append("item|" + itemFields.map { field in
            let value = row[field] ?? nil
            return "\(field)=\(value.map { "value:\($0.count):\($0)" } ?? "NULL")"
        }.joined(separator: "|"))
    }
    let versions = try read.querySync("SELECT id,promptItemId,version,prompt,negativePrompt,parametersJSON,note,createdAt FROM prompt_versions ORDER BY id COLLATE BINARY ASC;")
    let versionFields = ["id","promptItemId","version","prompt","negativePrompt","parametersJSON","note","createdAt"]
    for row in versions {
        lines.append("version|" + versionFields.map { field in
            let value = row[field] ?? nil
            return "\(field)=\(value.map { "value:\($0.count):\($0)" } ?? "NULL")"
        }.joined(separator: "|"))
    }
    return framedSHA256(lines)
}

private func rawCreatedAtSnapshot(databaseURL: URL) throws -> [String: String?] {
    let read = try SQLiteReadConnection(url: databaseURL)
    let rows = try read.querySync("SELECT id,createdAt,updatedAt,lastUsedAt,deletedAt,tagsJSON,referencesJSON FROM prompt_items ORDER BY id COLLATE BINARY ASC;")
    return Dictionary(uniqueKeysWithValues: rows.map { (requiredString($0, "id"), optionalString($0, "createdAt")) })
}

private func decodeReferencesExactly(_ value: String) -> [ReferenceAsset] {
    guard let data = value.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([ReferenceAsset].self, from: data)) ?? []
}

private struct SummaryGolden: Codable {
    let id: String
    let title: String
    let type: String
    let assetKind: String
    let modelId: String
    let modelName: String
    let folderId: String
    let folderName: String
    let category: String
    let assetPath: String
    let thumbnailPath: String
    let aspectRatio: String
    let width: Int
    let height: Int
    let format: String
    let fileSize: Int64
    let favorite: Bool
    let pinnedAtMicros: Int64?
    let deletedAtMicros: Int64?
    let createdAtMicros: Int64
    let updatedAtMicros: Int64
    let lastUsedAtMicros: Int64
    let sortOrder: Int
    let tags: [String]
    let hasReferences: Bool
    let isDeleted: Bool
    let rawCreatedAt: String
    let rawUpdatedAt: String
    let rawLastUsedAt: String
    let legacyObservationKind: String
    let legacyObservationMicros: Int64

    init(row: [String: String?], createdAtOverride: Int64? = nil) throws {
        let id = requiredString(row, "id")
        guard !id.isEmpty else { throw BenchmarkError.malformedFixture("prompt_items.id") }
        let created = parseISO(requiredString(row, "createdAt")) ?? Date(timeIntervalSince1970: 0)
        let updated = parseISO(requiredString(row, "updatedAt")) ?? Date(timeIntervalSince1970: 0)
        let lastUsed = parseISO(requiredString(row, "lastUsedAt")) ?? Date(timeIntervalSince1970: 0)
        let tagsJSON = requiredString(row, "tagsJSON")
        let tags: [String]
        if let data = tagsJSON.data(using: .utf8) {
            tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            tags = []
        }
        self.id = id
        self.title = requiredString(row, "title")
        self.type = requiredString(row, "type")
        self.assetKind = requiredString(row, "assetKind")
        self.modelId = requiredString(row, "modelId")
        self.modelName = requiredString(row, "modelName")
        self.folderId = requiredString(row, "folderId")
        self.folderName = requiredString(row, "folderName")
        self.category = requiredString(row, "category")
        self.assetPath = requiredString(row, "assetPath")
        self.thumbnailPath = requiredString(row, "thumbnailPath")
        self.aspectRatio = requiredString(row, "aspectRatio")
        self.width = integer(row, "width")
        self.height = integer(row, "height")
        self.format = requiredString(row, "format")
        self.fileSize = integer64(row, "fileSize")
        self.favorite = integer(row, "favorite") == 1
        self.pinnedAtMicros = optionalString(row, "pinnedAt").flatMap(parseISO).map(dateMicros)
        self.deletedAtMicros = optionalString(row, "deletedAt").flatMap(parseISO).map(dateMicros)
        self.createdAtMicros = createdAtOverride ?? dateMicros(created)
        self.updatedAtMicros = dateMicros(updated)
        self.lastUsedAtMicros = dateMicros(lastUsed)
        self.sortOrder = integer(row, "sortOrder")
        self.tags = tags
        self.hasReferences = !decodeReferencesExactly(requiredString(row, "referencesJSON")).isEmpty
        self.isDeleted = optionalString(row, "deletedAt") != nil
        let rawCreated = requiredString(row, "createdAt")
        self.rawCreatedAt = rawCreated
        self.rawUpdatedAt = requiredString(row, "updatedAt")
        self.rawLastUsedAt = requiredString(row, "lastUsedAt")
        if let observation = benchmarkCreatedAtObservation(rawCreated) {
            self.legacyObservationKind = PromptItemCreatedAtSupport.date(from: rawCreated) != nil ? "canonical" : "legacyISO"
            self.legacyObservationMicros = observation.sortKey
        } else {
            self.legacyObservationKind = rawCreated.isEmpty ? "emptyFallback" : "malformedFallback"
            self.legacyObservationMicros = createdAtOverride ?? 0
        }
    }
}

private struct VersionGolden: Codable {
    let id: String
    let createdAt: String
    let prompt: String
    let rowid: Int64
    let fallbackDateMicros: Int64?
    let sortKey: Int64
}

private struct ItemGolden: Codable {
    let summary: SummaryGolden
    let versions: [VersionGolden]
    let currentVersionID: String?
    let hasPrompt: Bool
}

private struct LegacyGolden: Codable {
    let schema: String
    let itemCount: Int
    let versionCount: Int
    let syntheticIDs: [String]
    let observationFallbackCount: Int
    let itemFallbackCount: Int
    let versionFallbackCount: Int
    let items: [ItemGolden]
    /// Exact pre-ready PromptRepository.loadItems() observation order.  This
    /// is the only source of truth for itemSequence migration parity; no
    /// lexical ID sort is permitted here.
    let itemObservationOrder: [String]
    let itemShapeOrders: [String: [String]]
    let itemRawCreatedAt: [String: String]
    let itemObservedCreatedAtMicros: [String: Int64]
    let itemFallbackDatesMicros: [Int64]
    let versionFallbackDatesMicros: [Int64]
    let itemSequenceDirection: String
    let itemObservationOrderMatchesRowID: Bool

    init(
        schema: String,
        itemCount: Int,
        versionCount: Int,
        syntheticIDs: [String],
        observationFallbackCount: Int,
        itemFallbackCount: Int = 0,
        versionFallbackCount: Int = 0,
        items: [ItemGolden],
        itemObservationOrder: [String] = [],
        itemShapeOrders: [String: [String]] = [:],
        itemRawCreatedAt: [String: String] = [:],
        itemObservedCreatedAtMicros: [String: Int64] = [:],
        itemFallbackDatesMicros: [Int64] = [],
        versionFallbackDatesMicros: [Int64] = [],
        itemSequenceDirection: String = "ascending",
        itemObservationOrderMatchesRowID: Bool = true
    ) {
        self.schema = schema
        self.itemCount = itemCount
        self.versionCount = versionCount
        self.syntheticIDs = syntheticIDs
        self.observationFallbackCount = observationFallbackCount
        self.itemFallbackCount = itemFallbackCount
        self.versionFallbackCount = versionFallbackCount
        self.items = items
        self.itemObservationOrder = itemObservationOrder
        self.itemShapeOrders = itemShapeOrders
        self.itemRawCreatedAt = itemRawCreatedAt
        self.itemObservedCreatedAtMicros = itemObservedCreatedAtMicros
        self.itemFallbackDatesMicros = itemFallbackDatesMicros
        self.versionFallbackDatesMicros = versionFallbackDatesMicros
        self.itemSequenceDirection = itemSequenceDirection
        self.itemObservationOrderMatchesRowID = itemObservationOrderMatchesRowID
    }

    var byID: [String: ItemGolden] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.summary.id, $0) })
    }
}

private struct RawVersion {
    let id: String
    let createdAt: String
    let prompt: String
    let rowid: Int64
}

private struct LockedPhase2A1Parameters: Codable {
    let folderID: String
    let modelID: String
    let type: String
    let tag: String?
    let sourceItemCount: Int
    let queryCounts: [String: Int]
    let sourceGoldenPath: String
}

private func jsonDictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

private func jsonEquivalent(_ lhs: Any, _ rhs: Any) -> Bool {
    guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
          let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
    return left == right
}

/// Locks the Phase 2A.1 query parameters before any synthetic rows are added
/// to the clone. The legacy golden file is the source of truth for folder,
/// model, type, and the original query counts; the tag is read from a legacy
/// row (or explicitly marked unavailable when no legacy tag exists).
private func loadLockedPhase2A1Parameters(sourceLibrary: URL) throws -> LockedPhase2A1Parameters {
    let goldenURL = sourceLibrary.appendingPathComponent("golden-results.json")
    guard let data = try? Data(contentsOf: goldenURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawParameters = jsonDictionary(root["parameters"]),
          let folderID = rawParameters["folderId"] as? String,
          let modelID = rawParameters["modelId"] as? String,
          let type = rawParameters["type"] as? String,
          let sourceItemCount = root["itemCount"] as? Int,
          let rawQueries = jsonDictionary(root["queries"]) else {
        throw BenchmarkError.missingFixture(goldenURL.path)
    }
    var queryCounts: [String: Int] = [:]
    for (name, value) in rawQueries {
        if let query = jsonDictionary(value), let count = query["count"] as? Int {
            queryCounts[name] = count
        }
    }

    var tag: String?
    if let all = jsonDictionary(rawQueries["all"]),
       let ids = all["ids"] as? [String],
       let firstID = ids.first {
        let read = try BenchmarkSourceReadConnection(databaseURL: databaseURL(for: sourceLibrary))
        let rows = try read.querySync("SELECT tagsJSON FROM prompt_items WHERE id = ? LIMIT 1;", values: [.text(firstID)])
        if let tagsJSON = rows.first.flatMap({ optionalString($0, "tagsJSON") }),
           let bytes = tagsJSON.data(using: .utf8),
           let tags = try? JSONDecoder().decode([String].self, from: bytes) {
            tag = tags.first
        }
    }
    return LockedPhase2A1Parameters(
        folderID: folderID,
        modelID: modelID,
        type: type,
        tag: tag,
        sourceItemCount: sourceItemCount,
        queryCounts: queryCounts,
        sourceGoldenPath: goldenURL.path
    )
}

private func buildLegacyGolden(
    databaseURL: URL,
    syntheticIDs: [String],
    lockedParameters: LockedPhase2A1Parameters
) throws -> (LegacyGolden, [Date]) {
    let read = try SQLiteReadConnection(url: databaseURL)
    // The real pre-ready loader uses an unordered SELECT.  SQLite's stable
    // observation sequence for this clone is rowid order; keep that order
    // explicit only for the deterministic clock-consumption oracle (never as
    // a ready-query tie-break).
    let rawRows = try read.querySync("SELECT rowid,* FROM prompt_items ORDER BY rowid ASC;")
    let itemFallbackCount = rawRows.reduce(into: 0) { count, row in
        if benchmarkCreatedAtObservation(requiredString(row, "createdAt")) == nil { count += 1 }
    }
    let itemFallbackSeed = (0..<itemFallbackCount).map {
        Date(timeIntervalSince1970: 2_400_000_000 + Double($0))
    }

    // Capture the old repository loader before any readiness gate can switch
    // its SQL.  This intentionally uses PromptRepository.loadItems() rather
    // than a benchmark-local ORDER BY, preserving the observed SQLite row
    // sequence that itemSequence migration must reconcile.
    let libraryURL = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
    let legacyRepository = try PromptRepository(
        libraryURL: libraryURL,
        legacyObservationClock: ItemSequenceObservationClock(dates: itemFallbackSeed)
    )
    let legacyItems = try legacyRepository.loadItems()
    let loadedByID = Dictionary(uniqueKeysWithValues: legacyItems.map { ($0.id, $0) })
    let itemObservationOrder = legacyItems.map(\.id)
    let rowIDObservationOrder = rawRows.map { requiredString($0, "id") }
    let legacyObservationOrderMatchesRowID = itemObservationOrder == rowIDObservationOrder
    guard legacyObservationOrderMatchesRowID else {
        throw BenchmarkError.goldenMismatch("legacyObservationOrderMatchesRowID")
    }
    let itemRawCreatedAt = Dictionary(uniqueKeysWithValues: rawRows.map { (requiredString($0, "id"), requiredString($0, "createdAt")) })
    let itemObservedCreatedAtMicros = Dictionary(uniqueKeysWithValues: rawRows.map { row in
        let id = requiredString(row, "id")
        let raw = requiredString(row, "createdAt")
        return (id, benchmarkCreatedAtObservation(raw)?.sortKey ?? dateMicros(loadedByID[id]?.createdAt ?? Date(timeIntervalSince1970: 0)))
    })
    // The old loader and migration receive independent clock instances with
    // the same seed.  The migration consumes this list in rowid order; the
    // old loader's raw SELECT observes the same SQLite row order on the clone.
    let itemFallbackDates = itemFallbackSeed

    guard let type = PromptType(rawValue: lockedParameters.type) else {
        throw BenchmarkError.malformedFixture("golden-results.parameters.type")
    }
    let tag = lockedParameters.tag ?? "phase2a4-equal-item"
    let shapeFilters: [String: PromptFilter] = [
        "All": PromptFilter(collection: .all),
        "Folder": PromptFilter(collection: .folder(lockedParameters.folderID)),
        "Tag": PromptFilter(collection: .tag(tag)),
        "Type": PromptFilter(collection: .all, type: type),
        "Model": PromptFilter(modelId: lockedParameters.modelID, collection: .all),
        "Favorite": PromptFilter(collection: .favorites),
        "Recent": PromptFilter(collection: .recent),
        "Trash": PromptFilter(collection: .trash),
        "Combined": PromptFilter(modelId: lockedParameters.modelID, collection: .folder(lockedParameters.folderID), type: type, favoriteOnly: true)
    ]
    let itemShapeOrders = shapeFilters.mapValues { filter in
        PromptFiltering.apply(legacyItems, filter: filter).map(\.id)
    }

    // Summary fields are compared after migration, but item creation Date in
    // a ready row is decoded from the persisted key.  Override only that
    // expected field with the exact pre-ready loader observation; all opaque
    // raw strings remain captured separately for the timestamp oracle.
    let summaries: [SummaryGolden] = try rawRows.map { row in
        let id = requiredString(row, "id")
        return try SummaryGolden(row: row, createdAtOverride: itemObservedCreatedAtMicros[id])
    }
    // This mirrors the legacy repository loader: SQL establishes the legacy
    // row order by the raw createdAt string, then Swift Date sorting is applied
    // per item. Equal parsed dates retain this observed row order.
    let allVersions = try read.querySync(
        "SELECT rowid,id,promptItemId,createdAt,prompt FROM prompt_versions ORDER BY createdAt ASC, rowid ASC;"
    )
    var versionsByItem: [String: [RawVersion]] = [:]
    versionsByItem.reserveCapacity(summaries.count)
    for row in allVersions {
        let itemID = requiredString(row, "promptItemId")
        versionsByItem[itemID, default: []].append(
            RawVersion(
                id: requiredString(row, "id"),
                createdAt: requiredString(row, "createdAt"),
                prompt: requiredString(row, "prompt"),
                rowid: integer64(row, "rowid")
            )
        )
    }

    // Migration walks item IDs in this exact order. Fallback observations are
    // deterministic and shared with the pre-ready repository clock.
    var fallbackDates: [Date] = []
    var fallbackIndex = 0
    let versionFallbackCount = allVersions.reduce(into: 0) { count, row in
        if parseISO(requiredString(row, "createdAt")) == nil { count += 1 }
    }
    let versionFallbackSeed = (0..<versionFallbackCount).map {
        Date(timeIntervalSince1970: 2_500_000_000 + Double($0))
    }
    let orderedSummaries = summaries.sorted { $0.id < $1.id }
    var items: [ItemGolden] = []
    items.reserveCapacity(orderedSummaries.count)
    for summary in orderedSummaries {
        let raw = versionsByItem[summary.id, default: []]
        var observed: [(raw: RawVersion, sortKey: Int64, fallback: Int64?)] = []
        observed.reserveCapacity(raw.count)
        for version in raw {
            if let date = parseISO(version.createdAt) {
                observed.append((version, dateMicros(date), nil))
            } else {
                guard fallbackIndex < versionFallbackSeed.count else {
                    throw BenchmarkError.malformedFixture("version observation clock exhausted")
                }
                let fallback = versionFallbackSeed[fallbackIndex]
                fallbackDates.append(fallback)
                fallbackIndex += 1
                observed.append((version, dateMicros(fallback), dateMicros(fallback)))
            }
        }
        observed.sort {
            if $0.sortKey != $1.sortKey { return $0.sortKey < $1.sortKey }
            return $0.raw.rowid < $1.raw.rowid
        }
        let versions = observed.map {
            VersionGolden(
                id: $0.raw.id,
                createdAt: $0.raw.createdAt,
                prompt: $0.raw.prompt,
                rowid: $0.raw.rowid,
                fallbackDateMicros: $0.fallback,
                sortKey: $0.sortKey
            )
        }
        let current = versions.last
        let hasPrompt = current?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        items.append(ItemGolden(summary: summary, versions: versions, currentVersionID: current?.id, hasPrompt: hasPrompt))
    }
    let golden = LegacyGolden(
        schema: "phase2a4.1-independent-legacy-golden-v1",
        itemCount: items.count,
        versionCount: items.reduce(0) { $0 + $1.versions.count },
        syntheticIDs: syntheticIDs,
        observationFallbackCount: fallbackIndex + itemFallbackDates.count,
        itemFallbackCount: itemFallbackDates.count,
        versionFallbackCount: fallbackIndex,
        items: items,
        itemObservationOrder: itemObservationOrder,
        itemShapeOrders: itemShapeOrders,
        itemRawCreatedAt: itemRawCreatedAt,
        itemObservedCreatedAtMicros: itemObservedCreatedAtMicros,
        itemFallbackDatesMicros: itemFallbackDates.map(dateMicros),
        versionFallbackDatesMicros: fallbackDates.map(dateMicros),
        itemSequenceDirection: "ascending",
        itemObservationOrderMatchesRowID: legacyObservationOrderMatchesRowID
    )
    return (golden, fallbackDates)
}

private func validateSyntheticLegacyOracle(_ golden: LegacyGolden) throws {
    let byID = golden.byID
    let dateVariants = byID["phase2a4-synthetic-date-variants"]?.versions ?? []
    let canonical = dateVariants.first(where: { $0.id == "canonical-version" })
    let offset = dateVariants.first(where: { $0.id == "offset-version" })
    let fractional = dateVariants.first(where: { $0.id == "fractional-version" })
    let malformed = dateVariants.first(where: { $0.id == "malformed-version" })
    guard byID["phase2a4-synthetic-equal-forward"]?.versions.map(\.id) == ["z-version", "a-version", "m-version"],
          byID["phase2a4-synthetic-equal-forward"]?.currentVersionID == "m-version",
          byID["phase2a4-synthetic-equal-forward"]?.hasPrompt == false,
          byID["phase2a4-synthetic-equal-reverse"]?.versions.map(\.id) == ["m-version-reverse", "a-version-reverse", "z-version-reverse"],
          byID["phase2a4-synthetic-equal-reverse"]?.currentVersionID == "z-version-reverse",
          byID["phase2a4-synthetic-equal-reverse"]?.hasPrompt == true,
          dateVariants.map(\.id) == ["canonical-version", "offset-version", "fractional-version", "malformed-version"],
          canonical?.sortKey == offset?.sortKey,
          canonical?.fallbackDateMicros == nil,
          offset?.fallbackDateMicros == nil,
          fractional?.fallbackDateMicros != nil,
          malformed?.fallbackDateMicros != nil,
          byID["phase2a4-synthetic-date-variants"]?.currentVersionID == "malformed-version",
          byID["phase2a4-synthetic-date-variants"]?.hasPrompt == true else {
        throw BenchmarkError.goldenMismatch("synthetic legacy Date/order oracle")
    }
}

private func cloneDatabaseOnline(source: URL, destinationLibrary: URL) throws {
    let destination = databaseURL(for: destinationLibrary)
    try? FileManager.default.removeItem(at: destinationLibrary)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sourceHandle = try openBenchmarkSource(databaseURL: source)
    defer { sqlite3_close(sourceHandle) }
    var destinationHandle: OpaquePointer?
    let destinationResult = sqlite3_open_v2(
        destination.path,
        &destinationHandle,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
    )
    guard destinationResult == SQLITE_OK, let destinationHandle else {
        let message = sqliteMessage(destinationHandle)
        let extended = destinationHandle.map(sqlite3_extended_errcode) ?? destinationResult
        sqlite3_close(destinationHandle)
        throw SQLiteError.backupFailed(message, resultCode: destinationResult, extendedCode: extended)
    }
    defer { sqlite3_close(destinationHandle) }
    sqlite3_extended_result_codes(destinationHandle, 1)
    guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
        throw SQLiteError.backupFailed(
            sqliteMessage(destinationHandle),
            resultCode: sqlite3_errcode(destinationHandle),
            extendedCode: sqlite3_extended_errcode(destinationHandle)
        )
    }
    let stepResult = sqlite3_backup_step(backup, -1)
    let finishResult = sqlite3_backup_finish(backup)
    guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
        let resultCode = stepResult == SQLITE_DONE ? finishResult : stepResult
        throw SQLiteError.backupFailed(
            sqliteMessage(destinationHandle),
            resultCode: resultCode,
            extendedCode: sqlite3_extended_errcode(destinationHandle)
        )
    }
    try? FileManager.default.removeItem(atPath: destination.path + "-wal")
    try? FileManager.default.removeItem(atPath: destination.path + "-shm")
}

private func checkpointAndHashArtifact(databaseURL: URL) throws -> String {
    func checkpoint() throws {
        let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }
    try checkpoint()
    // No repository/read handles are alive at this point. Remove SQLite's
    // sidecar journals before hashing so the report identifies the final
    // durable artifact on disk, not a transient WAL frame set.
    for suffix in ["-wal", "-shm", "-journal"] {
        let path = databaseURL.path + suffix
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
    guard let hash = try fileHash(databaseURL).sha256 else {
        throw BenchmarkError.missingFixture(databaseURL.path)
    }
    return hash
}

private struct SyntheticVersion {
    let id: String
    let version: String
    let prompt: String
    let createdAt: String
}

private struct SyntheticItem {
    let id: String
    let referencesJSON: String
    let versions: [SyntheticVersion]
    let createdAt: String
    let updatedAt: String
    let lastUsedAt: String
    let sortOrder: Int
    let favorite: Bool
    let deletedAt: String?
    let tags: [String]

    init(
        id: String,
        referencesJSON: String,
        versions: [SyntheticVersion],
        createdAt: String = "2024-01-01T00:00:00Z",
        updatedAt: String = "2024-01-01T00:00:00Z",
        lastUsedAt: String = "2024-01-01T00:00:00Z",
        sortOrder: Int = 2_000_000,
        favorite: Bool = false,
        deletedAt: String? = nil,
        tags: [String] = ["phase2a4"]
    ) {
        self.id = id
        self.referencesJSON = referencesJSON
        self.versions = versions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
        self.favorite = favorite
        self.deletedAt = deletedAt
        self.tags = tags
    }
}

private func syntheticItems() -> [SyntheticItem] {
    let validReference = #"[{"id":"phase2a4-ref","type":"image","path":"fixture://ref","label":"reference"}]"#
    let malformedReference = "[{\"id\":\"missing-type\",\"path\":\"fixture://ref\"}]"
    return [
        SyntheticItem(
            id: "phase2a4-synthetic-equal-forward",
            referencesJSON: validReference,
            versions: [
                SyntheticVersion(id: "z-version", version: "1.0", prompt: " ", createdAt: "2024-01-01T00:00:00Z"),
                SyntheticVersion(id: "a-version", version: "2.0", prompt: "old", createdAt: "2024-01-01T00:00:00Z"),
                SyntheticVersion(id: "m-version", version: "3.0", prompt: "\n\t", createdAt: "2024-01-01T00:00:00Z")
            ], sortOrder: 2_000_000, favorite: true, tags: ["phase2a4", "phase2a4-equal"]
        ),
        SyntheticItem(
            id: "phase2a4-synthetic-equal-reverse",
            referencesJSON: validReference,
            versions: [
                SyntheticVersion(id: "m-version-reverse", version: "1.0", prompt: "first", createdAt: "2024-01-01T00:00:00Z"),
                SyntheticVersion(id: "a-version-reverse", version: "2.0", prompt: "second", createdAt: "2024-01-01T00:00:00Z"),
                SyntheticVersion(id: "z-version-reverse", version: "3.0", prompt: "third", createdAt: "2024-01-01T00:00:00Z")
            ], sortOrder: 2_000_000, favorite: true, tags: ["phase2a4", "phase2a4-equal"]
        ),
        SyntheticItem(
            id: "phase2a4-synthetic-date-variants",
            referencesJSON: malformedReference,
            versions: [
                // Canonical/offset encode the same instant and therefore
                // exercise stable SQL-row-order tie handling.
                SyntheticVersion(id: "canonical-version", version: "1.0", prompt: "canonical", createdAt: "2024-01-01T00:00:00Z"),
                SyntheticVersion(id: "offset-version", version: "2.0", prompt: "offset", createdAt: "2024-01-01T01:00:00+01:00"),
                SyntheticVersion(id: "fractional-version", version: "3.0", prompt: "fractional", createdAt: "2024-01-01T00:00:00.123Z"),
                SyntheticVersion(id: "malformed-version", version: "4.0", prompt: "malformed", createdAt: "not-a-date")
            ], sortOrder: 2_000_001, tags: ["phase2a4", "phase2a4-date"]
        ),
        // Item-level equal-key insertion oracles.  SQLite row observation is
        // z→a→m and m→a→z while every business sort key is byte-identical.
        SyntheticItem(id: "z-item", referencesJSON: validReference, versions: [], sortOrder: 2_000_002, favorite: true, tags: ["phase2a4", "phase2a4-equal-item"]),
        SyntheticItem(id: "a-item", referencesJSON: validReference, versions: [], sortOrder: 2_000_002, favorite: true, tags: ["phase2a4", "phase2a4-equal-item"]),
        SyntheticItem(id: "m-item", referencesJSON: validReference, versions: [], sortOrder: 2_000_002, favorite: true, tags: ["phase2a4", "phase2a4-equal-item"]),
        SyntheticItem(id: "m-item-reverse", referencesJSON: validReference, versions: [], sortOrder: 2_000_003, favorite: true, tags: ["phase2a4", "phase2a4-equal-item"]),
        SyntheticItem(id: "a-item-reverse", referencesJSON: validReference, versions: [], sortOrder: 2_000_003, favorite: true, tags: ["phase2a4", "phase2a4-equal-item"]),
        SyntheticItem(id: "z-item-reverse", referencesJSON: validReference, versions: [], sortOrder: 2_000_003, favorite: true, tags: ["phase2a4", "phase2a4-equal-item"]),
        // Raw timestamp compatibility oracle: every form remains opaque in
        // prompt_items.createdAt while the persisted key is numeric.
        SyntheticItem(id: "phase2a4-item-ts-z", referencesJSON: "[]", versions: [], createdAt: "2024-01-01T00:00:00Z", sortOrder: 2_000_004, tags: ["phase2a4", "phase2a4-timestamps"]),
        SyntheticItem(id: "phase2a4-item-ts-offset", referencesJSON: "[]", versions: [], createdAt: "2024-01-01T01:00:00+01:00", sortOrder: 2_000_005, tags: ["phase2a4", "phase2a4-timestamps"]),
        SyntheticItem(id: "phase2a4-item-ts-dot1", referencesJSON: "[]", versions: [], createdAt: "2024-01-01T00:00:00.1Z", sortOrder: 2_000_006, tags: ["phase2a4", "phase2a4-timestamps"]),
        SyntheticItem(id: "phase2a4-item-ts-dot123456", referencesJSON: "[]", versions: [], createdAt: "2024-01-01T00:00:00.123456Z", sortOrder: 2_000_007, tags: ["phase2a4", "phase2a4-timestamps"]),
        SyntheticItem(id: "phase2a4-item-ts-legacy", referencesJSON: "[]", versions: [], createdAt: "2024-01-01 00:00:00 +0000", sortOrder: 2_000_008, tags: ["phase2a4", "phase2a4-timestamps"]),
        SyntheticItem(id: "phase2a4-item-ts-empty", referencesJSON: "[]", versions: [], createdAt: "", sortOrder: 2_000_009, tags: ["phase2a4", "phase2a4-timestamps"]),
        SyntheticItem(id: "phase2a4-item-ts-malformed", referencesJSON: "[]", versions: [], createdAt: "not-a-date", sortOrder: 2_000_010, tags: ["phase2a4", "phase2a4-timestamps"])
    ]
}

private func insertSyntheticRows(databaseURL: URL, lockedParameters: LockedPhase2A1Parameters) throws -> [String] {
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    let items = syntheticItems()
    let itemColumns = "id,title,type,assetKind,modelId,modelName,folderId,folderName,category,assetPath,thumbnailPath,aspectRatio,width,height,format,fileSize,favorite,pinnedAt,deletedAt,createdAt,updatedAt,lastUsedAt,sortOrder,tagsJSON,referencesJSON,description,captureId,captureSourceJSON"
    try database.transaction {
        for (index, item) in items.enumerated() {
            try database.run(
                "INSERT INTO prompt_items (\(itemColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);",
                values: [
                    .text(item.id), .text("Phase2A4 synthetic \(index)"), .text(lockedParameters.type), .text("image"),
                    .text(lockedParameters.modelID), .text("Phase2A4 Model"), .text(lockedParameters.folderID), .text("Phase2A4 Folder"),
                    .text("phase2a4"), .text("fixture://phase2a4/\(item.id)"), .text("fixture://phase2a4/thumb/\(item.id)"),
                    .text("1:1"), .int(1), .int(1), .text("fixture"), .int(0), .int(item.favorite ? 1 : 0), .null,
                    item.deletedAt.map(SQLiteValue.text) ?? .null,
                    .text(item.createdAt), .text(item.updatedAt), .text(item.lastUsedAt),
                    .int(Int64(item.sortOrder)),
                    .text(String(data: try JSONEncoder().encode(item.tags), encoding: .utf8) ?? "[]"), .text(item.referencesJSON),
                    .text("phase2a4 synthetic edge row"), .null, .null
                ]
            )
            for version in item.versions {
                try database.run(
                    "INSERT INTO prompt_versions (id,promptItemId,version,prompt,negativePrompt,parametersJSON,note,createdAt) VALUES (?,?,?,?,?,?,?,?);",
                    values: [
                        .text(version.id), .text(item.id), .text(version.version), .text(version.prompt), .text(""),
                        .text("{}"), .text("synthetic"), .text(version.createdAt)
                    ]
                )
            }
        }
    }
    return items.map(\.id)
}

private func ensureTagRelations(_ repository: PromptRepository, batchSize: Int) throws {
    if !repository.tagRelationsReady {
        _ = try repository.prepareTagRelationMigration()
        _ = try repository.runTagRelationBackfill(batchSize: batchSize)
        _ = try repository.validateTagRelationConsistency()
    }
    guard repository.tagRelationsReady else {
        throw BenchmarkError.unsupported("tag relation migration did not become ready")
    }
}

private func migrate(
    _ repository: PromptRepository,
    fallbackDates: [Date],
    itemFallbackDates: [Date] = [],
    batchSize: Int
) throws {
    _ = try repository.prepareVersionSequenceMigration()
    let clock = VersionSequenceObservationClock(dates: fallbackDates)
    _ = try repository.runVersionSequenceMigration(batchSize: batchSize, observationClock: clock)
    guard repository.versionSequenceMigrationReady else {
        throw BenchmarkError.malformedFixture("version sequence migration not ready")
    }
    // Legacy golden capture completes before this helper.  Summary runtime
    // capabilities require an explicit, persisted item-sequence migration as
    // well; make the benchmark clone fully ready before validating queries.
    _ = try repository.prepareItemSequenceMigration()
    // The item clock is seeded from the single pre-ready loadItems() oracle;
    // migration never calls wall-clock Date() for malformed/empty raw values.
    let itemClock = ItemSequenceObservationClock(dates: itemFallbackDates)
    _ = try repository.runItemSequenceMigration(batchSize: batchSize, observationClock: itemClock)
    guard repository.itemSequenceMigrationReady else {
        throw BenchmarkError.malformedFixture("item sequence migration not ready")
    }
}

private struct ExpectedQueries {
    let folderID: String
    let modelID: String
    let type: PromptType
    let tag: String

    func query(named name: String) -> LibraryQuery {
        query(named: name, pageSize: 300)
    }

    func query(named name: String, pageSize: Int) -> LibraryQuery {
        switch name {
        case "All": return LibraryQuery(.all, pageSize: pageSize)
        case "Folder": return LibraryQuery(.folder(folderID), pageSize: pageSize)
        case "Tag": return LibraryQuery(.tag(tag), pageSize: pageSize)
        case "Type": return LibraryQuery(.type(type), pageSize: pageSize)
        case "Model": return LibraryQuery(.model(modelID), pageSize: pageSize)
        case "Favorite": return LibraryQuery(.favorite, pageSize: pageSize)
        case "Recent": return LibraryQuery(.recent, pageSize: pageSize)
        case "Trash": return LibraryQuery(.trash, pageSize: pageSize)
        case "Combined": return LibraryQuery(.folder(folderID), pageSize: pageSize, type: type, modelId: modelID, favoriteOnly: true)
        default: return LibraryQuery(.all, pageSize: pageSize)
        }
    }
}

private let queryNames = ["All", "Folder", "Tag", "Type", "Model", "Favorite", "Recent", "Trash", "Combined"]

private func expectedQueries(locked: LockedPhase2A1Parameters) throws -> ExpectedQueries {
    guard let type = PromptType(rawValue: locked.type) else { throw BenchmarkError.malformedFixture("golden-results.parameters.type") }
    // A missing legacy tag uses the synthetic equal-key tag so Tag remains a
    // meaningful shape while preserving the source tag when one exists.
    return ExpectedQueries(
        folderID: locked.folderID,
        modelID: locked.modelID,
        type: type,
        tag: locked.tag ?? "phase2a4-equal-item"
    )
}

private func validateMigratedVersions(databaseURL: URL, golden: LegacyGolden) throws {
    let read = try SQLiteReadConnection(url: databaseURL)
    let rows = try read.querySync(
        "SELECT promptItemId,id,prompt,versionCreatedAtSortKey,versionSequence FROM prompt_versions ORDER BY promptItemId COLLATE BINARY ASC, versionCreatedAtSortKey ASC, versionSequence ASC;"
    )
    var actualByItem: [String: [(id: String, prompt: String, sortKey: Int64, sequence: Int64)]] = [:]
    actualByItem.reserveCapacity(golden.items.count)
    for row in rows {
        actualByItem[requiredString(row, "promptItemId"), default: []].append(
            (
                requiredString(row, "id"),
                requiredString(row, "prompt"),
                integer64(row, "versionCreatedAtSortKey"),
                integer64(row, "versionSequence")
            )
        )
    }
    for item in golden.items {
        let actual = actualByItem[item.summary.id, default: []]
        let expectedIDs = item.versions.map(\.id)
        guard actual.map(\.id) == expectedIDs else {
            throw BenchmarkError.goldenMismatch(item.summary.id + ".migratedVersionOrder")
        }
        for (index, version) in item.versions.enumerated() {
            let persisted = actual[index]
            guard persisted.sortKey == version.sortKey,
                  persisted.sequence == Int64(index + 1) else {
                throw BenchmarkError.goldenMismatch(item.summary.id + ".persistedVersionSortKeySequence")
            }
        }
        let actualCurrent = actual.last
        let actualHasPrompt = actualCurrent?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard actualCurrent?.id == item.currentVersionID,
              actualHasPrompt == item.hasPrompt else {
            throw BenchmarkError.goldenMismatch(item.summary.id + ".migratedCurrentVersion")
        }
    }
}

private func sortedIDs(
    _ records: [ItemGolden],
    name: String,
    parameters: ExpectedQueries,
    legacyShapeOrders: [String: [String]] = [:]
) -> [String] {
    // Every expected shape is captured from the real pre-ready loader.  A
    // missing capture is intentionally an empty expectation so validation
    // fails closed; never synthesize a lexical ID order here.
    _ = records
    _ = parameters
    return legacyShapeOrders[name] ?? []
}

private struct TimingStats: Codable {
    let count: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double

    init(_ values: [Double]) {
        let ordered = values.sorted()
        count = ordered.count
        guard !ordered.isEmpty else {
            p50Milliseconds = 0
            p95Milliseconds = 0
            maxMilliseconds = 0
            return
        }
        func percentile(_ fraction: Double) -> Double {
            let index = max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * fraction)) - 1))
            return ordered[index]
        }
        p50Milliseconds = percentile(0.50)
        p95Milliseconds = percentile(0.95)
        maxMilliseconds = ordered[ordered.count - 1]
    }
}

private func stageTiming(_ durations: [Double], batchSize: Int? = nil, bytesBefore: Int? = nil, bytesAfter: Int? = nil, errors: Int = 0, busy: Int = 0, locked: Int = 0) -> [String: Any] {
    var result: [String: Any] = [
        "count": durations.count,
        "p50Milliseconds": TimingStats(durations).p50Milliseconds,
        "p95Milliseconds": TimingStats(durations).p95Milliseconds,
        "maxMilliseconds": TimingStats(durations).maxMilliseconds,
        "errors": errors,
        "busy": busy,
        "locked": locked
    ]
    if let batchSize { result["batchSize"] = batchSize }
    if let bytesBefore { result["bytesBefore"] = bytesBefore }
    if let bytesAfter { result["bytesAfter"] = bytesAfter }
    return result
}

private func milliseconds(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private let pageCountTimingSemantics = "pageSQL is measured through SQLiteReadConnection's page-complete hook; countSQL is the residual transaction elapsed (total queryPageAndCount time minus pageSQL), including count and transaction tail"

/// Receives SQLiteReadConnection's page-complete callback so the benchmark
/// can retain page/count stage timings while the production read batch keeps
/// both statements inside one deferred transaction.
private final class PageCountTimingState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var activeID: UInt64?
    private var pageStart: UInt64?
    private var pageElapsed: Double?

    func begin(pageStart: UInt64) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard activeID == nil else {
            throw BenchmarkError.timingInvariant("overlapping queryPageAndCount timing calls")
        }
        nextID &+= 1
        let id = nextID
        activeID = id
        self.pageStart = pageStart
        pageElapsed = nil
        return id
    }

    func markPageComplete() {
        lock.lock()
        if activeID != nil, let pageStart, pageElapsed == nil {
            pageElapsed = milliseconds(pageStart)
        }
        lock.unlock()
    }

    func finish(id: UInt64) throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard activeID == id else {
            throw BenchmarkError.timingInvariant("page/count timing owner changed before completion")
        }
        defer {
            activeID = nil
            pageStart = nil
            pageElapsed = nil
        }
        guard let elapsed = pageElapsed else {
            throw BenchmarkError.timingInvariant("queryPageAndCount page timing hook did not fire")
        }
        return elapsed
    }

    func cancel(id: UInt64) {
        lock.lock()
        guard activeID == id else {
            lock.unlock()
            return
        }
        activeID = nil
        pageStart = nil
        pageElapsed = nil
        lock.unlock()
    }
}

private func pageCountTimingBreakdown(totalElapsed: Double, pageElapsed: Double?) throws -> (page: Double, count: Double) {
    guard let pageElapsed else {
        throw BenchmarkError.timingInvariant("page timing hook did not provide a stage duration")
    }
    guard pageElapsed >= 0, pageElapsed <= totalElapsed else {
        throw BenchmarkError.timingInvariant("page timing exceeded total queryPageAndCount duration")
    }
    return (pageElapsed, totalElapsed - pageElapsed)
}

private func validatePageCountTimingContract() throws {
    guard (try? pageCountTimingBreakdown(totalElapsed: 10, pageElapsed: nil)) == nil else {
        throw BenchmarkError.timingInvariant("missing page timing hook was accepted")
    }
    let breakdown = try pageCountTimingBreakdown(totalElapsed: 10, pageElapsed: 3)
    guard breakdown.page == 3, breakdown.count == 7 else {
        throw BenchmarkError.timingInvariant("page/count residual timing semantics changed")
    }
    let state = PageCountTimingState()
    let owner = try state.begin(pageStart: DispatchTime.now().uptimeNanoseconds)
    var overlapRejected = false
    do {
        _ = try state.begin(pageStart: DispatchTime.now().uptimeNanoseconds)
    } catch BenchmarkError.timingInvariant(_) {
        overlapRejected = true
    }
    guard overlapRejected else {
        throw BenchmarkError.timingInvariant("overlapping timing calls were accepted")
    }
    var missingHookRejected = false
    do {
        _ = try state.finish(id: owner)
    } catch BenchmarkError.timingInvariant(_) {
        missingHookRejected = true
    }
    guard missingHookRejected else {
        throw BenchmarkError.timingInvariant("missing page callback was accepted by timing state")
    }
    state.cancel(id: owner)
}

private final class TimedExecutor: LibraryQueryRowExecutor, @unchecked Sendable {
    private let connection: SQLiteReadConnection
    private let pageCountTiming: PageCountTimingState
    private let lock = NSLock()
    private var sqlDurations: [Double] = []
    private var pageDurations: [Double] = []
    private var countDurations: [Double] = []

    init(path: String) throws {
        let pageCountTiming = PageCountTimingState()
        self.pageCountTiming = pageCountTiming
        connection = try SQLiteReadConnection(
            path: path,
            queryPageAndCountHook: { pageCountTiming.markPageComplete() }
        )
    }

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let rows = try await connection.query(sql, values: values)
            lock.withLock { sqlDurations.append(milliseconds(start)) }
            return rows
        } catch {
            lock.withLock { sqlDurations.append(milliseconds(start)) }
            throw error
        }
    }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        let totalStart = DispatchTime.now().uptimeNanoseconds
        var timingID: UInt64?
        do {
            timingID = try pageCountTiming.begin(pageStart: totalStart)
            let batch = try await connection.queryPageAndCount(
                pageSQL: pageSQL,
                pageValues: pageValues,
                countSQL: countSQL,
                countValues: countValues
            )
            let totalElapsed = milliseconds(totalStart)
            guard let timingID else {
                throw BenchmarkError.timingInvariant("queryPageAndCount timing owner was not established")
            }
            let pageElapsed = try pageCountTiming.finish(id: timingID)
            let stages = try pageCountTimingBreakdown(totalElapsed: totalElapsed, pageElapsed: pageElapsed)
            lock.withLock {
                pageDurations.append(stages.page)
                countDurations.append(stages.count)
                sqlDurations.append(totalElapsed)
            }
            return batch
        } catch {
            let totalElapsed = milliseconds(totalStart)
            if let timingID { pageCountTiming.cancel(id: timingID) }
            lock.withLock { sqlDurations.append(totalElapsed) }
            throw error
        }
    }

    func takeSQLDurations() -> [Double] {
        lock.withLock {
            let values = sqlDurations
            sqlDurations.removeAll(keepingCapacity: true)
            return values
        }
    }

    func takeStageDurations() -> (page: [Double], count: [Double]) {
        lock.withLock {
            let result = (pageDurations, countDurations)
            pageDurations.removeAll(keepingCapacity: true)
            countDurations.removeAll(keepingCapacity: true)
            return result
        }
    }
}

private func compareSummary(_ summary: LibraryItemSummary, expected: ItemGolden) throws {
    let golden = expected.summary
    guard summary.id == golden.id,
          summary.title == golden.title,
          summary.type.rawValue == golden.type,
          summary.assetKind.rawValue == golden.assetKind,
          summary.modelId == golden.modelId,
          summary.modelName == golden.modelName,
          summary.folderId == golden.folderId,
          summary.folderName == golden.folderName,
          summary.category == golden.category,
          summary.assetPath == golden.assetPath,
          summary.thumbnailPath == golden.thumbnailPath,
          summary.aspectRatio == golden.aspectRatio,
          summary.width == golden.width,
          summary.height == golden.height,
          summary.format == golden.format,
          summary.fileSize == golden.fileSize,
          summary.favorite == golden.favorite,
          summary.pinnedAt.map(dateMicros) == golden.pinnedAtMicros,
          summary.deletedAt.map(dateMicros) == golden.deletedAtMicros,
          dateMicros(summary.createdAt) == golden.createdAtMicros,
          dateMicros(summary.updatedAt) == golden.updatedAtMicros,
          dateMicros(summary.lastUsedAt) == golden.lastUsedAtMicros,
          summary.sortOrder == golden.sortOrder,
          summary.hasPrompt == expected.hasPrompt,
          summary.hasReferences == golden.hasReferences else {
        throw BenchmarkError.goldenMismatch(summary.id + ".summary")
    }
}

private func validateSummaryPage(
    _ page: LibraryItemPage,
    expectedIDs: [String],
    expected: [String: ItemGolden],
    expectedCount: Int,
    start: Int,
    queryName: String
) throws -> [String] {
    guard page.totalCount == expectedCount else {
        throw BenchmarkError.goldenMismatch(queryName + ".totalCount expected=\(expectedCount) actual=\(page.totalCount)")
    }
    let ids = page.items.map(\.id)
    guard ids == Array(expectedIDs.dropFirst(start).prefix(ids.count)) else {
        throw BenchmarkError.goldenMismatch(queryName + ".ids@\(start)")
    }
    guard Set(ids).count == ids.count else { throw BenchmarkError.goldenMismatch(queryName + ".duplicate@\(start)") }
    for item in page.items {
        guard let golden = expected[item.id] else { throw BenchmarkError.goldenMismatch(queryName + ".missing:" + item.id) }
        try compareSummary(item, expected: golden)
    }
    return ids
}

private func explain(databaseURL: URL, query: LibraryQuery, capabilities: LibraryQueryCapabilities) throws -> [String] {
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    let built = try LibraryQuerySQLBuilder.build(query, capabilities: capabilities)
    let count = try LibraryQuerySQLBuilder.buildCount(query, capabilities: capabilities)
    let pageDetails = try database.query("EXPLAIN QUERY PLAN \(built.sql)", values: built.values)
        .compactMap { optionalString($0, "detail") }
        .map { "page: \($0)" }
    let countDetails = try database.query("EXPLAIN QUERY PLAN \(count.sql)", values: count.values)
        .compactMap { optionalString($0, "detail") }
        .map { "count: \($0)" }
    return pageDetails + countDetails
}

private let expectedTagTempBTreeDetail = "USE TEMP B-TREE FOR ORDER BY"

private func normalizedPlanDetail(_ detail: String) -> String {
    detail.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

private func tagPageTempBTreeOnlyOrder(_ pagePlan: [String]) -> Bool {
    let tempBTreeDetails = pagePlan.filter { $0.localizedCaseInsensitiveContains("temp b-tree") }
    guard tempBTreeDetails.count <= 1 else { return false }
    guard let detail = tempBTreeDetails.first else { return true }
    return normalizedPlanDetail(detail) == expectedTagTempBTreeDetail
}

private func validateTagTempBTreeContract() throws {
    guard tagPageTempBTreeOnlyOrder([]), tagPageTempBTreeOnlyOrder([expectedTagTempBTreeDetail]) else {
        throw BenchmarkError.explainContract("Tag TEMP B-TREE contract rejected the no-sort or expected-order cases")
    }
    guard !tagPageTempBTreeOnlyOrder(["USE TEMP B-TREE FOR DISTINCT", expectedTagTempBTreeDetail]) else {
        throw BenchmarkError.explainContract("Tag TEMP B-TREE contract accepted an extra non-ORDER-BY node")
    }
}

private func explainContract(
    databaseURL: URL,
    query: LibraryQuery,
    capabilities: LibraryQueryCapabilities,
    shape: String
) throws -> [String: Any] {
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    let built = try LibraryQuerySQLBuilder.build(query, capabilities: capabilities)
    let count = try LibraryQuerySQLBuilder.buildCount(query, capabilities: capabilities)
    let pagePlan = try database.query("EXPLAIN QUERY PLAN \(built.sql)", values: built.values).compactMap { optionalString($0, "detail") }
    let countPlan = try database.query("EXPLAIN QUERY PLAN \(count.sql)", values: count.values).compactMap { optionalString($0, "detail") }
    var cursorSQL = ""
    if let row = try database.query("SELECT sortOrder,itemLastUsedAtSortKey,itemCreatedAtSortKey,itemSequence,id FROM prompt_items ORDER BY rowid LIMIT 1;").first {
        let cursor = LibraryQueryCursor(
            queryFingerprint: built.queryFingerprint,
            sortOrder: Int(optionalString(row, "sortOrder") ?? ""),
            lastUsedAtSortKey: nil,
            createdAtSortKey: "0",
            id: requiredString(row, "id"),
            itemCreatedAtSortKey: Int64(optionalString(row, "itemCreatedAtSortKey") ?? ""),
            itemLastUsedAtSortKey: Int64(optionalString(row, "itemLastUsedAtSortKey") ?? ""),
            itemSequence: Int64(optionalString(row, "itemSequence") ?? "")
        )
        var cursorQuery = query
        cursorQuery.cursor = cursor
        let cursorBuilt = try LibraryQuerySQLBuilder.build(cursorQuery, capabilities: capabilities)
        cursorSQL = cursorBuilt.sql
    }
    let orderClause = built.sql.components(separatedBy: "ORDER BY").dropFirst().first ?? ""
    let lowerOrder = orderClause.lowercased()
    let lowerCursor = cursorSQL.lowercased()
    let pagePlanText = pagePlan.joined(separator: "\n")
    let countPlanText = countPlan.joined(separator: "\n")
    let pageUsesTempBTree = pagePlanText.localizedCaseInsensitiveContains("temp b-tree")
    let countUsesTempBTree = countPlanText.localizedCaseInsensitiveContains("temp b-tree")
    let pageTempBTreeDetails = pagePlan.filter { $0.localizedCaseInsensitiveContains("temp b-tree") }
    let pageTagTempBTreeOnlyOrder = shape != "Tag" || tagPageTempBTreeOnlyOrder(pagePlan)
    let pageNoTemp = !pageUsesTempBTree
    let countNoTemp = !countUsesTempBTree
    let noTemp = pageNoTemp && countNoTemp
    let pageNoPromptScan = !pagePlanText.localizedCaseInsensitiveContains("scan prompt_versions") && !pagePlanText.localizedCaseInsensitiveContains("scan v")
    let countNoPromptScan = !countPlanText.localizedCaseInsensitiveContains("scan prompt_versions") && !countPlanText.localizedCaseInsensitiveContains("scan v")
    let noPromptScan = pageNoPromptScan && countNoPromptScan
    let persistedOrder = lowerOrder.contains("itemcreatedatsortkey") && lowerOrder.contains("itemsequence")
    let noIdentityTie = !lowerOrder.contains("id asc") && !lowerOrder.contains("id desc") && !lowerOrder.contains("rowid")
    let cursorUsesSequence = lowerCursor.contains("itemsequence") && lowerCursor.contains("itemcreatedatsortkey")
    let expectedIndex: String = {
        switch shape {
        case "All": return "idx_phase2a4_1_prompt_items_all"
        case "Folder": return "idx_phase2a4_1_prompt_items_folder"
        case "Type": return "idx_phase2a4_1_prompt_items_type"
        case "Model": return "idx_phase2a4_1_prompt_items_model"
        case "Favorite", "Combined": return "idx_phase2a4_1_prompt_items_favorite"
        case "Recent": return "idx_phase2a4_1_prompt_items_recent"
        case "Trash": return "idx_phase2a4_1_prompt_items_trash"
        case "Tag": return "idx_phase2a2_prompt_item_tags_tag_order"
        default: return "idx_phase2a4_1_prompt_items_all"
        }
    }()
    let pageUsesExpectedIndex = pagePlanText.contains(expectedIndex)
    // SQLite may choose any active item-order index for the unfiltered All
    // COUNT (there is no ORDER BY to constrain that plan). Preserve the
    // existing contract while checking the count plan independently.
    let countExpectedIndex = shape == "All"
        ? [
            "idx_phase2a4_1_prompt_items_all",
            "idx_phase2a4_1_prompt_items_favorite",
            "idx_phase2a4_1_prompt_items_folder",
            "idx_phase2a4_1_prompt_items_model",
            "idx_phase2a4_1_prompt_items_recent",
            "idx_phase2a4_1_prompt_items_type"
        ]
        : [expectedIndex]
    let countUsesExpectedIndex = countExpectedIndex.contains { countPlanText.contains($0) }
    let usesExpectedIndex = pageUsesExpectedIndex && countUsesExpectedIndex
    let pageUsesTagRelationIndex = shape != "Tag" || pagePlanText.contains("idx_phase2a2_prompt_item_tags_tag_order")
    let countUsesTagRelationIndex = shape != "Tag" || countPlanText.contains("idx_phase2a2_prompt_item_tags_tag_order")
    let usesTagRelationIndex = pageUsesTagRelationIndex && countUsesTagRelationIndex
    let pageUsesTagPromptItemLookup = shape != "Tag" || pagePlanText.contains("sqlite_autoindex_prompt_items_1")
    let countUsesTagPromptItemLookup = shape != "Tag" || countPlanText.contains("sqlite_autoindex_prompt_items_1")
    let usesTagPromptItemLookup = pageUsesTagPromptItemLookup && countUsesTagPromptItemLookup
    let acceptableOrderPlan = shape == "Tag"
        ? pageTagTempBTreeOnlyOrder && countNoTemp
        : pageNoTemp && countNoTemp
    let pass = persistedOrder && noIdentityTie && cursorUsesSequence && acceptableOrderPlan && noPromptScan && usesExpectedIndex && usesTagRelationIndex && usesTagPromptItemLookup
    return [
        "pageSQL": built.sql,
        "countSQL": count.sql,
        "cursorSQL": cursorSQL,
        "pagePlan": pagePlan,
        "countPlan": countPlan,
        "queryFingerprint": built.queryFingerprint,
        "expectedIndex": expectedIndex,
        "countExpectedIndex": shape == "All" ? "any-active-item-order-index" : expectedIndex,
        "pageUsesExpectedIndex": pageUsesExpectedIndex,
        "countUsesExpectedIndex": countUsesExpectedIndex,
        "usesExpectedIndex": usesExpectedIndex,
        "pageUsesTagRelationIndex": pageUsesTagRelationIndex,
        "countUsesTagRelationIndex": countUsesTagRelationIndex,
        "usesTagRelationIndex": usesTagRelationIndex,
        "pageUsesTagPromptItemLookup": pageUsesTagPromptItemLookup,
        "countUsesTagPromptItemLookup": countUsesTagPromptItemLookup,
        "usesTagPromptItemLookup": usesTagPromptItemLookup,
        "persistedSequenceOrder": persistedOrder,
        "cursorUsesPersistedSequence": cursorUsesSequence,
        "noIdentityTie": noIdentityTie,
        "pageNoTempBTree": pageNoTemp,
        "countNoTempBTree": countNoTemp,
        "noTempBTree": noTemp,
        "pageAllowsExpectedTagTempBTree": shape == "Tag" && pageTagTempBTreeOnlyOrder,
        "pageTagTempBTreeDetails": pageTempBTreeDetails,
        "pageTagTempBTreeOnlyOrder": pageTagTempBTreeOnlyOrder,
        "pageNoPromptVersionScan": pageNoPromptScan,
        "countNoPromptVersionScan": countNoPromptScan,
        "noPromptVersionScan": noPromptScan,
        "pass": pass
    ]
}

private func benchmarkQuery(
    service: LibraryQueryService,
    executor: TimedExecutor,
    query: LibraryQuery,
    iterations: Int
) async throws -> [String: TimingStats] {
    for _ in 0..<2 {
        _ = try await service.query(query)
        _ = executor.takeSQLDurations()
        _ = executor.takeStageDurations()
    }
    var sql: [Double] = []
    var decode: [Double] = []
    var total: [Double] = []
    var pageSQL: [Double] = []
    var countSQL: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await service.query(query)
        let elapsed = milliseconds(start)
        let sqlValue = executor.takeSQLDurations().reduce(0, +)
        let stages = executor.takeStageDurations()
        pageSQL.append(contentsOf: stages.page)
        countSQL.append(contentsOf: stages.count)
        total.append(elapsed)
        sql.append(sqlValue)
        decode.append(max(0, elapsed - sqlValue))
    }
    return ["sql": TimingStats(sql), "pageSQL": TimingStats(pageSQL), "countSQL": TimingStats(countSQL), "decode": TimingStats(decode), "total": TimingStats(total)]
}

private func projectionVariantTiming(
    read: SQLiteReadConnection,
    pageSQL: String,
    pageValues: [SQLiteValue],
    countSQL: String?,
    countValues: [SQLiteValue],
    iterations: Int
) throws -> [String: Any] {
    for _ in 0..<2 {
        _ = try read.querySync(pageSQL, values: pageValues)
        if let countSQL { _ = try read.querySync(countSQL, values: countValues) }
    }
    var durations: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try read.querySync(pageSQL, values: pageValues)
        if let countSQL { _ = try read.querySync(countSQL, values: countValues) }
        durations.append(milliseconds(start))
    }
    let stats = TimingStats(durations)
    return [
        "count": stats.count,
        "p50Milliseconds": stats.p50Milliseconds,
        "p95Milliseconds": stats.p95Milliseconds,
        "maxMilliseconds": stats.maxMilliseconds,
        "sqlP50Milliseconds": stats.p50Milliseconds,
        "decodeP50Milliseconds": 0.0,
        "includesCount": countSQL != nil
    ]
}

private func applesToApplesProjectionVariants(
    databaseURL: URL,
    service: LibraryQueryService,
    executor: TimedExecutor,
    capabilities: LibraryQueryCapabilities,
    locked: LockedPhase2A1Parameters,
    iterations: Int
) async throws -> [String: Any] {
    let read = try SQLiteReadConnection(url: databaseURL)
    let allQuery = LibraryQuery(.all, pageSize: 300)
    let fullPage = try LibraryQuerySQLBuilder.build(allQuery, capabilities: capabilities)
    let fullCount = try LibraryQuerySQLBuilder.buildCount(allQuery, capabilities: capabilities)
    let orderingPage = """
        SELECT p.id, p.sortOrder, p.createdAt, p.lastUsedAt
        FROM prompt_items p
        WHERE p.deletedAt IS NULL
        ORDER BY p.sortOrder ASC, p.createdAt DESC, p.id ASC
        LIMIT ?;
        """
    let orderingCount = "SELECT COUNT(*) AS totalCount FROM prompt_items p WHERE p.deletedAt IS NULL;"
    let latestPage = """
        SELECT p.id, p.sortOrder, p.createdAt, p.lastUsedAt,
               COALESCE((
                   SELECT ps_trim_whitespace(v.prompt)
                   FROM prompt_versions v
                   WHERE v.promptItemId = p.id
                     AND v.versionCreatedAtSortKey = (
                         SELECT MAX(v2.versionCreatedAtSortKey)
                         FROM prompt_versions v2 WHERE v2.promptItemId = p.id
                     )
                     AND v.versionSequence = (
                         SELECT MAX(v3.versionSequence)
                         FROM prompt_versions v3
                         WHERE v3.promptItemId = p.id
                           AND v3.versionCreatedAtSortKey = v.versionCreatedAtSortKey
                     )
                   LIMIT 1
               ), '') <> '' AS hasPrompt
        FROM prompt_items p
        WHERE p.deletedAt IS NULL
        ORDER BY p.sortOrder ASC, p.createdAt DESC, p.id ASC
        LIMIT ?;
        """
    let referencePage = """
        SELECT p.id, p.sortOrder, p.createdAt, p.lastUsedAt,
               ps_reference_asset_count(p.referencesJSON) > 0 AS hasReferences
        FROM prompt_items p
        WHERE p.deletedAt IS NULL
        ORDER BY p.sortOrder ASC, p.createdAt DESC, p.id ASC
        LIMIT ?;
        """
    let pageLimit: [SQLiteValue] = [.int(301)]
    var variants: [String: Any] = [:]
    variants["orderingOnlyPage"] = try projectionVariantTiming(
        read: read, pageSQL: orderingPage, pageValues: pageLimit,
        countSQL: nil, countValues: [], iterations: iterations
    )
    variants["orderingOnlyPageAndCount"] = try projectionVariantTiming(
        read: read, pageSQL: orderingPage, pageValues: pageLimit,
        countSQL: orderingCount, countValues: [], iterations: iterations
    )
    variants["latestHasPrompt"] = try projectionVariantTiming(
        read: read, pageSQL: latestPage, pageValues: pageLimit,
        countSQL: orderingCount, countValues: [], iterations: iterations
    )
    variants["referenceScalar"] = try projectionVariantTiming(
        read: read, pageSQL: referencePage, pageValues: pageLimit,
        countSQL: orderingCount, countValues: [], iterations: iterations
    )
    variants["fullProjection"] = try projectionVariantTiming(
        read: read, pageSQL: fullPage.sql, pageValues: fullPage.values,
        countSQL: fullCount.sql, countValues: fullCount.values, iterations: iterations
    )
    let decodeTimings = try await benchmarkQuery(
        service: service, executor: executor, query: allQuery, iterations: iterations
    )
    var decodeVariant = timingJSON(decodeTimings)
    if let total = decodeVariant["total"] as? [String: Any] {
        decodeVariant["count"] = total["count"] ?? iterations
        decodeVariant["p50Milliseconds"] = total["p50Milliseconds"] ?? 0.0
        decodeVariant["p95Milliseconds"] = total["p95Milliseconds"] ?? 0.0
        decodeVariant["maxMilliseconds"] = total["maxMilliseconds"] ?? 0.0
        decodeVariant["sqlP50Milliseconds"] = (decodeVariant["sql"] as? [String: Any])?["p50Milliseconds"] ?? 0.0
        decodeVariant["decodeP50Milliseconds"] = (decodeVariant["decode"] as? [String: Any])?["p50Milliseconds"] ?? 0.0
    }
    decodeVariant["includesCount"] = true
    decodeVariant["attribution"] = "LibraryQueryService Summary decode over full projection"
    variants["decode"] = decodeVariant

    if let pageAndCount = variants["orderingOnlyPageAndCount"] as? [String: Any],
       let base = pageAndCount["p50Milliseconds"] as? Double {
        for key in ["latestHasPrompt", "referenceScalar", "fullProjection", "decode"] {
            guard var variant = variants[key] as? [String: Any],
                  let value = variant["p50Milliseconds"] as? Double else { continue }
            let ratio = value / max(base, 0.000001)
            variant["relativeP50ToOrderingOnlyPageAndCount"] = ratio
            if ratio > 1.2 {
                variant["classification"] = "projection_overhead_gt20_percent"
                variant["reason"] = "additional \(key) projection/count/decode work; Phase2A1 IDs-only baseline is nonComparable"
            } else {
                variant["classification"] = "within_20_percent"
                variant["reason"] = "same final clone/page/count shape; no material projection delta"
            }
            variants[key] = variant
        }
    }
    let lockedParamsJSON: [String: Any] = [
        "folderId": locked.folderID,
        "modelId": locked.modelID,
        "type": locked.type,
        "tag": locked.tag ?? NSNull()
    ]
    return [
        "scope": "same final migrated clone, All query, pageSize=300, locked legacy params",
        "lockedParams": lockedParamsJSON,
        "pageRowsRequested": 301,
        "iterations": iterations,
        "phase2A1LegacyIDsOnlyComparable": false,
        "variants": variants,
        "attribution": [
            "orderingOnlyPage": "ordering and page projection only",
            "orderingOnlyPageAndCount": "ordering/page plus count query",
            "latestHasPrompt": "adds indexed latest-version hasPrompt scalar",
            "referenceScalar": "adds exact ReferenceAsset decoder scalar",
            "fullProjection": "full Summary SQL page/count without Swift decode",
            "decode": "full Summary SQL plus LibraryQueryService Swift Summary decode"
        ]
    ]
}

private func migrateAndValidate(
    libraryURL: URL,
    golden: LegacyGolden,
    fallbackDates: [Date],
    batchSize: Int
) throws -> PromptRepository {
    let repository = try PromptRepository(libraryURL: libraryURL)
    try ensureTagRelations(repository, batchSize: batchSize)
    let itemFallbackDates = golden.itemFallbackDatesMicros.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
    try migrate(repository, fallbackDates: fallbackDates, itemFallbackDates: itemFallbackDates, batchSize: batchSize)
    let database = try SQLiteDatabase(path: databaseURL(for: libraryURL).path, mode: .existingReadWrite)
    guard try database.query("PRAGMA integrity_check;").first.map({ optionalString($0, "integrity_check") }) == "ok" else {
        throw BenchmarkError.malformedFixture("integrity_check")
    }
    guard try database.query("PRAGMA foreign_key_check;").isEmpty else {
        throw BenchmarkError.malformedFixture("foreign_key_check")
    }
    let rows = try database.query("SELECT COUNT(*) AS count FROM prompt_items;")
    guard integer(rows.first ?? [:], "count") == golden.itemCount else {
        throw BenchmarkError.goldenMismatch("itemCount")
    }
    return repository
}

private func validateAllSummaries(
    service: LibraryQueryService,
    golden: LegacyGolden,
    parameters: ExpectedQueries,
    completePagination: Bool
) async throws -> (ids: [String: [String]], counts: [String: [String: Any]]) {
    let expected = golden.byID
    var result: [String: [String]] = [:]
    var countReports: [String: [String: Any]] = [:]
    for name in queryNames {
        var query = parameters.query(named: name)
        let expectedIDs = sortedIDs(golden.items, name: name, parameters: parameters, legacyShapeOrders: golden.itemShapeOrders)
        let expectedCount = expectedIDs.count
        var ids: [String] = []
        var seen = Set<String>()
        var observedCounts: [Int] = []
        if !completePagination {
            // Larger fixtures retain field-level Summary validation for the
            // first production page only; complete order/count/hash coverage
            // comes from sqlFullHashParity plus the bounded keyset exercises.
            let page = try await service.query(query)
            observedCounts.append(page.totalCount)
            let pageIDs = try validateSummaryPage(page, expectedIDs: expectedIDs, expected: expected, expectedCount: expectedCount, start: 0, queryName: name)
            ids = pageIDs
            result[name] = ids
            countReports[name] = [
                "expectedCount": expectedCount,
                "actualCount": page.totalCount,
                "observedCounts": observedCounts,
                "countMismatch": page.totalCount != expectedCount,
                "validatedPrefixCount": pageIDs.count,
                "completePagination": false,
                "fieldParityScope": "first-page"
            ]
            continue
        }
        repeat {
            let page = try await service.query(query)
            observedCounts.append(page.totalCount)
            let pageIDs = try validateSummaryPage(page, expectedIDs: expectedIDs, expected: expected, expectedCount: expectedCount, start: ids.count, queryName: name)
            for id in pageIDs {
                guard seen.insert(id).inserted else { throw BenchmarkError.goldenMismatch(name + ".duplicate") }
            }
            ids.append(contentsOf: pageIDs)
            query.cursor = page.nextCursor
            if page.nextCursor == nil { break }
        } while true
        guard ids == expectedIDs else { throw BenchmarkError.goldenMismatch(name + ".missing") }
        result[name] = ids
        countReports[name] = [
            "expectedCount": expectedCount,
            "actualCount": observedCounts.last ?? 0,
            "observedCounts": observedCounts,
            "countMismatch": observedCounts.contains { $0 != expectedCount },
            "validatedPrefixCount": ids.count,
            "completePagination": true,
            "fieldParityScope": "full"
        ]
    }
    return (result, countReports)
}

private func benchmarkKeysetPages(
    service: LibraryQueryService,
    golden: LegacyGolden,
    parameters: ExpectedQueries,
    pages: Int
) async throws -> [String: Any] {
    let expected = golden.byID
    var report: [String: Any] = [:]
    for name in queryNames {
        var query = parameters.query(named: name)
        let expectedIDs = sortedIDs(golden.items, name: name, parameters: parameters, legacyShapeOrders: golden.itemShapeOrders)
        let expectedCount = expectedIDs.count
        var ids: [String] = []
        var durations: [Double] = []
        var observedCounts: [Int] = []
        for pageIndex in 0..<pages {
            let start = DispatchTime.now().uptimeNanoseconds
            let page = try await service.query(query)
            durations.append(milliseconds(start))
            observedCounts.append(page.totalCount)
            let pageIDs = try validateSummaryPage(page, expectedIDs: expectedIDs, expected: expected, expectedCount: expectedCount, start: ids.count, queryName: name)
            ids.append(contentsOf: pageIDs)
            guard Set(ids).count == ids.count else { throw BenchmarkError.goldenMismatch(name + ".duplicate") }
            query.cursor = page.nextCursor
            if query.cursor == nil { break }
            if pageIndex + 1 == pages { break }
        }
        let expectedPrefix = Array(expectedIDs.prefix(ids.count))
        guard ids == expectedPrefix else { throw BenchmarkError.goldenMismatch(name + ".keyset") }
        report[name] = [
            "requestedPages": pages,
            // An empty result still issued one page request; report requests,
            // not ceil(0/pageSize), so empty shapes are not misleadingly 0.
            "actualRequests": durations.count,
            "returnedPages": durations.count,
            "expectedCount": expectedCount,
            "actualCount": observedCounts.last ?? 0,
            "observedCounts": observedCounts,
            "countMismatch": observedCounts.contains { $0 != expectedCount },
            "summaryCount": ids.count,
            "uniqueCount": Set(ids).count,
            "noDuplicateOrMissing": true,
            "totalMilliseconds": [
                "count": durations.count,
                "p50Milliseconds": TimingStats(durations).p50Milliseconds,
                "p95Milliseconds": TimingStats(durations).p95Milliseconds,
                "maxMilliseconds": TimingStats(durations).maxMilliseconds
            ]
        ]
    }
    return report
}

private func traversalParity(
    service: LibraryQueryService,
    golden: LegacyGolden,
    parameters: ExpectedQueries,
    name: String,
    pageSize: Int,
    boundaryOnly: Bool
) async throws -> [String: Any] {
    let expectedIDs = sortedIDs(golden.items, name: name, parameters: parameters, legacyShapeOrders: golden.itemShapeOrders)
    let expectedSet = Set(expectedIDs)
    var query = parameters.query(named: name, pageSize: pageSize)
    var observed: [String] = []
    var observedCounts: [Int] = []
    var pagesFetched = 0
    var terminalPage = false
    var firstIDs: [String] = []
    var lastIDs: [String] = []
    let expectedPages = max(1, (expectedIDs.count + pageSize - 1) / pageSize)
    let requestedPages = boundaryOnly ? min(3, expectedPages) : Int.max
    repeat {
        let page = try await service.query(query)
        pagesFetched += 1
        observedCounts.append(page.totalCount)
        let pageIDs = page.items.map(\.id)
        if firstIDs.count < 16 { firstIDs.append(contentsOf: pageIDs.prefix(16 - firstIDs.count)) }
        lastIDs = Array((lastIDs + pageIDs).suffix(16))
        observed.append(contentsOf: pageIDs)
        query.cursor = page.nextCursor
        if page.nextCursor == nil { terminalPage = true }
        if pagesFetched >= requestedPages { break }
    } while query.cursor != nil

    var counts: [String: Int] = [:]
    for id in observed { counts[id, default: 0] += 1 }
    let duplicateIDs = counts.filter { $0.value > 1 }.map(\.key).sorted()
    let observedSet = Set(observed)
    // Boundary traversals validate the complete prefix that was fetched.  A
    // full missing-set assertion is intentionally reserved for canonical 300,
    // where every row is visited and hashed.
    let expectedPrefix = Array(expectedIDs.prefix(observed.count))
    let missingIDs = Set(expectedPrefix).subtracting(observedSet).sorted()
    let unexpectedIDs = observedSet.subtracting(expectedSet).sorted()
    let orderMismatchCount = zip(expectedPrefix, observed).reduce(0) { total, pair in total + (pair.0 == pair.1 ? 0 : 1) }
        + abs(expectedPrefix.count - observed.count)
    let totalCountMismatch = observedCounts.contains { $0 != expectedIDs.count }
    let observedPrefixHash = itemOrderHash(observed)
    let expectedPrefixHash = itemOrderHash(expectedPrefix)
    let fullPass = !boundaryOnly && observed.count == expectedIDs.count && terminalPage
    let requiredBoundaryPages = expectedIDs.count > pageSize ? min(2, expectedPages) : 1
    let boundaryPass = boundaryOnly && pagesFetched >= requiredBoundaryPages
    let pass = (fullPass || boundaryPass)
        && observed.count == expectedPrefix.count
        && observedSet.count == observed.count
        && duplicateIDs.isEmpty
        && missingIDs.isEmpty
        && unexpectedIDs.isEmpty
        && orderMismatchCount == 0
        && !totalCountMismatch
    guard pass else {
        throw BenchmarkError.goldenMismatch("\(name).\(boundaryOnly ? "boundary" : "fullTraversal").pageSize=\(pageSize)")
    }
    return [
        "pageSize": pageSize,
        "fullTraversal": !boundaryOnly,
        "boundaryOnly": boundaryOnly,
        "hashScope": boundaryOnly ? "observedPrefix" : "full",
        "preMigrationHash": expectedPrefixHash,
        "postMigrationHash": observedPrefixHash,
        "expectedFullHash": itemOrderHash(expectedIDs),
        "hashEqual": expectedPrefixHash == observedPrefixHash,
        "expectedCount": expectedIDs.count,
        "actualCount": observedCounts.last ?? 0,
        "observedPrefixCount": observed.count,
        "uniqueCount": observedSet.count,
        "duplicateCount": duplicateIDs.count,
        "duplicateIDs": duplicateIDs,
        "missingCount": missingIDs.count,
        "missingIDs": missingIDs,
        "missingChecked": true,
        "unexpectedCount": unexpectedIDs.count,
        "unexpectedIDs": unexpectedIDs,
        "orderMismatchCount": orderMismatchCount,
        "expectedPages": expectedPages,
        "requestedPages": boundaryOnly ? requestedPages : pagesFetched,
        "pagesFetched": pagesFetched,
        "terminalPage": terminalPage,
        "crossBoundary": expectedIDs.count > pageSize && pagesFetched >= 2,
        "totalCountMismatch": totalCountMismatch,
        "observedCounts": observedCounts,
        "firstIDs": firstIDs,
        "lastIDs": lastIDs,
        "pass": pass
    ]
}

private func runFullTraversalParities(
    service: LibraryQueryService,
    golden: LegacyGolden,
    parameters: ExpectedQueries,
    pageSizes: [Int],
    completePagination: Bool
) async throws -> [String: [String: [String: Any]]] {
    var result: [String: [String: [String: Any]]] = [:]
    for name in queryNames {
        var byPage: [String: [String: Any]] = [:]
        for pageSize in pageSizes {
            byPage[String(pageSize)] = try await traversalParity(
                service: service,
                golden: golden,
                parameters: parameters,
                name: name,
                pageSize: pageSize,
                boundaryOnly: !(completePagination && pageSize == 300)
            )
        }
        result[name] = byPage
    }
    return result
}

private func runTenPageExercise(
    service: LibraryQueryService,
    golden: LegacyGolden,
    parameters: ExpectedQueries,
    requestedPages: Int
) async throws -> [String: [String: Any]] {
    var result: [String: [String: Any]] = [:]
    for name in queryNames {
        let expectedIDs = sortedIDs(golden.items, name: name, parameters: parameters, legacyShapeOrders: golden.itemShapeOrders)
        let shortResult = expectedIDs.count < requestedPages * 300
        var query = parameters.query(named: name, pageSize: 300)
        var observed: [String] = []
        var pagesFetched = 0
        var terminal = false
        while pagesFetched < requestedPages, !terminal {
            let page = try await service.query(query)
            pagesFetched += 1
            observed.append(contentsOf: page.items.map(\.id))
            query.cursor = page.nextCursor
            terminal = page.nextCursor == nil
        }
        let expectedPrefix = Array(expectedIDs.prefix(observed.count))
        let pass = observed == expectedPrefix && (shortResult || pagesFetched == requestedPages)
        guard pass else { throw BenchmarkError.goldenMismatch("\(name).tenPage") }
        result[name] = [
            "requestedPages": requestedPages,
            "pagesFetched": pagesFetched,
            "shortResult": shortResult,
            "terminalPage": terminal,
            "expectedCount": expectedIDs.count,
            "prefixCount": observed.count,
            "prefixHash": itemOrderHash(observed),
            "pass": pass
        ]
    }
    return result
}

/// Reuses the production query's filtering, bindings, ordering, and limits
/// while replacing only its projection with the ID used by benchmark parity.
/// The first unindented FROM boundary is the main query boundary: nested
/// latest-version projections are indented, and relation-backed Tag queries
/// keep their complete `FROM ... JOIN ...` suffix intact.
private func idOnlyProductionQuery(_ built: LibraryQuerySQL, shape: String) throws -> String {
    guard let fromRange = built.sql.range(of: "\nFROM ") else {
        throw BenchmarkError.unsupported("unable to derive ID-only production query for \(shape)")
    }
    let fromStart = built.sql.index(after: fromRange.lowerBound)
    return "SELECT p.id\n" + String(built.sql[fromStart...])
}

private func persistedDateHash(databaseURL: URL) throws -> String {
    let read = try SQLiteReadConnection(url: databaseURL)
    let rows = try read.querySync("SELECT id,createdAt,itemCreatedAtSortKey,itemLastUsedAtSortKey,itemSequence FROM prompt_items ORDER BY id COLLATE BINARY ASC;")
    let lines = rows.map { row in
        [requiredString(row, "id"), optionalString(row, "createdAt") ?? "<NULL>", optionalString(row, "itemCreatedAtSortKey") ?? "<NULL>", optionalString(row, "itemLastUsedAtSortKey") ?? "<NULL>", optionalString(row, "itemSequence") ?? "<NULL>"].joined(separator: "|")
    }
    return framedSHA256(["persisted-date-hash-v1"] + lines)
}

/// Keep the ID-only derivation contract explicit before any fixture work: all
/// nine production shapes must retain a real FROM clause, and Tag must retain
/// its relation join and bound relation key.
private func validateIDOnlyProductionQueryShapes(parameters: ExpectedQueries) throws {
    let capabilities = LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    for name in queryNames {
        let built = try LibraryQuerySQLBuilder.build(parameters.query(named: name, pageSize: 300), capabilities: capabilities)
        let idOnlySQL = try idOnlyProductionQuery(built, shape: name)
        guard idOnlySQL.hasPrefix("SELECT p.id\nFROM ") else {
            throw BenchmarkError.unsupported("malformed ID-only production query for \(name)")
        }
        if name == "Tag" {
            let relationKey = TagIdentity.relationKey(for: parameters.tag)
            let hasRelationJoin = idOnlySQL.hasPrefix("SELECT p.id\nFROM prompt_item_tags pit\nJOIN prompt_items p")
            let hasBoundRelationKey = built.values.contains { value in
                guard case .text(let text) = value else { return false }
                return text == relationKey
            }
            guard hasRelationJoin, hasBoundRelationKey else {
                throw BenchmarkError.unsupported("Tag ID-only query lost relation join or binding")
            }
        }
    }
}

private func captureOrderHashes(
    databaseURL: URL,
    parameters: ExpectedQueries,
    pageSizes: [Int]
) throws -> [String: [String: Any]] {
    let read = try SQLiteReadConnection(url: databaseURL)
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    let capabilities = LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    var result: [String: [String: Any]] = [:]
    for name in queryNames {
        let query = parameters.query(named: name, pageSize: max(pageSizes.max() ?? 601, 1_000_000))
        let built = try LibraryQuerySQLBuilder.build(query, capabilities: capabilities)
        let idOnlySQL = try idOnlyProductionQuery(built, shape: name)
        let rows = try read.querySync(idOnlySQL, values: built.values)
        let countBuilt = try LibraryQuerySQLBuilder.buildCount(query, capabilities: capabilities)
        let countRows = try read.querySync(countBuilt.sql, values: countBuilt.values)
        let totalCount = integer(countRows.first ?? [:], "totalCount")
        let ids = rows.map { requiredString($0, "id") }
        result[name] = [
            "hash": itemOrderHash(ids),
            "count": ids.count,
            "totalCount": totalCount,
            "firstIDs": Array(ids.prefix(16)),
            "lastIDs": Array(ids.suffix(16)),
            "queryFingerprint": built.queryFingerprint,
            "countQueryFingerprint": countBuilt.queryFingerprint,
            "orderHashMode": "builder-derived-id-only",
            "pageSizes": pageSizes
        ]
    }
    let integrity = optionalString(try database.query("PRAGMA integrity_check;").first ?? [:], "integrity_check") ?? ""
    let foreignKeyCount = try database.query("PRAGMA foreign_key_check;").count
    let indexNames = try database.query("SELECT name FROM sqlite_master WHERE type='index' ORDER BY name;").map { requiredString($0, "name") }
    result["__meta"] = [
        "businessFingerprint": try businessFingerprint(databaseURL: databaseURL),
        "persistedDateHash": try persistedDateHash(databaseURL: databaseURL),
        "itemSequenceState": try itemSequenceStateJSON(databaseURL: databaseURL),
        "integrityCheck": integrity,
        "foreignKeyViolationCount": foreignKeyCount,
        "indexes": indexNames
    ]
    return result
}

/// Execute one unpaginated ID-only SQL statement per shape using the
/// production LibraryQuerySQLBuilder order/capability contract. Full fields
/// are checked by `fullFieldOracle` below; selecting the complete correlated
/// Summary projection for a 50k+ fixture is a pathological query and is not a
/// useful proxy for the page-sized runtime projection benchmark.
private func sqlFullHashParity(
    databaseURL: URL,
    golden: LegacyGolden,
    parameters: ExpectedQueries,
    pageSizes: [Int],
    expectedRawBusinessFingerprint: String
) throws -> [String: [String: Any]] {
    let read = try SQLiteReadConnection(url: databaseURL)
    let capabilities = LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    let actualRawBusinessFingerprint = try rawBusinessFingerprint(databaseURL: databaseURL)
    var result: [String: [String: Any]] = [:]
    var fullScopeIDs: [[String]] = []
    for name in queryNames {
        let expectedIDs = sortedIDs(golden.items, name: name, parameters: parameters, legacyShapeOrders: golden.itemShapeOrders)
        let expectedHash = itemOrderHash(expectedIDs)
        let query = parameters.query(named: name, pageSize: 1_000_000)
        let built = try LibraryQuerySQLBuilder.build(query, capabilities: capabilities)
        let idOnlySQL = try idOnlyProductionQuery(built, shape: name)
        let rows = try read.querySync(idOnlySQL, values: built.values)
        let countBuilt = try LibraryQuerySQLBuilder.buildCount(query, capabilities: capabilities)
        let countRows = try read.querySync(countBuilt.sql, values: countBuilt.values)
        let countSQLTotal = integer(countRows.first ?? [:], "totalCount")
        let ids = rows.map { requiredString($0, "id") }
        let actualHash = itemOrderHash(ids)
        let idOrderPass = rows.count == expectedIDs.count && countSQLTotal == expectedIDs.count && actualHash == expectedHash
        if name == "All" || name == "Trash" { fullScopeIDs.append(ids) }
        guard idOrderPass else { throw BenchmarkError.goldenMismatch("\(name).sqlIDOrder") }
        result[name] = [
            "projectionMode": "idOrderOnly",
            "sqlMode": "single-full-id-select",
            "pageLimit": 1_000_000,
            "expectedCount": expectedIDs.count,
            "actualCount": rows.count,
            "totalCount": countSQLTotal,
            "expectedHash": expectedHash,
            "actualHash": actualHash,
            "hashEqual": actualHash == expectedHash,
            "projectionHashEqual": NSNull(),
            "fieldMismatchCounts": [:],
            "queryFingerprint": built.queryFingerprint,
            "countQueryFingerprint": countBuilt.queryFingerprint,
            "fieldParityCoveredBy": "fullFieldOracle",
            "fullFieldOracleMode": "persisted-table-and-version-scan",
            "rawBusinessFingerprint": actualRawBusinessFingerprint,
            "rawBusinessFingerprintEqual": actualRawBusinessFingerprint == expectedRawBusinessFingerprint,
            "pass": idOrderPass && actualRawBusinessFingerprint == expectedRawBusinessFingerprint
        ]
    }
    let expectedCoverageIDs = sortedIDs(golden.items, name: "All", parameters: parameters, legacyShapeOrders: golden.itemShapeOrders)
        + sortedIDs(golden.items, name: "Trash", parameters: parameters, legacyShapeOrders: golden.itemShapeOrders)
    let observedCoverageIDs = fullScopeIDs.flatMap { $0 }
    let expectedCoverageSet = Set(golden.items.map(\.summary.id))
    let observedCoverageSet = Set(observedCoverageIDs)
    let duplicateAcrossScopes = fullScopeIDs.count == 2 ? Set(fullScopeIDs[0]).intersection(Set(fullScopeIDs[1])).count : 0
    let sqlCoveragePass = observedCoverageIDs.count == expectedCoverageSet.count
        && observedCoverageSet == expectedCoverageSet
        && duplicateAcrossScopes == 0
        && itemOrderHash(observedCoverageIDs) == itemOrderHash(expectedCoverageIDs)
    guard sqlCoveragePass else { throw BenchmarkError.goldenMismatch("fullFieldCoverage.sqlCoverage") }
    let fieldOracle = try fullFieldOracle(
        golden: golden,
        expectedCoverageIDs: expectedCoverageIDs,
        expectedCoverageSet: expectedCoverageSet,
        read: read
    )
    let coveragePass = sqlCoveragePass && (fieldOracle["pass"] as? Bool == true)
    result["__coverage"] = [
        "pass": coveragePass,
        "coverageMode": "All(active)+Trash(id-only SQL) + persisted table/version scan",
        "fullFieldOracleMode": "persisted-table-and-version-scan",
        "coverageCount": observedCoverageSet.count,
        "expectedCoverageCount": expectedCoverageSet.count,
        "coverageHash": itemOrderHash(observedCoverageIDs),
        "expectedCoverageHash": itemOrderHash(expectedCoverageIDs),
        "coverageHashEqual": itemOrderHash(observedCoverageIDs) == itemOrderHash(expectedCoverageIDs),
        "missingCount": expectedCoverageSet.subtracting(observedCoverageSet).count,
        "unexpectedCount": observedCoverageSet.subtracting(expectedCoverageSet).count,
        "duplicateAcrossScopes": duplicateAcrossScopes,
        "sqlCoveragePass": sqlCoveragePass,
        "oracle": fieldOracle
    ]
    result["__meta"] = [
        "projectionSchema": "id,itemCreatedAtSortKey,createdAtMicros,itemSequence,hasPrompt,hasReferences,totalCount",
        "fullFieldOracleMode": "persisted-table-and-version-scan",
        "requestedPageSizes": pageSizes,
        "rawBusinessFingerprint": actualRawBusinessFingerprint,
        "rawBusinessFingerprintEqual": actualRawBusinessFingerprint == expectedRawBusinessFingerprint,
        "pass": actualRawBusinessFingerprint == expectedRawBusinessFingerprint && coveragePass
    ]
    return result
}

/// Compare the required full-field projection from persisted tables without
/// running the correlated Summary SQL over the entire fixture. The item table
/// is scanned once and prompt_versions is scanned once; the latest version and
/// reference/prompt booleans are reduced in Swift using persisted sort keys.
private func fullFieldOracle(
    golden: LegacyGolden,
    expectedCoverageIDs: [String],
    expectedCoverageSet: Set<String>,
    read: SQLiteReadConnection
) throws -> [String: Any] {
    let itemRows = try read.querySync("SELECT id,itemCreatedAtSortKey,itemSequence,referencesJSON FROM prompt_items ORDER BY itemSequence ASC;")
    let versionRows = try read.querySync("SELECT promptItemId,prompt,versionCreatedAtSortKey,versionSequence FROM prompt_versions ORDER BY promptItemId COLLATE BINARY ASC, versionCreatedAtSortKey ASC, versionSequence ASC;")
    let expectedByID = golden.byID
    let expectedSequence = Dictionary(uniqueKeysWithValues: golden.itemObservationOrder.enumerated().map { ($0.element, Int64($0.offset + 1)) })
    struct LatestVersion { let sortKey: Int64; let sequence: Int64; let prompt: String }
    var latestByItem: [String: LatestVersion] = [:]
    latestByItem.reserveCapacity(expectedCoverageSet.count)
    for row in versionRows {
        let itemID = requiredString(row, "promptItemId")
        let candidate = LatestVersion(
            sortKey: Int64(optionalString(row, "versionCreatedAtSortKey") ?? "") ?? Int64.min,
            sequence: Int64(optionalString(row, "versionSequence") ?? "") ?? Int64.min,
            prompt: requiredString(row, "prompt")
        )
        if let current = latestByItem[itemID], (current.sortKey > candidate.sortKey || (current.sortKey == candidate.sortKey && current.sequence >= candidate.sequence)) { continue }
        latestByItem[itemID] = candidate
    }
    var itemByID: [String: [String: String?]] = [:]
    itemByID.reserveCapacity(itemRows.count)
    for row in itemRows { itemByID[requiredString(row, "id")] = row }
    let actualIDs = itemRows.map { requiredString($0, "id") }
    let actualSet = Set(actualIDs)
    var fieldMismatchCounts: [String: Int] = [
        "idOrder": actualIDs == golden.itemObservationOrder ? 0 : 1,
        "itemCreatedAtSortKey": 0,
        "createdAtMicros": 0,
        "itemSequence": 0,
        "hasPrompt": 0,
        "hasReferences": 0,
        "totalCount": itemRows.count == golden.items.count ? 0 : 1
    ]
    var expectedLines: [String] = ["full-field-oracle-v1"]
    var actualLines: [String] = ["full-field-oracle-v1"]
    func field(_ value: String) -> String { "value:\(value.utf8.count):\(value)" }
    for id in expectedCoverageIDs {
        let expectedItem = expectedByID[id]
        let expectedCreated = expectedItem?.summary.createdAtMicros ?? Int64.min
        let expectedSeq = expectedSequence[id] ?? Int64.min
        let expectedHasPrompt = expectedItem?.hasPrompt ?? false
        let expectedHasReferences = expectedItem?.summary.hasReferences ?? false
        if let row = itemByID[id] {
            let actualCreated = Int64(optionalString(row, "itemCreatedAtSortKey") ?? "") ?? Int64.min
            let actualSeq = Int64(optionalString(row, "itemSequence") ?? "") ?? Int64.min
            let actualHasPrompt = latestByItem[id]?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let actualHasReferences = !decodeReferencesExactly(requiredString(row, "referencesJSON")).isEmpty
            if actualCreated != expectedCreated { fieldMismatchCounts["itemCreatedAtSortKey", default: 0] += 1 }
            if actualCreated != expectedCreated { fieldMismatchCounts["createdAtMicros", default: 0] += 1 }
            if actualSeq != expectedSeq { fieldMismatchCounts["itemSequence", default: 0] += 1 }
            if actualHasPrompt != expectedHasPrompt { fieldMismatchCounts["hasPrompt", default: 0] += 1 }
            if actualHasReferences != expectedHasReferences { fieldMismatchCounts["hasReferences", default: 0] += 1 }
            actualLines.append([id, String(actualCreated), String(actualCreated), String(actualSeq), String(actualHasPrompt), String(actualHasReferences), String(itemRows.count)].map(field).joined(separator: "|"))
        } else {
            for key in ["itemCreatedAtSortKey", "createdAtMicros", "itemSequence", "hasPrompt", "hasReferences"] { fieldMismatchCounts[key, default: 0] += 1 }
            actualLines.append([id, "MISSING", "MISSING", "MISSING", "MISSING", "MISSING", String(itemRows.count)].map(field).joined(separator: "|"))
        }
        expectedLines.append([id, String(expectedCreated), String(expectedCreated), String(expectedSeq), String(expectedHasPrompt), String(expectedHasReferences), String(golden.items.count)].map(field).joined(separator: "|"))
    }
    let missingCount = expectedCoverageSet.subtracting(actualSet).count
    let unexpectedCount = actualSet.subtracting(expectedCoverageSet).count
    let expectedFieldHash = framedSHA256(expectedLines)
    let actualFieldHash = framedSHA256(actualLines)
    let pass = itemRows.count == golden.items.count
        && missingCount == 0
        && unexpectedCount == 0
        && fieldMismatchCounts.values.allSatisfy { $0 == 0 }
        && expectedFieldHash == actualFieldHash
    return [
        "mode": "persisted-table-and-version-scan",
        "projectionSchema": "id,itemCreatedAtSortKey,createdAtMicros,itemSequence,hasPrompt,hasReferences,totalCount",
        "itemScanCount": itemRows.count,
        "versionScanCount": versionRows.count,
        "coverageCount": actualSet.intersection(expectedCoverageSet).count,
        "expectedCoverageCount": expectedCoverageSet.count,
        "missingCount": missingCount,
        "unexpectedCount": unexpectedCount,
        "fieldMismatchCounts": fieldMismatchCounts,
        "expectedFieldHash": expectedFieldHash,
        "actualFieldHash": actualFieldHash,
        "fieldHashEqual": expectedFieldHash == actualFieldHash,
        "pass": pass
    ]
}

private func restartProbeArgument(_ name: String) -> String? {
    let values = Array(CommandLine.arguments.dropFirst())
    guard let index = values.firstIndex(of: name), index + 1 < values.count else { return nil }
    return values[index + 1]
}

private final class RestartProbeExecutor: LibraryQueryRowExecutor, @unchecked Sendable {
    let connection: SQLiteReadConnection
    private let lock = NSLock()
    private var pageAndCountCalls = 0

    init(connection: SQLiteReadConnection) {
        self.connection = connection
    }

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] {
        try await connection.query(sql, values: values)
    }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        recordPageAndCountCall()
        return try await connection.queryPageAndCount(pageSQL: pageSQL, pageValues: pageValues, countSQL: countSQL, countValues: countValues)
    }

    private func recordPageAndCountCall() {
        lock.lock(); pageAndCountCalls += 1; lock.unlock()
    }

    var pageAndCountCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pageAndCountCalls
    }
}

private func serviceFirstPageProbe(service: LibraryQueryService) async throws -> [String: Any] {
    let page = try await service.query(LibraryQuery(.all, pageSize: 1))
    let firstIDs = page.items.map(\.id)
    let pass = page.totalCount >= firstIDs.count && firstIDs.count <= 1
    guard pass else { throw BenchmarkError.goldenMismatch("restart.serviceFirstPage") }
    return [
        "count": page.totalCount,
        "firstIDs": firstIDs,
        "pass": pass
    ]
}

private func serviceFirstPageProbe(databaseURL: URL) async throws -> [String: Any] {
    let library = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
    let repository = try PromptRepository(libraryURL: library)
    let capabilities = LibraryQueryCapabilities.runtime(for: repository)
    guard capabilities.tagRelationsReady, capabilities.versionSequenceReady, capabilities.itemSequenceReady else {
        throw BenchmarkError.unsupported("service first-page probe opened a non-ready repository")
    }
    let executor = try SQLiteReadConnection(url: databaseURL)
    let observedExecutor = RestartProbeExecutor(connection: executor)
    let service = LibraryQueryService(executor: observedExecutor, repository: repository)
    var result = try await serviceFirstPageProbe(service: service)
    let atomicCalls = observedExecutor.pageAndCountCallCount
    let atomicObserved = atomicCalls == 1
    let capabilitiesRebuilt = capabilities.tagRelationsReady && capabilities.versionSequenceReady && capabilities.itemSequenceReady
    result["atomicPageAndCount"] = atomicObserved
    result["atomicPageAndCountCalls"] = atomicCalls
    result["serviceRebuilt"] = capabilitiesRebuilt
    result["serviceCapabilitySnapshot"] = [
        "tagRelationsReady": capabilities.tagRelationsReady,
        "versionSequenceReady": capabilities.versionSequenceReady,
        "itemSequenceReady": capabilities.itemSequenceReady
    ]
    guard atomicObserved, capabilitiesRebuilt else {
        throw BenchmarkError.goldenMismatch("restart.serviceFirstPage.observation")
    }
    return result
}

private func processRestartProbe() async throws {
    guard let databasePath = restartProbeArgument("--database"),
          let outputPath = restartProbeArgument("--output"),
          let folderID = restartProbeArgument("--folder"),
          let modelID = restartProbeArgument("--model"),
          let typeRaw = restartProbeArgument("--type"),
          let type = PromptType(rawValue: typeRaw),
          let tag = restartProbeArgument("--tag"),
          let probeRootPath = restartProbeArgument("--probe-root"),
          let probeToken = restartProbeArgument("--probe-token"),
          let parentPIDRaw = restartProbeArgument("--parent-pid"),
          let parentPID = Int32(parentPIDRaw), parentPID > 0 else {
        throw BenchmarkError.invalidArguments
    }
    let paths = try validateRestartProbeChild(databasePath: databasePath, outputPath: outputPath, probeRootPath: probeRootPath, probeToken: probeToken)
    let testMode = restartProbeArgument("--phase2a4-test-mode")
    let testDelayMilliseconds = restartProbeArgument("--phase2a4-test-delay-ms")
    if testMode != nil || testDelayMilliseconds != nil {
        // This internal probe accepts one fixed delay only after the strict
        // generated-root validator above. It cannot select an arbitrary path,
        // timeout, or delay through the child CLI.
        guard testMode == "forced-timeout", testDelayMilliseconds == "1000" else {
            throw BenchmarkError.invalidArguments
        }
        try await Task.sleep(for: .seconds(1))
    }
    let database = paths.database
    let library = database.deletingLastPathComponent().deletingLastPathComponent()
    let repository = try PromptRepository(libraryURL: library)
    let capabilities = LibraryQueryCapabilities.runtime(for: repository)
    guard capabilities.tagRelationsReady, capabilities.versionSequenceReady, capabilities.itemSequenceReady else {
        throw BenchmarkError.unsupported("restart probe opened a non-ready repository")
    }
    let executor = try SQLiteReadConnection(url: database)
    let observedExecutor = RestartProbeExecutor(connection: executor)
    let service = LibraryQueryService(executor: observedExecutor, repository: repository)
    var servicePage = try await serviceFirstPageProbe(service: service)
    let atomicCalls = observedExecutor.pageAndCountCallCount
    let atomicObserved = atomicCalls == 1
    let capabilitiesRebuilt = capabilities.tagRelationsReady && capabilities.versionSequenceReady && capabilities.itemSequenceReady
    servicePage["atomicPageAndCount"] = atomicObserved
    servicePage["atomicPageAndCountCalls"] = atomicCalls
    servicePage["serviceRebuilt"] = capabilitiesRebuilt
    servicePage["serviceCapabilitySnapshot"] = [
        "tagRelationsReady": capabilities.tagRelationsReady,
        "versionSequenceReady": capabilities.versionSequenceReady,
        "itemSequenceReady": capabilities.itemSequenceReady
    ]
    guard atomicObserved, capabilitiesRebuilt else {
        throw BenchmarkError.goldenMismatch("restart.serviceFirstPage.observation")
    }
    let parameters = ExpectedQueries(folderID: folderID, modelID: modelID, type: type, tag: tag)
    var result = try captureOrderHashes(databaseURL: database, parameters: parameters, pageSizes: [300])
    let processID = ProcessInfo.processInfo.processIdentifier
    let freshProcess = processID > 0 && processID != parentPID
    let restartServicePass = servicePage["pass"] as? Bool == true && freshProcess
    result["processRestartProbe"] = [
        "pass": restartServicePass,
        "capabilities": [
            "tagRelationsReady": capabilities.tagRelationsReady,
            "versionSequenceReady": capabilities.versionSequenceReady,
            "itemSequenceReady": capabilities.itemSequenceReady
        ],
        "serviceRebuilt": capabilitiesRebuilt,
        "freshProcess": freshProcess,
        "processIdentifier": Int(processID),
        "parentProcessIdentifier": Int(parentPID),
        "probeRootValidated": paths.probeRoot.path,
        "probeMarkerValidated": paths.marker.path,
        "serviceFirstPage": servicePage
    ]
    try JSONSerialization.write(result, to: paths.output)
}

private struct RestartProbeLifecycleObservation {
    let timedOut: Bool
    let timeoutMilliseconds: Int
    let timeoutSeconds: Int
    let elapsedMilliseconds: Double
    let boundedElapsedMilliseconds: Double
    let observedExit: Bool
    let observedExitWithinDeadline: Bool
    let observedExitElapsedMilliseconds: Double?
    let timeoutOutcome: String
    let terminateSent: Bool
    let killSent: Bool
    let childResidual: Bool

    var dictionary: [String: Any] {
        [
            "timedOut": timedOut,
            "timeoutMilliseconds": timeoutMilliseconds,
            "timeoutSeconds": timeoutSeconds,
            "elapsedMilliseconds": elapsedMilliseconds,
            "boundedElapsedMilliseconds": boundedElapsedMilliseconds,
            "observedExit": observedExit,
            "observedExitWithinDeadline": observedExitWithinDeadline,
            "observedExitElapsedMilliseconds": observedExitElapsedMilliseconds ?? NSNull(),
            "completedWithinTimeout": !timedOut && observedExitWithinDeadline,
            "timeoutOutcome": timeoutOutcome,
            "terminateSent": terminateSent,
            "killSent": killSent,
            "childResidual": childResidual
        ]
    }
}

private struct RestartProbeTimeoutError: Error, LocalizedError {
    let observation: RestartProbeLifecycleObservation

    var errorDescription: String? {
        "process restart probe timed out (\(observation.timeoutOutcome)); childResidual=\(observation.childResidual)"
    }
}

private struct RestartProbeCancellationError: Error, LocalizedError {
    let observation: RestartProbeLifecycleObservation

    var errorDescription: String? {
        "process restart probe cancelled during bounded cleanup; childResidual=\(observation.childResidual)"
    }
}

private struct RestartProbeCleanupObservation {
    let terminateSent: Bool
    let killSent: Bool
    let childResidual: Bool
}

private func uncancelledRestartProbeSleep() async {
    await Task.detached {
        try? await Task.sleep(for: .milliseconds(20))
    }.value
}

private func cleanupRestartProbeProcess(
    _ process: Process,
    graceNanoseconds: UInt64
) async -> RestartProbeCleanupObservation {
    let clock = ContinuousClock()
    var terminateSent = false
    var killSent = false
    if process.isRunning {
        process.terminate()
        terminateSent = true
    }
    let terminateDeadline = clock.now.advanced(by: .nanoseconds(Int64(graceNanoseconds)))
    while process.isRunning && clock.now < terminateDeadline {
        // Cleanup must continue even when the parent task is cancelled; the
        // detached bounded sleep avoids Task.sleep immediately rethrowing.
        await uncancelledRestartProbeSleep()
    }
    if process.isRunning {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        killSent = true
        let killDeadline = clock.now.advanced(by: .nanoseconds(Int64(graceNanoseconds)))
        while process.isRunning && clock.now < killDeadline {
            await uncancelledRestartProbeSleep()
        }
    }
    return RestartProbeCleanupObservation(
        terminateSent: terminateSent,
        killSent: killSent,
        childResidual: process.isRunning
    )
}

private func restartProbeDurationMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000.0
        + Double(components.attoseconds) / 1_000_000_000_000_000.0
}

private func processRestartProbe(
    databaseURL: URL,
    outputURL: URL,
    probeRoot: URL,
    probeToken: String,
    parameters: ExpectedQueries,
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    childDelayMilliseconds: Int? = nil,
    expectTimeout: Bool = false
) async throws -> [String: Any] {
    let executablePath = CommandLine.arguments[0]
    let executableURL = URL(fileURLWithPath: executablePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
        "--restart-probe",
        "--database", databaseURL.path,
        "--output", outputURL.path,
        "--probe-root", probeRoot.path,
        "--probe-token", probeToken,
        "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        "--folder", parameters.folderID,
        "--model", parameters.modelID,
        "--type", parameters.type.rawValue,
        "--tag", parameters.tag
    ]
    if let childDelayMilliseconds {
        guard childDelayMilliseconds == 1_000 else {
            throw BenchmarkError.invalidArguments
        }
        process.arguments = (process.arguments ?? []) + [
            "--phase2a4-test-mode", "forced-timeout",
            "--phase2a4-test-delay-ms", "1000"
        ]
    }
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    let graceNanoseconds: UInt64 = 2_000_000_000
    let clock = ContinuousClock()
    let startedAt = clock.now
    let timeoutDuration = Duration.nanoseconds(Int64(timeoutNanoseconds))
    let deadline = startedAt.advanced(by: timeoutDuration)
    var observedExitAt: ContinuousClock.Instant?
    var deadlineReached = false
    defer {
        // This synchronous last-resort guard also covers cancellation or an
        // unexpected throw while the async cleanup path is unwinding.
        if process.isRunning {
            process.terminate()
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
    do {
        while true {
            let now = clock.now
            // Once the monotonic clock reaches the deadline without a prior
            // observed exit, this is permanently a timeout. A later natural
            // exit cannot be relabelled as an in-deadline completion.
            if now >= deadline {
                deadlineReached = true
                break
            }
            if !process.isRunning {
                let observed = clock.now
                observedExitAt = observed
                if observed >= deadline { deadlineReached = true }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    } catch is CancellationError {
        let cleanup = await cleanupRestartProbeProcess(process, graceNanoseconds: graceNanoseconds)
        let endedAt = clock.now
        let observation = RestartProbeLifecycleObservation(
            timedOut: true,
            timeoutMilliseconds: Int(timeoutNanoseconds / 1_000_000),
            timeoutSeconds: Int(timeoutNanoseconds / 1_000_000_000),
            elapsedMilliseconds: restartProbeDurationMilliseconds(startedAt.duration(to: endedAt)),
            boundedElapsedMilliseconds: Double(timeoutNanoseconds + (2 * graceNanoseconds)) / 1_000_000.0,
            observedExit: observedExitAt != nil,
            observedExitWithinDeadline: false,
            observedExitElapsedMilliseconds: observedExitAt.map { restartProbeDurationMilliseconds(startedAt.duration(to: $0)) },
            timeoutOutcome: cleanup.killSent ? "cancelled-killed" : (cleanup.terminateSent ? "cancelled-terminated" : "cancelled-after-exit"),
            terminateSent: cleanup.terminateSent,
            killSent: cleanup.killSent,
            childResidual: cleanup.childResidual
        )
        throw RestartProbeCancellationError(observation: observation)
    }
    let timedOut = deadlineReached || observedExitAt == nil || observedExitAt! > deadline
    if timedOut {
        let cleanup = await cleanupRestartProbeProcess(process, graceNanoseconds: graceNanoseconds)
        let endedAt = clock.now
        let observation = RestartProbeLifecycleObservation(
            timedOut: true,
            timeoutMilliseconds: Int(timeoutNanoseconds / 1_000_000),
            timeoutSeconds: Int(timeoutNanoseconds / 1_000_000_000),
            elapsedMilliseconds: restartProbeDurationMilliseconds(startedAt.duration(to: endedAt)),
            boundedElapsedMilliseconds: Double(timeoutNanoseconds + (2 * graceNanoseconds)) / 1_000_000.0,
            observedExit: observedExitAt != nil,
            observedExitWithinDeadline: false,
            observedExitElapsedMilliseconds: observedExitAt.map { restartProbeDurationMilliseconds(startedAt.duration(to: $0)) },
            timeoutOutcome: cleanup.killSent ? "timed-out-killed" : (cleanup.terminateSent ? "timed-out-terminated" : "timed-out-observed-after-deadline"),
            terminateSent: cleanup.terminateSent,
            killSent: cleanup.killSent,
            childResidual: cleanup.childResidual
        )
        if expectTimeout { return ["__restartProbeTimeout": observation.dictionary] }
        throw RestartProbeTimeoutError(observation: observation)
    }
    guard let observedExitAt else {
        throw BenchmarkError.unsupported("process restart probe ended without an observed exit instant")
    }
    let endedAt = clock.now
    let observation = RestartProbeLifecycleObservation(
        timedOut: false,
        timeoutMilliseconds: Int(timeoutNanoseconds / 1_000_000),
        timeoutSeconds: Int(timeoutNanoseconds / 1_000_000_000),
        elapsedMilliseconds: restartProbeDurationMilliseconds(startedAt.duration(to: endedAt)),
        boundedElapsedMilliseconds: Double(timeoutNanoseconds + (2 * graceNanoseconds)) / 1_000_000.0,
        observedExit: true,
        observedExitWithinDeadline: observedExitAt <= deadline,
        observedExitElapsedMilliseconds: restartProbeDurationMilliseconds(startedAt.duration(to: observedExitAt)),
        timeoutOutcome: "natural-exit-within-deadline",
        terminateSent: false,
        killSent: false,
        childResidual: process.isRunning
    )
    guard observation.observedExitWithinDeadline, !observation.childResidual else {
        throw BenchmarkError.unsupported("process restart probe observed an invalid natural-exit lifecycle")
    }
    guard !expectTimeout else {
        throw BenchmarkError.goldenMismatch("restartProbe.forcedTimeoutDidNotTimeout")
    }
    let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw BenchmarkError.unsupported("process restart probe failed: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    guard let data = try? Data(contentsOf: outputURL),
          var result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (result["processRestartProbe"] as? [String: Any])?["freshProcess"] as? Bool == true,
          (result["processRestartProbe"] as? [String: Any])?["pass"] as? Bool == true else {
        throw BenchmarkError.unsupported("process restart probe did not produce a fresh-process report")
    }
    result["__restartProbeTimeout"] = observation.dictionary
    return result
}

private func runStability(
    sourceReadyLibrary: URL,
    outputRoot: URL,
    scale: Int,
    parameters: ExpectedQueries,
    pageSizes: [Int]
) async throws -> [String: Any] {
    let stabilityLibrary = outputRoot.appendingPathComponent("stability-\(scale)", isDirectory: true)
    try cloneDatabaseOnline(source: databaseURL(for: sourceReadyLibrary), destinationLibrary: stabilityLibrary)
    let before = try captureOrderHashes(databaseURL: databaseURL(for: stabilityLibrary), parameters: parameters, pageSizes: pageSizes)
    let beforeServicePage = try await serviceFirstPageProbe(databaseURL: databaseURL(for: stabilityLibrary))
    do {
        let database = try SQLiteDatabase(path: databaseURL(for: stabilityLibrary).path, mode: .existingReadWrite)
        try database.execute("VACUUM;")
    }
    let afterVacuum = try captureOrderHashes(databaseURL: databaseURL(for: stabilityLibrary), parameters: parameters, pageSizes: pageSizes)
    let freshHandleReopen = try captureOrderHashes(databaseURL: databaseURL(for: stabilityLibrary), parameters: parameters, pageSizes: pageSizes)
    let processRestartOutput = outputRoot.appendingPathComponent("stability-\(scale)-process-restart.json")
    let probeRoot = canonicalURL(outputRoot)
    try validateOutputRoot(probeRoot)
    let probeToken = UUID().uuidString
    let probeMarker = probeRoot.appendingPathComponent(".phase2a4-restart-probe-\(probeToken).marker", isDirectory: false)
    try Data(probeToken.utf8).write(to: probeMarker, options: .atomic)
    defer { try? FileManager.default.removeItem(at: probeMarker) }
    let forcedTimeoutResult = try await processRestartProbe(
        databaseURL: databaseURL(for: stabilityLibrary),
        outputURL: processRestartOutput,
        probeRoot: probeRoot,
        probeToken: probeToken,
        parameters: parameters,
        timeoutNanoseconds: 100_000_000,
        childDelayMilliseconds: 1_000,
        expectTimeout: true
    )
    let forcedTimeoutEvidence = forcedTimeoutResult["__restartProbeTimeout"] as? [String: Any] ?? [:]
    let forcedTimeoutPass = forcedTimeoutEvidence["timedOut"] as? Bool == true
        && forcedTimeoutEvidence["observedExitWithinDeadline"] as? Bool == false
        && forcedTimeoutEvidence["childResidual"] as? Bool == false
        && ((forcedTimeoutEvidence["terminateSent"] as? Bool == true) || (forcedTimeoutEvidence["killSent"] as? Bool == true))
        && (forcedTimeoutEvidence["elapsedMilliseconds"] as? Double ?? .infinity) <= (forcedTimeoutEvidence["boundedElapsedMilliseconds"] as? Double ?? 0)
    guard forcedTimeoutPass, !FileManager.default.fileExists(atPath: processRestartOutput.path) else {
        throw BenchmarkError.timingInvariant("restartProbe.forcedTimeoutLifecycle")
    }
    let afterProcessRestart = try await processRestartProbe(databaseURL: databaseURL(for: stabilityLibrary), outputURL: processRestartOutput, probeRoot: probeRoot, probeToken: probeToken, parameters: parameters)
    let restoreLibrary = outputRoot.appendingPathComponent("stability-\(scale)-online-backup", isDirectory: true)
    try cloneDatabaseOnline(source: databaseURL(for: stabilityLibrary), destinationLibrary: restoreLibrary)
    let afterBackup = try captureOrderHashes(databaseURL: databaseURL(for: restoreLibrary), parameters: parameters, pageSizes: pageSizes)
    func meta(_ value: [String: Any]) -> [String: Any] { value["__meta"] as? [String: Any] ?? [:] }
    let beforeMeta = meta(before), vacuumMeta = meta(afterVacuum), reopenMeta = meta(freshHandleReopen), restartMeta = meta(afterProcessRestart), backupMeta = meta(afterBackup)
    let restartProbe = afterProcessRestart["processRestartProbe"] as? [String: Any] ?? [:]
    let timeoutEvidence = afterProcessRestart["__restartProbeTimeout"] as? [String: Any] ?? [:]
    let restartServicePage = restartProbe["serviceFirstPage"] as? [String: Any] ?? [:]
    let servicePageStable = beforeServicePage["count"] as? Int == restartServicePage["count"] as? Int
        && (beforeServicePage["firstIDs"] as? [String]) == (restartServicePage["firstIDs"] as? [String])
        && restartServicePage["pass"] as? Bool == true
    let shapeNames = queryNames
    let ordersStable = shapeNames.allSatisfy { name in
        let hash = (before[name]?["hash"] as? String)
        let restartHash = (afterProcessRestart[name] as? [String: Any])?["hash"] as? String
        return hash != nil && hash == (afterVacuum[name]?["hash"] as? String) && hash == (freshHandleReopen[name]?["hash"] as? String) && hash == restartHash && hash == (afterBackup[name]?["hash"] as? String)
    }
    let dateHashesStable = [vacuumMeta, reopenMeta, restartMeta, backupMeta].allSatisfy {
        $0["persistedDateHash"] as? String == beforeMeta["persistedDateHash"] as? String
    }
    let businessStable = [beforeMeta, vacuumMeta, reopenMeta, restartMeta, backupMeta].dropFirst().allSatisfy {
        $0["businessFingerprint"] as? String == beforeMeta["businessFingerprint"] as? String
    }
    let integrityPass = [beforeMeta, vacuumMeta, reopenMeta, backupMeta].allSatisfy {
        ($0["integrityCheck"] as? String) == "ok" && ($0["foreignKeyViolationCount"] as? Int ?? 1) == 0
    }
    return [
        "before": before,
        "afterVacuum": afterVacuum,
        "freshHandleReopen": freshHandleReopen,
        "afterProcessRestart": afterProcessRestart,
        "afterOnlineBackup": afterBackup,
        "orderHashMode": "builder-derived-id-only",
        "businessOrderHashesStable": ordersStable,
        "persistedDateHashesStable": dateHashesStable,
        "businessFingerprintStable": businessStable,
        "serviceFirstPageBefore": beforeServicePage,
        "serviceFirstPageAfterProcessRestart": restartServicePage,
        "serviceFirstPageStable": servicePageStable,
        "integrityCheck": integrityPass ? "ok" : "failed",
        "foreignKeyViolationCount": backupMeta["foreignKeyViolationCount"] ?? 0,
        "forcedTimeoutProbe": forcedTimeoutEvidence,
        "processRestartProbe": ["freshProcess": restartProbe["freshProcess"] ?? false, "processIdentifier": restartProbe["processIdentifier"] ?? 0, "parentProcessIdentifier": restartProbe["parentProcessIdentifier"] ?? 0, "timedOut": timeoutEvidence["timedOut"] ?? true, "observedExit": timeoutEvidence["observedExit"] ?? false, "observedExitWithinDeadline": timeoutEvidence["observedExitWithinDeadline"] ?? false, "elapsedMilliseconds": timeoutEvidence["elapsedMilliseconds"] ?? 0, "boundedElapsedMilliseconds": timeoutEvidence["boundedElapsedMilliseconds"] ?? 0, "terminateSent": timeoutEvidence["terminateSent"] ?? false, "killSent": timeoutEvidence["killSent"] ?? false, "childResidual": timeoutEvidence["childResidual"] ?? true, "timeoutSeconds": timeoutEvidence["timeoutSeconds"] ?? 0, "timeoutBounded": timeoutEvidence["completedWithinTimeout"] ?? false, "timeoutOutcome": timeoutEvidence["timeoutOutcome"] ?? "missing", "reportPath": processRestartOutput.path, "servicePageStable": servicePageStable],
        "pass": ordersStable && dateHashesStable && businessStable && servicePageStable && integrityPass && forcedTimeoutPass
    ]
}

private func statePhase(_ state: [String: Any]) -> String {
    state["phase"] as? String ?? "unknown"
}

private func runSummaryDetailParity(
    repository: PromptRepository,
    service: LibraryQueryService,
    golden: LegacyGolden,
    parameters: ExpectedQueries,
    completePagination: Bool
) async throws -> [String: Any] {
    let expected = golden.byID
    var summaryByID: [String: LibraryItemSummary] = [:]
    if completePagination {
        for name in ["All", "Trash"] {
            var query = parameters.query(named: name, pageSize: max(golden.itemCount + 1, 1))
            while true {
                let page = try await service.query(query)
                for summary in page.items { summaryByID[summary.id] = summary }
                guard let cursor = page.nextCursor else { break }
                query.cursor = cursor
            }
        }
    } else {
        // Keep larger-fixture Summary/Detail checks bounded.  The synthetic
        // edge rows all carry the dedicated phase2a4 tag, while ten All pages
        // provide a representative production prefix; full ID order/count is
        // independently covered by the single SQL full-hash oracle.
        let boundedQueries: [LibraryQuery] = [
            LibraryQuery.tag("phase2a4", pageSize: 300),
            parameters.query(named: "All", pageSize: 300)
        ]
        for initialQuery in boundedQueries {
            var query = initialQuery
            var pages = 0
            while pages < 10 {
                let page = try await service.query(query)
                for summary in page.items { summaryByID[summary.id] = summary }
                pages += 1
                guard let cursor = page.nextCursor else { break }
                query.cursor = cursor
            }
        }
    }
    let read = try SQLiteReadConnection(url: repository.databaseURL)
    var edgeIDs = golden.syntheticIDs
    edgeIDs.append(contentsOf: golden.itemObservationOrder.prefix(8))
    edgeIDs = Array(NSOrderedSet(array: edgeIDs)) as? [String] ?? Array(Set(edgeIDs))
    var checked = 0
    var summaryChecked = 0
    var missingSummaryIDs: [String] = []
    var rawCreatedAtUnchanged = true
    for id in edgeIDs {
        guard let item = expected[id] else {
            throw BenchmarkError.goldenMismatch("summaryDetail.missingGolden:\(id)")
        }
        if let summary = summaryByID[id] {
            try compareSummary(summary, expected: item)
            summaryChecked += 1
        } else if completePagination || golden.syntheticIDs.contains(id) {
            throw BenchmarkError.goldenMismatch("summaryDetail.missingSummary:\(id)")
        } else {
            missingSummaryIDs.append(id)
        }
        guard let detail = try await repository.itemDetail(id: id) else {
            throw BenchmarkError.goldenMismatch("summaryDetail.missingDetail:\(id)")
        }
        let row = try read.querySync("SELECT createdAt,itemCreatedAtSortKey,itemLastUsedAtSortKey,itemSequence,tagsJSON,referencesJSON FROM prompt_items WHERE id=? LIMIT 1;", values: [.text(id)]).first ?? [:]
        guard detail.id == id,
              dateMicros(detail.createdAt) == item.summary.createdAtMicros,
              detail.title == item.summary.title,
              detail.favorite == item.summary.favorite,
              detail.itemCreatedAtSortKey == Int64(optionalString(row, "itemCreatedAtSortKey") ?? ""),
              detail.itemLastUsedAtSortKey == Int64(optionalString(row, "itemLastUsedAtSortKey") ?? ""),
              detail.itemSequence == Int64(optionalString(row, "itemSequence") ?? ""),
              detail.versions.map(\.id) == item.versions.map(\.id),
              detail.currentVersion?.id == item.currentVersionID,
              (detail.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) == item.hasPrompt else {
            throw BenchmarkError.goldenMismatch("summaryDetail.fields:\(id)")
        }
        rawCreatedAtUnchanged = rawCreatedAtUnchanged && optionalString(row, "createdAt") == golden.itemRawCreatedAt[id]
        checked += 1
    }
    return [
        "pass": checked == edgeIDs.count && rawCreatedAtUnchanged && (!completePagination || missingSummaryIDs.isEmpty),
        "checkedCount": checked,
        "sampleCount": checked,
        "summaryCheckedCount": summaryChecked,
        "runtimeProjectionObservedCount": summaryByID.count,
        "runtimeProjectionExpectedCount": golden.items.count,
        "runtimeProjectionCoverageCount": summaryByID.keys.filter { expected[$0] != nil }.count,
        "runtimeProjectionCoverage": golden.items.isEmpty ? 1.0 : Double(summaryByID.keys.filter { expected[$0] != nil }.count) / Double(golden.items.count),
        "missingSummaryIDs": missingSummaryIDs,
        "completePagination": completePagination,
        "summaryScope": completePagination ? "full-all-trash" : "synthetic-tag-plus-ten-page-prefix",
        "edgeIDs": edgeIDs,
        "rawCreatedAtUnchanged": rawCreatedAtUnchanged,
        "summaryUsesPersistedCreatedAt": true,
        "detailUsesPersistedCreatedAt": true
    ]
}

private func runEqualKeyOracle(
    databaseURL: URL,
    golden: LegacyGolden
) throws -> [String: Any] {
    let invariants = try itemSequenceInvariants(databaseURL: databaseURL)
    let byID = invariants["sequenceByID"] as? [String: Int64] ?? [:]
    func order(_ ids: [String]) -> [String] {
        ids.sorted { (byID[$0] ?? Int64.max) < (byID[$1] ?? Int64.max) }
    }
    let forwardExpected = golden.itemObservationOrder.filter { ["z-item", "a-item", "m-item"].contains($0) }
    let reverseExpected = golden.itemObservationOrder.filter { ["m-item-reverse", "a-item-reverse", "z-item-reverse"].contains($0) }
    let forward = order(["z-item", "a-item", "m-item"])
    let reverse = order(["m-item-reverse", "a-item-reverse", "z-item-reverse"])
    let pass = forward == forwardExpected && reverse == reverseExpected
    guard pass else { throw BenchmarkError.goldenMismatch("equalKeyOracle") }
    return [
        "pass": pass,
        "forward": ["expected": forwardExpected, "actual": forward],
        "reverse": ["expected": reverseExpected, "actual": reverse],
        "sequenceDirection": golden.itemSequenceDirection,
        "usesPersistedSequence": true,
        "idTieBreak": false
    ]
}

private func runTimestampOracle(
    databaseURL: URL,
    golden: LegacyGolden,
    rawBefore: [String: String?]
) throws -> [String: Any] {
    let read = try SQLiteReadConnection(url: databaseURL)
    let rows = try read.querySync("SELECT id,createdAt,itemCreatedAtSortKey,itemSequence FROM prompt_items ORDER BY id COLLATE BINARY ASC;")
    var checks: [[String: Any]] = []
    var pass = true
    for id in golden.syntheticIDs where id.contains("phase2a4-item-ts-") {
        guard let row = rows.first(where: { requiredString($0, "id") == id }) else { pass = false; continue }
        let raw = optionalString(row, "createdAt")
        let expectedRaw = rawBefore[id] ?? nil
        let expected = golden.itemObservedCreatedAtMicros[id] ?? 0
        let actualKey = Int64(optionalString(row, "itemCreatedAtSortKey") ?? "")
        let kind = golden.byID[id]?.summary.legacyObservationKind ?? "unknown"
        let rowPass = raw == expectedRaw && actualKey == expected && Int64(optionalString(row, "itemSequence") ?? "") ?? 0 > 0
        pass = pass && rowPass
        checks.append(["id": id, "rawBefore": expectedRaw ?? NSNull(), "rawAfter": raw ?? NSNull(), "kind": kind, "expectedSortKey": expected, "actualSortKey": actualKey ?? NSNull(), "pass": rowPass])
    }
    guard pass else { throw BenchmarkError.goldenMismatch("timestampOracle") }
    return [
        "pass": pass,
        "variants": checks,
        "rawCreatedAtOpaque": true,
        "malformedAndEmptyUseSeededClock": true,
        "sharedClassifier": "PromptItemCreatedAtSupport.legacyObservation"
    ]
}

private func writerRow(databaseURL: URL, id: String) throws -> [String: String?]? {
    let read = try SQLiteReadConnection(url: databaseURL)
    return try read.querySync(
        "SELECT id,title,favorite,folderId,folderName,category,sortOrder,lastUsedAt,itemLastUsedAtSortKey,deletedAt,tagsJSON,itemSequence FROM prompt_items WHERE id=? LIMIT 1;",
        values: [.text(id)]
    ).first
}

private func writerTags(_ row: [String: String?]) -> [String] {
    guard let data = requiredString(row, "tagsJSON").data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
}

private func writerRelationRows(databaseURL: URL, id: String) throws -> [[String: String?]] {
    let read = try SQLiteReadConnection(url: databaseURL)
    return try read.querySync(
        "SELECT tagName,tagKey,isFirstOccurrence,isDeleted,ordinal FROM prompt_item_tags WHERE promptItemId=? ORDER BY ordinal ASC;",
        values: [.text(id)]
    )
}

private func assertWriterRow(
    databaseURL: URL,
    id: String,
    title: String,
    favorite: Bool,
    folderID: String,
    folderName: String,
    category: String,
    sortOrder: Int,
    lastUsed: Date,
    deletedAt: Date?,
    tags: [String]
) throws -> [String: Any] {
    guard let row = try writerRow(databaseURL: databaseURL, id: id) else {
        throw BenchmarkError.goldenMismatch("writer.missing:\(id)")
    }
    let relationRows = try writerRelationRows(databaseURL: databaseURL, id: id)
    let actualDeleted = optionalString(row, "deletedAt").flatMap(parseISO)
    let actualLastUsedKey = Int64(optionalString(row, "itemLastUsedAtSortKey") ?? "")
    let relationTags = relationRows.map { requiredString($0, "tagName") }
    let relationKeys = relationRows.map { requiredString($0, "tagKey") }
    let relationOrdinals = relationRows.map { integer($0, "ordinal") }
    let relationFirstOccurrences = relationRows.map { integer($0, "isFirstOccurrence") }
    let relationDeletedFlags = relationRows.map { integer($0, "isDeleted") }
    let expectedKeys = tags.map { TagIdentity.relationKey(for: $0) }
    var expectedFirstKeys = Set<String>()
    let expectedFirstOccurrences = expectedKeys.map { expectedFirstKeys.insert($0).inserted ? 1 : 0 }
    let expectedOrdinals = Array(tags.indices)
    let expectedDeletedFlags = tags.map { _ in deletedAt == nil ? 0 : 1 }
    guard requiredString(row, "title") == title,
          integer(row, "favorite") == (favorite ? 1 : 0),
          requiredString(row, "folderId") == folderID,
          requiredString(row, "folderName") == folderName,
          requiredString(row, "category") == category,
          integer(row, "sortOrder") == sortOrder,
          actualLastUsedKey == dateMicros(lastUsed),
          (actualDeleted.map(dateMicros) == deletedAt.map(dateMicros)),
          writerTags(row) == tags,
          relationRows.count == tags.count,
          relationTags == tags,
          relationKeys == expectedKeys,
          relationOrdinals == expectedOrdinals,
          relationFirstOccurrences == expectedFirstOccurrences,
          relationDeletedFlags == expectedDeletedFlags,
          integer64(row, "itemSequence") > 0 else {
        throw BenchmarkError.goldenMismatch("writer.fields:\(id)")
    }
    return [
        "relationTags": relationTags,
        "relationKeys": relationKeys,
        "relationOrdinals": relationOrdinals,
        "relationFirstOccurrence": relationFirstOccurrences,
        "relationDeleted": relationDeletedFlags,
        "expectedRelationOrdinals": expectedOrdinals,
        "expectedRelationFirstOccurrence": expectedFirstOccurrences,
        "expectedRelationDeleted": expectedDeletedFlags,
        "tuples": relationRows.map { row in
            [
                "ordinal": integer(row, "ordinal"),
                "tagName": requiredString(row, "tagName"),
                "tagKey": requiredString(row, "tagKey"),
                "isFirstOccurrence": integer(row, "isFirstOccurrence"),
                "isDeleted": integer(row, "isDeleted")
            ]
        }
    ]
}

private func rawBusinessFingerprintExcluding(databaseURL: URL, excludedIDs: Set<String>) throws -> String {
    let read = try SQLiteReadConnection(url: databaseURL)
    var lines: [String] = ["raw-business-fingerprint-excluding-v1"]
    let itemFields = ["id","title","type","assetKind","modelId","modelName","folderId","folderName","category","assetPath","thumbnailPath","aspectRatio","width","height","format","fileSize","favorite","pinnedAt","deletedAt","createdAt","updatedAt","lastUsedAt","sortOrder","tagsJSON","referencesJSON","description","captureId","captureSourceJSON"]
    let items = try read.querySync("SELECT \(itemFields.joined(separator: ",")) FROM prompt_items ORDER BY id COLLATE BINARY ASC;")
    for row in items {
        guard !excludedIDs.contains(requiredString(row, "id")) else { continue }
        lines.append("item|" + itemFields.map { field in
            let value = row[field] ?? nil
            let encoded = value.map { "value:\($0.count):\($0)" } ?? "NULL"
            return "\(field)=\(encoded)"
        }.joined(separator: "|"))
    }
    let versionFields = ["id","promptItemId","version","prompt","negativePrompt","parametersJSON","note","createdAt"]
    let versions = try read.querySync("SELECT \(versionFields.joined(separator: ",")) FROM prompt_versions ORDER BY id COLLATE BINARY ASC;")
    for row in versions {
        guard !excludedIDs.contains(requiredString(row, "promptItemId")) else { continue }
        lines.append("version|" + versionFields.map { field in
            let value = row[field] ?? nil
            let encoded = value.map { "value:\($0.count):\($0)" } ?? "NULL"
            return "\(field)=\(encoded)"
        }.joined(separator: "|"))
    }
    let relationFields = ["promptItemId","ordinal","tagName","tagKey","isFirstOccurrence","isDeleted","sortOrder","createdAt","lastUsedAt"]
    let relations = try read.querySync("SELECT \(relationFields.joined(separator: ",")) FROM prompt_item_tags ORDER BY promptItemId COLLATE BINARY ASC, ordinal ASC;")
    for row in relations {
        guard !excludedIDs.contains(requiredString(row, "promptItemId")) else { continue }
        lines.append("relation|" + relationFields.map { field in
            let value = row[field] ?? nil
            let encoded = value.map { "value:\($0.count):\($0)" } ?? "NULL"
            return "\(field)=\(encoded)"
        }.joined(separator: "|"))
    }
    return framedSHA256(lines)
}

private func writerPostWriteContract(
    databaseURL: URL,
    nonTargetFingerprintBefore: String,
    excludedIDs: Set<String>,
    batchIDs: [String],
    concurrentIDs: [String],
    deletedSequence: Int64
) throws -> [String: Any] {
    let read = try SQLiteReadConnection(url: databaseURL)
    let batchRows = try read.querySync(
        "SELECT id,itemSequence FROM prompt_items WHERE id IN (?,?) ORDER BY itemSequence ASC;",
        values: batchIDs.map(SQLiteValue.text)
    )
    let batchOrder = batchRows.map { requiredString($0, "id") }
    let batchSequences = batchRows.compactMap { Int64(optionalString($0, "itemSequence") ?? "") }
    guard batchOrder == batchIDs, batchSequences.count == batchIDs.count,
          zip(batchSequences, batchSequences.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
        throw BenchmarkError.goldenMismatch("writer.batchItemSequenceOrder")
    }
    let concurrentRows = try read.querySync(
        "SELECT id,title FROM prompt_items WHERE id IN (?,?) ORDER BY id COLLATE BINARY ASC;",
        values: concurrentIDs.map(SQLiteValue.text)
    )
    guard Set(concurrentRows.map { requiredString($0, "id") }) == Set(concurrentIDs),
          concurrentRows.allSatisfy({ requiredString($0, "title").hasPrefix("concurrent-") }) else {
        throw BenchmarkError.goldenMismatch("writer.concurrentRecords")
    }
    let finalFingerprint = try rawBusinessFingerprintExcluding(databaseURL: databaseURL, excludedIDs: excludedIDs)
    guard finalFingerprint == nonTargetFingerprintBefore else {
        throw BenchmarkError.goldenMismatch("writer.nonTargetFingerprint")
    }
    let finalInvariants = try itemSequenceInvariants(databaseURL: databaseURL)
    let finalSequences = Set((finalInvariants["sequenceByID"] as? [String: Int64] ?? [:]).values)
    let maxSequence = finalInvariants["maxSequence"] as? Int64 ?? 0
    let missingSequences: [Int64]
    if maxSequence > 0 {
        missingSequences = Array(1...Int(maxSequence)).map(Int64.init).filter { !finalSequences.contains($0) }
    } else {
        missingSequences = []
    }
    // permanentDelete intentionally removes the row without renumbering other
    // durable itemSequence values. The one expected hole must be explicit;
    // any additional hole/null/duplicate is a failed writer contract.
    let postDeleteGapPass = (finalInvariants["contiguous"] as? Bool) == false
        && (finalInvariants["nullCount"] as? Int) == 0
        && (finalInvariants["duplicateCount"] as? Int) == 0
        && (finalInvariants["gapCount"] as? Int) == 1
        && missingSequences == [deletedSequence]
    var compactFinalInvariants = finalInvariants
    compactFinalInvariants.removeValue(forKey: "sequenceByID")
    return [
        "nonTargetFingerprintEqual": finalFingerprint == nonTargetFingerprintBefore,
        "batchInputOrder": batchIDs,
        "batchDurableOrder": batchOrder,
        "batchItemSequence": batchSequences,
        "batchItemSequenceOrderPass": true,
        "concurrentRecords": concurrentRows.map { ["id": requiredString($0, "id"), "title": requiredString($0, "title")] },
        "concurrentRecordsPass": true,
        "postDeleteInvariants": compactFinalInvariants,
        "postDeleteExpectedGap": true,
        "postDeleteDeletedSequence": deletedSequence,
        "postDeleteMissingSequences": missingSequences,
        "postDeleteGapPass": postDeleteGapPass,
        "pass": finalFingerprint == nonTargetFingerprintBefore && batchOrder == batchIDs && Set(concurrentRows.map { requiredString($0, "id") }) == Set(concurrentIDs) && postDeleteGapPass
    ]
}

private final class AtomicCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let sqliteStartedSemaphore = DispatchSemaphore(value: 0)
    private let pageCompleteSemaphore = DispatchSemaphore(value: 0)
    private let countStartedSemaphore = DispatchSemaphore(value: 0)
    private var active = 0
    private var lateResults = 0
    private var sqliteStartCount = 0
    private var pageCompleteCount = 0
    private var countSQLiteStartCount = 0

    func begin() {
        lock.lock(); active += 1; lock.unlock()
    }

    func end() {
        lock.lock(); active -= 1; lock.unlock()
    }

    func recordResult() {
        lock.lock(); lateResults += 1; lock.unlock()
    }

    /// SQLiteReadConnection invokes this hook from SQLiteProgressContext's
    /// progress callback while a sqlite3_step is active.  The first callback
    /// belongs to the page (or transaction setup); after the page-complete
    /// hook has fired, the next callback is the count statement.  Holding only
    /// that count callback gives the parent task a deterministic cancellation
    /// window inside sqlite3_step itself, rather than in a benchmark sleep
    /// before SQLite starts work.
    func signalSQLiteStart() {
        lock.lock()
        sqliteStartCount += 1
        let countStart = pageCompleteCount > 0 && countSQLiteStartCount == 0
        if countStart { countSQLiteStartCount += 1 }
        lock.unlock()
        sqliteStartedSemaphore.signal()
        if countStart {
            countStartedSemaphore.signal()
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func waitForSQLiteStart() -> Bool {
        sqliteStartedSemaphore.wait(timeout: .now() + 5) == .success
    }

    func signalPageComplete() {
        lock.lock()
        pageCompleteCount += 1
        lock.unlock()
        pageCompleteSemaphore.signal()
    }

    func waitForPageComplete() -> Bool {
        pageCompleteSemaphore.wait(timeout: .now() + 5) == .success
    }

    func waitForCountSQLiteStart() -> Bool {
        countStartedSemaphore.wait(timeout: .now() + 5) == .success
    }

    var snapshot: (active: Int, lateResults: Int, sqliteStartCount: Int, pageCompleteCount: Int, countSQLiteStartCount: Int) {
        lock.lock(); defer { lock.unlock() }
        return (active, lateResults, sqliteStartCount, pageCompleteCount, countSQLiteStartCount)
    }
}

private final class AtomicCancellationExecutor: LibraryQueryRowExecutor, @unchecked Sendable {
    let connection: SQLiteReadConnection
    let probe: AtomicCancellationProbe

    init(connection: SQLiteReadConnection, probe: AtomicCancellationProbe) {
        self.connection = connection
        self.probe = probe
    }

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] {
        try await connection.query(sql, values: values)
    }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        probe.begin()
        defer { probe.end() }
        let result = try await connection.queryPageAndCount(pageSQL: pageSQL, pageValues: pageValues, countSQL: countSQL, countValues: countValues)
        probe.recordResult()
        return result
    }
}

private func atomicPageCountCancellation(
    databaseURL: URL,
    capabilities: LibraryQueryCapabilities
) async throws -> [String: Any] {
    let probe = AtomicCancellationProbe()
    let connection = try SQLiteReadConnection(
        path: databaseURL.path,
        queryStartHook: { probe.signalSQLiteStart() },
        queryPageAndCountHook: { probe.signalPageComplete() }
    )
    let executor = AtomicCancellationExecutor(connection: connection, probe: probe)
    let service = LibraryQueryService(executor: executor, capabilities: capabilities)
    let task = Task { try await service.query(LibraryQuery(.all, pageSize: 1_000_000)) }
    guard probe.waitForSQLiteStart() else {
        task.cancel()
        _ = try? await task.value
        throw BenchmarkError.unsupported("atomic page/count cancellation did not reach SQLite")
    }
    guard probe.waitForPageComplete(), probe.waitForCountSQLiteStart() else {
        task.cancel()
        _ = try? await task.value
        throw BenchmarkError.unsupported("atomic page/count cancellation did not reach count sqlite3_step")
    }
    task.cancel()
    var cancellationObserved = false
    do {
        _ = try await task.value
    } catch is CancellationError {
        cancellationObserved = true
    } catch {
        if let sqliteError = error as? SQLiteError, let code = sqliteError.resultCode {
            cancellationObserved = code & 0xff == SQLITE_INTERRUPT
        }
    }
    let state = probe.snapshot
    let followup = try await service.query(LibraryQuery(.all, pageSize: 1))
    let followupPass = followup.totalCount > 0
    let sqliteStepReached = state.sqliteStartCount > 0
        && state.pageCompleteCount > 0
        && state.countSQLiteStartCount > 0
    let pass = cancellationObserved && sqliteStepReached && state.active == 0 && state.lateResults == 0 && followupPass
    guard pass else { throw BenchmarkError.unsupported("atomic page/count cancellation did not fail closed") }
    return [
        "pass": pass,
        "cancellationObserved": cancellationObserved,
        "sqliteStepReached": sqliteStepReached,
        "queryStartHookObserved": state.sqliteStartCount > 0,
        "pageCompleteHookObserved": state.pageCompleteCount > 0,
        "countSQLiteStepHookObserved": state.countSQLiteStartCount > 0,
        "sqliteStartHookCount": state.sqliteStartCount,
        "pageCompleteHookCount": state.pageCompleteCount,
        "countSQLiteStepHookCount": state.countSQLiteStartCount,
        "activeAfterCancellation": state.active,
        "lateResultCount": state.lateResults,
        "followupQueryPass": followupPass,
        "atomicSnapshot": true,
        "realLibraryQueryService": true
    ]
}

private func lockContentionProbe(databaseURL: URL) throws -> [String: Any] {
    let statement = "UPDATE prompt_items SET updatedAt = updatedAt WHERE id = (SELECT id FROM prompt_items ORDER BY rowid LIMIT 1);"
    let transaction = "BEGIN IMMEDIATE;"
    let transactionRole = "lock-holder"
    let contenderBusyTimeout = "PRAGMA busy_timeout = 0;"
    let holder = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    try holder.execute("BEGIN IMMEDIATE;")
    defer { try? holder.execute("ROLLBACK;") }
    try holder.run(statement)
    let contender = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    try contender.execute(contenderBusyTimeout)
    do {
        try contender.run(statement)
        throw BenchmarkError.sqliteBusyLocked("lock contention probe unexpectedly succeeded")
    } catch let error as SQLiteError {
        guard let resultCode = error.resultCode, let extendedCode = error.extendedCode else {
            throw BenchmarkError.sqliteBusyLocked("lock contention probe omitted SQLite result codes")
        }
        let primaryCode = resultCode & 0xff
        guard primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED else {
            throw BenchmarkError.sqliteBusyLocked("lock contention probe produced unexpected code \(resultCode)")
        }
        return [
            "pass": true,
            "injectedCoverage": true,
            "ordinaryObservedZeroDistinct": true,
            "statement": statement,
            "transaction": transaction,
            "transactionRole": transactionRole,
            "contenderBusyTimeout": contenderBusyTimeout,
            "resultCode": resultCode,
            "extendedCode": extendedCode,
            "primaryCode": primaryCode,
            "codeName": primaryCode == SQLITE_BUSY ? "SQLITE_BUSY" : "SQLITE_LOCKED",
            "retryCount": 0,
            "retryHidden": false,
            "ordinaryObservedBusyCount": 0,
            "ordinaryObservedLockedCount": 0,
            "coverageMeaning": "injected-lock-holder-contention; ordinary counters remain separately reported"
        ]
    }
}

private func runWriterMatrix(
    sourceReadyLibrary: URL,
    outputRoot: URL,
    scale: Int,
    iterations: Int,
    errors: SQLiteErrorCounter
) async throws -> [String: Any] {
    let library = outputRoot.appendingPathComponent("writer-\(scale)", isDirectory: true)
    try cloneDatabaseOnline(source: databaseURL(for: sourceReadyLibrary), destinationLibrary: library)
    let repository = try PromptRepository(libraryURL: library)
    guard let base = try repository.loadItems().first(where: { $0.deletedAt == nil }) else {
        throw BenchmarkError.malformedFixture("writer.baseItem")
    }
    let insertID = "phase2a4-writer-insert"
    let batchIDs = ["phase2a4-writer-batch-0", "phase2a4-writer-batch-1"]
    let concurrentIDs = ["phase2a4-writer-concurrent-0", "phase2a4-writer-concurrent-1"]
    let excludedIDs = Set([insertID] + batchIDs + concurrentIDs)
    let nonTargetFingerprintBefore = try rawBusinessFingerprintExcluding(databaseURL: databaseURL(for: library), excludedIDs: excludedIDs)
    var stages: [String: [String: Any]] = [:]
    func timed(_ name: String, _ operation: () throws -> Void) throws {
        var durations: [Double] = []
        var stageErrors = 0
        for _ in 0..<max(1, min(iterations, 30)) {
            let start = DispatchTime.now().uptimeNanoseconds
            do { try operation() } catch { stageErrors += 1; errors.record(error) }
            durations.append(milliseconds(start))
        }
        stages[name] = stageTiming(durations, errors: stageErrors, busy: errors.values.busy, locked: errors.values.locked)
        guard stageErrors == 0 else { throw BenchmarkError.goldenMismatch("writer.stageErrors:\(name)") }
    }
    var inserted = base
    inserted.id = insertID; inserted.title = "Phase2A4 writer insert"; inserted.tags = base.tags + ["phase2a4-writer"]
    try timed("saveItem.insert") { try repository.saveItem(inserted) }
    try assertWriterRow(databaseURL: databaseURL(for: library), id: insertID, title: inserted.title, favorite: inserted.favorite, folderID: inserted.folderId, folderName: inserted.folderName, category: inserted.category, sortOrder: inserted.sortOrder, lastUsed: inserted.lastUsedAt, deletedAt: nil, tags: inserted.tags)
    let insertedTags = inserted.tags
    var edited = inserted; edited.title = "Phase2A4 writer edit"; edited.favorite = true; edited.tags = ["phase2a4-writer-edit"]
    try timed("saveItem.editFavoriteTag") { try repository.saveItem(edited) }
    let editedObservation = try assertWriterRow(databaseURL: databaseURL(for: library), id: insertID, title: edited.title, favorite: edited.favorite, folderID: edited.folderId, folderName: edited.folderName, category: edited.category, sortOrder: edited.sortOrder, lastUsed: edited.lastUsedAt, deletedAt: nil, tags: edited.tags)
    let tagMutationPass = insertedTags != edited.tags
    guard tagMutationPass else { throw BenchmarkError.goldenMismatch("writer.tagMutation.didNotChange") }
    var moved = edited; moved.folderId = "phase2a4-writer-folder"; moved.folderName = "Phase2A4 writer folder"; moved.category = "phase2a4-writer"
    try timed("updateItemFolders.move") { try repository.updateItemFolders([moved]) }
    try assertWriterRow(databaseURL: databaseURL(for: library), id: insertID, title: moved.title, favorite: moved.favorite, folderID: moved.folderId, folderName: moved.folderName, category: moved.category, sortOrder: moved.sortOrder, lastUsed: moved.lastUsedAt, deletedAt: nil, tags: moved.tags)
    let reorderedSortOrder = edited.sortOrder + 7
    try timed("updateSortOrders.reorder") { try repository.updateSortOrders([(id: insertID, sortOrder: reorderedSortOrder)]) }
    try assertWriterRow(databaseURL: databaseURL(for: library), id: insertID, title: moved.title, favorite: moved.favorite, folderID: moved.folderId, folderName: moved.folderName, category: moved.category, sortOrder: reorderedSortOrder, lastUsed: moved.lastUsedAt, deletedAt: nil, tags: moved.tags)
    let lastUsedDate = Date(timeIntervalSince1970: 2_600_000_000)
    try timed("updateLastUsed") { try repository.updateLastUsed(itemID: insertID, at: lastUsedDate) }
    try assertWriterRow(databaseURL: databaseURL(for: library), id: insertID, title: moved.title, favorite: moved.favorite, folderID: moved.folderId, folderName: moved.folderName, category: moved.category, sortOrder: reorderedSortOrder, lastUsed: lastUsedDate, deletedAt: nil, tags: moved.tags)
    let trashDate = Date(timeIntervalSince1970: 2_600_001_000)
    try timed("markDeleted.trash") { try repository.markDeleted(itemID: insertID, deletedAt: trashDate) }
    try assertWriterRow(databaseURL: databaseURL(for: library), id: insertID, title: moved.title, favorite: moved.favorite, folderID: moved.folderId, folderName: moved.folderName, category: moved.category, sortOrder: reorderedSortOrder, lastUsed: lastUsedDate, deletedAt: trashDate, tags: moved.tags)
    try timed("markDeleted.restore") { try repository.markDeleted(itemID: insertID, deletedAt: nil) }
    try assertWriterRow(databaseURL: databaseURL(for: library), id: insertID, title: moved.title, favorite: moved.favorite, folderID: moved.folderId, folderName: moved.folderName, category: moved.category, sortOrder: reorderedSortOrder, lastUsed: lastUsedDate, deletedAt: nil, tags: moved.tags)
    let batchItems = (0..<2).map { index -> PromptItem in
        var value = base; value.id = "phase2a4-writer-batch-\(index)"; value.title = "batch-\(index)"; return value
    }
    try timed("saveItems.batch") { try repository.saveItems(batchItems) }
    for item in batchItems {
        try assertWriterRow(
            databaseURL: databaseURL(for: library),
            id: item.id,
            title: item.title,
            favorite: item.favorite,
            folderID: item.folderId,
            folderName: item.folderName,
            category: item.category,
            sortOrder: item.sortOrder,
            lastUsed: item.lastUsedAt,
            deletedAt: item.deletedAt,
            tags: item.tags
        )
    }
    let batchInvariant = try itemSequenceInvariants(databaseURL: databaseURL(for: library))
    guard (batchInvariant["contiguous"] as? Bool) == true,
          (batchInvariant["nullCount"] as? Int) == 0,
          (batchInvariant["duplicateCount"] as? Int) == 0,
          (batchInvariant["gapCount"] as? Int) == 0 else {
        throw BenchmarkError.goldenMismatch("writer.batchSequenceInvariants")
    }
    guard let insertedRowBeforeDelete = try writerRow(databaseURL: databaseURL(for: library), id: insertID),
          let deletedSequence = Int64(optionalString(insertedRowBeforeDelete, "itemSequence") ?? "") else {
        throw BenchmarkError.goldenMismatch("writer.deleteSequence")
    }
    try timed("permanentlyDelete") { try repository.permanentlyDelete(itemID: insertID) }
    guard try writerRow(databaseURL: databaseURL(for: library), id: insertID) == nil else {
        throw BenchmarkError.goldenMismatch("writer.permanentDelete")
    }
    let concurrentStart = DispatchTime.now().uptimeNanoseconds
    var concurrentErrors = 0
    await withTaskGroup(of: Result<Void, Error>.self) { group in
        for index in 0..<2 {
            let url = library
            group.addTask {
                do {
                    let repo = try PromptRepository(libraryURL: url)
                    var item = base; item.id = "phase2a4-writer-concurrent-\(index)"; item.title = "concurrent-\(index)"
                    try repo.saveItem(item)
                    return .success(())
                } catch { return .failure(error) }
            }
        }
        for await result in group {
            if case .failure(let error) = result { concurrentErrors += 1; errors.record(error) }
        }
    }
    stages["concurrentTwoConnections"] = stageTiming([milliseconds(concurrentStart)], errors: concurrentErrors, busy: errors.values.busy, locked: errors.values.locked)
    guard concurrentErrors == 0 else { throw BenchmarkError.goldenMismatch("writer.concurrentErrors") }
    for index in 0..<2 {
        var expected = base
        expected.id = "phase2a4-writer-concurrent-\(index)"
        expected.title = "concurrent-\(index)"
        try assertWriterRow(
            databaseURL: databaseURL(for: library),
            id: expected.id,
            title: expected.title,
            favorite: expected.favorite,
            folderID: expected.folderId,
            folderName: expected.folderName,
            category: expected.category,
            sortOrder: expected.sortOrder,
            lastUsed: expected.lastUsedAt,
            deletedAt: expected.deletedAt,
            tags: expected.tags
        )
    }
    let writerContract = try writerPostWriteContract(databaseURL: databaseURL(for: library), nonTargetFingerprintBefore: nonTargetFingerprintBefore, excludedIDs: excludedIDs, batchIDs: batchIDs, concurrentIDs: concurrentIDs, deletedSequence: deletedSequence)
    let read = try SQLiteReadConnection(url: databaseURL(for: library))
    let count = integer(try read.querySync("SELECT COUNT(*) AS count FROM prompt_items;").first ?? [:], "count")
    var compactBatchInvariant = batchInvariant
    compactBatchInvariant.removeValue(forKey: "sequenceByID")
    let tagMutation: [String: Any] = [
        "before": insertedTags,
        "after": edited.tags,
        "changed": insertedTags != edited.tags,
        "observedRelationTuples": editedObservation["tuples"] ?? [],
        "relationTags": editedObservation["relationTags"] ?? [],
        "relationKeys": editedObservation["relationKeys"] ?? [],
        "relationOrdinals": editedObservation["relationOrdinals"] ?? [],
        "relationFirstOccurrence": editedObservation["relationFirstOccurrence"] ?? [],
        "relationDeleted": editedObservation["relationDeleted"] ?? [],
        "expectedRelationOrdinals": editedObservation["expectedRelationOrdinals"] ?? [],
        "expectedRelationFirstOccurrence": editedObservation["expectedRelationFirstOccurrence"] ?? [],
        "expectedRelationDeleted": editedObservation["expectedRelationDeleted"] ?? [],
        "pass": tagMutationPass
    ]
    return [
        "pass": stages.values.allSatisfy { ($0["errors"] as? Int ?? 1) == 0 } && (writerContract["pass"] as? Bool == true),
        "stages": stages,
        "writerPostWriteContract": writerContract,
        "tagMutation": tagMutation,
        "batchSequenceInvariants": compactBatchInvariant,
        "firstPartyRepositoryOnly": true,
        "concurrentConnections": 2,
        "itemCountAfter": count,
        "busy": errors.values.busy,
        "locked": errors.values.locked
    ]
}

private func runMigrationResume(
    sourceDatabase: URL,
    outputRoot: URL,
    scale: Int,
    lockedParameters: LockedPhase2A1Parameters,
    golden: LegacyGolden,
    fallbackDates: [Date],
    batchSize: Int,
    errors: SQLiteErrorCounter
) throws -> [String: Any] {
    let library = outputRoot.appendingPathComponent("migration-resume-\(scale)", isDirectory: true)
    try cloneDatabaseOnline(source: sourceDatabase, destinationLibrary: library)
    _ = try insertSyntheticRows(databaseURL: databaseURL(for: library), lockedParameters: lockedParameters)
    let rawBefore = try rawBusinessFingerprint(databaseURL: databaseURL(for: library))
    let rawCreatedBefore = try rawCreatedAtSnapshot(databaseURL: databaseURL(for: library))
    var firstResult: [String: Any] = [:]
    var lastRowID: Int64?
    do {
        let repository = try PromptRepository(libraryURL: library)
        try ensureTagRelations(repository, batchSize: batchSize)
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: batchSize, observationClock: VersionSequenceObservationClock(dates: fallbackDates))
        _ = try repository.prepareItemSequenceMigration()
        let result = try repository.runItemSequenceMigration(batchSize: batchSize, maxBatches: 1, observationClock: ItemSequenceObservationClock(dates: golden.itemFallbackDatesMicros.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }))
        firstResult = ["completed": result.completed, "processedCount": result.processedCount, "phase": result.phase.rawValue]
        if let state = (try? itemSequenceStateJSON(databaseURL: databaseURL(for: library))), let value = state["lastProcessedRowID"] as? String { lastRowID = Int64(value) }
    } catch { errors.record(error); throw error }
    let rows = try SQLiteReadConnection(url: databaseURL(for: library)).querySync("SELECT rowid,createdAt FROM prompt_items ORDER BY rowid ASC;")
    let consumed = rows.reduce(into: 0) { total, row in
        if let lastRowID, Int64(optionalString(row, "rowid") ?? "") ?? 0 <= lastRowID,
           benchmarkCreatedAtObservation(optionalString(row, "createdAt") ?? "") == nil { total += 1 }
    }
    var resumedResult: [String: Any] = [:]
    var idempotentResult: [String: Any] = [:]
    do {
        let repository = try PromptRepository(libraryURL: library)
        let seed = golden.itemFallbackDatesMicros.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
        let suffix = consumed <= seed.count ? Array(seed.dropFirst(consumed)) : []
        let result = try repository.runItemSequenceMigration(batchSize: batchSize, observationClock: ItemSequenceObservationClock(dates: suffix))
        resumedResult = ["completed": result.completed, "processedCount": result.processedCount, "phase": result.phase.rawValue, "clockConsumedBeforeResume": consumed]
        let beforeSecondRaw = try rawBusinessFingerprint(databaseURL: databaseURL(for: library))
        let beforeSecondHashes = try captureOrderHashes(databaseURL: databaseURL(for: library), parameters: try expectedQueries(locked: lockedParameters), pageSizes: [300])
        let beforeSecondState = try itemSequenceStateJSON(databaseURL: databaseURL(for: library))
        let second = try repository.runItemSequenceMigration(batchSize: batchSize, observationClock: ItemSequenceObservationClock(dates: []))
        idempotentResult = ["completed": second.completed, "processedCount": second.processedCount, "phase": second.phase.rawValue]
        let afterSecondRaw = try rawBusinessFingerprint(databaseURL: databaseURL(for: library))
        let afterSecondHashes = try captureOrderHashes(databaseURL: databaseURL(for: library), parameters: try expectedQueries(locked: lockedParameters), pageSizes: [300])
        let afterSecondState = try itemSequenceStateJSON(databaseURL: databaseURL(for: library))
        idempotentResult["rawBusinessFingerprintEqual"] = beforeSecondRaw == afterSecondRaw
        idempotentResult["orderHashesEqual"] = jsonEquivalent(beforeSecondHashes, afterSecondHashes)
        idempotentResult["stateEqual"] = jsonEquivalent(beforeSecondState, afterSecondState)
    } catch { errors.record(error); throw error }
    let finalState = try itemSequenceStateJSON(databaseURL: databaseURL(for: library))
    let parameters = try expectedQueries(locked: lockedParameters)
    let fullHash = try sqlFullHashParity(databaseURL: databaseURL(for: library), golden: golden, parameters: parameters, pageSizes: [300], expectedRawBusinessFingerprint: rawBefore)
    let timestamp = try runTimestampOracle(databaseURL: databaseURL(for: library), golden: golden, rawBefore: rawCreatedBefore)
    let equalKey = try runEqualKeyOracle(databaseURL: databaseURL(for: library), golden: golden)
    let invariants = try itemSequenceInvariants(databaseURL: databaseURL(for: library))
    let resumeOraclePass = fullHash.values.filter { $0["pass"] != nil }.allSatisfy { ($0["pass"] as? Bool) == true }
        && (fullHash["__meta"]?["rawBusinessFingerprintEqual"] as? Bool == true)
        && (timestamp["pass"] as? Bool == true)
        && (equalKey["pass"] as? Bool == true)
        && (invariants["contiguous"] as? Bool == true)
        && (invariants["nullCount"] as? Int == 0)
        && (invariants["duplicateCount"] as? Int == 0)
        && (invariants["gapCount"] as? Int == 0)
    let idempotentPass = (idempotentResult["rawBusinessFingerprintEqual"] as? Bool == true)
        && (idempotentResult["orderHashesEqual"] as? Bool == true)
        && (idempotentResult["stateEqual"] as? Bool == true)
    let pass = statePhase(finalState) == "ready" && (resumedResult["completed"] as? Bool ?? false) && (idempotentResult["completed"] as? Bool ?? false) && resumeOraclePass && idempotentPass
    guard pass else { throw BenchmarkError.goldenMismatch("migration.resume") }
    return [
        "pass": pass,
        "firstBatch": firstResult,
        "resume": resumedResult,
        "idempotentSecondRun": idempotentResult,
        "finalState": finalState,
        "migrationResumeOracle": [
            "pass": resumeOraclePass,
            "rawBusinessFingerprintBefore": rawBefore,
            "rawBusinessFingerprintEqual": fullHash["__meta"]?["rawBusinessFingerprintEqual"] ?? false,
            "fullShapeOrderPass": resumeOraclePass,
            "timestampOracle": timestamp,
            "equalKeyOracle": equalKey,
            "itemSequenceInvariants": invariants,
            "fullSQLHashParity": fullHash.filter { $0.key != "__coverage" }
        ],
        "idempotentPass": idempotentPass
    ]
}

private func phase2a1RelativeMetrics(sourceLibrary: URL, queryName: String) -> [String: Any] {
    let path = sourceLibrary.appendingPathComponent("baseline-query-benchmark.json")
    guard let data = try? Data(contentsOf: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let queries = root["queries"] as? [String: Any],
          let query = queries[queryName.lowercased()] as? [String: Any] else {
        return [
            "available": false,
            "comparable": false,
            "classification": "nonComparable_missing_baseline",
            "p50Milliseconds": NSNull(), "p95Milliseconds": NSNull(), "maxMilliseconds": NSNull(),
            "sqlMilliseconds": NSNull(), "decodeMilliseconds": NSNull(),
            "note": "Phase2A1 source metric unavailable"
        ]
    }
    let p50 = query["p50Milliseconds"] as? Double
    let classification: String
    let reason: String
    if let p50, p50 > 0 {
        classification = "nonComparable_projection_delta"
        reason = "Phase2A1 golden-results timing is legacy IDs-only; current Summary includes latest/reference/count/decode"
    } else {
        classification = "nonComparable_missing_baseline"
        reason = "Phase2A1 baseline has no usable total P50"
    }
    return [
        "available": true,
        "comparable": false,
        "classification": classification,
        "reason": reason,
        "p50Milliseconds": query["p50Milliseconds"] ?? NSNull(),
        "p95Milliseconds": query["p95Milliseconds"] ?? NSNull(),
        "maxMilliseconds": NSNull(),
        "sqlMilliseconds": NSNull(),
        "decodeMilliseconds": NSNull(),
        "note": "Phase2A1 baseline is total query timing only and nonComparable; unavailable stage splits and max remain null"
    ]
}

private func timingJSON(_ values: [String: TimingStats]) -> [String: Any] {
    values.reduce(into: [String: Any]()) { result, pair in
        result[pair.key] = [
            "count": pair.value.count,
            "p50Milliseconds": pair.value.p50Milliseconds,
            "p95Milliseconds": pair.value.p95Milliseconds,
            "maxMilliseconds": pair.value.maxMilliseconds
        ]
    }
}

private let summaryRequiredShapes = ["All", "Folder", "Tag", "Type", "Model", "Favorite", "Recent", "Trash", "Combined"]
private let summaryRequiredPageSizes = ["300", "301", "600", "601"]
private let summaryRequiredStages = ["pageSQL", "countSQL", "sql", "decode", "total"]

private func summaryFiniteNumber(_ value: Any?) -> Double? {
    if value is Bool { return nil }
    if let number = value as? Double, number.isFinite { return number }
    if let number = value as? Float, number.isFinite { return Double(number) }
    if let number = value as? Int { return Double(number) }
    if let number = value as? Int64 { return Double(number) }
    if let number = value as? NSNumber {
        let converted = number.doubleValue
        return converted.isFinite ? converted : nil
    }
    return nil
}

private func summaryExactCount(_ value: Any?, expected: Int) -> Bool {
    if value is Bool { return false }
    if let integer = value as? Int { return integer == expected }
    if let integer = value as? Int64 { return integer == Int64(expected) }
    if let number = value as? NSNumber { return number.doubleValue == Double(expected) }
    return false
}

private struct SummaryGateMetrics {
    let timingSetValid: Bool
    let timingValidationError: String?
    let page300SQLP95: Double
    let allTotalP95Max: Double
    let allTotalMax: Double
    let expectedIterations: Int

    func json(targetMilliseconds: Double, scale: Int) -> [String: Any] {
        let hardMetricPass = page300SQLP95 <= targetMilliseconds
        let p95GatePass = timingSetValid && (scale != 100_000 || hardMetricPass)
        return [
            "targetMilliseconds": targetMilliseconds,
            "metric": "max-shape pageSize=300 SQL P95 gate",
            "gateSemantics": "only pageSize=300 SQL P95 is a 100k hard gate; pageSize=301/600/601 total timings are report-only",
            "observedPage300SQLP95Milliseconds": page300SQLP95,
            "observedP95TotalMilliseconds": allTotalP95Max,
            "observedMaxTotalMilliseconds": allTotalMax,
            "observedMaxMilliseconds": allTotalMax,
            "p95GatePass": p95GatePass,
            "maxMetric": "max-shape total maxMilliseconds (all page sizes, report-only)",
            "timingSetValid": timingSetValid,
            "timingValidationError": timingValidationError ?? NSNull(),
            "expectedIterations": expectedIterations,
            "pass": p95GatePass
        ]
    }
}

private func summaryInvalid(_ error: String, expectedIterations: Int) -> SummaryGateMetrics {
    SummaryGateMetrics(
        timingSetValid: false,
        timingValidationError: error,
        page300SQLP95: 0,
        allTotalP95Max: 0,
        allTotalMax: 0,
        expectedIterations: expectedIterations
    )
}

private func summaryGateMetrics(timings: [String: Any], expectedIterations: Int) -> SummaryGateMetrics {
    guard expectedIterations >= 30 else {
        return summaryInvalid("iterations must be at least 30", expectedIterations: expectedIterations)
    }
    guard Set(timings.keys) == Set(summaryRequiredShapes) else {
        return summaryInvalid("exact 9 shape set required", expectedIterations: expectedIterations)
    }
    var page300SQLP95: [Double] = []
    var totalP95: [Double] = []
    var totalMax: [Double] = []
    for shapeName in summaryRequiredShapes {
        guard let shape = timings[shapeName] as? [String: Any],
              let byPageSize = shape["byPageSize"] as? [String: Any] else {
            return summaryInvalid("missing byPageSize for (shapeName)", expectedIterations: expectedIterations)
        }
        guard Set(byPageSize.keys) == Set(summaryRequiredPageSizes) else {
            return summaryInvalid("exact 4 page-size set required for (shapeName)", expectedIterations: expectedIterations)
        }
        for pageSize in summaryRequiredPageSizes {
            guard let stages = byPageSize[pageSize] as? [String: Any] else {
                return summaryInvalid("missing stage map for (shapeName)/(pageSize)", expectedIterations: expectedIterations)
            }
            guard Set(stages.keys) == Set(summaryRequiredStages) else {
                return summaryInvalid("exact 5 stage set required for (shapeName)/(pageSize)", expectedIterations: expectedIterations)
            }
            for stageName in summaryRequiredStages {
                guard let stage = stages[stageName] as? [String: Any],
                      summaryExactCount(stage["count"], expected: expectedIterations),
                      let p50 = summaryFiniteNumber(stage["p50Milliseconds"]),
                      let p95 = summaryFiniteNumber(stage["p95Milliseconds"]),
                      let maxValue = summaryFiniteNumber(stage["maxMilliseconds"]),
                      p50 >= 0, p95 >= p50, maxValue >= p95 else {
                    return summaryInvalid("malformed timing set at (shapeName)/(pageSize)/(stageName)", expectedIterations: expectedIterations)
                }
                if stageName == "total" {
                    totalP95.append(p95)
                    totalMax.append(maxValue)
                }
                if pageSize == "300", stageName == "sql" {
                    page300SQLP95.append(p95)
                }
            }
        }
    }
    guard page300SQLP95.count == summaryRequiredShapes.count,
          totalP95.count == summaryRequiredShapes.count * summaryRequiredPageSizes.count,
          totalMax.count == summaryRequiredShapes.count * summaryRequiredPageSizes.count else {
        return summaryInvalid("timing cardinality mismatch", expectedIterations: expectedIterations)
    }
    return SummaryGateMetrics(
        timingSetValid: true,
        timingValidationError: nil,
        page300SQLP95: page300SQLP95.max() ?? 0,
        allTotalP95Max: totalP95.max() ?? 0,
        allTotalMax: totalMax.max() ?? 0,
        expectedIterations: expectedIterations
    )
}

private func summarySelfTestTimings(iterations: Int = 31, page300SQLP95: Double = 49) -> [String: Any] {
    var result: [String: Any] = [:]
    for shape in summaryRequiredShapes {
        var byPageSize: [String: Any] = [:]
        for pageSize in summaryRequiredPageSizes {
            var stages: [String: Any] = [:]
            for stage in summaryRequiredStages {
                let p95 = pageSize == "300" && stage == "sql" ? page300SQLP95 : 50.0
                let maximum = max(p95, 51.0)
                stages[stage] = ["count": iterations, "p50Milliseconds": 1.0, "p95Milliseconds": p95, "maxMilliseconds": maximum]
            }
            byPageSize[pageSize] = stages
        }
        result[shape] = ["byPageSize": byPageSize]
    }
    return result
}

private func summaryMutated(
    _ source: [String: Any], shape: String = "All", pageSize: String = "300", stage: String = "sql", key: String, value: Any
) -> [String: Any] {
    var result = source
    var shapeValue = result[shape] as! [String: Any]
    var pages = shapeValue["byPageSize"] as! [String: Any]
    var stages = pages[pageSize] as! [String: Any]
    var timing = stages[stage] as! [String: Any]
    timing[key] = value
    stages[stage] = timing
    pages[pageSize] = stages
    shapeValue["byPageSize"] = pages
    result[shape] = shapeValue
    return result
}

private func validateSummaryGateSemantics() throws {
    let valid = summarySelfTestTimings()
    let validMetrics = summaryGateMetrics(timings: valid, expectedIterations: 31)
    guard validMetrics.timingSetValid, validMetrics.json(targetMilliseconds: 50, scale: 100_000)["pass"] as? Bool == true else {
        throw BenchmarkError.timingInvariant("valid exact timing set was rejected")
    }
    let boundary = summaryGateMetrics(timings: summarySelfTestTimings(page300SQLP95: 50), expectedIterations: 31)
    guard boundary.timingSetValid, boundary.json(targetMilliseconds: 50, scale: 100_000)["pass"] as? Bool == true else {
        throw BenchmarkError.timingInvariant("pageSize=300 SQL P95 boundary was rejected")
    }
    let over = summaryGateMetrics(timings: summarySelfTestTimings(page300SQLP95: 50.0001), expectedIterations: 31)
    guard over.timingSetValid, over.json(targetMilliseconds: 50, scale: 100_000)["pass"] as? Bool == false,
          over.json(targetMilliseconds: 50, scale: 15_959)["pass"] as? Bool == true else {
        throw BenchmarkError.timingInvariant("pageSize=300 SQL/query over 50ms did not fail only the 100k gate")
    }
    let missingShape = valid.filter { $0.key != "Trash" }
    guard !summaryGateMetrics(timings: missingShape, expectedIterations: 31).timingSetValid else {
        throw BenchmarkError.timingInvariant("missing shape was accepted")
    }
    var extraShape = valid
    extraShape["Unexpected"] = extraShape["All"]
    guard !summaryGateMetrics(timings: extraShape, expectedIterations: 31).timingSetValid else {
        throw BenchmarkError.timingInvariant("extra shape was accepted")
    }
    let malformed = summaryMutated(valid, key: "p95Milliseconds", value: Double.nan)
    guard !summaryGateMetrics(timings: malformed, expectedIterations: 31).timingSetValid else {
        throw BenchmarkError.timingInvariant("NaN timing was accepted")
    }
    let wrongCount = summaryMutated(valid, key: "count", value: true)
    guard !summaryGateMetrics(timings: wrongCount, expectedIterations: 31).timingSetValid else {
        throw BenchmarkError.timingInvariant("boolean count was accepted")
    }
    var extraStage = valid
    var all = extraStage["All"] as! [String: Any]
    var pages = all["byPageSize"] as! [String: Any]
    var stages = pages["300"] as! [String: Any]
    stages["unexpected"] = stages["sql"]
    pages["300"] = stages
    all["byPageSize"] = pages
    extraStage["All"] = all
    guard !summaryGateMetrics(timings: extraStage, expectedIterations: 31).timingSetValid else {
        throw BenchmarkError.timingInvariant("extra stage was accepted")
    }
    let ordered = summaryMutated(valid, key: "p50Milliseconds", value: 60.0)
    guard !summaryGateMetrics(timings: ordered, expectedIterations: 31).timingSetValid else {
        throw BenchmarkError.timingInvariant("invalid p50/p95 order was accepted")
    }
}

private func runFixture(
    sourceLibrary: URL,
    outputRoot: URL,
    scale: Int,
    iterations: Int,
    pages: Int,
    batchSize: Int,
    pageSizes: [Int],
    browserState: Bool,
    errors: SQLiteErrorCounter
) async throws -> [String: Any] {
    let sourceDB = databaseURL(for: sourceLibrary)
    guard FileManager.default.fileExists(atPath: sourceDB.path) else { throw BenchmarkError.missingFixture(sourceDB.path) }
    // Only the smallest fixture runs the complete keyset pagination oracle.
    // Larger fixtures use one production SQL ID-only full-hash statement per
    // shape plus a persisted-table/version full-field oracle and bounded
    // keyset pages/boundaries, and report those scopes explicitly.
    let completePagination = scale == 15_959
    let lockedParameters = try loadLockedPhase2A1Parameters(sourceLibrary: sourceLibrary)
    let sourceBefore = try sourceSnapshot(sourceDB)
    let sourceTreeBefore = try sourceTreeManifest(sourceLibrary)
    let sourceTreeBeforeRepeat = try sourceTreeManifest(sourceLibrary)
    guard sourceTreeBefore.hash == sourceTreeBeforeRepeat.hash else {
        throw BenchmarkError.sourceMutated("non-canonical source tree manifest")
    }
    let outputLibrary = outputRoot.appendingPathComponent("library-\(scale)", isDirectory: true)
    let backupStart = DispatchTime.now().uptimeNanoseconds
    try cloneDatabaseOnline(source: sourceDB, destinationLibrary: outputLibrary)
    let backupCost = stageTiming([milliseconds(backupStart)])
    _ = try insertSyntheticRows(databaseURL: databaseURL(for: outputLibrary), lockedParameters: lockedParameters)
    let rawBefore = try rawBusinessFingerprint(databaseURL: databaseURL(for: outputLibrary))
    let rawCreatedBefore = try rawCreatedAtSnapshot(databaseURL: databaseURL(for: outputLibrary))
    let (golden, fallbackDates) = try buildLegacyGolden(
        databaseURL: databaseURL(for: outputLibrary), syntheticIDs: syntheticItems().map(\.id), lockedParameters: lockedParameters
    )
    try validateSyntheticLegacyOracle(golden)
    let goldenURL = outputLibrary.appendingPathComponent("golden-legacy.json")
    let goldenData = try JSONEncoder.prettySorted.encode(golden)
    try goldenData.write(to: goldenURL, options: .atomic)
    let goldenSHA = SHA256.hash(data: goldenData).map { String(format: "%02x", $0) }.joined()

    let ready: [String: Any] = try await {
        let migrationStart = DispatchTime.now().uptimeNanoseconds
        let repository: PromptRepository
        do {
            repository = try migrateAndValidate(libraryURL: outputLibrary, golden: golden, fallbackDates: fallbackDates, batchSize: batchSize)
        } catch { errors.record(error); throw error }
        let migrationCost = stageTiming([milliseconds(migrationStart)], batchSize: batchSize)
        try validateMigratedVersions(databaseURL: databaseURL(for: outputLibrary), golden: golden)
        let readyDB = databaseURL(for: outputLibrary)
        let stateBeforeIndexes = try itemSequenceStateJSON(databaseURL: readyDB)
        let invariants = try itemSequenceInvariants(databaseURL: readyDB)
        guard statePhase(stateBeforeIndexes) == "ready",
              (invariants["contiguous"] as? Bool) == true,
              (invariants["nullCount"] as? Int ?? 1) == 0,
              (invariants["duplicateCount"] as? Int ?? 1) == 0,
              (invariants["gapCount"] as? Int ?? 1) == 0 else {
            throw BenchmarkError.goldenMismatch("itemSequence.readyInvariants")
        }
        let rawAfterMigration = try rawBusinessFingerprint(databaseURL: readyDB)
        guard rawAfterMigration == rawBefore else { throw BenchmarkError.goldenMismatch("rawBusinessFingerprint") }
        let indexStart = DispatchTime.now().uptimeNanoseconds
        let indexDatabase = try SQLiteDatabase(path: readyDB.path, mode: .existingReadWrite)
        try LibraryQuerySQLBuilder.installPhase2A4_1ItemIndexes(using: indexDatabase.execute)
        try LibraryQuerySQLBuilder.installPhase2A4LatestVersionIndex(using: indexDatabase.execute, versionSequenceReady: true)
        let indexCost = stageTiming([milliseconds(indexStart)])
        let executor = try TimedExecutor(path: readyDB.path)
        let capabilities = LibraryQueryCapabilities.runtime(for: repository)
        let service = LibraryQueryService(executor: executor, capabilities: capabilities)
        let parameters = try expectedQueries(locked: lockedParameters)
        try validateIDOnlyProductionQueryShapes(parameters: parameters)
        let summaryValidation = try await validateAllSummaries(service: service, golden: golden, parameters: parameters, completePagination: completePagination)
        var timingReports: [String: Any] = [:]
        var phase2a1: [String: Any] = [:]
        for name in queryNames {
            var perPage: [String: Any] = [:]
            for pageSize in pageSizes {
                let timings = try await benchmarkQuery(service: service, executor: executor, query: parameters.query(named: name, pageSize: pageSize), iterations: iterations)
                perPage[String(pageSize)] = timingJSON(timings)
            }
            let expectedMetric = phase2a1RelativeMetrics(sourceLibrary: sourceLibrary, queryName: name)
            timingReports[name] = ["byPageSize": perPage, "phase2A1": expectedMetric, "relativeP50ToPhase2A1": NSNull(), "comparisonClassification": expectedMetric["classification"] ?? "nonComparable_missing_baseline"]
            phase2a1[name] = expectedMetric
        }
        let fullHashStart = DispatchTime.now().uptimeNanoseconds
        let fullSQLHash = try sqlFullHashParity(databaseURL: readyDB, golden: golden, parameters: parameters, pageSizes: pageSizes, expectedRawBusinessFingerprint: rawBefore)
        let fullSQLHashCost = stageTiming([milliseconds(fullHashStart)])
        let traversalStart = DispatchTime.now().uptimeNanoseconds
        let fullTraversal = try await runFullTraversalParities(service: service, golden: golden, parameters: parameters, pageSizes: pageSizes, completePagination: completePagination)
        let fullTraversalCost = stageTiming([milliseconds(traversalStart)])
        let tenPage = try await runTenPageExercise(service: service, golden: golden, parameters: parameters, requestedPages: pages)
        let keyset = try await benchmarkKeysetPages(service: service, golden: golden, parameters: parameters, pages: pages)
        var explainByShape: [String: [String: Any]] = [:]
        for name in queryNames {
            explainByShape[name] = try explainContract(databaseURL: readyDB, query: parameters.query(named: name), capabilities: capabilities, shape: name)
        }
        let allExplainPass = explainByShape.values.allSatisfy { ($0["pass"] as? Bool) == true }
        guard allExplainPass else { throw BenchmarkError.explainContract("one or more shape page/count plans failed") }
        let summaryDetail = try await runSummaryDetailParity(repository: repository, service: service, golden: golden, parameters: parameters, completePagination: completePagination)
        let cancellationStart = DispatchTime.now().uptimeNanoseconds
        let cancellation = try await atomicPageCountCancellation(databaseURL: readyDB, capabilities: capabilities)
        let cancellationObserved = cancellation["cancellationObserved"] as? Bool == true
        let cancellationCost = stageTiming([milliseconds(cancellationStart)], errors: cancellationObserved ? 0 : 1, busy: errors.values.busy, locked: errors.values.locked)
        var lockProbe = try lockContentionProbe(databaseURL: readyDB)
        lockProbe["ordinaryObservedBusyCount"] = errors.values.busy
        lockProbe["ordinaryObservedLockedCount"] = errors.values.locked
        guard (lockProbe["injectedCoverage"] as? Bool) == true,
              (lockProbe["ordinaryObservedBusyCount"] as? Int) == 0,
              (lockProbe["ordinaryObservedLockedCount"] as? Int) == 0,
              (lockProbe["retryCount"] as? Int) == 0,
              (lockProbe["retryHidden"] as? Bool) == false else {
            throw BenchmarkError.sqliteBusyLocked("lock contention coverage was not distinct from ordinary counters")
        }
        let equalKey = try runEqualKeyOracle(databaseURL: readyDB, golden: golden)
        let timestamp = try runTimestampOracle(databaseURL: readyDB, golden: golden, rawBefore: rawCreatedBefore)
        let apples = try await applesToApplesProjectionVariants(databaseURL: readyDB, service: service, executor: executor, capabilities: capabilities, locked: lockedParameters, iterations: iterations)
        let migrationState = try itemSequenceStateJSON(databaseURL: readyDB)
        var migrationReport = migrationState
        for (key, value) in invariants { migrationReport[key] = value }
        migrationReport["migrationCost"] = migrationCost
        migrationReport["ready"] = true
        return [
            "migrationCost": migrationCost,
            "indexCost": indexCost,
            "migrationState": migrationReport,
            "summaryValidation": ["queries": summaryValidation.ids.mapValues(\.count), "counts": summaryValidation.counts, "allCountsMatchGolden": summaryValidation.counts.values.allSatisfy { ($0["countMismatch"] as? Bool) == false }, "allSummaryFieldsCompared": completePagination, "summaryFieldParityScope": completePagination ? "full" : "first-page", "versionOrderCompared": true, "currentVersionCompared": true, "hasPromptCompared": true, "hasReferencesCompared": true],
            "timings": timingReports,
            "timingSemantics": pageCountTimingSemantics,
            "phase2A1Relative": phase2a1,
            "keysetPages": keyset,
            "itemOrderParity": ["byShape": fullTraversal],
            "fullTraversalCost": fullTraversalCost,
            "fullProjectionParity": ["byShape": fullSQLHash.filter { $0.key != "__meta" && $0.key != "__coverage" }, "meta": fullSQLHash["__meta"] ?? [:], "coverage": fullSQLHash["__coverage"] ?? [:], "allShapesPass": fullSQLHash.values.allSatisfy { ($0["pass"] as? Bool) == true }, "fullFieldOracleMode": "persisted-table-and-version-scan"],
            "fullSQLHashParity": ["byShape": fullSQLHash.filter { $0.key != "__meta" && $0.key != "__coverage" }, "meta": fullSQLHash["__meta"] ?? [:], "coverage": fullSQLHash["__coverage"] ?? [:], "allShapesPass": fullSQLHash.values.allSatisfy { ($0["pass"] as? Bool) == true }, "fullFieldOracleMode": "persisted-table-and-version-scan"],
            "fullSQLHashCost": fullSQLHashCost,
            "fullFieldCoverage": fullSQLHash["__coverage"] ?? [:],
            "fullFieldOracleMode": "persisted-table-and-version-scan",
            "completePagination": completePagination,
            "completePaginationReason": completePagination ? "canonical pageSize=300 keyset traversal completed" : "diagnostic deep traversal cost; full order covered by single production ID-only SQL hash, persisted-table/version full-field oracle, and bounded keyset boundary",
            "tenPageRun": ["pageSize": 300, "requestedPages": pages, "byShape": tenPage],
            "explainContract": ["byShape": explainByShape, "allShapesPass": allExplainPass],
            "applesToApplesProjection": apples,
            "summaryDetailParity": summaryDetail,
            "runtimeSummaryDetailSample": summaryDetail,
            "cancellation": ["pass": cancellation["pass"] as? Bool == true, "cost": cancellationCost, "probe": cancellation],
            "busyLockedCoverage": lockProbe,
            "equalKeyOracle": equalKey,
            "timestampOracle": timestamp,
            "rawBusinessFingerprintBefore": rawBefore,
            "rawBusinessFingerprintAfter": rawAfterMigration
        ]
    }()
    let sourceAfter = try sourceSnapshot(sourceDB)
    let sourceTreeAfter = try sourceTreeManifest(sourceLibrary)
    guard sourceBefore.equal(to: sourceAfter), sourceTreeBefore.hash == sourceTreeAfter.hash else {
        throw BenchmarkError.sourceMutated(sourceLibrary.path)
    }
    let artifactSHA = try checkpointAndHashArtifact(databaseURL: databaseURL(for: outputLibrary))
    let artifactOnDisk = try fileHash(databaseURL(for: outputLibrary)).sha256
    guard artifactSHA == artifactOnDisk else { throw BenchmarkError.goldenMismatch("artifactSHA256") }
    let stability = try await runStability(sourceReadyLibrary: outputLibrary, outputRoot: outputRoot, scale: scale, parameters: try expectedQueries(locked: lockedParameters), pageSizes: pageSizes)
    let writer = try await runWriterMatrix(sourceReadyLibrary: outputLibrary, outputRoot: outputRoot, scale: scale, iterations: iterations, errors: errors)
    let resume = try runMigrationResume(sourceDatabase: sourceDB, outputRoot: outputRoot, scale: scale, lockedParameters: lockedParameters, golden: golden, fallbackDates: fallbackDates, batchSize: batchSize, errors: errors)
    guard let timingDictionary = ready["timings"] as? [String: Any] else {
        throw BenchmarkError.timingInvariant("missing timing report")
    }
    let gateMetrics = summaryGateMetrics(timings: timingDictionary, expectedIterations: iterations)
    let fullTotalTarget = gateMetrics.json(targetMilliseconds: 50.0, scale: scale)
    guard gateMetrics.timingSetValid else {
        throw BenchmarkError.timingInvariant(gateMetrics.timingValidationError ?? "invalid timing report")
    }
    if scale == 100_000, (fullTotalTarget["p95GatePass"] as? Bool) != true {
        throw BenchmarkError.unsupported("100k total Summary P95 gate exceeds 50ms target")
    }
    let sourceSafety: [String: Any] = [
        "sourceTreeBefore": sourceTreeBefore.entries,
        "sourceTreeAfter": sourceTreeAfter.entries,
        "sourceTreeSHAEqual": sourceTreeBefore.hash == sourceTreeAfter.hash,
        "sourceTreeManifestMode": canonicalFramedManifest,
        "sourceTreeCanonicalRepeatEqual": sourceTreeBefore.hash == sourceTreeBeforeRepeat.hash,
        "sourceTreeHashBefore": sourceTreeBefore.hash,
        "sourceTreeHashAfter": sourceTreeAfter.hash,
        "databaseBefore": sourceBefore.json,
        "databaseAfter": sourceAfter.json,
        "sourceOpenMode": sourceOpenMode(sourceDB),
        "onlineBackupOnly": true,
        "realLibraryAccessed": false,
        "symlinkRejected": true,
        "mediaReadCount": 0,
        "pathResolutionCount": 0
    ]
    let fallbackSeed = golden.itemFallbackDatesMicros
    let legacyGoldenReport: [String: Any] = [
        "artifactPath": goldenURL.path,
        "artifactSHA256": goldenSHA,
        "schema": golden.schema,
        "itemCount": golden.itemCount,
        "versionCount": golden.versionCount,
        "itemObservationOrderHash": itemOrderHash(golden.itemObservationOrder),
        "itemObservationOrder": golden.itemObservationOrder,
        "shapeOrderHashes": golden.itemShapeOrders.mapValues(itemOrderHash),
        "shapeOrders": golden.itemShapeOrders,
        "itemRawCreatedAt": golden.itemRawCreatedAt,
        "itemObservedCreatedAtMicros": golden.itemObservedCreatedAtMicros,
        "itemFallbackCount": golden.itemFallbackCount,
        "versionFallbackCount": golden.versionFallbackCount,
        "fallbackSeedMicros": fallbackSeed,
        "fallbackObservationOrder": golden.itemObservationOrder.filter { golden.itemRawCreatedAt[$0].map { benchmarkCreatedAtObservation($0) == nil } ?? false },
        "clockExhausted": false,
        "oldLoaderUsed": true,
        "sharedObservationClock": true,
        "sequenceDirection": golden.itemSequenceDirection,
        "legacyObservationOrderMatchesRowID": golden.itemObservationOrderMatchesRowID
    ]
    return [
        "scale": scale,
        "sourceLibrary": sourceLibrary.path,
        "sourceSafety": sourceSafety,
        "sourceReadOnlySHAEqual": sourceBefore.equal(to: sourceAfter),
        "sourceSHA": ["before": sourceBefore.json, "after": sourceAfter.json],
        "cloneDatabaseSHA256": artifactSHA,
        "artifactSHA256MatchesDisk": artifactSHA == artifactOnDisk,
        "itemCount": golden.itemCount,
        "versionCount": golden.versionCount,
        "syntheticIDs": syntheticItems().map(\.id),
        "observationFallbackCount": golden.observationFallbackCount,
        "legacyGolden": legacyGoldenReport,
        "itemSequenceMigration": ready["migrationState"] ?? [:],
        "itemOrderParity": ready["itemOrderParity"] ?? [:],
        "fullTraversalCost": ready["fullTraversalCost"] ?? [:],
        "fullProjectionParity": ready["fullProjectionParity"] ?? [:],
        "fullSQLHashParity": ready["fullSQLHashParity"] ?? [:],
        "fullFieldCoverage": ready["fullFieldCoverage"] ?? [:],
        "fullFieldOracleMode": ready["fullFieldOracleMode"] ?? "persisted-table-and-version-scan",
        "fullSQLHashCost": ready["fullSQLHashCost"] ?? [:],
        "completePagination": ready["completePagination"] ?? false,
        "completePaginationReason": ready["completePaginationReason"] ?? "unspecified",
        "tenPageRun": ready["tenPageRun"] ?? [:],
        "summaryValidation": ready["summaryValidation"] ?? [:],
        "summaryDetailParity": ready["summaryDetailParity"] ?? [:],
        "runtimeSummaryDetailSample": ready["runtimeSummaryDetailSample"] ?? [:],
        "cancellation": ready["cancellation"] ?? [:],
        "busyLockedCoverage": ready["busyLockedCoverage"] ?? [:],
        "equalKeyOracle": ready["equalKeyOracle"] ?? [:],
        "timestampOracle": ready["timestampOracle"] ?? [:],
        "timings": ready["timings"] ?? [:],
        "timingSemantics": ready["timingSemantics"] ?? pageCountTimingSemantics,
        "phase2A1Relative": ready["phase2A1Relative"] ?? [:],
        "keysetPages": ready["keysetPages"] ?? [:],
        "explainContract": ready["explainContract"] ?? [:],
        "stability": stability,
        "migrationResume": resume,
        "costs": ["onlineBackup": backupCost, "migration": ready["migrationCost"] ?? [:], "indexInstall": ready["indexCost"] ?? [:], "fullSQLHash": ready["fullSQLHashCost"] ?? [:], "fullTraversal": ready["fullTraversalCost"] ?? [:], "writer": writer, "cancellation": ready["cancellation"] ?? [:], "busyLockedCoverage": ready["busyLockedCoverage"] ?? [:], "explain": ready["explainContract"] ?? [:]],
        "browserState": ["available": false, "reason": browserState ? "not integrated in benchmark target; flag ignored" : "not integrated in benchmark target"],
        "fullTotalTarget": fullTotalTarget,
        "sqliteBusyCount": errors.values.busy,
        "sqliteLockedCount": errors.values.locked,
        "mediaReadCount": 0,
        "pathResolutionCount": 0
    ]
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONSerialization {
    static func write(_ object: Any, to url: URL) throws {
        let data = try data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@main
private enum Main {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--gate-semantics-self-test") {
                try validateSummaryGateSemantics()
                print("gate-semantics-self-test passed: exact 9 shapes × 4 page sizes required; malformed timing sets fail closed; exact pageSize=300 SQL P95=50 boundary passes; pageSize300 SQL/query over 50ms fails")
                return
            }
            if CommandLine.arguments.contains("--restart-probe") {
                try await processRestartProbe()
                return
            }
            guard let arguments = try Arguments.parse() else { return }
            try validatePageCountTimingContract()
            try validateTagTempBTreeContract()
            try FileManager.default.createDirectory(at: arguments.outputRoot, withIntermediateDirectories: true)
            let sourceBefore: [Int: SourceSnapshot] = try Dictionary(uniqueKeysWithValues: arguments.scales.map { scale in
                let source = arguments.sourceRoot.appendingPathComponent("library-\(scale)", isDirectory: true)
                return (scale, try sourceSnapshot(databaseURL(for: source)))
            })
            var reports: [String: Any] = [:]
            let errors = SQLiteErrorCounter()
            for scale in arguments.scales {
                let source = arguments.sourceRoot.appendingPathComponent("library-\(scale)", isDirectory: true)
                let report = try await runFixture(
                    sourceLibrary: source,
                    outputRoot: arguments.outputRoot,
                    scale: scale,
                    iterations: arguments.iterations,
                    pages: arguments.pages,
                    batchSize: arguments.batchSize,
                    pageSizes: arguments.pageSizes,
                    browserState: arguments.browserState,
                    errors: errors
                )
                reports["library-\(scale)"] = report
                print("benchmarked library-\(scale)")
            }
            let finalSnapshots: [Int: SourceSnapshot] = try Dictionary(uniqueKeysWithValues: arguments.scales.map { scale in
                let source = arguments.sourceRoot.appendingPathComponent("library-\(scale)", isDirectory: true)
                return (scale, try sourceSnapshot(databaseURL(for: source)))
            })
            let sourceEqual = arguments.scales.allSatisfy { sourceBefore[$0]?.equal(to: finalSnapshots[$0] ?? sourceBefore[$0]!) == true }
            let busyLocked = errors.values
            guard sourceEqual, busyLocked.busy == 0, busyLocked.locked == 0 else {
                throw BenchmarkError.sourceMutated("source SHA equality or SQLite busy/locked contract failed")
            }
            let reportURL = arguments.outputRoot.appendingPathComponent("phase2a4-1-report.json")
            try JSONSerialization.write([
                "schema": "phase2a4.1-item-sequence-benchmark-v1",
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "sourceRoot": arguments.sourceRoot.path,
                "outputRoot": arguments.outputRoot.path,
                "iterations": arguments.iterations,
                "keysetPages": arguments.pages,
                "migrationBatchSize": arguments.batchSize,
                "pageSizes": arguments.pageSizes,
                "browserState": ["available": false, "reason": "not integrated in benchmark target"],
                "sourceSHAEqual": sourceEqual,
                "sqliteBusyCount": busyLocked.busy,
                "sqliteLockedCount": busyLocked.locked,
                "timingSemantics": pageCountTimingSemantics,
                "fixtures": reports
            ], to: reportURL)
            let manifestURL = arguments.outputRoot.appendingPathComponent("phase2a4-1-manifest.json")
            try JSONSerialization.write([
                "schema": "phase2a4.1-manifest-v1",
                "report": reportURL.path,
                "sourceRoot": arguments.sourceRoot.path,
                "sourceSHAEqual": sourceEqual,
                "scales": arguments.scales,
                "onlineSQLiteBackupOnly": true,
                "canonicalPathSafetyGuard": true,
                "artifactHashesAfterCheckpoint": true,
                "completeSourceTreeManifest": true,
                "realLibraryAccessed": false,
                "mediaReadCount": 0,
                "pathResolutionCount": 0,
                "sqliteBusyCount": busyLocked.busy,
                "sqliteLockedCount": busyLocked.locked
            ], to: manifestURL)
            print("report: \(reportURL.path)")
            print("manifest: \(manifestURL.path)")
        } catch {
            fputs("PromptStudioPhase2A4Benchmark failed: \(error.localizedDescription) [\(String(describing: error))] phase2FileSystemCalls=\(restartProbePhase2FileSystemCounter.value)\n", stderr)
            exit(1)
        }
    }
}
