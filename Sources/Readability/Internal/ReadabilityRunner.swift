import Foundation
import ReadabilityCore
import WebKit

/// A single, reusable WebKit runner. Every parse receives a generation token so
/// messages from a cancelled or replaced document cannot complete a new request.
@MainActor
final class ReadabilityRunner: NSObject, WKNavigationDelegate {
    private static let messageHandlerName = "readabilityMessageHandler"
    private static let basicFunction = "__swiftReadabilityParseBasic"
    private static let sanitizedFunction = "__swiftReadabilityParseSanitized"

    private var configuration: WKWebViewConfiguration!
    private var contentController: WKUserContentController!
    private var webView: WKWebView!
    private var messageHandler: ReadabilityMessageHandler<EmptyContentGenerator>!
    private let scriptLoader = ScriptLoader(bundle: .module)
    private let encoder = JSONEncoder()

    private var bootstrapsInstalled = false
    private var nextRequestID: UInt64 = 0
    private var reservedRequestID: UInt64?
    private var activeRequest: ActiveRequest?

    private static let defaultParseDeadline: TimeInterval = 10
    private var parseDeadline: TimeInterval
    private var suppressedParserInvocations: Int

    var registeredUserScriptCount: Int { contentController.userScripts.count }

    override init() {
        parseDeadline = Self.defaultParseDeadline
        suppressedParserInvocations = 0
        super.init()
        createWebView()
    }

    init(parseDeadline: TimeInterval, suppressedParserInvocations: Int = 0) {
        self.parseDeadline = parseDeadline
        self.suppressedParserInvocations = suppressedParserInvocations
        super.init()
        createWebView()
    }

    var activeRequestIDForTesting: UInt64? { activeRequest?.id }
    var hasActiveTimeoutTaskForTesting: Bool { activeRequest?.deadlineTask != nil }
    var hasSuppressedParserInvocationForTesting: Bool { suppressedParserInvocations > 0 }
    var registeredMessageHandlerCountForTesting: Int { messageHandler == nil ? 0 : 1 }

    func setParseDeadlineForTesting(_ deadline: TimeInterval) {
        parseDeadline = deadline
    }

    func parseHTML(
        _ html: String,
        options: Readability.Options?,
        baseURL: URL? = nil
    ) async throws -> ReadabilityResult {
        let requestID = reserveRequest()

        do {
            try await installBootstrapsIfNeeded()
        } catch {
            if reservedRequestID == requestID {
                reservedRequestID = nil
            }
            invalidateWebView()
            throw error
        }

        guard reservedRequestID == requestID else {
            throw CancellationError()
        }

        do {
            try Task.checkCancellation()
        } catch {
            if reservedRequestID == requestID {
                reservedRequestID = nil
            }
            throw error
        }
        let optionsJSON = try generateJSONOptions(options: options)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reservedRequestID == requestID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                reservedRequestID = nil
                activeRequest = ActiveRequest(
                    id: requestID,
                    functionName: options?.shouldSanitize == true ? Self.sanitizedFunction : Self.basicFunction,
                    optionsJSON: optionsJSON,
                    completion: continuation
                )
                activeRequest?.deadlineTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.parseDeadline * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.expireRequest(id: requestID)
                }

