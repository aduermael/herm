import Dispatch
import Foundation
import CPSL
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

private nonisolated final class CPSLWebBrowserCallbackBox: @unchecked Sendable {
    let service: CPSLWebBrowserService

    init(service: CPSLWebBrowserService) {
        self.service = service
    }
}

private nonisolated final class CPSLFileActivityCallbackBox: @unchecked Sendable {
    let notifier: CPSLFileActivityNotifier

    init(notifier: CPSLFileActivityNotifier) {
        self.notifier = notifier
    }
}

private nonisolated final class CPSLCalendarActivityCallbackBox: @unchecked Sendable {
    let notifier: CPSLCalendarActivityNotifier

    init(notifier: CPSLCalendarActivityNotifier) {
        self.notifier = notifier
    }
}

private nonisolated final class CPSLLocationCallbackBox: @unchecked Sendable {
    let service: CPSLLocationService

    init(service: CPSLLocationService) {
        self.service = service
    }
}

private nonisolated final class CPSLVisionCallbackBox: @unchecked Sendable {
    let client: CPSLVisionClient?
    let configurationError: String?

    init() {
        do {
            client = CPSLVisionClient(config: try CPSLAgentConfig.load())
            configurationError = nil
        } catch {
            client = nil
            configurationError = error.localizedDescription
        }
    }
}

private typealias CPSLFileActivityHandleFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Void

private typealias CPSLFileActivityUserDataFreeFunction = @convention(c) (
    UnsafeMutableRawPointer?
) -> Void

private typealias CPSLCalendarActivityHandleFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> Void

private typealias CPSLCalendarActivityUserDataFreeFunction = @convention(c) (
    UnsafeMutableRawPointer?
) -> Void

private typealias CPSLLocationHandleJSONFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

private typealias CPSLLocationStringFreeFunction = @convention(c) (
    UnsafeMutablePointer<CChar>?
) -> Void

private typealias CPSLLocationUserDataFreeFunction = @convention(c) (
    UnsafeMutableRawPointer?
) -> Void

private typealias CPSLVisionHandleFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer?,
    UInt,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void

private typealias CPSLVisionUserDataFreeFunction = @convention(c) (
    UnsafeMutableRawPointer?
) -> Void

private typealias CPSLVisionRespondFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer?,
    UInt,
    UInt8
) -> Void

private nonisolated struct CPSLFileActivityCallbacks {
    var user_data: UnsafeMutableRawPointer?
    var handle_activity: CPSLFileActivityHandleFunction?
    var user_data_free: CPSLFileActivityUserDataFreeFunction?
}

private nonisolated struct CPSLCalendarActivityCallbacks {
    var user_data: UnsafeMutableRawPointer?
    var handle_activity: CPSLCalendarActivityHandleFunction?
    var user_data_free: CPSLCalendarActivityUserDataFreeFunction?
}

private nonisolated struct CPSLLocationCallbacks {
    var user_data: UnsafeMutableRawPointer?
    var handle_json: CPSLLocationHandleJSONFunction?
    var string_free: CPSLLocationStringFreeFunction?
    var user_data_free: CPSLLocationUserDataFreeFunction?
}

private nonisolated struct CPSLVisionInputFFI {
    var data: UnsafeRawPointer?
    var data_len: UInt
    var filename: UnsafePointer<CChar>?
    var media_type: UnsafePointer<CChar>?
}

private nonisolated struct CPSLVisionCallbacks {
    var user_data: UnsafeMutableRawPointer?
    var handle: CPSLVisionHandleFunction?
    var user_data_free: CPSLVisionUserDataFreeFunction?
}

private typealias CPSLSessionNewWithCallbacksFunction = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<cpsl_webbrowser_callbacks_t>?,
    UnsafeRawPointer?
) -> OpaquePointer?

private typealias CPSLSessionNewWithHostCallbacksFunction = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<cpsl_webbrowser_callbacks_t>?,
    UnsafeRawPointer?,
    UnsafeRawPointer?
) -> OpaquePointer?

private typealias CPSLSessionNewWithHostCallbacksV2Function = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<cpsl_webbrowser_callbacks_t>?,
    UnsafeRawPointer?,
    UnsafeRawPointer?,
    UnsafeRawPointer?
) -> OpaquePointer?

private typealias CPSLSessionNewWithHostCallbacksV3Function = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<cpsl_webbrowser_callbacks_t>?,
    UnsafeRawPointer?,
    UnsafeRawPointer?,
    UnsafeRawPointer?,
    UnsafeRawPointer?
) -> OpaquePointer?

nonisolated private final class CPSLFileCoordinatorCancellationBox: @unchecked Sendable {
    let coordinator = NSFileCoordinator(filePresenter: nil)

    func cancel() {
        coordinator.cancel()
    }
}

private nonisolated final class CPSLWebBrowserCallbackResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(value: String) {
        self.value = value
    }

    func set(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        let value = value
        lock.unlock()
        return value
    }
}

private nonisolated final class CPSLVisionCallbackResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?

    func set(_ value: Result<String, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Result<String, Error>? {
        lock.lock()
        let value = value
        lock.unlock()
        return value
    }
}

private nonisolated let cpslWebBrowserHandleJSON: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? = { userData, requestJSON in
    guard let userData, let requestJSON else {
        return cpslWebBrowserOwnedErrorCString("webbrowser callback received NULL input")
    }
    guard !Thread.isMainThread else {
        return cpslWebBrowserOwnedErrorCString("webbrowser callback cannot run on the main thread")
    }

    let callbackBox = Unmanaged<CPSLWebBrowserCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let request = String(cString: requestJSON)
    let response = CPSLWebBrowserCallbackResponse(
        value: #"{"ok":false,"error":"webbrowser callback did not complete"}"#
    )
    let semaphore = DispatchSemaphore(value: 0)
    let task = Task { @MainActor in
        response.set(await callbackBox.service.handleJSON(request))
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + .seconds(55)) == .timedOut {
        task.cancel()
        return cpslWebBrowserOwnedErrorCString("webbrowser callback timed out")
    }
    return cpslWebBrowserOwnedCString(response.get())
}

