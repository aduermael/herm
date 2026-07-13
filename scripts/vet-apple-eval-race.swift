import Foundation

@main
private struct CPSLEvalRaceChecks {
    static func main() async throws {
        let startState = CPSLEvalRaceBox()
        try require(!startState.didStartEvaluation, "new evaluation was marked as started")
        try require(startState.startEvaluationIfPending(), "evaluation did not start")
        try require(startState.didStartEvaluation, "evaluation start was not recorded")
        try require(!startState.startEvaluationIfPending(), "evaluation started twice")

        let cancelledBeforeStart = CPSLEvalRaceBox()
        let cancellationResult = await withCheckedContinuation { continuation in
            cancelledBeforeStart.resume(.cancelled, continuation: continuation)
        }
        guard case .cancelled = cancellationResult else {
            throw CheckFailure("pre-start cancellation did not win the race")
        }
        try require(
            !cancelledBeforeStart.startEvaluationIfPending(),
            "evaluation started after cancellation"
        )
        try require(
            !cancelledBeforeStart.didStartEvaluation,
            "cancelled evaluation was marked as started"
        )
        try require(
            !cancelledBeforeStart.isDetachedEvaluationRunning,
            "pre-start cancellation left detached work"
        )

        let cancelledAfterStart = CPSLEvalRaceBox()
        try require(cancelledAfterStart.startEvaluationIfPending(), "evaluation did not start")
        let cancelledResult = await withCheckedContinuation { continuation in
            cancelledAfterStart.resume(.cancelled, continuation: continuation)
        }
        guard case .cancelled = cancelledResult else {
            throw CheckFailure("started evaluation was not cancelled")
        }
        try require(
            cancelledAfterStart.isDetachedEvaluationRunning,
            "cancelled native evaluation was not retained as running"
        )
        try require(
            !cancelledAfterStart.resume(.completed(successResult)),
            "late cancelled completion resumed the continuation twice"
        )
        cancelledAfterStart.finishDetachedEvaluation()
        try require(
            !cancelledAfterStart.isDetachedEvaluationRunning,
            "finished cancelled evaluation remained busy"
        )

        let timedOutRace = CPSLEvalRaceBox()
        try require(timedOutRace.startEvaluationIfPending(), "timed-out evaluation did not start")
        var timedOutContinuation: CheckedContinuation<CPSLEvalRaceResult, Never>?
        let timeoutResult = await withCheckedContinuation { continuation in
            timedOutContinuation = continuation
            timedOutRace.resume(.timedOut, continuation: continuation)
        }
        guard case .timedOut = timeoutResult else {
            throw CheckFailure("timeout did not win the evaluation race")
        }
        try require(
            timedOutRace.isDetachedEvaluationRunning,
            "timed-out evaluation was not retained as running"
        )

        guard let timedOutContinuation else {
            throw CheckFailure("timeout continuation was not captured")
        }
        let lateCompletionWon = timedOutRace.resume(
            .completed(successResult),
            continuation: timedOutContinuation
        )
        try require(!lateCompletionWon, "late completion resumed the continuation twice")
        try require(
            timedOutRace.isDetachedEvaluationRunning,
            "late completion cleared the busy state before native cleanup"
        )

        timedOutRace.finishDetachedEvaluation()
        try require(
            !timedOutRace.isDetachedEvaluationRunning,
            "finished timed-out evaluation remained busy"
        )

        let completedRace = CPSLEvalRaceBox()
        let completedResult = await withCheckedContinuation { continuation in
            completedRace.resume(.completed(successResult), continuation: continuation)
        }
        guard case .completed = completedResult else {
            throw CheckFailure("normal completion did not win the evaluation race")
        }
        try require(
            !completedRace.isDetachedEvaluationRunning,
            "normal completion entered the timed-out busy state"
        )
    }

    private static let successResult: CPSLEvalServiceResult = (
        rawJSON: nil,
        stdout: "",
        stderr: "",
        exitCode: 0,
        ok: true,
        cwd: "/home/herm",
        errorCode: nil,
        errorMessage: nil,
        warnings: [],
        ffiError: nil
    )

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw CheckFailure(message)
        }
    }
}

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
