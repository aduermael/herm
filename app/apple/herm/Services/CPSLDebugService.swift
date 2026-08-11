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

private nonisolated final class CPSLXlsxCallbackBox: @unchecked Sendable {
    let service: CPSLExcelService

    init(service: CPSLExcelService) {
        self.service = service
    }
}

private nonisolated enum CPSLFileMutationError: LocalizedError {
    case destinationContainsSource
    case destinationExists
    case destinationUnavailable
    case duplicateName
    case overlappingSelection
    case protectedLocation
    case readOnly

    var errorDescription: String? {
        switch self {
        case .destinationContainsSource:
            return "A folder cannot be moved inside itself."
        case .destinationExists:
            return "An item with the same name already exists in that folder."
        case .destinationUnavailable:
            return "Choose a folder inside Home, Attachments, Temporary, or a writable iCloud folder."
        case .duplicateName:
            return "The selected items include duplicate names."
        case .overlappingSelection:
            return "Select either a folder or items inside it, not both."
        case .protectedLocation:
            return "This location cannot be moved or deleted."
        case .readOnly:
            return "This iCloud folder is read-only in Herm."
        }
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

private typealias CPSLXlsxHandleJSONFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

private typealias CPSLXlsxStringFreeFunction = @convention(c) (
    UnsafeMutablePointer<CChar>?
) -> Void

private typealias CPSLXlsxUserDataFreeFunction = @convention(c) (
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

private nonisolated struct CPSLXlsxCallbacks {
    var user_data: UnsafeMutableRawPointer?
    var handle_json: CPSLXlsxHandleJSONFunction?
    var string_free: CPSLXlsxStringFreeFunction?
    var user_data_free: CPSLXlsxUserDataFreeFunction?
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

private typealias CPSLSessionNewWithHostCallbacksV4Function = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<cpsl_webbrowser_callbacks_t>?,
    UnsafeRawPointer?,
    UnsafeRawPointer?,
    UnsafeRawPointer?,
    UnsafeRawPointer?,
    UnsafeRawPointer?
) -> OpaquePointer?

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

private nonisolated let cpslXlsxHandleJSON: CPSLXlsxHandleJSONFunction = { userData, requestJSON in
    guard let userData, let requestJSON else {
        return cpslWebBrowserOwnedErrorCString("xlsx callback received NULL input")
    }
    let callbackBox = Unmanaged<CPSLXlsxCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let request = String(cString: requestJSON)
    // cells_xlsx is pure CPU/file I/O; keep it off the main thread and run
    // synchronously so CPSL eval threads are not forced onto MainActor.
    let response = callbackBox.service.handleJSON(request)
    return cpslWebBrowserOwnedCString(response)
}

private nonisolated let cpslXlsxStringFree: CPSLXlsxStringFreeFunction = { value in
    cpslWebBrowserStringFree(value)
}

private nonisolated let cpslXlsxUserDataFree: CPSLXlsxUserDataFreeFunction = { userData in
    guard let userData else {
        return
    }
    Unmanaged<CPSLXlsxCallbackBox>.fromOpaque(userData).release()
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

private nonisolated func cpslSessionNewWithHostCallbacksV4Function() -> CPSLSessionNewWithHostCallbacksV4Function? {
#if canImport(Darwin)
    let lookupHandle = UnsafeMutableRawPointer(bitPattern: -2)
#else
    let lookupHandle: UnsafeMutableRawPointer? = nil
#endif
    let symbol = "cpsl_session_new_with_host_callbacks_v4".withCString { name in
        dlsym(lookupHandle, name)
    }
    guard let symbol else {
        return nil
    }
    return unsafeBitCast(symbol, to: CPSLSessionNewWithHostCallbacksV4Function.self)
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

    private let webBrowser: CPSLWebBrowserService
    private let location: CPSLLocationService
    private let excel: CPSLExcelService
    private let calendarActivityNotifier: CPSLCalendarActivityNotifier
    private let fileActivityNotifier: CPSLFileActivityNotifier
    private var iCloudMountManager: CPSLICloudMountManager?
    private var session: CPSLSessionHandle?
    private var sessionMountRevision: UInt64?
    private var nextSessionID = 0
    private var isInitializingSession = false
    private var evaluatingSessionID: Int?
    private var detachedEvaluations: [CPSLEvalRaceBox] = []
    private var sandboxURLs: CPSLSandboxURLs?
    private var currentVirtualDirectory = CPSLVirtualPath.initialDirectory

    init(
        webBrowser: CPSLWebBrowserService,
        location: CPSLLocationService,
        excel: CPSLExcelService = CPSLExcelService(),
        calendarActivityNotifier: CPSLCalendarActivityNotifier,
        fileActivityNotifier: CPSLFileActivityNotifier
    ) {
        self.webBrowser = webBrowser
        self.location = location
        self.excel = excel
        self.calendarActivityNotifier = calendarActivityNotifier
        self.fileActivityNotifier = fileActivityNotifier
    }

    deinit {
        if let session {
            cpsl_session_free(session.pointer)
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
        guard let url = try? hostURL(
            forVirtualPath: attachment.path,
            sandboxURLs: sandboxURLs
        ) else {
            return
        }
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
                let manager = try ensureICloudMountManager()
                let entries = manager.mounts.map {
                    CPSLFileEntry(
                        name: $0.label,
                        path: $0.virtualPath,
                        isDirectory: true,
                        syncState: manager.isKeepDownloaded($0.virtualPath)
                            ? .keepDownloaded
                            : nil
                    )
                }
                return CPSLDirectoryListing(entries: entries, error: nil)
            }
            let mountUseLease = try iCloudUseLease(forVirtualPath: normalizedPath)
            defer { mountUseLease?.release() }
            let hostURL = try hostURL(forVirtualPath: normalizedPath, sandboxURLs: sandboxURLs)
            guard isBrowserHostURLAllowed(hostURL, sandboxURLs: sandboxURLs) else {
                throw CPSLFileAccessError.outsideFilesystem
            }

            let fileManager = FileManager.default
            var resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
#if canImport(Darwin)
            resourceKeys.append(contentsOf: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
#endif
            let urls = try fileManager.contentsOfDirectory(
                at: hostURL,
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
            let manager = try? ensureICloudMountManager()
            let entries = try urls.map { url in
                let values = try url.resourceValues(forKeys: Set(resourceKeys))
                let childPath = Self.virtualChildPath(
                    parent: normalizedPath,
                    child: url.lastPathComponent
                )
                let syncState = Self.syncState(
                    for: values,
                    virtualPath: childPath,
                    manager: manager
                )
                return CPSLFileEntry(
                    name: url.lastPathComponent,
                    path: childPath,
                    isDirectory: values.isDirectory == true,
                    syncState: syncState
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            // Metadata listing only — never block navigation on downloads.
            // Bounded small-file prefetch runs after the listing is returned.
            if mountUseLease != nil, let manager {
                let prefetchPath = normalizedPath
                let prefetchURLs = urls
                Task {
                    guard let lease = try? manager.beginReadUse(for: prefetchPath) else {
                        return
                    }
                    defer { lease.release() }
                    try? manager.prefetchSmallCloudFiles(at: prefetchURLs)
                }
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
            let mountUseLease = try iCloudUseLease(forVirtualPath: normalizedPath)
            defer { mountUseLease?.release() }
            let hostURL = try hostURL(
                forVirtualPath: normalizedPath,
                sandboxURLs: sandboxURLs
            )
            guard FileManager.default.fileExists(atPath: hostURL.path) else {
                return CPSLFileEntryLookup(entry: nil, error: "File does not exist.")
            }
            var resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]
#if canImport(Darwin)
            resourceKeys.formUnion([
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
#endif
            let values = try hostURL.resourceValues(forKeys: resourceKeys)
            let name = normalizedPath == CPSLVirtualPath.root
                ? CPSLVirtualPath.root
                : hostURL.lastPathComponent
            let manager = try? ensureICloudMountManager()
            return CPSLFileEntryLookup(
                entry: CPSLFileEntry(
                    name: name,
                    path: normalizedPath,
                    isDirectory: values.isDirectory == true,
                    syncState: Self.syncState(
                        for: values,
                        virtualPath: normalizedPath,
                        manager: manager
                    )
                ),
                error: nil
            )
        } catch {
            return CPSLFileEntryLookup(entry: nil, error: error.localizedDescription)
        }
    }

    func deleteFileEntries(_ entries: [CPSLFileEntry]) throws {
        guard !entries.isEmpty else {
            return
        }

        let sandboxURLs = try ensureSandboxURLs()
        self.sandboxURLs = sandboxURLs
        let paths = entries.map { Self.normalizedVirtualPath($0.path) }
        try paths.forEach(validateFileMutationSource)
        try validateNonoverlappingSelection(entries)
        let mountUseLease = try iCloudWriteUseLease(forVirtualPaths: paths)
        defer { mountUseLease?.release() }

        let urls = try paths.map { path in
            let url = try hostURL(forVirtualPath: path, sandboxURLs: sandboxURLs)
            guard isBrowserHostURLAllowed(url, sandboxURLs: sandboxURLs) else {
                throw CPSLFileAccessError.outsideFilesystem
            }
            return (path, url)
        }

        for (path, url) in urls {
            try FileManager.default.removeItem(at: url)
            fileActivityNotifier.notify(CPSLFileActivity(path: path, operation: "delete"))
        }
    }

    func moveFileEntries(
        _ entries: [CPSLFileEntry],
        toDirectory destinationPath: String
    ) throws {
        guard !entries.isEmpty else {
            return
        }

        let sandboxURLs = try ensureSandboxURLs()
        self.sandboxURLs = sandboxURLs
        let normalizedDestination = Self.normalizedVirtualPath(destinationPath)
        try validateFileMutationDestination(normalizedDestination)

        let sourcePaths = entries.map { Self.normalizedVirtualPath($0.path) }
        try sourcePaths.forEach(validateFileMutationSource)
        try validateNonoverlappingSelection(entries)
        let sourceNames = sourcePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard Set(sourceNames.map { $0.lowercased() }).count == sourceNames.count else {
            throw CPSLFileMutationError.duplicateName
        }

        for entry in entries where entry.isDirectory {
            let sourcePath = Self.normalizedVirtualPath(entry.path)
            if normalizedDestination == sourcePath ||
                normalizedDestination.hasPrefix("\(sourcePath)/") {
                throw CPSLFileMutationError.destinationContainsSource
            }
        }

        let mountUseLease = try iCloudWriteUseLease(
            forVirtualPaths: sourcePaths + [normalizedDestination]
        )
        defer { mountUseLease?.release() }

        let destinationURL = try hostURL(
            forVirtualPath: normalizedDestination,
            sandboxURLs: sandboxURLs
        )
        guard isBrowserHostURLAllowed(destinationURL, sandboxURLs: sandboxURLs) else {
            throw CPSLFileAccessError.outsideFilesystem
        }
        let destinationValues = try destinationURL.resourceValues(forKeys: [.isDirectoryKey])
        guard destinationValues.isDirectory == true else {
            throw CPSLFileMutationError.destinationUnavailable
        }

        let fileManager = FileManager.default
        let moves = try zip(sourcePaths, sourceNames).map { sourcePath, sourceName in
            let sourceURL = try hostURL(
                forVirtualPath: sourcePath,
                sandboxURLs: sandboxURLs
            )
            guard isBrowserHostURLAllowed(sourceURL, sandboxURLs: sandboxURLs) else {
                throw CPSLFileAccessError.outsideFilesystem
            }
            let targetURL = destinationURL.appendingPathComponent(sourceName)
            guard !fileManager.fileExists(atPath: targetURL.path) else {
                throw CPSLFileMutationError.destinationExists
            }
            return (sourcePath, sourceURL, targetURL)
        }

        for (sourcePath, sourceURL, targetURL) in moves {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
            fileActivityNotifier.notify(
                CPSLFileActivity(path: sourcePath, operation: "move")
            )
        }
    }

    func attachmentThumbnail(for attachment: CPSLAttachment) async -> Data? {
        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let normalizedPath = Self.normalizedVirtualPath(attachment.path)
            let mountUseLease = try iCloudUseLease(forVirtualPath: normalizedPath)
            defer { mountUseLease?.release() }
            if mountUseLease != nil {
                try await ensureICloudMountManager().materializeFile(at: normalizedPath)
            }
            let url = try hostURL(forVirtualPath: normalizedPath, sandboxURLs: sandboxURLs)
            guard isBrowserHostURLAllowed(url, sandboxURLs: sandboxURLs) else {
                return nil
            }
            return Self.thumbnailData(for: url, maximumPixelSize: 96)
        } catch {
            return nil
        }
    }

    func previewFile(_ entry: CPSLFileEntry) async -> CPSLFilePreviewLoadResult {
        guard !entry.isDirectory else {
            return CPSLFilePreviewLoadResult(preview: nil, error: "Directories cannot be previewed.")
        }

        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let mountUseLease = try iCloudUseLease(forVirtualPath: entry.path)
            if mountUseLease != nil {
                try await ensureICloudMountManager().materializeFile(at: entry.path)
            }
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
            let result: CPSLFilePreviewLoadResult
            switch metadata.category {
            case .pdf:
                result = Self.previewResult(entry: entry, metadata: metadata, kind: .pdf(hostURL))
            case .code(let language):
                result = try Self.textualPreview(
                    hostURL: hostURL,
                    entry: entry,
                    metadata: metadata,
                    oversizedReason: "Text preview is limited to 1 MB."
                ) { text in
                    .code(text, language: language)
                }
            case .text:
                result = try Self.textualPreview(
                    hostURL: hostURL,
                    entry: entry,
                    metadata: metadata,
                    oversizedReason: "Text preview is limited to 1 MB."
                ) { text in
                    .text(text)
                }
            case .image:
                metadata.dimensions = Self.imageDimensions(for: hostURL)
                result = Self.previewResult(entry: entry, metadata: metadata, kind: .image(hostURL))
            case .audio:
                metadata.durationSeconds = await Self.mediaDuration(for: hostURL)
                result = Self.previewResult(entry: entry, metadata: metadata, kind: .audio(hostURL))
            case .video:
                let mediaInfo = await Self.videoInfo(for: hostURL)
                metadata.durationSeconds = mediaInfo.durationSeconds
                metadata.dimensions = mediaInfo.dimensions
                result = Self.previewResult(entry: entry, metadata: metadata, kind: .video(hostURL))
            case .archive, .data, .file:
                result = Self.previewResult(entry: entry, metadata: metadata, kind: .file(reason: nil))
            }
            let lifetimeToken: AnyObject?
            switch metadata.category {
            case .pdf, .image, .audio, .video:
                lifetimeToken = mountUseLease?.releaseGateRetainingScopes()
            case .archive, .code, .data, .file, .text:
                lifetimeToken = nil
            }
            return CPSLFilePreviewLoadResult(
                preview: result.preview,
                error: result.error,
                lifetimeToken: lifetimeToken
            )
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

    private nonisolated static func thumbnailData(
        for url: URL,
        maximumPixelSize: Int
    ) -> Data? {
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
#else
        _ = url
        _ = maximumPixelSize
        return nil
#endif
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
        iCloudMountManager?.mounts ?? []
    }

    func prepareICloudMounts() throws -> [CPSLICloudMount] {
        try ensureICloudMountManager().mounts
    }

    func connectICloudDirectory(
        from sourceURL: URL,
        accessMode: CPSLICloudMountAccessMode,
        progress: @escaping @Sendable (CPSLICloudImportProgress) -> Void
    ) async throws -> CPSLICloudMount {
        guard !isSessionBusy else {
            throw CPSLICloudMountError.sessionBusy
        }
        let iCloudMountManager = try ensureICloudMountManager()
        self.sandboxURLs = try ensureSandboxURLs()
        let mount = try await iCloudMountManager.connectDirectory(
            from: sourceURL,
            accessMode: accessMode,
            progress: progress
        )
        resetSessionIfMountRevisionChanged(to: iCloudMountManager.currentRevision)
        return mount
    }

    func removeICloudMount(at virtualPath: String) throws {
        guard !isSessionBusy else {
            throw CPSLICloudMountError.sessionBusy
        }
        let iCloudMountManager = try ensureICloudMountManager()
        let normalizedPath = Self.normalizedVirtualPath(virtualPath)
        try iCloudMountManager.removeMount(at: normalizedPath)
        resetSessionIfMountRevisionChanged(to: iCloudMountManager.currentRevision)
    }

    func setICloudMountAccessMode(
        _ accessMode: CPSLICloudMountAccessMode,
        at virtualPath: String
    ) throws {
        guard !isSessionBusy else {
            throw CPSLICloudMountError.sessionBusy
        }
        let manager = try ensureICloudMountManager()
        try manager.setAccessMode(
            accessMode,
            at: Self.normalizedVirtualPath(virtualPath)
        )
        resetSessionIfMountRevisionChanged(to: manager.currentRevision)
    }

    func setKeepDownloaded(
        _ keep: Bool,
        at virtualPath: String
    ) async throws {
        guard !isSessionBusy else {
            throw CPSLICloudMountError.sessionBusy
        }
        try await ensureICloudMountManager().setKeepDownloaded(
            keep,
            at: Self.normalizedVirtualPath(virtualPath)
        )
    }

    private nonisolated static func syncState(
        for values: URLResourceValues,
        virtualPath: String,
        manager: CPSLICloudMountManager?
    ) -> CPSLFileSyncState? {
        let isPinned = manager?.isKeepDownloaded(virtualPath) == true
#if canImport(Darwin)
        let status = CPSLICloudSyncPolicy.downloadStatus(from: values)
        return CPSLICloudSyncPolicy.syncState(
            isUbiquitous: values.isUbiquitousItem,
            downloadStatus: status,
            isPinned: isPinned
        )
#else
        _ = values
        return isPinned ? .keepDownloaded : nil
#endif
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
        if Task.isCancelled {
            return Self.cancellationFailure()
        }
        let mountUseLease: CPSLICloudMountUseLease
        do {
            let manager = try ensureICloudMountManager()
            guard let lease = try manager.beginSessionUse() else {
                return Self.ffiFailure("An iCloud folder is already in use")
            }
            mountUseLease = lease
            // Pins only — never whole-tree hydrate every mount for an eval.
            try await manager.materializePinnedContent()
        } catch is CancellationError {
            return Self.cancellationFailure()
        } catch {
            return Self.ffiFailure("Workspace setup failed: \(error.localizedDescription)")
        }
        if session != nil, sessionMountRevision != mountUseLease.revision {
            resetSessionForMountChange()
        }
        let sandboxURLs: CPSLSandboxURLs
        do {
            sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            await webBrowser.setSandboxRoot(sandboxURLs.root)
        } catch is CancellationError {
            return Self.cancellationFailure()
        } catch {
            return Self.ffiFailure("Workspace setup failed: \(error.localizedDescription)")
        }
        if Task.isCancelled {
            return Self.cancellationFailure()
        }

        if let sessionError = await initializeSessionIfNeeded(
            sandboxURLs: sandboxURLs,
            mountRevision: mountUseLease.revision
        ) {
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
            requestJSON: requestJSON,
            lifetimeToken: mountUseLease
        )

        let evaluation = await Self.performBlockingEvalWithTimeout(request) {
            Task {
                await self.pruneFinishedDetachedEvaluations()
            }
        }
        switch evaluation.result {
        case .completed(let result):
            if evaluatingSessionID == activeSession.id {
                evaluatingSessionID = nil
            }
            if let cwd = result.cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentVirtualDirectory = Self.normalizedVirtualPath(cwd, trimsOuterWhitespace: false)
            }
            return result
        case .timedOut:
            retainDetachedEvaluationIfRunning(evaluation.race)
            if session?.id == activeSession.id {
                // cpsl_eval may still be blocked. The worker owns this session
                // until the native call returns and it is safe to release.
                session = nil
                sessionMountRevision = nil
                currentVirtualDirectory = CPSLVirtualPath.initialDirectory
            }
            if evaluatingSessionID == activeSession.id {
                evaluatingSessionID = nil
            }
            return Self.timeoutFailure()
        case .cancelled:
            if evaluation.race.didStartEvaluation {
                retainDetachedEvaluationIfRunning(evaluation.race)
            } else {
                cpsl_session_free(activeSession.pointer)
            }
            if session?.id == activeSession.id {
                // A started worker releases the session after cpsl_eval returns.
                session = nil
                sessionMountRevision = nil
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
        if let resolved = iCloudMountManager?.hostURL(for: normalized) {
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
        return iCloudMountManager?.containsHostURL(url) == true
    }

    private nonisolated static func virtualChildPath(parent: String, child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    private func resetSessionForMountChange() {
        if let session {
            cpsl_session_free(session.pointer)
        }
        session = nil
        sessionMountRevision = nil
        evaluatingSessionID = nil
        currentVirtualDirectory = CPSLVirtualPath.initialDirectory
    }

    private func resetSessionIfMountRevisionChanged(to revision: UInt64) {
        guard session != nil, sessionMountRevision != revision else {
            return
        }
        resetSessionForMountChange()
    }

    private var isSessionBusy: Bool {
        pruneFinishedDetachedEvaluations()
        return isInitializingSession ||
            iCloudMountManager?.isUpdating == true ||
            evaluatingSessionID != nil ||
            !detachedEvaluations.isEmpty
    }

    private func retainDetachedEvaluationIfRunning(_ race: CPSLEvalRaceBox) {
        if race.isDetachedEvaluationRunning {
            detachedEvaluations.append(race)
        }
    }

    private func pruneFinishedDetachedEvaluations() {
        detachedEvaluations.removeAll { !$0.isDetachedEvaluationRunning }
    }

    private func initializeSessionIfNeeded(
        sandboxURLs: CPSLSandboxURLs,
        mountRevision: UInt64
    ) async -> String? {
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
        guard let configJSON = makeSessionConfigJSON(sandboxURLs: sandboxURLs) else {
            return "Could not encode session config JSON"
        }

        let callbackBox = CPSLWebBrowserCallbackBox(service: webBrowser)
        let fileActivityCallbackBox = CPSLFileActivityCallbackBox(notifier: fileActivityNotifier)
        let calendarActivityCallbackBox = CPSLCalendarActivityCallbackBox(notifier: calendarActivityNotifier)
        let locationCallbackBox = CPSLLocationCallbackBox(service: location)
        let xlsxCallbackBox = CPSLXlsxCallbackBox(service: excel)
        let visionCallbackBox = CPSLVisionCallbackBox()
        let result = await Self.performBlockingSessionInit(
            configJSON: configJSON,
            callbackBox: callbackBox,
            fileActivityCallbackBox: fileActivityCallbackBox,
            calendarActivityCallbackBox: calendarActivityCallbackBox,
            locationCallbackBox: locationCallbackBox,
            visionCallbackBox: visionCallbackBox,
            xlsxCallbackBox: xlsxCallbackBox
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
        sessionMountRevision = mountRevision
        currentVirtualDirectory = CPSLVirtualPath.initialDirectory
        return nil
    }

    private func iCloudUseLease(
        forVirtualPath virtualPath: String
    ) throws -> CPSLICloudMountUseLease? {
        let normalized = Self.normalizedVirtualPath(virtualPath)
        guard normalized.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/") else {
            return nil
        }
        guard let lease = try ensureICloudMountManager().beginReadUse(for: normalized) else {
            throw CPSLICloudMountError.sessionBusy
        }
        return lease
    }

    private func iCloudWriteUseLease(
        forVirtualPaths virtualPaths: [String]
    ) throws -> CPSLICloudMountUseLease? {
        let iCloudPaths = virtualPaths
            .map { Self.normalizedVirtualPath($0) }
            .filter { $0.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/") }
        guard !iCloudPaths.isEmpty else {
            return nil
        }

        let manager = try ensureICloudMountManager()
        for path in iCloudPaths {
            guard let mount = CPSLICloudMountResolver.mount(
                containing: path,
                in: manager.mounts
            ) else {
                throw CPSLICloudMountError.mountNotFound
            }
            guard mount.accessMode == .readWrite else {
                throw CPSLFileMutationError.readOnly
            }
        }
        guard let lease = try manager.beginSessionUse() else {
            throw CPSLICloudMountError.sessionBusy
        }
        return lease
    }

    private func validateFileMutationSource(_ virtualPath: String) throws {
        let normalized = Self.normalizedVirtualPath(virtualPath)
        guard Self.isFileMutationPathAllowed(normalized) else {
            throw CPSLFileMutationError.destinationUnavailable
        }
        let isMountRoot: Bool
        if normalized.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/") {
            isMountRoot = try ensureICloudMountManager().mounts.contains {
                $0.virtualPath == normalized
            }
        } else {
            isMountRoot = false
        }
        guard normalized != CPSLVirtualPath.home,
              normalized != CPSLVirtualPath.attachments,
              normalized != CPSLVirtualPath.temporary,
              normalized != CPSLVirtualPath.iCloudRoot,
              !isMountRoot
        else {
            throw CPSLFileMutationError.protectedLocation
        }
    }

    private func validateFileMutationDestination(_ virtualPath: String) throws {
        let normalized = Self.normalizedVirtualPath(virtualPath)
        guard Self.isFileMutationPathAllowed(normalized),
              normalized != CPSLVirtualPath.root,
              normalized != CPSLVirtualPath.iCloudRoot
        else {
            throw CPSLFileMutationError.destinationUnavailable
        }
    }

    private func validateNonoverlappingSelection(_ entries: [CPSLFileEntry]) throws {
        let directoryPaths = entries
            .filter(\.isDirectory)
            .map { Self.normalizedVirtualPath($0.path) }
        let allPaths = entries.map { Self.normalizedVirtualPath($0.path) }
        for directoryPath in directoryPaths where allPaths.contains(where: {
            $0 != directoryPath && $0.hasPrefix("\(directoryPath)/")
        }) {
            throw CPSLFileMutationError.overlappingSelection
        }
    }

    private nonisolated static func isFileMutationPathAllowed(_ virtualPath: String) -> Bool {
        virtualPath == CPSLVirtualPath.home ||
            virtualPath.hasPrefix("\(CPSLVirtualPath.home)/") ||
            virtualPath == CPSLVirtualPath.attachments ||
            virtualPath.hasPrefix("\(CPSLVirtualPath.attachments)/") ||
            virtualPath == CPSLVirtualPath.temporary ||
            virtualPath.hasPrefix("\(CPSLVirtualPath.temporary)/") ||
            virtualPath.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/")
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
        let sandboxURLs = CPSLSandboxURLs(
            root: rootURL,
            iCloudNamespace: sandboxURL.appendingPathComponent("icloud", isDirectory: true),
            iCloudMountStorage: sandboxURL.appendingPathComponent(
                "iCloudMounts",
                isDirectory: true
            ),
            legacyICloudRecovery: rootURL.appendingPathComponent(
                "home/herm/recovered-icloud-copies",
                isDirectory: true
            )
        )

        try ensureSandboxScaffold(sandboxURLs)
        let iCloudMountManager = CPSLICloudMountManager.shared(
            storageRoot: sandboxURLs.iCloudMountStorage,
            legacyRecoveryRoot: sandboxURLs.legacyICloudRecovery
        )
        do {
            try iCloudMountManager.prepare()
        } catch {
            if iCloudMountManager.hasPreparedState {
                self.iCloudMountManager = iCloudMountManager
                self.sandboxURLs = sandboxURLs
            }
            throw error
        }
        self.iCloudMountManager = iCloudMountManager
        self.sandboxURLs = sandboxURLs
        return sandboxURLs
    }

    private func ensureICloudMountManager() throws -> CPSLICloudMountManager {
        if let iCloudMountManager {
            return iCloudMountManager
        }
        _ = try ensureSandboxURLs()
        guard let iCloudMountManager else {
            throw CPSLICloudMountError.savedMountUnavailable
        }
        return iCloudMountManager
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
        try fileManager.createDirectory(
            at: sandboxURLs.iCloudNamespace,
            withIntermediateDirectories: true
        )

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

    private func makeSessionConfigJSON(sandboxURLs: CPSLSandboxURLs) -> String? {
        let rootPath = sandboxURLs.root.resolvingSymlinksInPath().path
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
            ],
            [
                "host": sandboxURLs.iCloudNamespace.resolvingSymlinksInPath().path,
                "virtual": CPSLVirtualPath.iCloudRoot,
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
        let iCloudMounts = iCloudMountManager?.mounts ?? []
        for mount in iCloudMounts {
            mounts.append([
                "host": mount.hostURL.resolvingSymlinksInPath().path,
                "virtual": mount.virtualPath,
                "mode": mount.accessMode.rawValue
            ])
        }

        let allowedDomains = ["*"]
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
        visionCallbackBox: CPSLVisionCallbackBox,
        xlsxCallbackBox: CPSLXlsxCallbackBox
    ) async -> CPSLSessionInitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .default).async {
                continuation.resume(returning: createSession(
                    configJSON: configJSON,
                    callbackBox: callbackBox,
                    fileActivityCallbackBox: fileActivityCallbackBox,
                    calendarActivityCallbackBox: calendarActivityCallbackBox,
                    locationCallbackBox: locationCallbackBox,
                    visionCallbackBox: visionCallbackBox,
                    xlsxCallbackBox: xlsxCallbackBox
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
        visionCallbackBox: CPSLVisionCallbackBox,
        xlsxCallbackBox: CPSLXlsxCallbackBox
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
        let xlsxUserData = Unmanaged.passRetained(xlsxCallbackBox).toOpaque()
        var xlsxCallbacks = CPSLXlsxCallbacks(
            user_data: xlsxUserData,
            handle_json: cpslXlsxHandleJSON,
            string_free: cpslXlsxStringFree,
            user_data_free: cpslXlsxUserDataFree
        )

        func createPointer(
            webBrowserCallbacks: UnsafePointer<cpsl_webbrowser_callbacks_t>?
        ) -> (pointer: OpaquePointer?, fallback: String) {
            if let sessionNewWithHostCallbacksV4 = cpslSessionNewWithHostCallbacksV4Function(),
               cpslVisionRespondFunction() != nil {
                let pointer = configJSON.withCString { configPointer in
                    withUnsafePointer(to: &fileActivityCallbacks) { fileActivityCallbacksPointer in
                        withUnsafePointer(to: &calendarActivityCallbacks) { calendarActivityCallbacksPointer in
                            withUnsafePointer(to: &locationCallbacks) { locationCallbacksPointer in
                                withUnsafePointer(to: &visionCallbacks) { visionCallbacksPointer in
                                    withUnsafePointer(to: &xlsxCallbacks) { xlsxCallbacksPointer in
                                        sessionNewWithHostCallbacksV4(
                                            configPointer,
                                            webBrowserCallbacks,
                                            UnsafeRawPointer(fileActivityCallbacksPointer),
                                            UnsafeRawPointer(calendarActivityCallbacksPointer),
                                            UnsafeRawPointer(locationCallbacksPointer),
                                            UnsafeRawPointer(visionCallbacksPointer),
                                            UnsafeRawPointer(xlsxCallbacksPointer)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                return (pointer, "cpsl_session_new_with_host_callbacks_v4 returned NULL")
            }

            // Older CPSL builds: release xlsx callback context and fall back.
            cpslXlsxUserDataFree(xlsxUserData)
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
        _ request: CPSLBlockingEvalRequest,
        onDetachedEvaluationFinished: @escaping @Sendable () -> Void
    ) async -> (result: CPSLEvalRaceResult, race: CPSLEvalRaceBox) {
        let race = CPSLEvalRaceBox()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                guard !Task.isCancelled, race.startEvaluationIfPending() else {
                    race.resume(.cancelled)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let result = performBlockingEval(request)
                    if !race.resume(.completed(result)) {
                        cpsl_session_free(request.session)
                        race.finishDetachedEvaluation()
                        onDetachedEvaluationFinished()
                    }
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
        return (result, race)
    }

    private nonisolated static func performBlockingEval(
        _ request: CPSLBlockingEvalRequest
    ) -> CPSLEvalServiceResult {
        let responsePointer = withExtendedLifetime(request.lifetimeToken) {
            request.requestJSON.withCString { requestPointer in
                cpsl_eval(request.session, requestPointer)
            }
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