private nonisolated let cpslWebBrowserStringFree: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { value in
    guard let value else {
        return
    }
#if canImport(Darwin)
    Darwin.free(value)
#elseif canImport(Glibc)
    Glibc.free(value)
#endif
}

private nonisolated let cpslWebBrowserUserDataFree: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userData in
    guard let userData else {
        return
    }
    Unmanaged<CPSLWebBrowserCallbackBox>.fromOpaque(userData).release()
}

private nonisolated let cpslLocationHandleJSON: CPSLLocationHandleJSONFunction = { userData, requestJSON in
    guard let userData, let requestJSON else {
        return cpslWebBrowserOwnedErrorCString("location callback received NULL input")
    }
    guard !Thread.isMainThread else {
        return cpslWebBrowserOwnedErrorCString("location callback cannot run on the main thread")
    }

    let callbackBox = Unmanaged<CPSLLocationCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let request = String(cString: requestJSON)
    let response = CPSLWebBrowserCallbackResponse(
        value: #"{"ok":false,"error":"location callback did not complete"}"#
    )
    let semaphore = DispatchSemaphore(value: 0)
    let task = Task { @MainActor in
        response.set(await callbackBox.service.handleJSON(request))
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + .seconds(55)) == .timedOut {
        task.cancel()
        return cpslWebBrowserOwnedErrorCString("location callback timed out")
    }
    return cpslWebBrowserOwnedCString(response.get())
}

private nonisolated let cpslLocationStringFree: CPSLLocationStringFreeFunction = { value in
    cpslWebBrowserStringFree(value)
}

private nonisolated let cpslLocationUserDataFree: CPSLLocationUserDataFreeFunction = { userData in
    guard let userData else {
        return
    }
    Unmanaged<CPSLLocationCallbackBox>.fromOpaque(userData).release()
}

private nonisolated let cpslFileActivityHandle: CPSLFileActivityHandleFunction = { userData, path, operation in
    guard let userData, let path, let operation else {
        return
    }
    let callbackBox = Unmanaged<CPSLFileActivityCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    callbackBox.notifier.notify(
        CPSLFileActivity(
            path: String(cString: path),
            operation: String(cString: operation)
        )
    )
}

private nonisolated let cpslFileActivityUserDataFree: CPSLFileActivityUserDataFreeFunction = { userData in
    guard let userData else {
        return
    }
    Unmanaged<CPSLFileActivityCallbackBox>.fromOpaque(userData).release()
}

private nonisolated let cpslCalendarActivityHandle: CPSLCalendarActivityHandleFunction = { userData, operation in
    guard let userData, let operation else {
        return
    }
    let callbackBox = Unmanaged<CPSLCalendarActivityCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    callbackBox.notifier.notify(
        CPSLCalendarActivity(operation: String(cString: operation))
    )
}

private nonisolated let cpslCalendarActivityUserDataFree: CPSLCalendarActivityUserDataFreeFunction = { userData in
    guard let userData else {
        return
    }
    Unmanaged<CPSLCalendarActivityCallbackBox>.fromOpaque(userData).release()
}

private nonisolated let cpslVisionHandle: CPSLVisionHandleFunction = {
    userData, rawInputs, inputCount, queryPointer, responseContext in
    guard let respond = cpslVisionRespondFunction(), let responseContext else {
        return
    }

    func complete(_ value: String, isError: Bool) {
        let data = Data(value.utf8)
        data.withUnsafeBytes { bytes in
            respond(responseContext, bytes.baseAddress, UInt(bytes.count), isError ? 1 : 0)
        }
    }

    guard let userData, let queryPointer else {
        complete("vision callback received NULL input", isError: true)
        return
    }
    guard !Thread.isMainThread else {
        complete("vision callback cannot run on the main thread", isError: true)
        return
    }
    guard inputCount == 0 || rawInputs != nil else {
        complete("vision callback received a NULL input array", isError: true)
        return
    }
    guard inputCount <= UInt(Int.max) else {
        complete("vision callback received too many inputs", isError: true)
        return
    }

    let callbackBox = Unmanaged<CPSLVisionCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    guard let client = callbackBox.client else {
        complete(
            callbackBox.configurationError ?? "Vision model configuration is unavailable.",
            isError: true
        )
        return
    }

    let inputsPointer = rawInputs?.assumingMemoryBound(to: CPSLVisionInputFFI.self)
    var inputs: [CPSLVisionInput] = []
    inputs.reserveCapacity(Int(inputCount))
    for index in 0..<Int(inputCount) {
        guard let ffiInput = inputsPointer?[index],
              ffiInput.data_len == 0 || ffiInput.data != nil,
              ffiInput.data_len <= UInt(Int.max),
              let mediaTypePointer = ffiInput.media_type
        else {
            complete("vision callback received an invalid input", isError: true)
            return
        }
        let data = ffiInput.data_len == 0
            ? Data()
            : Data(bytes: ffiInput.data!, count: Int(ffiInput.data_len))
        inputs.append(CPSLVisionInput(
            data: data,
            mediaType: String(cString: mediaTypePointer)
        ))
    }

    let query = String(cString: queryPointer)
    let response = CPSLVisionCallbackResponse()
    let semaphore = DispatchSemaphore(value: 0)
    let task = Task {
        do {
            response.set(.success(try await client.read(
                inputs: inputs,
                query: query
            )))
        } catch {
            response.set(.failure(error))
        }
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + .seconds(55)) == .timedOut {
        task.cancel()
        complete("vision callback timed out", isError: true)
        return
    }
    guard let result = response.get() else {
        complete("vision callback did not complete", isError: true)
        return
    }
    switch result {
    case .success(let text):
        complete(text, isError: false)
    case .failure(let error):
        complete(error.localizedDescription, isError: true)
    }
}

