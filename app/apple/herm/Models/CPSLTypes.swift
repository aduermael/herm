import Foundation
import SwiftUI

typealias CPSLEvalServiceResult = (
    rawJSON: String?,
    stdout: String,
    stderr: String,
    exitCode: Int?,
    ok: Bool?,
    cwd: String?,
    errorCode: String?,
    errorMessage: String?,
    warnings: [String],
    ffiError: String?
)

nonisolated struct CPSLSessionHandle {
    let id: Int
    let pointer: OpaquePointer
}

nonisolated struct CPSLSessionInitResult: @unchecked Sendable {
    let pointer: OpaquePointer?
    let errorMessage: String?
}

nonisolated struct CPSLBlockingEvalRequest: @unchecked Sendable {
    let session: OpaquePointer
    let requestJSON: String
}

nonisolated enum CPSLEvalRaceResult: Sendable {
    case completed(CPSLEvalServiceResult)
    case timedOut
}

nonisolated final class CPSLEvalRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ result: CPSLEvalRaceResult,
        continuation: CheckedContinuation<CPSLEvalRaceResult, Never>
    ) {
        lock.lock()
        let shouldResume = !didResume
        if shouldResume {
            didResume = true
        }
        lock.unlock()

        if shouldResume {
            continuation.resume(returning: result)
        }
    }
}

struct CPSLSandboxURLs {
    let root: URL
    let workdir: URL
}

enum CPSLChatRole: String, Decodable {
    case assistant
    case user
    case command
    case output
    case error

    var isTrailingAligned: Bool {
        self == .user
    }

    var isFullWidth: Bool {
        self == .assistant || self == .command
    }

    var usesMonospaceBody: Bool {
        self == .command || self == .output || self == .error
    }

    var isFramed: Bool {
        self != .assistant
    }

    var displaysTitle: Bool {
        self != .assistant
    }

    var fill: Color {
        switch self {
        case .assistant:
            return .clear
        case .user:
            return CPSLTheme.elevated
        case .command:
            return CPSLTheme.command
        case .output:
            return CPSLTheme.surface
        case .error:
            return CPSLTheme.error
        }
    }

    var foreground: Color {
        CPSLTheme.text
    }
}

struct CPSLChatMessage: Identifiable {
    let id = UUID()
    let role: CPSLChatRole
    let title: String?
    var body: String

    init(role: CPSLChatRole, title: String?, body: String) {
        self.role = role
        self.title = title
        self.body = body
    }
}

struct CPSLFileEntry: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let isDirectory: Bool
}

struct CPSLDirectoryListing: Sendable {
    let entries: [CPSLFileEntry]
    let error: String?
}
