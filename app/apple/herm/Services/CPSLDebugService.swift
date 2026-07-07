import Dispatch
import Foundation
import CPSL
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

actor CPSLDebugService {
    private nonisolated static let evalTimeoutMilliseconds: UInt64 = 60_000
    private nonisolated static let textPreviewByteLimit = 1_000_000

    private var session: CPSLSessionHandle?
    private var nextSessionID = 0
    private var evaluatingSessionID: Int?
    private var sandboxURLs: CPSLSandboxURLs?
    private var currentVirtualDirectory = CPSLVirtualPath.initialDirectory

    deinit {
        if let session {
            cpsl_session_free(session.pointer)
        }
    }

    func listDirectory(_ virtualPath: String) -> CPSLDirectoryListing {
        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let hostURL = hostURL(forVirtualPath: virtualPath, sandboxURLs: sandboxURLs)

            let fileManager = FileManager.default
            let urls = try fileManager.contentsOfDirectory(
                at: hostURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            let normalizedPath = Self.normalizedVirtualPath(virtualPath)
            let entries = try urls.map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                return CPSLFileEntry(
                    name: url.lastPathComponent,
                    path: Self.virtualChildPath(parent: normalizedPath, child: url.lastPathComponent),
                    isDirectory: values.isDirectory == true
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return CPSLDirectoryListing(entries: entries, error: nil)
        } catch {
            return CPSLDirectoryListing(entries: [], error: error.localizedDescription)
        }
    }

    func previewFile(_ entry: CPSLFileEntry) async -> CPSLFilePreviewLoadResult {
        guard !entry.isDirectory else {
            return CPSLFilePreviewLoadResult(preview: nil, error: "Directories cannot be previewed.")
        }

        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let hostURL = hostURL(forVirtualPath: entry.path, sandboxURLs: sandboxURLs)
            let values = try hostURL.resourceValues(
                forKeys: [
                    .contentModificationDateKey,
                    .contentTypeKey,
                    .creationDateKey,
                    .fileSizeKey,
                    .isDirectoryKey,
                    .localizedTypeDescriptionKey,
                ]
            )
            guard Self.isHostURL(hostURL, inside: sandboxURLs.root) else {
                return CPSLFilePreviewLoadResult(
                    preview: nil,
                    error: "File preview is only available inside the CPSL filesystem."
                )
            }
            guard values.isDirectory != true else {
                return CPSLFilePreviewLoadResult(preview: nil, error: "Directories cannot be previewed.")
            }

            var metadata = Self.metadata(for: hostURL, values: values)
            switch metadata.category {
            case .pdf:
                return Self.previewResult(entry: entry, metadata: metadata, kind: .pdf(hostURL))
            case .code(let language):
                return try Self.textualPreview(
                    hostURL: hostURL,
                    entry: entry,
                    metadata: metadata,
                    oversizedReason: "Text preview is limited to 1 MB."
                ) { text in
                    .code(text, language: language)
                }
            case .text:
                return try Self.textualPreview(
                    hostURL: hostURL,
                    entry: entry,
                    metadata: metadata,
                    oversizedReason: "Text preview is limited to 1 MB."
                ) { text in
                    .text(text)
                }
            case .image:
                metadata.dimensions = Self.imageDimensions(for: hostURL)
                return Self.previewResult(entry: entry, metadata: metadata, kind: .image(hostURL))
            case .audio:
                metadata.durationSeconds = await Self.mediaDuration(for: hostURL)
                return Self.previewResult(entry: entry, metadata: metadata, kind: .audio(hostURL))
            case .video:
                let mediaInfo = await Self.videoInfo(for: hostURL)
                metadata.durationSeconds = mediaInfo.durationSeconds
                metadata.dimensions = mediaInfo.dimensions
                return Self.previewResult(entry: entry, metadata: metadata, kind: .video(hostURL))
            case .archive, .data, .file:
                return Self.previewResult(entry: entry, metadata: metadata, kind: .file(reason: nil))
            }
        } catch {
            return CPSLFilePreviewLoadResult(preview: nil, error: error.localizedDescription)
        }
    }

    private nonisolated static func previewResult(
        entry: CPSLFileEntry,
        metadata: CPSLFileMetadata,
        kind: CPSLFilePreviewKind
    ) -> CPSLFilePreviewLoadResult {
        CPSLFilePreviewLoadResult(
            preview: CPSLFilePreview(
                name: entry.name,
                path: entry.path,
                metadata: metadata,
                kind: kind
            ),
            error: nil
        )
    }

    private nonisolated static func textualPreview(
        hostURL: URL,
        entry: CPSLFileEntry,
        metadata: CPSLFileMetadata,
        oversizedReason: String,
        makeKind: (String) -> CPSLFilePreviewKind
    ) throws -> CPSLFilePreviewLoadResult {
        guard (metadata.sizeBytes ?? 0) <= textPreviewByteLimit else {
            return Self.previewResult(
                entry: entry,
                metadata: metadata,
                kind: .file(reason: oversizedReason)
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: hostURL)
        } catch {
            return Self.previewResult(
                entry: entry,
                metadata: metadata,
                kind: .file(reason: "This text file could not be read.")
            )
        }

        guard let text = decodedText(from: data) else {
            return Self.previewResult(
                entry: entry,
                metadata: metadata,
                kind: .file(reason: "This text file could not be decoded.")
            )
        }

        return Self.previewResult(entry: entry, metadata: metadata, kind: makeKind(text))
    }

    private nonisolated static func decodedText(from data: Data) -> String? {
        for encoding in [
            String.Encoding.utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
        ] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private nonisolated static func metadata(
        for url: URL,
        values: URLResourceValues
    ) -> CPSLFileMetadata {
        let fileExtension = url.pathExtension.lowercased()
        let category = CPSLFilePreviewCategory(
            fileName: url.lastPathComponent,
            fileExtension: fileExtension,
            contentTypeIdentifier: values.contentType?.identifier
        )
        return CPSLFileMetadata(
            category: category,
            typeDescription: values.localizedTypeDescription ?? String(localized: category.displayName),
            sizeBytes: values.fileSize.map(Int64.init),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            durationSeconds: nil,
            dimensions: nil
        )
    }

    private nonisolated static func imageDimensions(for url: URL) -> CPSLFileDimensions? {
        #if canImport(ImageIO)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else {
                return nil
            }
            let width = properties[kCGImagePropertyPixelWidth] as? Int
            let height = properties[kCGImagePropertyPixelHeight] as? Int
            guard let width, let height else {
                return nil
            }
            return CPSLFileDimensions(width: width, height: height)
        #else
            return nil
        #endif
    }

    private nonisolated static func mediaDuration(for url: URL) async -> Double? {
        #if canImport(AVFoundation)
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else {
                return nil
            }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite && seconds > 0 else {
                return nil
            }
            return seconds
        #else
            return nil
        #endif
    }

    private nonisolated static func videoInfo(
        for url: URL
    ) async -> (durationSeconds: Double?, dimensions: CPSLFileDimensions?) {
        #if canImport(AVFoundation)
            let asset = AVURLAsset(url: url)
            let durationSeconds = await mediaDuration(for: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                let track = tracks.first,
                let naturalSize = try? await track.load(.naturalSize),
                let preferredTransform = try? await track.load(.preferredTransform)
            else {
                return (durationSeconds, nil)
            }
            let transformedSize = naturalSize.applying(preferredTransform)
            let width = Int(abs(transformedSize.width).rounded())
            let height = Int(abs(transformedSize.height).rounded())
            guard width > 0, height > 0 else {
                return (durationSeconds, nil)
            }
            return (durationSeconds, CPSLFileDimensions(width: width, height: height))
        #else
            return (nil, nil)
        #endif
    }

    func evaluate(_ command: String) async -> CPSLEvalServiceResult {
        await evaluate(command, language: "bash")
    }

    func evaluateLuau(_ source: String) async -> CPSLEvalServiceResult {
        await evaluate(source, language: "luau")
    }

    func currentDirectory() -> String {
        currentVirtualDirectory
    }

    func availableSkills() -> [CPSLAgentSkill] {
        let userRootURL: URL?
        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            userRootURL = sandboxURLs.root.appendingPathComponent("skills", isDirectory: true)
        } catch {
            userRootURL = nil
        }
        return CPSLSkillCatalog.availableSkills(userRootURL: userRootURL)
    }

    func restoreCurrentDirectory(_ directory: String) async -> String? {
        let targetDirectory = Self.normalizedVirtualPath(directory, trimsOuterWhitespace: false)
        guard currentVirtualDirectory != targetDirectory else {
            return nil
        }

        let result = await evaluate("cd \(Self.shellDoubleQuoted(targetDirectory))", language: "bash")
        guard result.ok == true else {
            return result.errorMessage ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func evaluate(_ input: String, language: String) async -> CPSLEvalServiceResult {
        let sandboxURLs: CPSLSandboxURLs
        do {
            sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
        } catch {
            return Self.ffiFailure("Workspace setup failed: \(error.localizedDescription)")
        }

        if let sessionError = await initializeSessionIfNeeded(sandboxURLs: sandboxURLs) {
            return Self.ffiFailure("Session init: \(sessionError)")
        }

        guard let requestJSON = makeEvalRequestJSON(input: input, language: language) else {
            return Self.ffiFailure("Could not encode eval request JSON")
        }

        guard let activeSession = session else {
            return Self.ffiFailure("CPSL session is not initialized")
        }

        guard evaluatingSessionID != activeSession.id else {
            return Self.ffiFailure("CPSL eval is already running")
        }

        evaluatingSessionID = activeSession.id
        let request = CPSLBlockingEvalRequest(
            session: activeSession.pointer,
            requestJSON: requestJSON
        )

        switch await Self.performBlockingEvalWithTimeout(request) {
        case .completed(let result):
            if evaluatingSessionID == activeSession.id {
                evaluatingSessionID = nil
            }
            if let cwd = result.cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentVirtualDirectory = Self.normalizedVirtualPath(cwd, trimsOuterWhitespace: false)
            }
            return result
        case .timedOut:
            if session?.id == activeSession.id {
                // cpsl_eval may still be blocked; abandon and intentionally leak this session.
                session = nil
                currentVirtualDirectory = CPSLVirtualPath.initialDirectory
            }
            if evaluatingSessionID == activeSession.id {
                evaluatingSessionID = nil
            }
            return Self.timeoutFailure()
        }
    }

    private func hostURL(forVirtualPath virtualPath: String, sandboxURLs: CPSLSandboxURLs) -> URL {
        let normalized = Self.normalizedVirtualPath(virtualPath)
        return Self.appendingVirtualPath(normalized.dropFirst(), to: sandboxURLs.root)
    }

    private nonisolated static func normalizedVirtualPath(
        _ path: String,
        trimsOuterWhitespace: Bool = true
    ) -> String {
        var normalized = trimsOuterWhitespace
            ? path.trimmingCharacters(in: .whitespacesAndNewlines)
            : path
        if normalized.isEmpty {
            normalized = "/"
        }
        if !normalized.hasPrefix("/") {
            normalized = "/\(normalized)"
        }
        var components: [String] = []
        for component in normalized.split(separator: "/") {
            let pathComponent = String(component)
            switch pathComponent {
            case ".", "":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(pathComponent)
            }
        }
        return components.isEmpty ? "/" : "/\(components.joined(separator: "/"))"
    }

    private nonisolated static func shellDoubleQuoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "$":
                escaped += "\\$"
            case "`":
                escaped += "\\`"
            default:
                escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private nonisolated static func appendingVirtualPath<T: StringProtocol>(_ relativePath: T, to baseURL: URL) -> URL {
        var url = baseURL
        for component in relativePath.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private nonisolated static func isHostURL(_ url: URL, inside rootURL: URL) -> Bool {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix("\(rootPath)/")
    }

    private nonisolated static func virtualChildPath(parent: String, child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    private func initializeSessionIfNeeded(sandboxURLs: CPSLSandboxURLs) async -> String? {
        guard session == nil else {
            return nil
        }
        guard let configJSON = makeSessionConfigJSON(
            rootPath: sandboxURLs.root.resolvingSymlinksInPath().path
        ) else {
            return "Could not encode session config JSON"
        }

        let result = await Self.performBlockingSessionInit(configJSON: configJSON)
        guard let newSession = result.pointer else {
            return result.errorMessage ?? "cpsl_session_new returned NULL"
        }
        guard session == nil else {
            cpsl_session_free(newSession)
            return nil
        }

        nextSessionID += 1
        session = CPSLSessionHandle(id: nextSessionID, pointer: newSession)
        currentVirtualDirectory = CPSLVirtualPath.initialDirectory
        return nil
    }

    private func ensureSandboxURLs() throws -> CPSLSandboxURLs {
        if let sandboxURLs {
            return sandboxURLs
        }

        let fileManager = FileManager.default
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "herm"
        let appURL = supportURL.appendingPathComponent(bundleID, isDirectory: true)
        let sandboxURL = appURL.appendingPathComponent("CPSLDebugSandbox", isDirectory: true)
        let rootURL = sandboxURL.appendingPathComponent("root", isDirectory: true)
        let sandboxURLs = CPSLSandboxURLs(root: rootURL)

        try ensureSandboxScaffold(sandboxURLs)
        return sandboxURLs
    }

    private func ensureSandboxScaffold(_ sandboxURLs: CPSLSandboxURLs) throws {
        let fileManager = FileManager.default
        let directoryNames = [
            "",
            "bin",
            "etc",
            "home",
            "home/herm",
            "root",
            "skills",
            "tmp",
            "usr",
            "var"
        ]

        for name in directoryNames {
            let url = name.isEmpty ? sandboxURLs.root : sandboxURLs.root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        try writeFileIfMissing(
            sandboxURLs.root.appendingPathComponent("etc/hosts", isDirectory: false),
            contents: "127.0.0.1 localhost\n"
        )
        try writeFileIfMissing(
            sandboxURLs.root.appendingPathComponent("etc/passwd", isDirectory: false),
            contents: "root:x:0:0:root:/root:/bin/sh\nherm:x:501:20:Herm:/home/herm:/bin/sh\n"
        )
    }

    private func writeFileIfMissing(_ url: URL, contents: String) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSessionConfigJSON(rootPath: String) -> String? {
        var mounts: [[String: Any]] = [
            [
                "host": rootPath,
                "virtual": "/",
                "mode": "rw"
            ]
        ]
        for mount in CPSLSkillCatalog.systemSkillMounts() {
            mounts.append([
                "host": mount.hostURL.path,
                "virtual": mount.virtualPath,
                "mode": "ro"
            ])
        }

        let config: [String: Any] = [
            "mounts": mounts,
            "initial_cwd": CPSLVirtualPath.initialDirectory,
            "language": "luau",
            "http": [
                "mode": "policy",
                "allow_domains": [] as [String],
                "deny_domains": [] as [String]
            ]
        ]
        return jsonString(config)
    }

    private func makeEvalRequestJSON(input: String, language: String) -> String? {
        let request: [String: Any] = [
            "language": language,
            "input": input,
            "timeout_ms": Int(Self.evalTimeoutMilliseconds)
        ]
        return jsonString(request)
    }

    private func jsonString(_ object: Any) -> String? {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    private nonisolated static func performBlockingSessionInit(
        configJSON: String
    ) async -> CPSLSessionInitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .default).async {
                continuation.resume(returning: createSession(configJSON: configJSON))
            }
        }
    }

    private nonisolated static func createSession(configJSON: String) -> CPSLSessionInitResult {
        configureCPSLLibraryDirectory()
        let pointer = configJSON.withCString { configPointer in
            cpsl_session_new(configPointer)
        }
        guard let pointer else {
            return CPSLSessionInitResult(
                pointer: nil,
                errorMessage: lastErrorMessage(fallback: "cpsl_session_new returned NULL")
            )
        }
        return CPSLSessionInitResult(pointer: pointer, errorMessage: nil)
    }

    private nonisolated static func configureCPSLLibraryDirectory() {
        #if canImport(Darwin)
        let frameworksURL = Bundle.main.privateFrameworksURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        setenv("CPSL_LIBRARY_DIR", frameworksURL.path, 1)
        #endif
    }

    private nonisolated static func performBlockingEvalWithTimeout(
        _ request: CPSLBlockingEvalRequest
    ) async -> CPSLEvalRaceResult {
        await withCheckedContinuation { continuation in
            let race = CPSLEvalRaceBox()

            DispatchQueue.global(qos: .userInitiated).async {
                let result = performBlockingEval(request)
                race.resume(.completed(result), continuation: continuation)
            }

            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(Int(evalTimeoutMilliseconds))
            ) {
                race.resume(.timedOut, continuation: continuation)
            }
        }
    }

    private nonisolated static func performBlockingEval(
        _ request: CPSLBlockingEvalRequest
    ) -> CPSLEvalServiceResult {
        let responsePointer = request.requestJSON.withCString { requestPointer in
            cpsl_eval(request.session, requestPointer)
        }
        guard let responsePointer else {
            return ffiFailure(lastErrorMessage(fallback: "cpsl_eval returned NULL"))
        }
        defer {
            cpsl_string_free(responsePointer)
        }

        let rawJSON = String(cString: responsePointer)
        return parseEvalResponse(rawJSON: rawJSON)
    }

    private nonisolated static func parseEvalResponse(rawJSON: String) -> CPSLEvalServiceResult {
        guard
            let data = rawJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let response = object as? [String: Any]
        else {
            return (
                rawJSON: rawJSON,
                stdout: "",
                stderr: "",
                exitCode: nil,
                ok: false,
                cwd: nil,
                errorCode: "invalid_response",
                errorMessage: "CPSL returned a non-JSON response",
                warnings: [],
                ffiError: nil
            )
        }

        let error = response["error"] as? [String: Any]
        return (
            rawJSON: rawJSON,
            stdout: response["stdout"] as? String ?? "",
            stderr: response["stderr"] as? String ?? "",
            exitCode: intValue(response["exit_code"]),
            ok: boolValue(response["ok"]),
            cwd: response["cwd"] as? String,
            errorCode: error?["code"] as? String,
            errorMessage: error?["message"] as? String,
            warnings: stringArrayValue(response["warnings"]),
            ffiError: nil
        )
    }

    private nonisolated static func timeoutFailure() -> CPSLEvalServiceResult {
        (
            rawJSON: nil,
            stdout: "",
            stderr: "",
            exitCode: nil,
            ok: false,
            cwd: nil,
            errorCode: "timeout",
            errorMessage: "Command timed out after \(evalTimeoutMilliseconds / 1_000)s. You can try again.",
            warnings: [],
            ffiError: nil
        )
    }

    private nonisolated static func ffiFailure(_ message: String) -> CPSLEvalServiceResult {
        (
            rawJSON: nil,
            stdout: "",
            stderr: "",
            exitCode: nil,
            ok: false,
            cwd: nil,
            errorCode: "ffi_error",
            errorMessage: message,
            warnings: [],
            ffiError: message
        )
    }

    private nonisolated static func lastErrorMessage(fallback: String) -> String {
        guard let pointer = cpsl_last_error() else {
            return fallback
        }
        let message = String(cString: pointer)
        return message.isEmpty ? fallback : message
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private nonisolated static func stringArrayValue(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.map { String(describing: $0) }
        }
        return []
    }
}
