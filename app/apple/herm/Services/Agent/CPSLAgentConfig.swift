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
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            maxToolRounds: positiveIntValue(
                in: values,
                environment: environment,
                keys: ["HERM_MAX_TOOL_ROUNDS", "MAX_TOOL_ROUNDS"],
                defaultValue: defaultMaxToolRounds
            ),
            maxOutputTokens: positiveIntValue(
                in: values,
                environment: environment,
                keys: ["HERM_MAX_OUTPUT_TOKENS", "MAX_OUTPUT_TOKENS"],
                defaultValue: defaultMaxOutputTokens
            ),
            contextWindowTokens: optionalPositiveIntValue(
                in: values,
                environment: environment,
                keys: ["HERM_CONTEXT_WINDOW_TOKENS", "CONTEXT_WINDOW_TOKENS"]
            ),
            exploreSubAgentTurns: positiveIntValue(
                in: values,
                environment: environment,
                keys: ["HERM_EXPLORE_SUBAGENT_TURNS", "EXPLORE_SUBAGENT_TURNS"],
                defaultValue: defaultExploreSubAgentTurns
            ),
            generalSubAgentTurns: positiveIntValue(
                in: values,
                environment: environment,
                keys: ["HERM_GENERAL_SUBAGENT_TURNS", "GENERAL_SUBAGENT_TURNS"],
                defaultValue: defaultGeneralSubAgentTurns
            ),
            maxAgentDepth: nonNegativeIntValue(
                in: values,
                environment: environment,
                keys: ["HERM_MAX_AGENT_DEPTH", "MAX_AGENT_DEPTH"],
                defaultValue: defaultMaxAgentDepth
            )
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

    private static func positiveIntValue(
        in values: [String: String],
        environment: [String: String],
        keys: [String],
        defaultValue: Int
    ) -> Int {
        optionalPositiveIntValue(in: values, environment: environment, keys: keys) ?? defaultValue
    }

    private static func optionalPositiveIntValue(
        in values: [String: String],
        environment: [String: String],
        keys: [String]
    ) -> Int? {
        guard let rawValue = firstValue(in: values, environment: environment, keys: keys),
              let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else {
            return nil
        }
        return value
    }

    private static func nonNegativeIntValue(
        in values: [String: String],
        environment: [String: String],
        keys: [String],
        defaultValue: Int
    ) -> Int {
        guard let rawValue = firstValue(in: values, environment: environment, keys: keys),
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
