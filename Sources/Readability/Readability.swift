import ReadabilityCore
import SwiftUI
import WebKit

/// A public interface for parsing web pages using Mozilla's Readability library.
/// This struct provides asynchronous methods to parse HTML or a URL into a structured `ReadabilityResult`.
@MainActor
public struct Readability {
    private let runner: ReadabilityRunner

    public init() {
        runner = ReadabilityRunner()
    }

#if DEBUG
    /// Last completed parse configuration; no blocked-request count is inferred.
    public var resourceLoadingDiagnostics: ResourceLoadingDiagnostics? { runner.resourceLoadingDiagnostics }

    /// Snapshotted at parse entry, so overlapping calls retain their own correlation.
    public var resourceLoadingDiagnosticsHandler: (@MainActor (ResourceLoadingDiagnostics) -> Void)? {
        get { runner.resourceLoadingDiagnosticsHandler }
        nonmutating set { runner.resourceLoadingDiagnosticsHandler = newValue }
    }
#endif

    /// Parses the web page at the specified URL and returns a `ReadabilityResult`.
    ///
    /// - Parameters:
    ///   - url: The URL of the web page to parse.
    ///   - options: Optional configuration options for parsing.
    /// - Returns: A `ReadabilityResult` containing the parsed content.
    /// - Throws: An error if fetching or parsing fails.
    public func parse(
        url: URL,
        options: Readability.Options? = nil,
        resourceLoadingPolicy: ResourceLoadingPolicy = .allowAll
    ) async throws -> ReadabilityResult {
        // Fetch HTML content from the URL.
        let html = try await HTMLFetcher().fetch(url: url)
        // Parse the fetched HTML content.
        return try await parse(
            html: html,
            options: options,
            baseURL: nil,
            resourceLoadingPolicy: resourceLoadingPolicy
        )
    }

    /// Parses the provided HTML string and returns a `ReadabilityResult`.
    ///
    /// - Parameters:
    ///   - html: The HTML content to parse.
    ///   - options: Optional configuration options for parsing.
    ///   - baseURL: The base URL for the HTML content.
    /// - Returns: A `ReadabilityResult` containing the parsed content.
    /// - Throws: An error if parsing fails.
    public func parse(
        html: String,
        options: Readability.Options?,
        baseURL: URL?,
        resourceLoadingPolicy: ResourceLoadingPolicy = .allowAll
    ) async throws -> ReadabilityResult {
        try await runner.parseHTML(
            html,
            options: options,
            baseURL: baseURL,
            resourceLoadingPolicy: resourceLoadingPolicy
        )
    }
}
