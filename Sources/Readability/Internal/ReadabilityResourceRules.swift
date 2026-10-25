import Foundation
import WebKit

/// One asynchronous lookup/compilation shared by all extraction runners.
/// Both WebKit objects and the in-flight task stay isolated to the main actor.
@MainActor
final class ReadabilityResourceRules {
    static let shared = ReadabilityResourceRules()
    static let identifier = "swift-readability.external-resources.v1"
    static let encodedRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    struct Loaded {
        let list: WKContentRuleList
        let source: String
    }

    @MainActor
    private final class Compiled {
        let list: WKContentRuleList
        let source: String

        init(list: WKContentRuleList, source: String) {
            self.list = list
            self.source = source
        }
    }

    private let store: WKContentRuleListStore
    private let identifier: String
    private let encodedRules: String
    private var pending: Task<Compiled, any Error>?
    private var wasRequested = false
#if DEBUG
    private(set) var lookupCount = 0
    private(set) var compilationCount = 0
#endif

    init(
        store: WKContentRuleListStore = .default(),
        identifier: String = ReadabilityResourceRules.identifier,
        encodedRules: String = ReadabilityResourceRules.encodedRules
    ) {
        self.store = store
        self.identifier = identifier
        self.encodedRules = encodedRules
    }

    func load() async throws -> Loaded {
        let reused = wasRequested
        wasRequested = true
        if pending == nil {
#if DEBUG
            lookupCount += 1
#endif
            pending = Task { @MainActor [store, identifier, encodedRules] in
                // A missing or incompatible stored list is compiled once. Failed tasks
                // are retained too, so a configuration error is not retried per article.
                if let list = try? await store.contentRuleList(forIdentifier: identifier) {
                    return Compiled(list: list, source: "store")
                }
#if DEBUG
                self.compilationCount += 1
#endif
                guard let list = try await store.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: encodedRules
                ) else { throw CocoaError(.coderValueNotFound) }
                return Compiled(list: list, source: "compiled")
            }
        }
        let compiled = try await pending!.value
        return Loaded(list: compiled.list, source: reused ? "memory" : compiled.source)
    }
}
