import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

typealias CPSLEvalServiceResult = (
    rawJSON: String?,
    stdout: String,
    stderr: String,
    exitCode: Int?,
    ok: Bool?,
    cwd: String?,
    errorCode: String?,
    errorMessage: String?,
    warnings: [String],
    ffiError: String?
)

nonisolated struct CPSLSessionHandle {
    let id: Int
    let pointer: OpaquePointer
}

nonisolated struct CPSLSessionInitResult: @unchecked Sendable {
    let pointer: OpaquePointer?
    let errorMessage: String?
}

nonisolated struct CPSLBlockingEvalRequest: @unchecked Sendable {
    let session: OpaquePointer
    let requestJSON: String
}

nonisolated enum CPSLEvalRaceResult: Sendable {
    case completed(CPSLEvalServiceResult)
    case timedOut
    case cancelled
}

nonisolated final class CPSLEvalRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var pendingResult: CPSLEvalRaceResult?
    private var continuation: CheckedContinuation<CPSLEvalRaceResult, Never>?

    func install(_ continuation: CheckedContinuation<CPSLEvalRaceResult, Never>) {
        lock.lock()
        if let pendingResult, !didResume {
            didResume = true
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(returning: pendingResult)
            return
        }
        if !didResume {
            self.continuation = continuation
        }
        lock.unlock()
    }

    func resume(_ result: CPSLEvalRaceResult) {
        lock.lock()
        guard !didResume, pendingResult == nil else {
            lock.unlock()
            return
        }
        if let continuation {
            didResume = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}

struct CPSLSandboxURLs {
    let root: URL
}

nonisolated enum CPSLVirtualPath {
    static let root = "/"
    static let attachments = "/attachments"
    static let home = "/home/herm"
    static let iCloudRoot = "/icloud"
    static let temporary = "/tmp"
    static let initialDirectory = home
}

nonisolated struct CPSLAttachment: Identifiable, Equatable, Sendable, Codable {
    var id: String { path }

    let name: String
    let path: String

    nonisolated init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

enum CPSLFeatureAccessState: String, Equatable, Sendable {
    case granted
    case denied
    case undefined

    var isGranted: Bool {
        self == .granted
    }
}

nonisolated struct CPSLICloudMount: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let slug: String
    let virtualPath: String
    let hostURL: URL
    let mode: String

    init(label: String, slug: String, hostURL: URL) {
        self.id = slug
        self.label = label
        self.slug = slug
        self.virtualPath = "\(CPSLVirtualPath.iCloudRoot)/\(slug)"
        self.hostURL = hostURL
        self.mode = "ro"
    }
}

nonisolated enum CPSLChatRole: String, Codable, Equatable, Sendable {
    case assistant
    case user
    case command
    case output
    case error
    case toolStatus
    case hidden

    var isTrailingAligned: Bool {
        self == .user
    }

    var isFullWidth: Bool {
        self == .assistant || self == .command || self == .toolStatus
    }

    var usesMonospaceBody: Bool {
        self == .command || self == .output || self == .error
    }

    var rendersMarkdownBody: Bool {
        self == .assistant || self == .user
    }

    var isFramed: Bool {
        self != .assistant
    }

    var displaysTitle: Bool {
        self != .assistant
    }

    var isVisible: Bool {
        self != .hidden
    }

    @MainActor
    var fill: Color {
        switch self {
        case .assistant:
            return .clear
        case .user:
            return CPSLTheme.elevated
        case .command:
            return CPSLTheme.command
        case .output:
            return CPSLTheme.surface
        case .error:
            return CPSLTheme.error
        case .toolStatus:
            return CPSLTheme.surface
        case .hidden:
            return .clear
        }
    }

    @MainActor
    var foreground: Color {
        CPSLTheme.text
    }
}

nonisolated struct CPSLChatMessage: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let role: CPSLChatRole
    let title: String?
    var body: String
    let attachments: [CPSLAttachment]

    nonisolated init(
        id: UUID = UUID(),
        role: CPSLChatRole,
        title: String?,
        body: String,
        attachments: [CPSLAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.body = body
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case title
        case body
        case attachments
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(CPSLChatRole.self, forKey: .role)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        attachments = try container.decodeIfPresent([CPSLAttachment].self, forKey: .attachments) ?? []
    }
}

nonisolated struct CPSLWebSearchVisit: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let browserID: String
    let url: String
    let title: String
    let host: String
    let faviconURL: String?

    nonisolated init(
        id: String = UUID().uuidString,
        browserID: String,
        url: String,
        title: String,
        host: String,
        faviconURL: String?
    ) {
        self.id = id
        self.browserID = browserID
        self.url = url
        self.title = title
        self.host = host
        self.faviconURL = faviconURL
    }
}