                guard let navigation = webView.loadHTMLString(html, baseURL: baseURL) else {
                    failActiveRequest(with: Error.navigationDidNotStart, invalidate: true)
                    return
                }
                activeRequest?.navigation = navigation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: requestID)
            }
        }
    }

    func webView(_: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation,
              let activeRequest,
              let activeNavigation = activeRequest.navigation,
              activeNavigation === navigation
        else { return }

        if suppressedParserInvocations > 0 {
            suppressedParserInvocations -= 1
        } else {
            invokeParser(for: activeRequest)
        }
    }

    func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError _: Swift.Error) {
        if let navigation {
            failIfActive(navigation, error: .navigationFailed)
        }
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation!, withError _: Swift.Error) {
        if let navigation {
            failIfActive(navigation, error: .navigationFailed)
        }
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        failActiveRequest(with: Error.webContentProcessTerminated, invalidate: true)
    }

    private func createWebView() {
        let configuration = WKWebViewConfiguration()
        let contentController = configuration.userContentController
        let handler = ReadabilityMessageHandler(
            mode: .generateReadabilityResult,
            readerContentGenerator: EmptyContentGenerator(),
            requiresRequestID: true
        )

        handler.subscribeEvent { [weak self] event in
            self?.handle(event)
        }
        contentController.add(handler, name: Self.messageHandlerName)

        self.configuration = configuration
        self.contentController = contentController
        self.messageHandler = handler
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        bootstrapsInstalled = false
    }

    private func installBootstrapsIfNeeded() async throws {
        guard !bootstrapsInstalled else { return }

        async let basicSourceTask = scriptLoader.load(.readabilityBasic)
        async let sanitizedSourceTask = scriptLoader.load(.readabilitySanitized)
        let (basicSource, sanitizedSource) = try await (basicSourceTask, sanitizedSourceTask)

        guard !bootstrapsInstalled else { return }

        contentController.addUserScript(WKUserScript(
            source: basicSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        contentController.addUserScript(WKUserScript(
            source: sanitizedSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        bootstrapsInstalled = true
    }

    private func reserveRequest() -> UInt64 {
        cancelActiveRequest()
        nextRequestID &+= 1
        reservedRequestID = nextRequestID
        return nextRequestID
    }

    private func invokeParser(for request: ActiveRequest) {
        guard activeRequest?.id == request.id else { return }

        let payload = "{\"requestID\":\(request.id),\"options\":\(request.optionsJSON)}"
        let script = """
        (function() {
            const parser = window.\(request.functionName);
            if (typeof parser !== 'function') {
                throw new Error('Readability bootstrap is unavailable');
            }
            parser(\(payload));
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeRequest?.id == request.id else { return }
                if error != nil {
                    self.failActiveRequest(with: .javaScriptFailed, invalidate: true)
                }
            }
        }
    }

    private func handle(_ event: ReadabilityMessageHandler<EmptyContentGenerator>.Event) {
        guard let activeRequest else { return }

        switch event {
        case let .contentParsed(requestID, result):
            guard requestID == activeRequest.id else { return }
            completeActiveRequest(.success(result))
        case let .contentParseFailed(requestID):
            guard requestID == activeRequest.id else { return }
            completeActiveRequest(.failure(Error.readerIsUnavailable))
        case .availabilityChanged:
            // `isProbablyReaderable` is advisory: parsing can still succeed for pages
            // dominated by lists, tables, or figures.
            break
        case let .parseFailed(requestID, _):
            guard requestID == activeRequest.id else { return }
            failActiveRequest(with: .javaScriptFailed, invalidate: true)
        case .protocolViolation:
            failActiveRequest(with: .protocolViolation, invalidate: true)
        case .contentParsedAndGeneratedHTML:
            failActiveRequest(with: .protocolViolation, invalidate: true)
        }
    }

    func deliverLateContentParsedForTesting(requestID: UInt64, result: ReadabilityResult) {
        handle(.contentParsed(requestID: requestID, readabilityResult: result))
    }

    private func cancelRequest(id: UInt64) {
        if reservedRequestID == id {
            reservedRequestID = nil
            return
        }
        guard activeRequest?.id == id else { return }
        webView.stopLoading()
        completeActiveRequest(.failure(CancellationError()))
    }

    private func cancelActiveRequest() {
        if reservedRequestID != nil {
            reservedRequestID = nil
        }
        guard activeRequest != nil else { return }
        webView.stopLoading()
        completeActiveRequest(.failure(CancellationError()))
    }

    private func failIfActive(_ navigation: WKNavigation, error: Error) {
        guard let activeNavigation = activeRequest?.navigation,
              activeNavigation === navigation
        else { return }
        failActiveRequest(with: error, invalidate: true)
    }

    private func expireRequest(id: UInt64) {
        guard activeRequest?.id == id else { return }
        failActiveRequest(with: .readerIsUnavailable, invalidate: true)
    }

    private func failActiveRequest(with error: Error, invalidate: Bool) {
        completeActiveRequest(.failure(error))
        if invalidate {
            invalidateWebView()
        }
    }

    private func completeActiveRequest(_ result: Result<ReadabilityResult, Swift.Error>) {
        guard let request = activeRequest else { return }
        activeRequest = nil
        request.deadlineTask?.cancel()
        request.completion.resume(with: result)
    }

    private func invalidateWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        contentController?.removeScriptMessageHandler(forName: Self.messageHandlerName)
        contentController?.removeAllUserScripts()
        webView = nil
        messageHandler = nil
        contentController = nil
        configuration = nil
        createWebView()
    }

    private func generateJSONOptions(options: Readability.Options?) throws -> String {
        guard let options else { return "{}" }
        let data = try encoder.encode(options)
        return String(decoding: data, as: UTF8.self)
    }

    private struct ActiveRequest {
        let id: UInt64
        let functionName: String
        let optionsJSON: String
        var navigation: WKNavigation?
        var deadlineTask: Task<Void, Never>?
        let completion: CheckedContinuation<ReadabilityResult, Swift.Error>
    }

    enum Error: Swift.Error {
        case readerIsUnavailable
        case navigationDidNotStart
        case navigationFailed
        case javaScriptFailed
        case protocolViolation
        case webContentProcessTerminated
    }
}

private struct EmptyContentGenerator: ReaderContentGeneratable {
    func generate(_: ReadabilityResult, initialStyle _: ReaderStyle) async -> String? { nil }
}
