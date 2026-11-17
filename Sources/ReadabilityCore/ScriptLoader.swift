import Foundation

/// An actor responsible for loading JavaScript and HTML resources from the bundle.
package actor ScriptLoader {
    /// Resources available to be loaded by the ScriptLoader.
    package enum Resource {
        /// Script to be injected at document start.
        case atDocumentStart
        /// Script to be injected at document end.
        case atDocumentEnd
        /// HTML template for generating reader content.
        case readerHTML
        /// Shared basic and sanitized Readability parsing script.
        case readability

        /// The name of the resource file (without extension).
        var name: String {
            switch self {
            case .atDocumentStart:
                return "AtDocumentStart"
            case .atDocumentEnd:
                return "AtDocumentEnd"
            case .readerHTML:
                return "Reader"
            case .readability:
                return "Readability"
            }
        }

        /// The file extension of the resource.
        var ext: String {
            switch self {
            case .atDocumentStart, .atDocumentEnd, .readability:
                return "js"
            case .readerHTML:
                return "html"
            }
        }
    }

    // The bundle from which resources are loaded.
    private let bundle: Bundle

    /// Initializes a new `ScriptLoader` with the specified bundle.
    ///
    /// - Parameter bundle: The bundle containing the script resources.
    package init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// Loads the content of the specified resource.
    ///
    /// - Parameter resource: The resource to load.
    /// - Returns: A `String` containing the contents of the resource.
    /// - Throws: An error if the resource cannot be found or read.
    package func load(_ resource: Resource) throws -> String {
        try load(forResource: resource.name, withExtension: resource.ext)
    }

    /// Loads the content for a given resource name and file extension.
    ///
    /// - Parameters:
    ///   - name: The name of the resource.
    ///   - ext: The file extension of the resource.
    /// - Returns: A `String` containing the resource's contents.
    /// - Throws: An error if the resource cannot be located or read.
    private func load(forResource name: String, withExtension ext: String) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw Error.failedToCopyReadabilityScriptFromNodeModules
        }

        let readabilityScript = try String(contentsOf: url, encoding: .utf8)

        return readabilityScript
    }
}

extension ScriptLoader {
    /// Errors that can occur while loading script resources.
    enum Error: Swift.Error {
        /// Indicates failure to locate or read the Readability script from the bundle.
        case failedToCopyReadabilityScriptFromNodeModules
    }
}
