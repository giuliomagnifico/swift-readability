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
    post("StateChange", requestID, isProbablyReaderable(document) ? "Available" : "Unavailable");

    try {
        const result = new Readability(document.cloneNode(true), options).parse();
        post("ContentParsed", requestID, JSON.stringify(result));
    } catch (error) {
        post("ContentParsed", requestID, "null");
    }
};
