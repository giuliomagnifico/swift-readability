# Extraction WebView resource loading

Implemented on `feature/lettura-webkit-resource-blocking`, based on 0.4.1 (`a5515e86166da56d02a3c5181f9d92ca6db0ed4b`). No changes to Mozilla Readability, DOMPurify, their bundled scripts, sanitation options, result decoding, ReadabilityUI or the HTML fetcher.

## Public API and compatibility

Both `Readability.parse(html:options:baseURL:resourceLoadingPolicy:)` and `Readability.parse(url:options:resourceLoadingPolicy:)` accept a policy with default `.allowAll`. Existing call sites retain the original resource loading behavior.

```swift
let parser = Readability()
let result = try await parser.parse(
    html: completeStaticHTML,
    options: .init(shouldSanitize: true),
    baseURL: articleURL,
    resourceLoadingPolicy: .blockExternalResources
)
```

The opt-in policy is for documents whose editorial content is already available in the supplied HTML. It blocks HTTP/HTTPS resource requests in the extraction WebView. It does not rewrite `src`, `srcset`, `data-src`, `data-srcset`, `href` or `poster`, or remove elements. Non-HTTP schemes, inline page scripts and the bundled WKUserScripts remain available. It does not configure a displayed Reader WebView or an application's image loader. The public URL overload still downloads its main HTML through URLSession first; a loopback test verifies that this main request succeeds while the secondary photo request is absent.

Do not enable this policy unconditionally for dynamic documents. A regression fixture deliberately appends editorial paragraphs from an external script. Blocking produces a nonempty but incomplete result; `.allowAll` restores the original result on the same runner. There is no reliable generic completeness test based on nonempty output. Default loading is therefore preserved, and there is no speculative automatic second parse. Consumers must choose the original policy for pages needing external scripts or other network-dependent DOM construction.

## Implementation and lifecycle

- `ResourceLoadingPolicy.swift` declares the public enum and DEBUG-only diagnostic snapshot.
- `ReadabilityResourceRules.swift` owns the asynchronous WKContentRuleListStore lookup/compilation task, isolated to MainActor and shared by all runners. The identifier `swift-readability.external-resources.v1` versions the exact JSON rule: `[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]`. Bump the identifier if that JSON changes.
- A compatible persisted rule is reused. Otherwise, compilation happens once per provider. Concurrent callers await the same task. A failed task is retained too, preventing repeated failed compilation for each article.
- `ReadabilityRunner.configureResources` installs the rule before `loadHTMLString`. An already configured WebView has no subsequent rule-store await. Switching back to `.allowAll` removes this specific rule. Recreating the WebView clears the installation state and reinstalls the shared rule on the next blocked parse.
- Request identity and cancellation are checked after asynchronous rule preparation, so an obsolete parse cannot install a rule over a newer request. Cancelling a caller does not cancel the shared compilation task.
- Rule preparation failure uses the original loading path for that navigation, with a DEBUG diagnostic. It does not rerun extraction. Existing parse timeouts, WebView recovery, parser-error behavior and application-level fallback policies remain intact. As before bootstrap loading, rule preparation precedes the navigation deadline.
- Bootstrap registration and execution are unchanged: two bundled user scripts at document end, followed by parsing after the matching main navigation completes.

No new unchecked Sendable conformances, dependency, private API, swizzling or reflection are used. The minimum package platforms are unchanged. Production timing uses no new clock API; DEBUG measurements use monotonic `ProcessInfo.systemUptime`, compatible with the package's deployment targets.