private nonisolated let cpslVisionUserDataFree: CPSLVisionUserDataFreeFunction = { userData in
    guard let userData else {
        return
    }
    Unmanaged<CPSLVisionCallbackBox>.fromOpaque(userData).release()
}

private nonisolated func cpslSessionNewWithCallbacksFunction() -> CPSLSessionNewWithCallbacksFunction? {
#if canImport(Darwin)
    let lookupHandle = UnsafeMutableRawPointer(bitPattern: -2)
#else
    let lookupHandle: UnsafeMutableRawPointer? = nil
#endif
    let symbol = "cpsl_session_new_with_callbacks".withCString { name in
        dlsym(lookupHandle, name)
    }
    guard let symbol else {
        return nil
    }
    return unsafeBitCast(symbol, to: CPSLSessionNewWithCallbacksFunction.self)
}

private nonisolated func cpslSessionNewWithHostCallbacksFunction() -> CPSLSessionNewWithHostCallbacksFunction? {
#if canImport(Darwin)
    let lookupHandle = UnsafeMutableRawPointer(bitPattern: -2)
#else
    let lookupHandle: UnsafeMutableRawPointer? = nil
#endif
    let symbol = "cpsl_session_new_with_host_callbacks".withCString { name in
        dlsym(lookupHandle, name)
    }
    guard let symbol else {
        return nil
    }
    return unsafeBitCast(symbol, to: CPSLSessionNewWithHostCallbacksFunction.self)
}

private nonisolated func cpslSessionNewWithHostCallbacksV2Function() -> CPSLSessionNewWithHostCallbacksV2Function? {
#if canImport(Darwin)
    let lookupHandle = UnsafeMutableRawPointer(bitPattern: -2)
#else
    let lookupHandle: UnsafeMutableRawPointer? = nil
#endif
    let symbol = "cpsl_session_new_with_host_callbacks_v2".withCString { name in
        dlsym(lookupHandle, name)
    }
    guard let symbol else {
        return nil
    }
    return unsafeBitCast(symbol, to: CPSLSessionNewWithHostCallbacksV2Function.self)
}

private nonisolated func cpslSessionNewWithHostCallbacksV3Function() -> CPSLSessionNewWithHostCallbacksV3Function? {
#if canImport(Darwin)
    let lookupHandle = UnsafeMutableRawPointer(bitPattern: -2)
#else
    let lookupHandle: UnsafeMutableRawPointer? = nil
#endif
    let symbol = "cpsl_session_new_with_host_callbacks_v3".withCString { name in
        dlsym(lookupHandle, name)
    }
    guard let symbol else {
        return nil
    }
    return unsafeBitCast(symbol, to: CPSLSessionNewWithHostCallbacksV3Function.self)
}

private nonisolated func cpslVisionRespondFunction() -> CPSLVisionRespondFunction? {
#if canImport(Darwin)
    let lookupHandle = UnsafeMutableRawPointer(bitPattern: -2)
#else
    let lookupHandle: UnsafeMutableRawPointer? = nil
#endif
    let symbol = "cpsl_vision_respond".withCString { name in
        dlsym(lookupHandle, name)
    }
    guard let symbol else {
        return nil
    }
    return unsafeBitCast(symbol, to: CPSLVisionRespondFunction.self)
}

private nonisolated func cpslWebBrowserOwnedErrorCString(_ message: String) -> UnsafeMutablePointer<CChar>? {
    let object: [String: Any] = ["ok": false, "error": message]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return cpslWebBrowserOwnedCString(#"{"ok":false,"error":"webbrowser callback error"}"#)
    }
    return cpslWebBrowserOwnedCString(String(decoding: data, as: UTF8.self))
}

private nonisolated func cpslWebBrowserOwnedCString(_ value: String) -> UnsafeMutablePointer<CChar>? {
    let sanitized = value.replacingOccurrences(of: "\0", with: "\\u0000")
#if canImport(Darwin)
    return sanitized.withCString { Darwin.strdup($0) }
#elseif canImport(Glibc)
    return sanitized.withCString { Glibc.strdup($0) }
#else
    return nil
#endif
}

private enum CPSLAttachmentImportError: LocalizedError {
    case sourceIsNotFile

    var errorDescription: String? {
        switch self {
        case .sourceIsNotFile:
            String(localized: "Only files can be attached.")
        }
    }
}