nonisolated struct CPSLFileActivity: Equatable, Sendable {
    let path: String
    let operation: String
}

nonisolated final class CPSLFileActivityNotifier: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (CPSLFileActivity) -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func setHandler(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func notify(_ activity: CPSLFileActivity) {
        lock.lock()
        let handler = self.handler
        lock.unlock()

        guard let handler else {
            return
        }
        Task { @MainActor in
            handler(activity)
        }
    }
}

struct CPSLFileEntry: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let isDirectory: Bool
}

struct CPSLDirectoryListing: Sendable {
    let entries: [CPSLFileEntry]
    let error: String?
}

nonisolated struct CPSLCalendarActivity: Equatable, Sendable {
    let operation: String
}

nonisolated final class CPSLCalendarActivityNotifier: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (CPSLCalendarActivity) -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func setHandler(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func notify(_ activity: CPSLCalendarActivity) {
        lock.lock()
        let handler = handler
        lock.unlock()
        guard let handler else {
            return
        }
        Task { @MainActor in
            handler(activity)
        }
    }
}

struct CPSLFileEntryLookup: Sendable {
    let entry: CPSLFileEntry?
    let error: String?
}

enum CPSLFileBrowserNavigationDirection: Equatable, Sendable {
    case forward
    case backward
}

struct CPSLFileDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

