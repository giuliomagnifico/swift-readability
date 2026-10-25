import CryptoKit
import WebKit
import XCTest
@testable import Readability

@MainActor
final class ResourceLoadingTests: XCTestCase {
    private let paragraph = "Independent observations explain the sequence of events and preserve the sources, details and practical consequences of this editorial report. Readers can inspect the available evidence and understand the context of these findings."

    private func html(origin: String, token: String, sections: Int = 4) -> String {
        let root = origin + "/" + token
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Resource equivalence</title>
        <link rel="stylesheet" href="\(root)/external.css">
        <style>@font-face {font-family:Probe;src:url('\(root)/font.woff2')} p {font-family:Probe}</style>
        </head><body><article><h1>Resource equivalence</h1>
        \((0..<sections).map { "<section><h2>Section \($0)</h2><p>\(paragraph) café &amp; source \($0).</p><p>\(paragraph)</p></section>" }.joined())
        <p><a href="/editorial-source">Editorial source</a></p>
        <figure><img src="\(root)/photo.png" srcset="\(root)/photo.png 1x, \(root)/large.png 2x" width="1200" height="800" alt="Editorial scene"><figcaption>Editorial caption and credit.</figcaption></figure>
        <figure><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-src="\(root)/lazy.png" data-srcset="\(root)/lazy.png 1x, \(root)/lazy-large.png 2x" alt="Lazy editorial scene"><figcaption>Lazy caption.</figcaption></figure>
        <table><tr><th>Measure</th><th>Result</th></tr><tr><td>Evidence</td><td>Available</td></tr></table>
        <blockquote class="twitter-tweet"><p>Editorial quoted source.</p><a href="https://twitter.com/example/status/123">Source</a></blockquote>
        <iframe src="\(root)/frame" title="Editorial media"></iframe>
        <video preload="auto" src="\(root)/video.mp4" poster="\(root)/poster.png"></video>
        </article>
        <script src="\(root)/external.js"></script>
        <script>
        fetch('\(root)/fetch').catch(function(){});
        navigator.sendBeacon('\(root)/beacon', 'probe');
        document.fonts.load('12px Probe').catch(function(){});
        document.querySelector('video').load();
        </script></body></html>
        """
    }

    private var options: Readability.Options {
        .init(charThreshold: 100, classesToPreserve: ["twitter-tweet"], allowedVideoRegex: "127\\.0\\.0\\.1", shouldSanitize: true)
    }

    func testURLSessionMainHTMLDownloadIsNotBlocked() async throws {
        let server = try ResourceLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let result = try await Readability().parse(
            url: URL(string: server.origin + "/main")!, options: options,
            resourceLoadingPolicy: .blockExternalResources
        )
        XCTAssertEqual(server.requests["/main"], 1)
        XCTAssertNil(server.requests["/main-photo.png"])
        XCTAssertTrue(result.content.contains("/main-photo.png"))
        XCTAssertTrue(result.textContent.contains("downloaded by URLSession"))
    }

    func testBlockedNetworkAndIdenticalSanitizedEditorialHTML() async throws {
        let server = try ResourceLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let document = html(origin: server.origin, token: "equivalence")
        let parser = Readability()
        let original = try await parser.parse(html: document, options: options, baseURL: URL(string: server.origin))
        // Fetch/beacon can reach the listener after the navigation has finished.
        try await Task.sleep(nanoseconds: 100_000_000)
        let received = server.requests
        for resource in ["external.css", "external.js", "font.woff2", "frame", "poster.png", "fetch", "beacon"] {
            XCTAssertGreaterThan(received["/equivalence/" + resource, default: 0], 0, "Baseline must actually request \(resource)")
        }
        XCTAssertGreaterThan(received["/equivalence/photo.png", default: 0] + received["/equivalence/large.png", default: 0], 0)
        let blocked = try await parser.parse(html: document, options: options, baseURL: URL(string: server.origin), resourceLoadingPolicy: .blockExternalResources)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(server.requests, received, "The blocked parse must send no secondary HTTP requests")
        assertEquivalent(original, blocked)
        XCTAssertTrue(blocked.content.contains("Editorial caption and credit."))
        XCTAssertTrue(blocked.content.contains("/editorial-source"))
        XCTAssertTrue(blocked.content.contains("/equivalence/photo.png"))
        XCTAssertTrue(blocked.content.contains("/equivalence/large.png 2x"))
        XCTAssertTrue(blocked.content.contains("/equivalence/lazy.png"))
        XCTAssertTrue(blocked.content.contains("Lazy caption."))
        XCTAssertTrue(blocked.content.contains("<table"))
        XCTAssertFalse(blocked.content.contains("<script"), "DOMPurify remains active")
        XCTAssertEqual(parser.resourceLoadingDiagnostics?.ruleInstalled, true)
    }

    func testBasicModeMalformedHTMLAndPolicySwitching() async throws {
        let server = try ResourceLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let document = html(origin: server.origin, token: "malformed").replacingOccurrences(of: "</section>", with: "")
        let runner = ReadabilityRunner()
        let plainOptions = Readability.Options(charThreshold: 100, keepClasses: true)
        let original = try await runner.parseHTML(document, options: plainOptions, baseURL: URL(string: server.origin))
        let blocked = try await runner.parseHTML(document, options: plainOptions, baseURL: URL(string: server.origin), resourceLoadingPolicy: .blockExternalResources)
        assertEquivalent(original, blocked)
        XCTAssertTrue(blocked.content.contains("twitter-tweet"))
        let afterBlocked = server.requests.values.reduce(0, +)
        _ = try await runner.parseHTML(document, options: plainOptions, baseURL: URL(string: server.origin))
        XCTAssertGreaterThan(server.requests.values.reduce(0, +), afterBlocked, "Switching to the default policy removes the installed rule")
        XCTAssertEqual(runner.resourceLoadingDiagnostics?.ruleInstalled, false)
        XCTAssertEqual(runner.registeredUserScriptCount, 2)
    }

    func testSharedCompilationReuseAndPersistentStoreLookup() async throws {
        let identifier = "readability-test-" + UUID().uuidString
        let store = WKContentRuleListStore.default()!
        let rules = ReadabilityResourceRules(store: store, identifier: identifier)
        let first = try await rules.load()
        XCTAssertEqual(first.source, "compiled")
        async let second = rules.load()
        async let third = rules.load()
        let loaded = try await [second, third]
        XCTAssertTrue(loaded.allSatisfy { $0.list === first.list && $0.source == "memory" })
        XCTAssertEqual(rules.lookupCount, 1)
        XCTAssertEqual(rules.compilationCount, 1)
        let laterProcessEquivalent = ReadabilityResourceRules(store: store, identifier: identifier)
        let stored = try await laterProcessEquivalent.load()
        XCTAssertEqual(stored.source, "store")
        XCTAssertEqual(laterProcessEquivalent.compilationCount, 0)
        try await store.removeContentRuleList(forIdentifier: identifier)
    }

    func testUnavailableRulesFallBackWithoutRetryingOrDoubleParsing() async throws {
        let server = try ResourceLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let rules = ReadabilityResourceRules(identifier: "readability-invalid-" + UUID().uuidString, encodedRules: "not valid JSON")
        let runner = ReadabilityRunner(parseDeadline: 10, resourceRules: rules)
        let document = html(origin: server.origin, token: "failure")
        for _ in 0..<2 {
            let result = try await runner.parseHTML(document, options: options, resourceLoadingPolicy: .blockExternalResources)
            XCTAssertFalse(result.textContent.isEmpty)
            XCTAssertEqual(runner.resourceLoadingDiagnostics?.configurationFailed, true)
            XCTAssertEqual(runner.resourceLoadingDiagnostics?.ruleInstalled, false)
        }
        XCTAssertEqual(rules.compilationCount, 1)
        XCTAssertEqual(server.requests["/failure/external.js"], 2, "Exactly one original navigation per parse")
        XCTAssertEqual(runner.registeredUserScriptCount, 2)
    }

    func testRuleIsInstalledAgainAfterTimeoutRecreatesTheWebView() async throws {
        let server = try ResourceLoopbackServer()
        try await server.start()
        defer { server.stop() }
        let runner = ReadabilityRunner(parseDeadline: 3, suppressedParserInvocations: 1)
        let document = html(origin: server.origin, token: "recreation")
        do {
            _ = try await runner.parseHTML(document, options: options, resourceLoadingPolicy: .blockExternalResources)
            XCTFail("Expected the deliberately suppressed parser to time out")
        } catch is CancellationError { XCTFail("Expected timeout, not cancellation") }
        catch { }
        XCTAssertFalse(runner.hasSuppressedParserInvocationForTesting, "The first navigation must reach didFinish before the timeout")
        XCTAssertEqual(runner.registeredUserScriptCount, 0)
        runner.setParseDeadlineForTesting(10)
        let result = try await runner.parseHTML(document, options: options, resourceLoadingPolicy: .blockExternalResources)
        XCTAssertFalse(result.content.isEmpty)
        XCTAssertEqual(runner.resourceLoadingDiagnostics?.ruleInstalled, true)
        XCTAssertEqual(runner.resourceLoadingDiagnostics?.reusedWebView, false)
        XCTAssertEqual(runner.registeredUserScriptCount, 2)
        XCTAssertEqual(server.requests.values.reduce(0, +), 0)
    }

    func testCancellationDuringRuleInitializationDoesNotPoisonSharedRules() async throws {
        let identifier = "readability-cancel-" + UUID().uuidString
        let rules = ReadabilityResourceRules(identifier: identifier)
        let runner = ReadabilityRunner(parseDeadline: 10, resourceRules: rules)
        let document = "<article><h1>Cancellation</h1>" + String(repeating: "<p>\(paragraph)</p>", count: 8) + "</article>"
        let cancelled = Task { @MainActor in
            try await runner.parseHTML(document, options: options, resourceLoadingPolicy: .blockExternalResources)
        }
        await Task.yield()
        cancelled.cancel()
        let next = try await runner.parseHTML(document, options: options, resourceLoadingPolicy: .blockExternalResources)
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(next.content.isEmpty)
        XCTAssertEqual(rules.compilationCount, 1)
        XCTAssertEqual(runner.resourceLoadingDiagnostics?.ruleInstalled, true)
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
    }

    func testDynamicEditorialContentRequiresTheOriginalPolicy() async throws {
        let server = try ResourceLoopbackServer()
        server.dynamicScript = true
        try await server.start()
        defer { server.stop() }
        let document = html(origin: server.origin, token: "dynamic")
        let parser = Readability()
        let original = try await parser.parse(html: document, options: options, baseURL: nil)
        let blocked = try await parser.parse(html: document, options: options, baseURL: nil, resourceLoadingPolicy: .blockExternalResources)
        XCTAssertTrue(original.textContent.contains("EXTERNAL_EDITORIAL_SECTION"))
        XCTAssertFalse(blocked.textContent.contains("EXTERNAL_EDITORIAL_SECTION"))
        XCTAssertFalse(blocked.textContent.isEmpty, "A nonempty result alone cannot detect incomplete dynamic content")
        let restored = try await parser.parse(html: document, options: options, baseURL: nil)
        assertEquivalent(original, restored)
    }

    func testDiagnosticsRetainOperationIdentityWhenAParseIsReplaced() async throws {
        let runner = ReadabilityRunner()
        let document = "<article><h1>Trace identity</h1>" + String(repeating: "<p>\(paragraph)</p>", count: 8) + "</article>"
        _ = try await runner.parseHTML(document, options: options)
        var identities: [String] = []
        runner.resourceLoadingDiagnosticsHandler = { _ in identities.append("A") }
        let first = Task { @MainActor in try await runner.parseHTML(document, options: options, resourceLoadingPolicy: .blockExternalResources) }
        for _ in 0..<1_000 {
            if runner.activeRequestIDForTesting != nil { break }
            await Task.yield()
        }
        _ = try XCTUnwrap(runner.activeRequestIDForTesting)
        runner.resourceLoadingDiagnosticsHandler = { _ in identities.append("B") }
        _ = try await runner.parseHTML(document, options: options, resourceLoadingPolicy: .blockExternalResources)
        do { _ = try await first.value; XCTFail("Expected A to be cancelled") }
        catch is CancellationError { }
        XCTAssertEqual(identities, ["A", "B"])
    }

    func testRuleInitializationBenchmark() async throws {
        struct Row: Encodable {
            let repetition: Int
            let stage: String
            let milliseconds: Double
            let source: String
        }
        var rows: [Row] = []
        let store = WKContentRuleListStore.default()!
        for repetition in 0..<4 {
            let identifier = "readability-cold-" + UUID().uuidString
            let first = ReadabilityResourceRules(store: store, identifier: identifier)
            let second = ReadabilityResourceRules(store: store, identifier: identifier)
            for (stage, provider) in [("lookup_and_compile", first), ("memory", first), ("persistent_store", second)] {
                let start = ProcessInfo.processInfo.systemUptime
                let loaded = try await provider.load()
                rows.append(Row(repetition: repetition, stage: stage,
                    milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000, source: loaded.source))
            }
            XCTAssertEqual(first.compilationCount, 1)
            XCTAssertEqual(second.compilationCount, 0)
            try await store.removeContentRuleList(forIdentifier: identifier)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(rows), uniformTypeIdentifier: "public.json")
        attachment.name = "readability-resource-rule-initialization"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testResourceBlockingBenchmark() async throws {
        struct Row: Encodable {
            let fixture: String
            let scenario: String
            let policy: String
            let repetition: Int
            let reusedWebView: Bool
            let htmlBytes: Int
            let parseMilliseconds: Double
            let webViewInitializationMilliseconds: Double
            let configurationMilliseconds: Double
            let ruleSource: String
            let requests: [String: Int]
            let contentDigest: String
        }
        let server = try ResourceLoopbackServer()
        try await server.start()
        defer { server.stop() }
        var rows: [Row] = []
        let policies: [Readability.ResourceLoadingPolicy] = [.allowAll, .blockExternalResources]
        var caseIndex = 0
        for (fixture, sections) in [("small", 4), ("complex", 60)] {
            for (scenario, delay, unavailable) in [("fast", 0.0, false), ("slow", 0.25, false), ("unavailable", 0.05, true)] {
                server.delay = delay
                server.unavailable = unavailable
                var parsers: [Readability] = []
                var initializationMilliseconds: [Double] = []
                for _ in policies {
                    let start = ProcessInfo.processInfo.systemUptime
                    parsers.append(Readability())
                    initializationMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                }
                var expectedContent: String?
                // The exact same bytes and URLs are used by both configurations.
                let token = fixture + "-" + scenario
                let document = html(origin: server.origin, token: token, sections: sections)
                for repetition in 0..<4 {
                    for index in ((repetition + caseIndex).isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                        let before = server.requests
                        let start = ProcessInfo.processInfo.systemUptime
                        let result = try await parsers[index].parse(html: document, options: options, baseURL: URL(string: server.origin), resourceLoadingPolicy: policies[index])
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                        try await Task.sleep(nanoseconds: 50_000_000)
                        let delta = server.requests.reduce(into: [String: Int]()) { counts, entry in
                            let difference = entry.value - before[entry.key, default: 0]
                            if difference > 0 { counts[entry.key] = difference }
                        }
                        if let expectedContent { XCTAssertEqual(result.content, expectedContent) }
                        else { expectedContent = result.content }
                        if index == 1 { XCTAssertTrue(delta.isEmpty) }
                        else { XCTAssertGreaterThan(delta.values.reduce(0, +), 0) }
                        let diagnostics = try XCTUnwrap(parsers[index].resourceLoadingDiagnostics)
                        rows.append(Row(
                            fixture: fixture, scenario: scenario, policy: policies[index].rawValue,
                            repetition: repetition, reusedWebView: diagnostics.reusedWebView,
                            htmlBytes: document.utf8.count, parseMilliseconds: elapsed,
                            webViewInitializationMilliseconds: repetition == 0 ? initializationMilliseconds[index] : 0,
                            configurationMilliseconds: diagnostics.configurationMilliseconds,
                            ruleSource: diagnostics.ruleSource, requests: delta,
                            contentDigest: SHA256.hash(data: Data(result.content.utf8)).map { String(format: "%02x", $0) }.joined()
                        ))
                    }
                }
                caseIndex += 1
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(rows), uniformTypeIdentifier: "public.json")
        attachment.name = "readability-resource-blocking-benchmark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertEquivalent(_ lhs: ReadabilityResult, _ rhs: ReadabilityResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.content, rhs.content, file: file, line: line)
        XCTAssertEqual(lhs.textContent, rhs.textContent, file: file, line: line)
        XCTAssertEqual(lhs.title, rhs.title, file: file, line: line)
        XCTAssertEqual(lhs.byline, rhs.byline, file: file, line: line)
        XCTAssertEqual(lhs.length, rhs.length, file: file, line: line)
        XCTAssertEqual(lhs.excerpt, rhs.excerpt, file: file, line: line)
        XCTAssertEqual(lhs.siteName, rhs.siteName, file: file, line: line)
        XCTAssertEqual(lhs.language, rhs.language, file: file, line: line)
        XCTAssertEqual(lhs.direction, rhs.direction, file: file, line: line)
        XCTAssertEqual(lhs.publishedTime, rhs.publishedTime, file: file, line: line)
    }
}