actor CPSLDebugService {
    private nonisolated static let evalTimeoutMilliseconds: UInt64 = 60_000
    private nonisolated static let textPreviewByteLimit = 1_000_000
    private nonisolated static let temporaryFileLifetime: TimeInterval = 24 * 60 * 60
    private nonisolated static let iCloudStagingProcessRoot =
        CPSLICloudStagingStorage.makeProcessRoot(in: FileManager.default.temporaryDirectory)

    private let webBrowser: CPSLWebBrowserService
    private let location: CPSLLocationService
    private let calendarActivityNotifier: CPSLCalendarActivityNotifier
    private let fileActivityNotifier: CPSLFileActivityNotifier
    private var session: CPSLSessionHandle?
    private var nextSessionID = 0
    private var isInitializingSession = false
    private var isStagingICloudDirectory = false
    private var evaluatingSessionID: Int?
    private var sandboxURLs: CPSLSandboxURLs?
    private var currentVirtualDirectory = CPSLVirtualPath.initialDirectory
    private var iCloudMounts: [CPSLICloudMount] = []
    private let iCloudStagingRoot: URL

    init(
        webBrowser: CPSLWebBrowserService,
        location: CPSLLocationService,
        calendarActivityNotifier: CPSLCalendarActivityNotifier,
        fileActivityNotifier: CPSLFileActivityNotifier
    ) {
        self.webBrowser = webBrowser
        self.location = location
        self.calendarActivityNotifier = calendarActivityNotifier
        self.fileActivityNotifier = fileActivityNotifier
        iCloudStagingRoot = CPSLICloudStagingStorage.makeServiceRoot(
            in: Self.iCloudStagingProcessRoot
        )
    }

    deinit {
        if let session {
            cpsl_session_free(session.pointer)
        }
        let stagingRoot = iCloudStagingRoot
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
    }

    func prepareSandbox() async throws {
        let sandboxURLs = try ensureSandboxURLs()
        self.sandboxURLs = sandboxURLs
        await webBrowser.setSandboxRoot(sandboxURLs.root)
        cleanupTemporaryFiles(
            in: sandboxURLs.root.appendingPathComponent("tmp", isDirectory: true),
            olderThan: Date().addingTimeInterval(-Self.temporaryFileLifetime)
        )
    }

    func importAttachment(
        from sourceURL: URL,
        preferredName: String? = nil,
        conversationID: String
    ) throws -> CPSLAttachment {
        let sandboxURLs = try ensureSandboxURLs()
        self.sandboxURLs = sandboxURLs
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw CPSLAttachmentImportError.sourceIsNotFile
        }
        let destination = try attachmentDestination(
            preferredName: preferredName ?? sourceURL.lastPathComponent,
            conversationID: conversationID,
            sandboxURLs: sandboxURLs
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return composerAttachment(for: destination, conversationID: conversationID)
    }

    func importAttachment(
        data: Data,
        preferredName: String,
        conversationID: String
    ) throws -> CPSLAttachment {
        let sandboxURLs = try ensureSandboxURLs()
        self.sandboxURLs = sandboxURLs
        let destination = try attachmentDestination(
            preferredName: preferredName,
            conversationID: conversationID,
            sandboxURLs: sandboxURLs
        )
        try data.write(to: destination, options: .atomic)
        return composerAttachment(for: destination, conversationID: conversationID)
    }

    func removeAttachment(_ attachment: CPSLAttachment) {
        guard attachment.path.hasPrefix("\(CPSLVirtualPath.attachments)/") else {
            return
        }
        guard let sandboxURLs = try? ensureSandboxURLs() else {
            return
        }
        let attachmentsRoot = sandboxURLs.root
            .appendingPathComponent("attachments", isDirectory: true)
        let url = hostURL(forVirtualPath: attachment.path, sandboxURLs: sandboxURLs)
        guard url != attachmentsRoot,
              Self.isHostURL(url, inside: attachmentsRoot)
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
        let scopeURL = url.deletingLastPathComponent()
        if scopeURL != attachmentsRoot,
           Self.isHostURL(scopeURL, inside: attachmentsRoot),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: scopeURL.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: scopeURL)
        }
    }

    func removeAttachmentScope(conversationID: String) {
        guard let sandboxURLs = try? ensureSandboxURLs() else {
            return
        }
        let component = Self.safePathComponent(conversationID, fallback: "conversation")
        let url = sandboxURLs.root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        guard Self.isHostURL(url, inside: sandboxURLs.root) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func listDirectory(_ virtualPath: String) -> CPSLDirectoryListing {
        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let normalizedPath = Self.normalizedVirtualPath(virtualPath)
            if normalizedPath == CPSLVirtualPath.iCloudRoot {
                let entries = iCloudMounts.map {
                    CPSLFileEntry(name: $0.label, path: $0.virtualPath, isDirectory: true)
                }
                return CPSLDirectoryListing(entries: entries, error: nil)
            }
            let hostURL = try hostURL(forVirtualPath: normalizedPath, sandboxURLs: sandboxURLs)
            guard isBrowserHostURLAllowed(hostURL, sandboxURLs: sandboxURLs) else {
                throw CPSLFileAccessError.outsideFilesystem
            }

            let fileManager = FileManager.default
            let urls = try fileManager.contentsOfDirectory(
                at: hostURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
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
            fileActivityNotifier.notify(
                CPSLFileActivity(path: normalizedPath, operation: "read")
            )
            return CPSLDirectoryListing(entries: entries, error: nil)
        } catch {
            return CPSLDirectoryListing(entries: [], error: error.localizedDescription)
        }
    }

    func fileEntry(at virtualPath: String) -> CPSLFileEntryLookup {
        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let normalizedPath = Self.normalizedVirtualPath(virtualPath)
            let hostURL = hostURL(forVirtualPath: normalizedPath, sandboxURLs: sandboxURLs)
            guard FileManager.default.fileExists(atPath: hostURL.path) else {
                return CPSLFileEntryLookup(entry: nil, error: "File does not exist.")
            }
            let values = try hostURL.resourceValues(forKeys: [.isDirectoryKey])
            let name = normalizedPath == CPSLVirtualPath.root
                ? CPSLVirtualPath.root
                : hostURL.lastPathComponent
            return CPSLFileEntryLookup(
                entry: CPSLFileEntry(
                    name: name,
                    path: normalizedPath,
                    isDirectory: values.isDirectory == true
                ),
                error: nil
            )
        } catch {
            return CPSLFileEntryLookup(entry: nil, error: error.localizedDescription)
        }
    }

    func previewFile(_ entry: CPSLFileEntry) async -> CPSLFilePreviewLoadResult {
        guard !entry.isDirectory else {
            return CPSLFilePreviewLoadResult(preview: nil, error: "Directories cannot be previewed.")
        }

        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let hostURL = try hostURL(forVirtualPath: entry.path, sandboxURLs: sandboxURLs)
            guard isBrowserHostURLAllowed(hostURL, sandboxURLs: sandboxURLs) else {
                return CPSLFilePreviewLoadResult(
                    preview: nil,
                    error: "File preview is only available inside the CPSL filesystem."
                )
            }
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
            guard values.isDirectory != true else {
                return CPSLFilePreviewLoadResult(preview: nil, error: "Directories cannot be previewed.")
            }

            fileActivityNotifier.notify(
                CPSLFileActivity(path: entry.path, operation: "read")
            )
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

    func activeICloudMounts() -> [CPSLICloudMount] {
        iCloudMounts
    }

    func prepareICloudStaging() async {
        try? await CPSLICloudStagingCoordinator.shared.prepare(
            serviceRoot: iCloudStagingRoot,
            processRoot: Self.iCloudStagingProcessRoot,
            temporaryRoot: FileManager.default.temporaryDirectory
        )
    }

    func stageICloudDirectory(
        from sourceURL: URL,
        progress: @escaping @Sendable (CPSLICloudImportProgress) -> Void
    ) async throws -> CPSLICloudMount {
        guard !isSessionBusy else {
            throw CPSLICloudMountError.sessionBusy
        }
        isStagingICloudDirectory = true
        defer {
            isStagingICloudDirectory = false
        }
        try Task.checkCancellation()
        let sandboxURLs = try ensureSandboxURLs()
        self.sandboxURLs = sandboxURLs

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        guard didAccess else {
            throw CPSLICloudMountError.accessDenied
        }
        defer {
            sourceURL.stopAccessingSecurityScopedResource()
        }

        let values = try sourceURL.resourceValues(
            forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .localizedNameKey]
        )
        guard values.isDirectory == true else {
            throw CPSLICloudMountError.notDirectory
        }
        guard values.isUbiquitousItem == true else {
            throw CPSLICloudMountError.unsupportedProvider
        }

        let label = Self.sanitizedMountLabel(values.localizedName ?? sourceURL.lastPathComponent)
        guard !Self.isHostURL(sourceURL, inside: iCloudStagingRoot) else {
            throw CPSLICloudMountError.invalidSource
        }

        let permit = try await CPSLICloudStagingCoordinator.shared.beginImport(
            serviceRoot: iCloudStagingRoot,
            processRoot: Self.iCloudStagingProcessRoot,
            temporaryRoot: FileManager.default.temporaryDirectory
        )
        let slug = uniqueICloudMountSlug(for: label)
        let stagedURL = iCloudStagingRoot.appendingPathComponent(slug, isDirectory: true)
        do {
            _ = try await copyICloudDirectory(
                from: sourceURL,
                to: stagedURL,
                remainingUsage: permit.remainingUsage,
                availableCapacity: permit.availableCapacityBytes,
                progress: progress
            )
            try Task.checkCancellation()
        } catch {
            let originalError = error
            var cleanupFailed = false
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                do {
                    try FileManager.default.removeItem(at: stagedURL)
                } catch {
                    cleanupFailed = true
                }
            }
            await CPSLICloudStagingCoordinator.shared.finishImport()
            if cleanupFailed {
                throw CPSLICloudStagingError.cannotCleanUp
            }
            throw originalError
        }

        let mount = CPSLICloudMount(
            label: label,
            slug: slug,
            hostURL: stagedURL
        )
        iCloudMounts.append(mount)
        iCloudMounts.sort { $0.virtualPath < $1.virtualPath }
        resetSessionForMountChange()
        await CPSLICloudStagingCoordinator.shared.finishImport()
        return mount
    }

    func removeICloudMount(at virtualPath: String) throws {
        guard !isSessionBusy else {
            throw CPSLICloudMountError.sessionBusy
        }
        let normalizedPath = Self.normalizedVirtualPath(virtualPath)
        guard let index = iCloudMounts.firstIndex(where: { $0.virtualPath == normalizedPath }) else {
            throw CPSLICloudMountError.mountNotFound
        }

        let mount = iCloudMounts[index]
        if FileManager.default.fileExists(atPath: mount.hostURL.path) {
            try FileManager.default.removeItem(at: mount.hostURL)
        }
        iCloudMounts.remove(at: index)
        resetSessionForMountChange()
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
        guard !isStagingICloudDirectory else {
            return Self.ffiFailure("An iCloud folder is still being staged")
        }
        let sandboxURLs: CPSLSandboxURLs
        do {
            sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            await webBrowser.setSandboxRoot(sandboxURLs.root)
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
        case .cancelled:
            if session?.id == activeSession.id {
                // cpsl_eval cannot be interrupted safely; abandon this session and let its
                // background call finish without blocking the cancelled agent task.
                session = nil
                currentVirtualDirectory = CPSLVirtualPath.initialDirectory
            }
            if evaluatingSessionID == activeSession.id {
                evaluatingSessionID = nil
            }
            return Self.cancellationFailure()
        }
    }

    private func hostURL(forVirtualPath virtualPath: String, sandboxURLs: CPSLSandboxURLs) throws -> URL {
        let normalized = Self.normalizedVirtualPath(virtualPath)
        if let resolved = resolvedICloudHostURL(for: normalized) {
            return resolved
        }
        if normalized == CPSLVirtualPath.iCloudRoot ||
            normalized.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/") {
            throw CPSLICloudMountError.mountNotFound
        }
        return Self.appendingVirtualPath(normalized.dropFirst(), to: sandboxURLs.root)
    }

    private func attachmentDestination(
        preferredName: String,
        conversationID: String,
        sandboxURLs: CPSLSandboxURLs
    ) throws -> URL {
        let fileManager = FileManager.default
        let conversationComponent = Self.safePathComponent(conversationID, fallback: "conversation")
        let directory = sandboxURLs.root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(conversationComponent, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = Self.safeFileName(preferredName)
        let base = (safeName as NSString).deletingPathExtension
        let fileExtension = (safeName as NSString).pathExtension
        var destination = directory.appendingPathComponent(safeName, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            let candidate = fileExtension.isEmpty
                ? "\(base)-\(suffix)"
                : "\(base)-\(suffix).\(fileExtension)"
            destination = directory.appendingPathComponent(candidate, isDirectory: false)
            suffix += 1
        }
        return destination
    }

    private func composerAttachment(
        for destination: URL,
        conversationID: String
    ) -> CPSLAttachment {
        let conversationComponent = Self.safePathComponent(conversationID, fallback: "conversation")
        return CPSLAttachment(
            name: destination.lastPathComponent,
            path: "\(CPSLVirtualPath.attachments)/\(conversationComponent)/\(destination.lastPathComponent)"
        )
    }

    private nonisolated static func safeFileName(_ value: String) -> String {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = URL(fileURLWithPath: source.isEmpty ? "attachment" : source).lastPathComponent
        let component = safePathComponent(lastComponent, fallback: "attachment")
        return component.unicodeScalars.map { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? "-" : String(scalar)
        }
        .joined()
    }

    private nonisolated static func safePathComponent(_ value: String, fallback: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
            .union(.controlCharacters)
        let component = value.unicodeScalars.map { scalar in
            disallowed.contains(scalar) ? "-" : String(scalar)
        }
        .joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return component.isEmpty ? fallback : component
    }

    private func cleanupTemporaryFiles(in directory: URL, olderThan cutoff: Date) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: []
        ) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            ) else {
                continue
            }
            if values.isDirectory == true {
                directories.append(url)
            } else if (values.contentModificationDate ?? .distantFuture) < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }

        for url in directories.sorted(by: { $0.path.count > $1.path.count }) {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path),
                  contents.isEmpty
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
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

    private func isBrowserHostURLAllowed(_ url: URL, sandboxURLs: CPSLSandboxURLs) -> Bool {
        if Self.isHostURL(url, inside: sandboxURLs.root) {
            return true
        }
        return iCloudMounts.contains { mount in
            Self.isHostURL(url, inside: mount.hostURL)
        }
    }

    private func resolvedICloudHostURL(for normalizedPath: String) -> URL? {
        for mount in iCloudMounts {
            if normalizedPath == mount.virtualPath {
                return mount.hostURL
            }
            let prefix = "\(mount.virtualPath)/"
            if normalizedPath.hasPrefix(prefix) {
                let relativePath = normalizedPath.dropFirst(prefix.count)
                return Self.appendingVirtualPath(relativePath, to: mount.hostURL)
            }
        }
        return nil
    }

    private nonisolated static func virtualChildPath(parent: String, child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    private func copyICloudDirectory(
        from sourceURL: URL,
        to stagedURL: URL,
        remainingUsage: CPSLICloudStagingUsage,
        availableCapacity: Int64,
        progress: @escaping @Sendable (CPSLICloudImportProgress) -> Void
    ) async throws -> CPSLICloudStagingUsage {
        let cancellationBox = CPSLFileCoordinatorCancellationBox()
        let coordinator = cancellationBox.coordinator
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var coordinatorError: NSError?
            var copyError: Error?
            var stagingUsage: CPSLICloudStagingUsage?

            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: [],
                error: &coordinatorError
            ) { coordinatedURL in
                do {
                    stagingUsage = try CPSLICloudStagingStorage.stageDirectory(
                        from: coordinatedURL,
                        to: stagedURL,
                        remainingUsage: remainingUsage,
                        availableCapacityBytes: availableCapacity,
                        progress: progress
                    )
                } catch {
                    copyError = error
                }
            }

            try Task.checkCancellation()
            if let coordinatorError {
                throw coordinatorError
            }
            if let copyError {
                throw copyError
            }
            guard let stagingUsage else {
                throw CPSLICloudStagingError.cannotEnumerateFolder
            }
            return stagingUsage
        } onCancel: {
            // NSFileCoordinator may wait for an active accessor to return.
            // Never make the UI thread pay for that wait.
            DispatchQueue.global(qos: .utility).async {
                cancellationBox.cancel()
            }
        }
    }

    private func uniqueICloudMountSlug(for label: String) -> String {
        let baseSlug = Self.mountSlug(from: label)
        var slug = baseSlug
        var suffix = 2
        let usedSlugs = Set(iCloudMounts.map(\.slug))
        while usedSlugs.contains(slug) ||
            FileManager.default.fileExists(atPath: iCloudStagingRoot.appendingPathComponent(slug).path) {
            slug = "\(baseSlug)-\(suffix)"
            suffix += 1
        }
        return slug
    }

    private func resetSessionForMountChange() {
        if let session {
            cpsl_session_free(session.pointer)
        }
        session = nil
        evaluatingSessionID = nil
        currentVirtualDirectory = CPSLVirtualPath.initialDirectory
    }

    private var isSessionBusy: Bool {
        isInitializingSession || isStagingICloudDirectory || evaluatingSessionID != nil
    }

    private nonisolated static func sanitizedMountLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "iCloud Folder"
        }
        return String(trimmed.prefix(120))
    }

    private nonisolated static func mountSlug(from label: String) -> String {
        let lowercased = label.lowercased()
        var slug = ""
        var lastWasSeparator = false

        for scalar in lowercased.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
            if slug.count >= 64 {
                break
            }
        }

        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "icloud-folder" : slug
    }

    private func initializeSessionIfNeeded(sandboxURLs: CPSLSandboxURLs) async -> String? {
        guard session == nil else {
            return nil
        }
        guard !isInitializingSession else {
            return "CPSL session is already initializing"
        }
        isInitializingSession = true
        defer {
            isInitializingSession = false
        }
        await webBrowser.setSandboxRoot(sandboxURLs.root)
        guard let configJSON = makeSessionConfigJSON(
            rootPath: sandboxURLs.root.resolvingSymlinksInPath().path
        ) else {
            return "Could not encode session config JSON"
        }

        // A domain policy cannot constrain arbitrary JavaScript inside a WKWebView.
        // Omit the browser capability entirely while personal mounts are active.
        let callbackBox = iCloudMounts.isEmpty
            ? CPSLWebBrowserCallbackBox(service: webBrowser)
            : nil
        let fileActivityCallbackBox = CPSLFileActivityCallbackBox(notifier: fileActivityNotifier)
        let calendarActivityCallbackBox = CPSLCalendarActivityCallbackBox(notifier: calendarActivityNotifier)
        let locationCallbackBox = CPSLLocationCallbackBox(service: location)
        let visionCallbackBox = CPSLVisionCallbackBox()
        let result = await Self.performBlockingSessionInit(
            configJSON: configJSON,
            callbackBox: callbackBox,
            fileActivityCallbackBox: fileActivityCallbackBox,
            calendarActivityCallbackBox: calendarActivityCallbackBox,
            locationCallbackBox: locationCallbackBox,
            visionCallbackBox: visionCallbackBox
        )
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
            "attachments",
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
            ],
            [
                "host": URL(fileURLWithPath: rootPath)
                    .appendingPathComponent("attachments", isDirectory: true).path,
                "virtual": CPSLVirtualPath.attachments,
                "mode": "ro"
            ]
        ]
        for mount in CPSLSkillCatalog.systemSkillMounts() {
            mounts.append([
                "host": mount.hostURL.path,
                "virtual": mount.virtualPath,
                "mode": "ro"
            ])
        }
        for mount in iCloudMounts {
            mounts.append([
                "host": mount.hostURL.resolvingSymlinksInPath().path,
                "virtual": mount.virtualPath,
                "mode": "ro"
            ])
        }

        let allowedDomains: [String] = iCloudMounts.isEmpty ? ["*"] : []
        let config: [String: Any] = [
            "mounts": mounts,
            "initial_cwd": CPSLVirtualPath.initialDirectory,
            "language": "luau",
            "http": [
                "mode": "policy",
                "allow_domains": allowedDomains,
                "deny_domains": [] as [String]
            ],
            "webbrowser": [
                "mode": "policy",
                "allow_domains": allowedDomains,
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
        configJSON: String,
        callbackBox: CPSLWebBrowserCallbackBox?,
        fileActivityCallbackBox: CPSLFileActivityCallbackBox,
        calendarActivityCallbackBox: CPSLCalendarActivityCallbackBox,
        locationCallbackBox: CPSLLocationCallbackBox,
        visionCallbackBox: CPSLVisionCallbackBox
    ) async -> CPSLSessionInitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .default).async {
                continuation.resume(returning: createSession(
                    configJSON: configJSON,
                    callbackBox: callbackBox,
                    fileActivityCallbackBox: fileActivityCallbackBox,
                    calendarActivityCallbackBox: calendarActivityCallbackBox,
                    locationCallbackBox: locationCallbackBox,
                    visionCallbackBox: visionCallbackBox
                ))
            }
        }
    }

    private nonisolated static func createSession(
        configJSON: String,
        callbackBox: CPSLWebBrowserCallbackBox?,
        fileActivityCallbackBox: CPSLFileActivityCallbackBox,
        calendarActivityCallbackBox: CPSLCalendarActivityCallbackBox,
        locationCallbackBox: CPSLLocationCallbackBox,
        visionCallbackBox: CPSLVisionCallbackBox
    ) -> CPSLSessionInitResult {
        configureCPSLLibraryDirectory()
        let fileActivityUserData = Unmanaged.passRetained(fileActivityCallbackBox).toOpaque()
        var fileActivityCallbacks = CPSLFileActivityCallbacks(
            user_data: fileActivityUserData,
            handle_activity: cpslFileActivityHandle,
            user_data_free: cpslFileActivityUserDataFree
        )
        let calendarActivityUserData = Unmanaged.passRetained(calendarActivityCallbackBox).toOpaque()
        var calendarActivityCallbacks = CPSLCalendarActivityCallbacks(
            user_data: calendarActivityUserData,
            handle_activity: cpslCalendarActivityHandle,
            user_data_free: cpslCalendarActivityUserDataFree
        )
        let locationUserData = Unmanaged.passRetained(locationCallbackBox).toOpaque()
        var locationCallbacks = CPSLLocationCallbacks(
            user_data: locationUserData,
            handle_json: cpslLocationHandleJSON,
            string_free: cpslLocationStringFree,
            user_data_free: cpslLocationUserDataFree
        )
        let visionUserData = Unmanaged.passRetained(visionCallbackBox).toOpaque()
        var visionCallbacks = CPSLVisionCallbacks(
            user_data: visionUserData,
            handle: cpslVisionHandle,
            user_data_free: cpslVisionUserDataFree
        )

        func createPointer(
            webBrowserCallbacks: UnsafePointer<cpsl_webbrowser_callbacks_t>?
        ) -> (pointer: OpaquePointer?, fallback: String) {
            if let sessionNewWithHostCallbacksV3 = cpslSessionNewWithHostCallbacksV3Function(),
               cpslVisionRespondFunction() != nil {
                let pointer = configJSON.withCString { configPointer in
                    withUnsafePointer(to: &fileActivityCallbacks) { fileActivityCallbacksPointer in
                        withUnsafePointer(to: &calendarActivityCallbacks) { calendarActivityCallbacksPointer in
                            withUnsafePointer(to: &locationCallbacks) { locationCallbacksPointer in
                                withUnsafePointer(to: &visionCallbacks) { visionCallbacksPointer in
                                    sessionNewWithHostCallbacksV3(
                                        configPointer,
                                        webBrowserCallbacks,
                                        UnsafeRawPointer(fileActivityCallbacksPointer),
                                        UnsafeRawPointer(calendarActivityCallbacksPointer),
                                        UnsafeRawPointer(locationCallbacksPointer),
                                        UnsafeRawPointer(visionCallbacksPointer)
                                    )
                                }
                            }
                        }
                    }
                }
                return (pointer, "cpsl_session_new_with_host_callbacks_v3 returned NULL")
            }

            cpslVisionUserDataFree(visionUserData)
            if let sessionNewWithHostCallbacksV2 = cpslSessionNewWithHostCallbacksV2Function() {
                let pointer = configJSON.withCString { configPointer in
                    withUnsafePointer(to: &fileActivityCallbacks) { fileActivityCallbacksPointer in
                        withUnsafePointer(to: &calendarActivityCallbacks) { calendarActivityCallbacksPointer in
                            withUnsafePointer(to: &locationCallbacks) { locationCallbacksPointer in
                                sessionNewWithHostCallbacksV2(
                                    configPointer,
                                    webBrowserCallbacks,
                                    UnsafeRawPointer(fileActivityCallbacksPointer),
                                    UnsafeRawPointer(calendarActivityCallbacksPointer),
                                    UnsafeRawPointer(locationCallbacksPointer)
                                )
                            }
                        }
                    }
                }
                return (pointer, "cpsl_session_new_with_host_callbacks_v2 returned NULL")
            }

            if let sessionNewWithHostCallbacks = cpslSessionNewWithHostCallbacksFunction() {
                cpslCalendarActivityUserDataFree(calendarActivityUserData)
                let pointer = configJSON.withCString { configPointer in
                    withUnsafePointer(to: &fileActivityCallbacks) { fileActivityCallbacksPointer in
                        withUnsafePointer(to: &locationCallbacks) { locationCallbacksPointer in
                            sessionNewWithHostCallbacks(
                                configPointer,
                                webBrowserCallbacks,
                                UnsafeRawPointer(fileActivityCallbacksPointer),
                                UnsafeRawPointer(locationCallbacksPointer)
                            )
                        }
                    }
                }
                return (pointer, "cpsl_session_new_with_host_callbacks returned NULL")
            }

            if let sessionNewWithCallbacks = cpslSessionNewWithCallbacksFunction() {
                cpslCalendarActivityUserDataFree(calendarActivityUserData)
                cpslLocationUserDataFree(locationUserData)
                let pointer = configJSON.withCString { configPointer in
                    withUnsafePointer(to: &fileActivityCallbacks) { fileActivityCallbacksPointer in
                        sessionNewWithCallbacks(
                            configPointer,
                            webBrowserCallbacks,
                            UnsafeRawPointer(fileActivityCallbacksPointer)
                        )
                    }
                }
                return (pointer, "cpsl_session_new_with_callbacks returned NULL")
            }

            cpslFileActivityUserDataFree(fileActivityUserData)
            cpslCalendarActivityUserDataFree(calendarActivityUserData)
            cpslLocationUserDataFree(locationUserData)
            if let webBrowserCallbacks {
                let pointer = configJSON.withCString { configPointer in
                    cpsl_session_new_with_webbrowser_callbacks(configPointer, webBrowserCallbacks)
                }
                return (pointer, "cpsl_session_new_with_webbrowser_callbacks returned NULL")
            }
            let pointer = configJSON.withCString { configPointer in
                cpsl_session_new(configPointer)
            }
            return (pointer, "cpsl_session_new returned NULL")
        }

        let creationResult: (pointer: OpaquePointer?, fallback: String)
        if let callbackBox {
            let userData = Unmanaged.passRetained(callbackBox).toOpaque()
            var callbacks = cpsl_webbrowser_callbacks_t(
                user_data: userData,
                handle_json: cpslWebBrowserHandleJSON,
                string_free: cpslWebBrowserStringFree,
                user_data_free: cpslWebBrowserUserDataFree
            )
            creationResult = withUnsafePointer(to: &callbacks) { callbacksPointer in
                createPointer(webBrowserCallbacks: callbacksPointer)
            }
        } else {
            creationResult = createPointer(webBrowserCallbacks: nil)
        }

        guard let pointer = creationResult.pointer else {
            return CPSLSessionInitResult(
                pointer: nil,
                errorMessage: lastErrorMessage(fallback: creationResult.fallback)
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
        let race = CPSLEvalRaceBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                guard !Task.isCancelled else {
                    race.resume(.cancelled)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let result = performBlockingEval(request)
                    race.resume(.completed(result))
                }

                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .milliseconds(Int(evalTimeoutMilliseconds))
                ) {
                    race.resume(.timedOut)
                }
            }
        } onCancel: {
            race.resume(.cancelled)
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

    private nonisolated static func cancellationFailure() -> CPSLEvalServiceResult {
        (
            rawJSON: nil,
            stdout: "",
            stderr: "",
            exitCode: nil,
            ok: false,
            cwd: nil,
            errorCode: "cancelled",
            errorMessage: "Command cancelled.",
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

private enum CPSLFileAccessError: LocalizedError {
    case outsideFilesystem

    var errorDescription: String? {
        switch self {
        case .outsideFilesystem:
            return "Location is outside the CPSL filesystem."
        }
    }
}

private enum CPSLICloudMountError: LocalizedError {
    case accessDenied
    case invalidSource
    case mountNotFound
    case notDirectory
    case sessionBusy
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Herm could not access the selected iCloud folder."
        case .invalidSource:
            return "Choose a folder outside Herm's staged iCloud storage."
        case .mountNotFound:
            return "iCloud mount is not available."
        case .notDirectory:
            return "Choose a folder from iCloud Drive."
        case .sessionBusy:
            return "Wait for the current operation to finish."
        case .unsupportedProvider:
            return "Choose a folder from iCloud Drive, not another Files location."
        }
    }
}
