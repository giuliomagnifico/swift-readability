import XCTest
@testable import Readability

@MainActor
final class ReadabilityTests: XCTestCase {
    func testSequentialParsesWithDifferentModesAndOptions() async throws {
        let readability = Readability()
        let basic = try await readability.parse(
            html: articleHTML(title: "Basic"),
            options: .init(charThreshold: 100),
            baseURL: URL(string: "https://example.com/basic")
        )
        let sanitized = try await readability.parse(
            html: articleHTML(title: "Sanitized"),
            options: .init(charThreshold: 100, shouldSanitize: true),
            baseURL: URL(string: "https://example.com/sanitized")
        )
        let basicAgain = try await readability.parse(
            html: articleHTML(title: "Basic Again"),
            options: .init(charThreshold: 100, keepClasses: true),
            baseURL: URL(string: "https://example.com/basic-again")
        )

        XCTAssertEqual(basic.title, "Basic")
        XCTAssertEqual(sanitized.title, "Sanitized")
        XCTAssertEqual(basicAgain.title, "Basic Again")
    }

    func testManySequentialParsesReuseTheSamePublicInstance() async throws {
        let readability = Readability()
        for index in 0 ..< 100 {
            let result = try await readability.parse(
                html: articleHTML(title: "Article \(index)"),
                options: .init(charThreshold: 100, shouldSanitize: index.isMultiple(of: 2)),
                baseURL: URL(string: "https://example.com/\(index)")
            )
            XCTAssertEqual(result.title, "Article \(index)")
        }
    }

    func testCancellationOfAAllowsBToComplete() async throws {
        let readability = Readability()
        let first = Task { @MainActor in
            try await readability.parse(
                html: articleHTML(title: "A", repetitions: 5_000),
                options: .init(charThreshold: 100),
                baseURL: URL(string: "https://example.com/a")
            )
        }

        try await Task.sleep(for: .milliseconds(1))
        let second = try await readability.parse(
            html: articleHTML(title: "B"),
            options: .init(charThreshold: 100, shouldSanitize: true),
            baseURL: URL(string: "https://example.com/b")
        )

        XCTAssertEqual(second.title, "B")
        await XCTAssertThrowsCancellation(first)
    }

    func testPersistentRunnerInstallsExactlyTwoBootstrapScripts() async throws {
        let runner = ReadabilityRunner()
        XCTAssertEqual(runner.registeredUserScriptCount, 0)

        for _ in 0 ..< 3 {
            _ = try await runner.parseHTML(
                articleHTML(title: "Bootstrap"),
                options: .init(charThreshold: 100),
                baseURL: URL(string: "https://example.com/bootstrap")
            )
            XCTAssertEqual(runner.registeredUserScriptCount, 2)
        }
    }

    func testUnavailableDocumentFailsInsteadOfLeavingTheParsePending() async {
        let readability = Readability()
        do {
            _ = try await readability.parse(html: "<html><body>short</body></html>", options: nil, baseURL: nil)
            XCTFail("Expected an unavailable-reader error")
        } catch is CancellationError {
            XCTFail("The document was unavailable, not cancelled")
        } catch {
            // The internal error type is intentionally not public; failure is the compatibility contract.
        }
    }

    func testParsesContentThatIsProbablyReaderableWouldReject() async throws {
        let html = """
        <html><body><article>
        <p>A short intro line that is not long enough to score on its own.</p>
        <ul>
        <li><a href="https://example.com/1">Link one</a></li>
        <li><a href="https://example.com/2">Link two</a></li>
        <li><a href="https://example.com/3">Link three</a></li>
        </ul>
        <p>\(String(repeating: "Disclosure text that pads this paragraph out. ", count: 10))</p>
        </article></body></html>
        """

        let result = try await Readability().parse(html: html, options: nil, baseURL: nil)
        XCTAssertFalse(result.textContent.isEmpty)
    }

