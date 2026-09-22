import Foundation
import WebKit

/// Receives messages emitted by the scripts installed in a `WKWebView`.
@MainActor
package final class ReadabilityMessageHandler<Generator: ReaderContentGeneratable>: NSObject, WKScriptMessageHandler {
    package enum Mode {
        case generateReaderHTML(initialStyle: ReaderStyle)
        case generateReadabilityResult
    }

    package enum Event {
        case contentParsedAndGeneratedHTML(html: String)
        case contentParsed(requestID: UInt64?, readabilityResult: ReadabilityResult)
        case contentParseFailed(requestID: UInt64?)
        case parseFailed(requestID: UInt64?, message: String)
        case availabilityChanged(requestID: UInt64?, availability: ReaderAvailability)
        case protocolViolation
    }

    private let readerContentGenerator: Generator
    private let mode: Mode
    private let requiresRequestID: Bool

    package var eventHandler: (@MainActor (Event) -> Void)?

    package init(
        mode: Mode,
        readerContentGenerator: Generator,
        requiresRequestID: Bool = false
    ) {
        self.mode = mode
        self.readerContentGenerator = readerContentGenerator
        self.requiresRequestID = requiresRequestID
    }

    package func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let typeString = body["Type"] as? String,
              let type = ReadabilityMessageType(rawValue: typeString)
        else {
            eventHandler?(.protocolViolation)
            return
        }

        let requestID = (body["RequestID"] as? NSNumber)?.uint64Value
        guard !requiresRequestID || requestID != nil else {
            eventHandler?(.protocolViolation)
            return
        }

        switch type {
        case .stateChange:
            guard let value = body["Value"] as? String,
                  let availability = ReaderAvailability(rawValue: value)
            else {
                eventHandler?(.protocolViolation)
                return
            }
            eventHandler?(.availabilityChanged(requestID: requestID, availability: availability))

        case .parseError:
            guard let value = body["Value"] as? String else {
                eventHandler?(.protocolViolation)
                return
            }
            eventHandler?(.parseFailed(requestID: requestID, message: value))

        case .contentParsed:
            guard let jsonString = body["Value"] as? String,
                  let jsonData = jsonString.data(using: .utf8),
                  let result = try? JSONDecoder().decode(ReadabilityResult.self, from: jsonData)
            else {
                eventHandler?(.contentParseFailed(requestID: requestID))
                return
            }

            switch mode {
            case .generateReadabilityResult:
                eventHandler?(.contentParsed(requestID: requestID, readabilityResult: result))
            case let .generateReaderHTML(initialStyle):
                Task { @MainActor [weak self] in
                    guard let self,
                          let html = await readerContentGenerator.generate(result, initialStyle: initialStyle)
                    else { return }
                    eventHandler?(.contentParsedAndGeneratedHTML(html: html))
                }
            }
        }
    }

    package func subscribeEvent(_ operation: (@MainActor (Event) -> Void)?) {
        eventHandler = operation
    }
}
