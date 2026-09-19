import { isProbablyReaderable, Readability } from "@mozilla/readability";

function post(type, requestID, value) {
    webkit.messageHandlers.readabilityMessageHandler.postMessage({
        Type: type,
        RequestID: requestID,
        Value: value
    });
}

// Installed once in the content controller, then invoked by Swift after each
// document finishes loading. Options and the request ID remain per-request data.
window.__swiftReadabilityParseBasic = function({ requestID, options }) {
    try {
        if (!isProbablyReaderable(document)) {
            post("StateChange", requestID, "Unavailable");
            return;
        }

        const result = new Readability(document.cloneNode(true), options).parse();
        if (!result) {
            post("StateChange", requestID, "Unavailable");
            return;
        }

        post("ContentParsed", requestID, JSON.stringify(result));
    } catch (error) {
        post("ParseError", requestID, String(error));
    }
};