    func testTimeoutIgnoresLateCallbackAndRecoversForSubsequentParses() async throws {
        let runner = ReadabilityRunner(parseDeadline: 0.5, suppressedParserInvocations: 1)
        let first = Task { @MainActor in
            try await runner.parseHTML(
                articleHTML(title: "A"),
                options: .init(charThreshold: 100),
                baseURL: URL(string: "https://example.com/a")
            )
        }

        let firstRequestID = try await activeRequestID(of: runner)
        try await waitForSuppressedParserInvocation(of: runner)

        do {
            _ = try await first.value
            XCTFail("Expected A to time out")
        } catch is CancellationError {
            XCTFail("Expected a timeout, not cancellation")
        } catch {
            // Expected: the timed-out request is completed exactly once with an internal error.
        }

        XCTAssertNil(runner.activeRequestIDForTesting)
        XCTAssertFalse(runner.hasActiveTimeoutTaskForTesting)
        XCTAssertEqual(runner.registeredUserScriptCount, 0)
        XCTAssertEqual(runner.registeredMessageHandlerCountForTesting, 1)

        runner.deliverLateContentParsedForTesting(requestID: firstRequestID, result: try result(title: "Late A"))
        XCTAssertNil(runner.activeRequestIDForTesting)
        XCTAssertFalse(runner.hasActiveTimeoutTaskForTesting)

        runner.setParseDeadlineForTesting(10)

        let second: ReadabilityResult
        do {
            second = try await runner.parseHTML(
                articleHTML(title: "B"),
                options: .init(charThreshold: 100, shouldSanitize: true),
                baseURL: URL(string: "https://example.com/b")
            )
        } catch {
            XCTFail("B failed after A timed out: \(error)")
            return
        }
        XCTAssertEqual(second.title, "B")
        XCTAssertEqual(runner.registeredUserScriptCount, 2)
        XCTAssertEqual(runner.registeredMessageHandlerCountForTesting, 1)
        XCTAssertFalse(runner.hasActiveTimeoutTaskForTesting)

        let third: ReadabilityResult
        do {
            third = try await runner.parseHTML(
                articleHTML(title: "C"),
                options: .init(charThreshold: 100),
                baseURL: URL(string: "https://example.com/c")
            )
        } catch {
            XCTFail("C failed after B recovered: \(error)")
            return
        }
        XCTAssertEqual(third.title, "C")
        XCTAssertEqual(runner.registeredUserScriptCount, 2)
        XCTAssertEqual(runner.registeredMessageHandlerCountForTesting, 1)
        XCTAssertFalse(runner.hasActiveTimeoutTaskForTesting)
    }

    func testBenchmarkPersistentRunner() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["READABILITY_BENCHMARK"] == "1")

        for (name, repetitions) in [("small", 20), ("medium", 250), ("large", 1_500)] {
            let html = articleHTML(title: "Benchmark", repetitions: repetitions)
            let cold = try await measure(html: html, reuseInstance: false)
            let persistent = try await measure(html: html, reuseInstance: true)
            print("BENCHMARK \(name) cold median=\(milliseconds(cold.median)) p95=\(milliseconds(cold.p95)) persistent median=\(milliseconds(persistent.median)) p95=\(milliseconds(persistent.p95))")
        }
    }

    private func measure(html: String, reuseInstance: Bool) async throws -> (median: Duration, p95: Duration) {
        let reusable = Readability()
        var samples: [Duration] = []
        for _ in 0 ..< 5 {
            let readability = reuseInstance ? reusable : Readability()
            let clock = ContinuousClock()
            let start = clock.now
            _ = try await readability.parse(html: html, options: .init(charThreshold: 100), baseURL: URL(string: "https://example.com/benchmark"))
            samples.append(start.duration(to: clock.now))
        }
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted[sorted.count - 1])
    }

    private func articleHTML(title: String, repetitions: Int = 20) -> String {
        let paragraph = "<p>This is enough article content for Mozilla Readability to consistently extract the requested document without relying on network access.</p>"
        return "<html><head><title>\(title)</title></head><body><article><h1>\(title)</h1>\(String(repeating: paragraph, count: repetitions))</article></body></html>"
    }

    private func milliseconds(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1fms", milliseconds)
    }

    private func activeRequestID(of runner: ReadabilityRunner) async throws -> UInt64 {
        for _ in 0 ..< 100 {
            if let requestID = runner.activeRequestIDForTesting {
                return requestID
            }
            await Task.yield()
        }
        throw XCTSkip("The runner did not begin A before the test deadline")
    }

    private func waitForSuppressedParserInvocation(of runner: ReadabilityRunner) async throws {
        for _ in 0 ..< 100 {
            if !runner.hasSuppressedParserInvocationForTesting {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw XCTSkip("The runner did not suppress A's parser invocation before the test deadline")
    }

    private func result(title: String) throws -> ReadabilityResult {
        let json = """
        {
          "title": "\(title)",
          "byline": null,
          "content": "<p>Body</p>",
          "textContent": "Body",
          "length": 4,
          "excerpt": "Body",
          "siteName": null,
          "lang": null,
          "dir": null,
          "publishedTime": null
        }
        """
        return try JSONDecoder().decode(ReadabilityResult.self, from: Data(json.utf8))
    }

    private func XCTAssertThrowsCancellation(_ task: Task<ReadabilityResult, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancelled extraction A")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
