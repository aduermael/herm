import Foundation

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
    let lifetimeToken: AnyObject?
}

nonisolated enum CPSLEvalRaceResult: Sendable {
    case completed(CPSLEvalServiceResult)
    case timedOut
    case cancelled
}

nonisolated final class CPSLEvalRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var pendingResult: CPSLEvalRaceResult?
    private var continuation: CheckedContinuation<CPSLEvalRaceResult, Never>?
    private var evaluationStarted = false
    private var detachedEvaluationRunning = false

    func install(_ continuation: CheckedContinuation<CPSLEvalRaceResult, Never>) {
        lock.lock()
        if let pendingResult, !didResume {
            didResume = true
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(returning: pendingResult)
            return
        }
        if !didResume {
            self.continuation = continuation
        }
        lock.unlock()
    }

    @discardableResult
    func resume(_ result: CPSLEvalRaceResult) -> Bool {
        lock.lock()
        guard !didResume, pendingResult == nil else {
            lock.unlock()
            return false
        }
        if evaluationStarted {
            switch result {
            case .timedOut, .cancelled:
                detachedEvaluationRunning = true
            case .completed:
                break
            }
        }
        if let continuation {
            didResume = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
        return true
    }

    @discardableResult
    func resume(
        _ result: CPSLEvalRaceResult,
        continuation: CheckedContinuation<CPSLEvalRaceResult, Never>
    ) -> Bool {
        install(continuation)
        return resume(result)
    }

    var isDetachedEvaluationRunning: Bool {
        lock.lock()
        let isRunning = detachedEvaluationRunning
        lock.unlock()
        return isRunning
    }

    @discardableResult
    func startEvaluationIfPending() -> Bool {
        lock.lock()
        guard !evaluationStarted, !didResume, pendingResult == nil else {
            lock.unlock()
            return false
        }
        evaluationStarted = true
        lock.unlock()
        return true
    }

    var didStartEvaluation: Bool {
        lock.lock()
        let didStart = evaluationStarted
        lock.unlock()
        return didStart
    }

    func finishDetachedEvaluation() {
        lock.lock()
        detachedEvaluationRunning = false
        lock.unlock()
    }
}