nonisolated enum CPSLCodeLanguage: String, Equatable, Sendable {
    case c
    case cpp
    case css
    case go
    case html
    case java
    case javascript
    case json
    case kotlin
    case lua
    case markdown
    case objectiveC
    case python
    case ruby
    case rust
    case shell
    case swift
    case toml
    case typescript
    case xml
    case yaml

    init?(fileName: String, fileExtension: String) {
        let lowercasedName = fileName.lowercased()
        switch lowercasedName {
        case "dockerfile", ".bashrc", ".zshrc":
            self = .shell
            return
        case "makefile":
            self = .shell
            return
        default:
            break
        }

        switch fileExtension {
        case "c", "h":
            self = .c
        case "cc", "cpp", "cxx", "hh", "hpp", "hxx":
            self = .cpp
        case "css":
            self = .css
        case "go":
            self = .go
        case "htm", "html":
            self = .html
        case "java":
            self = .java
        case "js", "jsx", "mjs", "cjs":
            self = .javascript
        case "json":
            self = .json
        case "kt", "kts":
            self = .kotlin
        case "lua", "luau":
            self = .lua
        case "m":
            self = .objectiveC
        case "mm":
            self = .cpp
        case "md", "markdown":
            self = .markdown
        case "py":
            self = .python
        case "rb":
            self = .ruby
        case "rs":
            self = .rust
        case "bash", "command", "sh", "zsh":
            self = .shell
        case "swift":
            self = .swift
        case "toml":
            self = .toml
        case "ts", "tsx":
            self = .typescript
        case "plist", "svg", "xml":
            self = .xml
        case "yaml", "yml":
            self = .yaml
        default:
            return nil
        }
    }

    var sourceDisplayName: LocalizedStringResource {
        switch self {
        case .c:
            return "C source"
        case .cpp:
            return "C++ source"
        case .css:
            return "CSS source"
        case .go:
            return "Go source"
        case .html:
            return "HTML source"
        case .java:
            return "Java source"
        case .javascript:
            return "JavaScript source"
        case .json:
            return "JSON source"
        case .kotlin:
            return "Kotlin source"
        case .lua:
            return "Lua source"
        case .markdown:
            return "Markdown"
        case .objectiveC:
            return "Objective-C source"
        case .python:
            return "Python source"
        case .ruby:
            return "Ruby source"
        case .rust:
            return "Rust source"
        case .shell:
            return "Shell script"
        case .swift:
            return "Swift source"
        case .toml:
            return "TOML"
        case .typescript:
            return "TypeScript source"
        case .xml:
            return "XML"
        case .yaml:
            return "YAML"
        }
    }

    var keywords: [String] {
        switch self {
        case .c, .cpp, .objectiveC:
            return [
                "auto", "break", "case", "char", "class", "const", "continue", "default",
                "delete", "do", "double", "else", "enum", "extern", "float", "for",
                "goto", "if", "inline", "int", "long", "namespace", "new", "private",
                "protected", "public", "return", "short", "signed", "sizeof", "static",
                "struct", "switch", "template", "typedef", "typename", "union", "unsigned",
                "using", "virtual", "void", "volatile", "while",
            ]
        case .css:
            return [
                "align-items", "animation", "background", "border", "color", "display",
                "flex", "font", "gap", "grid", "height", "justify-content", "margin",
                "padding", "position", "transform", "transition", "width",
            ]
        case .go:
            return [
                "break", "case", "chan", "const", "continue", "default", "defer",
                "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                "interface", "map", "package", "range", "return", "select", "struct",
                "switch", "type", "var",
            ]
        case .html, .xml:
            return []
        case .java, .kotlin:
            return [
                "abstract", "break", "case", "catch", "class", "const", "continue",
                "data", "default", "do", "else", "enum", "extends", "false", "final",
                "finally", "for", "fun", "if", "implements", "import", "interface",
                "new", "null", "object", "override", "package", "private", "protected",
                "public", "return", "static", "super", "switch", "this", "throw",
                "throws", "true", "try", "val", "var", "void", "when", "while",
            ]
        case .javascript, .typescript:
            return [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends",
                "false", "finally", "for", "from", "function", "if", "import", "in",
                "instanceof", "interface", "let", "new", "null", "return", "static",
                "super", "switch", "this", "throw", "true", "try", "type", "typeof",
                "undefined", "var", "void", "while", "yield",
            ]
        case .json, .toml, .yaml:
            return ["false", "null", "true"]
        case .lua:
            return [
                "and", "break", "do", "else", "elseif", "end", "false", "for",
                "function", "if", "in", "local", "nil", "not", "or", "repeat",
                "return", "then", "true", "until", "while",
            ]
        case .markdown:
            return []
        case .python:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue",
                "def", "del", "elif", "else", "except", "False", "finally", "for",
                "from", "global", "if", "import", "in", "is", "lambda", "None",
                "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
                "while", "with", "yield",
            ]
        case .ruby:
            return [
                "alias", "and", "begin", "break", "case", "class", "def", "do",
                "else", "elsif", "end", "false", "for", "if", "in", "module",
                "next", "nil", "not", "or", "redo", "rescue", "retry", "return",
                "self", "super", "then", "true", "undef", "unless", "until", "when",
                "while", "yield",
            ]
        case .rust:
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "else",
                "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let",
                "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                "self", "Self", "static", "struct", "super", "trait", "true", "type",
                "unsafe", "use", "where", "while",
            ]
        case .shell:
            return [
                "case", "do", "done", "elif", "else", "esac", "export", "fi", "for",
                "function", "if", "in", "local", "readonly", "return", "select",
                "then", "until", "while",
            ]
        case .swift:
            return [
                "actor", "as", "associatedtype", "async", "await", "break", "case",
                "catch", "class", "continue", "defer", "do", "else", "enum", "extension",
                "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
                "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open",
                "operator", "private", "protocol", "public", "rethrows", "return",
                "self", "Self", "static", "struct", "subscript", "super", "switch",
                "throw", "throws", "true", "try", "typealias", "var", "where", "while",
            ]
        }
    }
}

