import Foundation

public extension Readability {
    /// Controls secondary network loads made by the extraction WebView only.
    enum ResourceLoadingPolicy: String, Sendable {
        /// Preserves the original loading behavior, including page scripts.
        case allowAll
        /// Blocks HTTP/HTTPS loads without rewriting the supplied DOM or attributes.
        /// Use for documents whose editorial content is already present in the HTML.
        /// External scripts cannot build additional content in this mode.
        case blockExternalResources
    }

#if DEBUG
    /// Observed configuration costs, not a counter of blocked requests or screen visibility.
    struct ResourceLoadingDiagnostics: Sendable {
        public let policy: ResourceLoadingPolicy
        public let ruleSource: String
        public let ruleInstalled: Bool
        public let reusedWebView: Bool
        public let configurationMilliseconds: Double
        public let parseMilliseconds: Double
        public let configurationFailed: Bool
    }

#endif
}
