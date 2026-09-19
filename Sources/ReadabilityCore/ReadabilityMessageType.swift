/// Represents the type of messages exchanged between the JavaScript and the native code.
enum ReadabilityMessageType: String {
    /// Indicates a change in the reader state.
    case stateChange = "StateChange"
    /// Indicates that the content has been parsed.
    case contentParsed = "ContentParsed"
    /// Indicates that parsing failed in JavaScript.
    case parseError = "ParseError"
}