nonisolated enum CPSLFilePreviewCategory: Equatable, Sendable {
    case archive
    case audio
    case code(CPSLCodeLanguage)
    case data
    case file
    case image
    case pdf
    case text
    case video

    init(
        fileName: String,
        fileExtension: String,
        contentTypeIdentifier: String? = nil
    ) {
        if fileExtension == "pdf" {
            self = .pdf
            return
        }
        if let language = CPSLCodeLanguage(fileName: fileName, fileExtension: fileExtension) {
            self = .code(language)
            return
        }
        if Self.imageExtensions.contains(fileExtension) {
            self = .image
            return
        }
        if Self.audioExtensions.contains(fileExtension) {
            self = .audio
            return
        }
        if Self.videoExtensions.contains(fileExtension) {
            self = .video
            return
        }
        if Self.textExtensions.contains(fileExtension) {
            self = .text
            return
        }
        if Self.archiveExtensions.contains(fileExtension) {
            self = .archive
            return
        }
        if Self.dataExtensions.contains(fileExtension) {
            self = .data
            return
        }

        #if canImport(UniformTypeIdentifiers)
            let contentType =
                contentTypeIdentifier.flatMap { UTType($0) }
                ?? UTType(filenameExtension: fileExtension)
            if contentType?.conforms(to: .pdf) == true {
                self = .pdf
                return
            }
            if contentType?.conforms(to: .image) == true {
                self = .image
                return
            }
            if contentType?.conforms(to: .audio) == true {
                self = .audio
                return
            }
            if contentType?.conforms(to: .movie) == true {
                self = .video
                return
            }
            if contentType?.conforms(to: .text) == true {
                self = .text
                return
            }
        #endif

        self = .file
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .archive:
            return "Archive"
        case .audio:
            return "Audio"
        case .code(let language):
            return language.sourceDisplayName
        case .data:
            return "Data"
        case .file:
            return "File"
        case .image:
            return "Image"
        case .pdf:
            return "PDF"
        case .text:
            return "Text"
        case .video:
            return "Video"
        }
    }

    @MainActor
    var systemImageName: String {
        switch self {
        case .archive:
            return "archivebox.fill"
        case .audio:
            return "waveform"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .data:
            return "tablecells"
        case .file:
            return "doc"
        case .image:
            return "photo.fill"
        case .pdf:
            return "doc.richtext"
        case .text:
            return "doc.text.fill"
        case .video:
            return "film.fill"
        }
    }

    @MainActor
    var iconColor: Color {
        switch self {
        case .archive, .data:
            return CPSLTheme.IconPalette.secondary
        case .audio:
            return CPSLTheme.mauve
        case .code:
            return CPSLTheme.secondaryText
        case .file, .pdf, .text:
            return CPSLTheme.IconPalette.file
        case .image:
            return CPSLTheme.success
        case .video:
            return CPSLTheme.IconPalette.folder
        }
    }

    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "gz", "rar", "tar", "tgz", "xz", "zip",
    ]

    private static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "flac", "m4a", "mp3", "oga", "ogg", "opus", "wav",
    ]

    private static let dataExtensions: Set<String> = [
        "bin", "db", "sqlite", "sqlite3",
    ]

    private static let imageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "icns", "ico", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]

    private static let textExtensions: Set<String> = [
        "csv", "diff", "env", "log", "patch", "rtf", "text", "txt",
    ]

    private static let videoExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm",
    ]
}

struct CPSLFileMetadata: Equatable, Sendable {
    var category: CPSLFilePreviewCategory
    var typeDescription: String
    var sizeBytes: Int64?
    var creationDate: Date?
    var modificationDate: Date?
    var durationSeconds: Double?
    var dimensions: CPSLFileDimensions?
}

enum CPSLFilePreviewKind: Equatable, Sendable {
    case text(String)
    case code(String, language: CPSLCodeLanguage)
    case pdf(URL)
    case image(URL)
    case audio(URL)
    case video(URL)
    case file(reason: String?)
}

struct CPSLFilePreview: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let metadata: CPSLFileMetadata
    let kind: CPSLFilePreviewKind
}

struct CPSLFilePreviewLoadResult: Sendable {
    let preview: CPSLFilePreview?
    let error: String?
}

extension CPSLFileEntry {
    var pathExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    var previewCategory: CPSLFilePreviewCategory {
        CPSLFilePreviewCategory(fileName: name, fileExtension: pathExtension)
    }
}
