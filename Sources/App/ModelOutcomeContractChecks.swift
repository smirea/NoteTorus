#if DEBUG
import Foundation

@MainActor
enum ModelOutcomeContractChecks {
	static func runFromLaunchArguments() async {
		guard ProcessInfo.processInfo.arguments.contains("-model-outcome-contract-tests") else { return }
		do {
			try await reflectionChecks()
			try await weeklyChecks()
			print("MODEL OUTCOME CONTRACT: completion, skip, unavailable, failure, cancellation, and weekly review checks passed")
			fflush(nil)
		} catch { fatalError("MODEL OUTCOME CONTRACT: \(error)") }
	}

	private static func reflectionChecks() async throws {
		let transcript = "I want to make more room for focused work. The next step is to protect an hour."
		let generated = ReflectionResult(headline: "You made room to focus", summary: "You protected an hour.", modelName: "fixture")
		let success = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { generated }
		try expect(success.outcome == .complete && success.headline == generated.headline, "Successful reflection must remain complete")
		let unavailable = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw ModelProcessingError.unavailable }
		try expect(unavailable.outcome == .unavailable && !unavailable.outcome.isComplete && !unavailable.headline.isEmpty,
			"Unavailable reflection must keep only an explicitly incomplete fallback")
		let failed = await ReflectionEngine.reflect(on: transcript, includeSummary: false) {
			throw NSError(domain: "PRIVATE_MODEL_PAYLOAD", code: 1)
		}
		if case let .failed(message) = failed.outcome {
			try expect(!message.contains("PRIVATE_MODEL_PAYLOAD") && !failed.headline.isEmpty && failed.summary == nil,
				"Reflection failure must have a safe status and preserve the short-note fallback")
		} else { throw Failure(message: "Reflection failure was treated as success") }
		let timeout = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw ModelProcessingError.timedOut }
		try expect(!timeout.outcome.isComplete, "Timeout must not complete reflection")
		let invalid = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw ModelProcessingError.invalidOutput }
		try expect(!invalid.outcome.isComplete, "Invalid model output must not complete reflection")
		let silence = await ReflectionEngine.reflect(on: " \n", includeSummary: true) { throw Failure(message: "Silence invoked the model") }
		try expect(silence.outcome == .skipped && silence.summary == nil, "Silence must skip analysis explicitly")
		let thrownCancellation = await ReflectionEngine.reflect(on: transcript, includeSummary: true) { throw CancellationError() }
		try expect(thrownCancellation.outcome == .cancelled && thrownCancellation.headline.isEmpty && thrownCancellation.summary == nil,
			"Reflection cancellation must not generate fallback")

		let started = ModelOutcomeSignal()
		let task = Task {
			await ReflectionEngine.reflect(on: transcript, includeSummary: true) {
				await started.send()
				try await Task.sleep(for: .seconds(5))
				return generated
			}
		}
		defer { task.cancel() }
		try await started.wait()
		task.cancel()
		let canceled = await task.value
		try expect(canceled.outcome == .cancelled && canceled.headline.isEmpty, "In-flight reflection child cancellation must be retained")
	}

	private static func weeklyChecks() async throws {
		let start = Date(timeIntervalSince1970: 1_800_000_000)
		let entry = JournalEntry(createdAt: start, duration: 10, transcript: "You planned a focused week.", headline: "Your plans")
		let complete = WeeklyReview(weekStart: start, title: "Your week", body: "You planned ahead.", recordingMinutes: [])
		let success = await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) { complete }
		try expect(success.outcome == .complete && success.title == complete.title, "A completed weekly review must remain complete")
		let empty = await ReflectionEngine.weeklyReview(entries: [], weekStart: start) {
			throw Failure(message: "Empty week invoked generation")
		}
		try expect(empty.outcome == .skipped, "An empty week must skip generation")
		let unavailable = await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) { throw ModelProcessingError.unavailable }
		try expect(unavailable.outcome == .unavailable && !unavailable.body.isEmpty, "Weekly fallback must remain explicitly incomplete")
		let canceled = await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) { throw CancellationError() }
		try expect(canceled.outcome == .cancelled && canceled.title.isEmpty && canceled.body.isEmpty,
			"Canceled review must not manufacture fallback text")
		let started = ModelOutcomeSignal()
		let task = Task {
			await ReflectionEngine.weeklyReview(entries: [entry], weekStart: start) {
				await started.send()
				try? await Task.sleep(for: .seconds(5))
				return complete
			}
		}
		defer { task.cancel() }
		try await started.wait()
		task.cancel()
		let late = await task.value
		try expect(late.outcome == .cancelled && late.body.isEmpty, "Late weekly generation must not publish after cancellation")
	}

	private static func expect(_ condition: Bool, _ message: String) throws {
		guard condition else { throw Failure(message: message) }
	}

	private struct Failure: Error { let message: String }
}

private actor ModelOutcomeSignal {
	private var started = false
	func send() { started = true }
	func wait() async throws {
		for _ in 0..<200 {
			if started { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		throw Timeout()
	}
	private struct Timeout: Error {}
}
#endif
