// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import { isProbablyReaderable, Readability } from "@mozilla/readability";
const DOMPurify = require("dompurify");

function post(type, requestID, value) {
    webkit.messageHandlers.readabilityMessageHandler.postMessage({
        Type: type,
        RequestID: requestID,
        Value: value
    });
}

// Installed once in the content controller, then invoked by Swift after each
// document finishes loading. Options and the request ID remain per-request data.
window.__swiftReadabilityParseSanitized = function({ requestID, options }) {
    post("StateChange", requestID, isProbablyReaderable(document) ? "Available" : "Unavailable");

    try {
        const serializedDocument = new XMLSerializer().serializeToString(document);
        const cleanDocument = DOMPurify.sanitize(serializedDocument, { WHOLE_DOCUMENT: true });
        const parsedDocument = new DOMParser().parseFromString(cleanDocument, "text/html");
        const result = new Readability(parsedDocument, options).parse();
        post("ContentParsed", requestID, JSON.stringify(result));
    } catch (error) {
        post("ContentParsed", requestID, "null");
    }
};
