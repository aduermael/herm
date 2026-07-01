import Foundation

nonisolated struct CPSLAgentConfig: Equatable, Sendable {
    let baseURL: URL
    let token: String
    let model: String

    static func load() throws -> CPSLAgentConfig {
        try make(
            values: try CPSLEnvLoader.load(),
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func make(
        values: [String: String],
        environment: [String: String] = [:]
    ) throws -> CPSLAgentConfig {
        guard let baseURLValue = firstValue(
            in: values,
            environment: environment,
            keys: ["OPENAI_BASE_URL", "OPENAI_API_BASE_URL", "API_BASE_URL", "API_URL", "URL"]
        )
        else {
            throw CPSLAgentConfigError.missingValue("OPENAI_BASE_URL")
        }
        let trimmedBaseURL = baseURLValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedBaseURL),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host?.isEmpty == false,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil
        else {
            throw CPSLAgentConfigError.invalidValue("OPENAI_BASE_URL")
        }

        guard let token = firstValue(
            in: values,
            environment: environment,
            keys: ["OPENAI_API_KEY", "API_KEY", "TOKEN", "XAI_API_KEY"]
        ),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CPSLAgentConfigError.missingValue("OPENAI_API_KEY")
        }

        guard let model = firstValue(
            in: values,
            environment: environment,
            keys: ["OPENAI_MODEL", "MODEL", "XAI_MODEL"]
        ),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CPSLAgentConfigError.missingValue("OPENAI_MODEL")
        }

        return CPSLAgentConfig(
            baseURL: baseURL,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func firstValue(
        in values: [String: String],
        environment: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = environment[key],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}

nonisolated enum CPSLAgentConfigError: LocalizedError {
    case missingEnvFile
    case missingValue(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .missingEnvFile:
            return "Add a .env file with OPENAI_BASE_URL, OPENAI_API_KEY, and OPENAI_MODEL."
        case .missingValue(let key):
            return "Missing \(key) in .env."
        case .invalidValue(let key):
            return "\(key) must be an absolute HTTP or HTTPS base URL without credentials, query, or fragment."
        }
    }
}

nonisolated enum CPSLEnvLoader {
    static func load() throws -> [String: String] {
        var values: [String: String] = [:]

        for url in candidateURLs() {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            parse(text).forEach { key, value in
                values[key] = value
            }
        }

        if values.isEmpty && !hasProcessEnvironmentFallback(environment: ProcessInfo.processInfo.environment) {
            throw CPSLAgentConfigError.missingEnvFile
        }
        return values
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []

        if let bundleURL = Bundle.main.url(forResource: ".env", withExtension: nil) {
            urls.append(bundleURL)
        }
        if let bundleURL = Bundle.main.url(forResource: "env", withExtension: nil) {
            urls.append(bundleURL)
        }
        if let bundleURL = Bundle.main.url(forResource: ".env.local", withExtension: nil) {
            urls.append(bundleURL)
        }
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(".env") {
            urls.append(resourceURL)
        }
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(".env.local") {
            urls.append(resourceURL)
        }

        let fileManager = FileManager.default
        if let supportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            let bundleID = Bundle.main.bundleIdentifier ?? "herm"
            let appSupportURL = supportURL.appendingPathComponent(bundleID, isDirectory: true)
            urls.append(appSupportURL.appendingPathComponent(".env"))
            urls.append(appSupportURL.appendingPathComponent(".env.local"))
            urls.append(supportURL.appendingPathComponent(".env"))
            urls.append(supportURL.appendingPathComponent(".env.local"))
        }

        urls.append(contentsOf: sourceCheckoutURLs(sourceFilePath: #filePath))

        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceResourcesURL = currentDirectoryURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("apple", isDirectory: true)
            .appendingPathComponent("herm", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        urls.append(sourceResourcesURL.appendingPathComponent(".env"))
        urls.append(sourceResourcesURL.appendingPathComponent(".env.local"))
        urls.append(currentDirectoryURL.appendingPathComponent(".env"))
        urls.append(currentDirectoryURL.appendingPathComponent(".env.local"))
        return urls
    }

    static func sourceCheckoutURLs(sourceFilePath: String) -> [URL] {
        let sourceFileURL = URL(fileURLWithPath: sourceFilePath)
        let hermDirectoryURL = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRootURL = hermDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return [
            hermDirectoryURL.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(".env"),
            hermDirectoryURL.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(".env.local"),
            hermDirectoryURL.appendingPathComponent(".env"),
            hermDirectoryURL.appendingPathComponent(".env.local"),
            repoRootURL.appendingPathComponent(".env"),
            repoRootURL.appendingPathComponent(".env.local")
        ]
    }

    static func hasProcessEnvironmentFallback(environment: [String: String]) -> Bool {
        return environment["OPENAI_BASE_URL"] != nil ||
            environment["OPENAI_API_BASE_URL"] != nil ||
            environment["API_BASE_URL"] != nil ||
            environment["API_URL"] != nil ||
            environment["URL"] != nil ||
            environment["OPENAI_API_KEY"] != nil ||
            environment["API_KEY"] != nil ||
            environment["TOKEN"] != nil ||
            environment["XAI_API_KEY"] != nil ||
            environment["OPENAI_MODEL"] != nil ||
            environment["MODEL"] != nil ||
            environment["XAI_MODEL"] != nil
    }

    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let assignment = line.hasPrefix("export ") ? String(line.dropFirst("export ".count)) : line
            guard let separator = assignment.firstIndex(of: "=") else {
                continue
            }

            let key = assignment[..<separator].trimmingCharacters(in: .whitespaces)
            var value = trimmedValue(assignment[assignment.index(after: separator)...])
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }

    private static func trimmedValue(_ rawValue: Substring) -> String {
        var value = ""
        var previousWasWhitespace = true
        var isInsideSingleQuotes = false
        var isInsideDoubleQuotes = false

        for character in rawValue {
            if character == "'", !isInsideDoubleQuotes {
                isInsideSingleQuotes.toggle()
            } else if character == "\"", !isInsideSingleQuotes {
                isInsideDoubleQuotes.toggle()
            } else if character == "#",
                      previousWasWhitespace,
                      !isInsideSingleQuotes,
                      !isInsideDoubleQuotes {
                break
            }

            value.append(character)
            previousWasWhitespace = character.isWhitespace
        }

        return value.trimmingCharacters(in: .whitespaces)
    }
}
