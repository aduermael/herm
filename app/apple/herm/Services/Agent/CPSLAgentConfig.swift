import Foundation

nonisolated struct CPSLAgentConfig: Equatable, Sendable {
    static let defaultMaxToolRounds = 200
    static let defaultMaxOutputTokens = 16_384
    static let defaultExploreSubAgentTurns = 15
    static let defaultGeneralSubAgentTurns = 20
    static let defaultMaxAgentDepth = 1

    let baseURL: URL
    let token: String
    let model: String
    let maxToolRounds: Int
    let maxOutputTokens: Int
    let contextWindowTokens: Int?
    let exploreSubAgentTurns: Int
    let generalSubAgentTurns: Int
    let maxAgentDepth: Int

    static func load() throws -> CPSLAgentConfig {
        let environment = ProcessInfo.processInfo.environment
        if CPSLEnvConstants.values.isEmpty && !hasProcessEnvironmentFallback(environment: environment) {
            throw CPSLAgentConfigError.missingEnvFile
        }

        return try make(
            values: CPSLEnvConstants.values,
            environment: environment
        )
    }

    static func make(
        values: [String: String],
        environment: [String: String] = [:]
    ) throws -> CPSLAgentConfig {
        let source = CPSLAgentConfigSource(values: values, environment: environment)
        guard let baseURLValue = firstValue(
            in: source,
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
            in: source,
            keys: ["OPENAI_API_KEY", "API_KEY", "TOKEN", "XAI_API_KEY"]
        ),
                !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CPSLAgentConfigError.missingValue("OPENAI_API_KEY")
        }

        guard let model = firstValue(
            in: source,
            keys: ["OPENAI_MODEL", "MODEL", "XAI_MODEL"]
        ),
                !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CPSLAgentConfigError.missingValue("OPENAI_MODEL")
        }

        return CPSLAgentConfig(
            baseURL: baseURL,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            maxToolRounds: positiveIntValue(
                in: source,
                keys: ["HERM_MAX_TOOL_ROUNDS", "MAX_TOOL_ROUNDS"],
                defaultValue: defaultMaxToolRounds
            ),
            maxOutputTokens: positiveIntValue(
                in: source,
                keys: ["HERM_MAX_OUTPUT_TOKENS", "MAX_OUTPUT_TOKENS"],
                defaultValue: defaultMaxOutputTokens
            ),
            contextWindowTokens: optionalPositiveIntValue(
                in: source,
                keys: ["HERM_CONTEXT_WINDOW_TOKENS", "CONTEXT_WINDOW_TOKENS"]
            ),
            exploreSubAgentTurns: positiveIntValue(
                in: source,
                keys: ["HERM_EXPLORE_SUBAGENT_TURNS", "EXPLORE_SUBAGENT_TURNS"],
                defaultValue: defaultExploreSubAgentTurns
            ),
            generalSubAgentTurns: positiveIntValue(
                in: source,
                keys: ["HERM_GENERAL_SUBAGENT_TURNS", "GENERAL_SUBAGENT_TURNS"],
                defaultValue: defaultGeneralSubAgentTurns
            ),
            maxAgentDepth: nonNegativeIntValue(
                in: source,
                keys: ["HERM_MAX_AGENT_DEPTH", "MAX_AGENT_DEPTH"],
                defaultValue: defaultMaxAgentDepth
            )
        )
    }

    private static func firstValue(
        in source: CPSLAgentConfigSource,
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = source.values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = source.environment[key],
                    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func positiveIntValue(
        in source: CPSLAgentConfigSource,
        keys: [String],
        defaultValue: Int
    ) -> Int {
        optionalPositiveIntValue(in: source, keys: keys) ?? defaultValue
    }

    private static func optionalPositiveIntValue(
        in source: CPSLAgentConfigSource,
        keys: [String]
    ) -> Int? {
        guard let rawValue = firstValue(in: source, keys: keys),
                let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                value > 0
        else {
            return nil
        }
        return value
    }

    private static func nonNegativeIntValue(
        in source: CPSLAgentConfigSource,
        keys: [String],
        defaultValue: Int
    ) -> Int {
        guard let rawValue = firstValue(in: source, keys: keys),
                let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                value >= 0
        else {
            return defaultValue
        }
        return value
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
}

private nonisolated struct CPSLAgentConfigSource {
    let values: [String: String]
    let environment: [String: String]
}

nonisolated enum CPSLAgentConfigError: LocalizedError {
    case missingEnvFile
    case missingValue(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .missingEnvFile:
            return "Add a local .env file with OPENAI_BASE_URL, OPENAI_API_KEY, and OPENAI_MODEL, then rebuild."
        case .missingValue(let key):
            return "Missing \(key) in .env."
        case .invalidValue(let key):
            return "\(key) must be an absolute HTTP or HTTPS base URL without credentials, query, or fragment."
        }
    }
}