Public references: [WKContentRuleListStore](https://developer.apple.com/documentation/webkit/wkcontentruleliststore), [WebKit content blocker rule format](https://webkit.org/blog/3476/content-blockers-first-look/). No blocked-request counter is inferred from these APIs; traffic counts below come from the test HTTP server.

## DEBUG diagnostics

`resourceLoadingDiagnostics` exposes the last navigation-backed parse snapshot and is reset on entry. `resourceLoadingDiagnosticsHandler` is captured at parse entry and attached to that request, preserving the caller's trace identity when another parse replaces it. It receives policy, rule source (`disabled`, `compiled`, `store`, `memory`, `installed`, `configuration_failed`), installation state, WebView reuse, configuration milliseconds, total parse milliseconds and configuration-failure status. Handler, snapshots and clock reads are DEBUG-only.

The callback runs when a navigation-backed parse completes, fails or is cancelled. Cancellation or bootstrap failure before active navigation has no completed snapshot. Consumers can retain their existing outer-operation logging for those paths. Parse time starts before rule preparation and ends before resuming the continuation; it includes rule preparation, bootstrap installation, navigation, parsing and Swift result decoding, but excludes `Readability()` construction and URLSession's main download. Configuration time covers rule preparation/installation alone. It is not a separate measure of JavaScript CPU time or display visibility.

The library emits no article text, URLs or author data. A consumer can attach the handler to its existing DEBUG trace and use `[Readability Performance]`; each handler should capture the operation's trace. Tests verify correlation across cancellation/replacement.

## Network benchmark

Environment: Xcode 27.1 SDK, iOS 27.0 iPhone 18 Pro Max simulator, Debug. Identical document bytes and URLs per baseline/blocked pair. Two fixtures: approximately 4 KB and 34 KB. Each condition has one first access and three subsequent parses on the same runner. Policy ordering alternates by repetition and scenario. Server responses are `Cache-Control: no-store`. Artificial delays exist only in this controlled test server, never in library code.

| Fixture | Response scenario | Original reused median [min, max] ms | Blocked reused median [min, max] ms | Median reduction |
| --- | --- | --- | --- | --- |
| Small | Fast | 29.633 [29.546, 51.891] | 15.058 [14.645, 22.485] | 49.19% |
| Small | 250 ms per response | 586.483 [559.842, 598.739] | 41.255 [29.814, 42.762] | 92.97% |
| Small | HTTP 503, 50 ms delay | 153.780 [137.480, 172.692] | 17.378 [16.506, 25.419] | 88.70% |
| Complex | Fast | 34.743 [30.888, 52.819] | 18.293 [16.887, 18.814] | 47.35% |
| Complex | 250 ms per response | 570.834 [563.512, 571.161] | 20.601 [18.251, 21.729] | 96.39% |
| Complex | HTTP 503, 50 ms delay | 139.909 [134.661, 173.662] | 25.260 [20.581, 32.270] | 81.95% |

Every baseline parse received 8 requests: CSS, external script, the srcset-selected image, video poster, font, iframe document, fetch and beacon. Every blocked parse received 0. Across 24 baseline and 24 blocked parses, the server observed 192 versus 0 secondary requests. This is a 100% reduction for the measured fixture traffic, not for arbitrary articles or total app traffic. A video element is included, but iOS WebKit did not request its media bytes in this offscreen fixture; no avoided video download is claimed. Font/media payloads are deliberately minimal probe data, not fidelity or playback tests. The loopback server exercises HTTP, not TLS; HTTPS is covered by the rule expression, not a separate HTTPS traffic test.

All paired content strings are compared exactly, with content SHA256 stored in `benchmark.json`. The same absolute loopback URLs appear in both configurations. Random ports mean digests need not match between separate test invocations. Separate tests compare all ReadabilityResult fields, both basic/sanitized modes, malformed markup, images/srcset/lazy content, captions, links, tables and retained embed markup. Sanitation remains unchanged; equivalence does not mean adding elements DOMPurify already excluded in the baseline.

### First access and rule overhead

| Fixture/scenario | Original first parse ms | Blocked first parse ms |
| --- | --- | --- |
| Small/fast | 1231.260 | 53.023 |
| Small/slow | 558.233 | 1644.164 |
| Small/unavailable | 1359.037 | 70.660 |
| Complex/fast | 86.166 | 1536.879 |
| Complex/slow | 1758.747 | 81.838 |
| Complex/unavailable | 170.184 | 1537.064 |

The first runner in a pair often bears approximately 1.2–1.6 seconds of process/startup cost; alternating the order moves this cost between policies. These first-access samples must not be used to claim a stable cold-start improvement or regression. The JSON also records WebView construction separately. A fresh WebView is not necessarily a fresh WebKit service or process.

Four new identifiers force lookup plus compilation independently of the shared production identifier. Measured median [min, max]: lookup plus compile 0.630 [0.590, 19.601] ms; lookup of a persisted list 0.182 [0.166, 0.242] ms; in-memory access below 0.001 ms in these samples. These measurements are in `rule-initialization.json`. They do not bound all future first-use costs. Tests assert one lookup/compilation, sharing and stored reuse, rather than unstable wall-clock thresholds.

## Validation

Added `ResourceLoadingTests.swift` and `ResourceLoopbackServer.swift`: 11 new tests in the final tree. They cover observed secondary traffic, exact static equivalence, sanitation/basic parsing, malformed HTML, policy switching, main URLSession HTML, shared/stored rules, invalid configuration and original-path fallback, cancellation during initialization, per-operation DEBUG correlation, timeout/recreation/reinstallation, the dynamic-content limitation and two benchmarks.

- iOS simulator suite: 17 selected tests, 16 passed, 0 failures, 1 skipped. The skipped pre-existing 0.5-second timeout test did not reach its suppressed invocation before its own fixture deadline. New 3-second controlled timeout/reinstallation coverage passed.
- macOS targeted validation: 3 passed, 0 failed/skipped, including that pre-existing timeout recovery test, the URLSession main-download test and network/static-equivalence test.
- The new URLSession main-download test was also run separately on iOS; see the consumer report for its result bundle.
- Release Mac Catalyst: Readability target build passed. This is a compilation check, not runtime/device/UI proof.
- Lettura integration, in an isolated temporary project with the local package and explicit blocking on static fixtures: 48 passed, 0 failed/skipped, including the unchanged image filter, extractor, trace, deadline tests and 60 existing golden output hashes. The actual Lettura checkout's sources and remote package reference were not changed.

The first development run had two test failures: an assertion incorrectly assumed iOS requested video media bytes, and a 1-second timeout could expire before the deliberately suppressed navigation reached didFinish. The corrected fixture reports only observed traffic and asserts that suppression was consumed before testing recovery. No production loading delay or media configuration was changed. The malformed/invalid-rule path and dynamic-content difference are intentionally tested, not masked.

## Reproduction

Choose an installed simulator and an unused result path:

```sh
xcodebuild test -scheme swift-readability-Package \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max,OS=27.0' \
  -derivedDataPath /tmp/ReadabilityResourceBlockingDerived \
  -parallel-testing-enabled NO \
  -only-testing:ReadabilityTests/ResourceLoadingTests \
  -resultBundlePath /tmp/ReadabilityResourceBlocking-repeated.xcresult \
  -collect-test-diagnostics never
```

Both JSON benchmarks are retained as XCTest attachments. Export them from Xcode's result viewer. Fixture/server/test sources travel with the package, including all artificial response latency and request counters. Real iPhone performance, site-specific completeness, image fidelity, cache behavior outside this WebView and UI presentation require separate real-world verification. There is no promise that blocking improves every article, especially when a parallel raw candidate dominates the consumer's total time.

## Publishing and consumer integration

No commit, tag, push, release or consumer dependency replacement was performed. This repository already has the user's GitHub fork as `origin`; another fork is not required. Publish the reviewed code/tests/docs to that fork, merge into the desired release commit, then tag a new patch version. `0.4.2` was absent from remote tags when checked on 25 October 2026 and is the proposed version; verify again before tagging. Preserve existing credit and license files.

Lettura must then resolve that remote tag/commit, commit its Package.resolved, and opt in at its parser call for suitable complete HTML. Updating the dependency alone does not enable blocking. Do not commit an XCLocalSwiftPackageReference as the final integration. The consumer's prepared patches and disposable validation helper are in its `Documentation/ReadabilityWebKit-2026-10-25` directory. The static opt-in patch is a validation candidate, not authorization to enable blocking globally on dynamic pages.
