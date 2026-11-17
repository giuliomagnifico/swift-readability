// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import { Readability } from "@mozilla/readability";
const DOMPurify = require("dompurify");

function post(requestID, value) {
    webkit.messageHandlers.readabilityMessageHandler.postMessage({
        Type: "ContentParsed",
        RequestID: requestID,
        Value: value
    });
}

// Both entry points share one bootstrap and one copy of Mozilla Readability.
// Options and the request ID remain per-request data.
window.__swiftReadabilityParseBasic = function({ requestID, options }) {
    try {
        const result = new Readability(document.cloneNode(true), options).parse();
        post(requestID, JSON.stringify(result));
    } catch (error) {
        post(requestID, "null");
    }
};

window.__swiftReadabilityParseSanitized = function({ requestID, options }) {
    try {
        const serializedDocument = new XMLSerializer().serializeToString(document);
        const cleanDocument = DOMPurify.sanitize(serializedDocument, { WHOLE_DOCUMENT: true });
        const parsedDocument = new DOMParser().parseFromString(cleanDocument, "text/html");
        const result = new Readability(parsedDocument, options).parse();
        post(requestID, JSON.stringify(result));
    } catch (error) {
        post(requestID, "null");
    }
};
