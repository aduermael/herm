import Foundation

nonisolated enum CPSLEnvConstants {
    static let values: [String: String] = [
        "OPENAI_BASE_URL": " https://api.x.ai/v1 ",
        "OPENAI_API_KEY": " generated-token ",
        "OPENAI_MODEL": " generated-model "
    ]
}

@main
private struct CPSLAgentConfigChecks {
    static func main() throws {
        try assertConfigLoadsGeneratedValues()
        try assertConfigPrefersFileValues()
        try assertEnvironmentFallbacks()
        try assertDedicatedVisionConfig()
        try assertInvalidBaseURLFails()
        try assertInvalidVisionBaseURLFails()
        try assertBaseURLQueryFails()
        try assertBaseURLCredentialsFail()
    }

    private static func assertConfigLoadsGeneratedValues() throws {
        let config = try CPSLAgentConfig.load()

        guard config.baseURL.absoluteString == "https://api.x.ai/v1",
              config.token == "generated-token",
              config.model == "generated-model",
              config.visionBaseURL.absoluteString == "https://api.x.ai/v1",
              config.visionToken == "generated-token",
              config.visionModel == "generated-model",
              config.maxToolRounds == 200,
              config.maxOutputTokens == 16_384,
              config.contextWindowTokens == nil,
              config.exploreSubAgentTurns == 15,
              config.generalSubAgentTurns == 20,
              config.maxAgentDepth == 1
        else {
            throw CheckFailure("generated constants should load as the default config")
        }
    }

    private static func assertDedicatedVisionConfig() throws {
        let config = try CPSLAgentConfig.make(values: [
            "OPENAI_BASE_URL": "https://api.x.ai/v1",
            "OPENAI_API_KEY": "main-token",
            "OPENAI_MODEL": "grok-4.5",
            "HERM_VISION_BASE_URL": "https://generativelanguage.googleapis.com/v1beta/openai",
            "HERM_VISION_API_KEY": "vision-token",
            "HERM_VISION_MODEL": "gemini-2.5-pro"
        ])

        guard config.visionBaseURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai",
              config.visionToken == "vision-token",
              config.visionModel == "gemini-2.5-pro"
        else {
            throw CheckFailure("dedicated vision config should override the main provider")
        }
    }

    private static func assertConfigPrefersFileValues() throws {
        let config = try CPSLAgentConfig.make(
            values: [
                "OPENAI_BASE_URL": " https://api.x.ai/v1 ",
                "OPENAI_API_KEY": " file-token ",
                "OPENAI_MODEL": " file-model ",
                "HERM_MAX_TOOL_ROUNDS": "77",
                "HERM_CONTEXT_WINDOW_TOKENS": "64000"
            ],
            environment: [
                "OPENAI_BASE_URL": "https://wrong.example/v1",
                "OPENAI_API_KEY": "env-token",
                "OPENAI_MODEL": "env-model",
                "HERM_MAX_TOOL_ROUNDS": "12"
            ]
        )

        guard config.baseURL.absoluteString == "https://api.x.ai/v1",
              config.token == "file-token",
              config.model == "file-model",
              config.maxToolRounds == 77,
              config.contextWindowTokens == 64_000
        else {
            throw CheckFailure("generated .env values should win over process environment")
        }
    }

    private static func assertEnvironmentFallbacks() throws {
        let config = try CPSLAgentConfig.make(
            values: [:],
            environment: [
                "API_URL": "https://compatible.example/v1",
                "TOKEN": "env-token",
                "OPENAI_MODEL": "env-model",
                "MAX_OUTPUT_TOKENS": "4096",
                "EXPLORE_SUBAGENT_TURNS": "9",
                "GENERAL_SUBAGENT_TURNS": "11",
                "MAX_AGENT_DEPTH": "0"
            ]
        )

        guard config.baseURL.absoluteString == "https://compatible.example/v1",
              config.token == "env-token",
              config.model == "env-model",
              config.maxOutputTokens == 4_096,
              config.exploreSubAgentTurns == 9,
              config.generalSubAgentTurns == 11,
              config.maxAgentDepth == 0,
              CPSLAgentConfig.hasProcessEnvironmentFallback(environment: ["MODEL": "env-model"])
        else {
            throw CheckFailure("environment fallback keys did not resolve")
        }
    }

    private static func assertInvalidBaseURLFails() throws {
        do {
            _ = try CPSLAgentConfig.make(
                values: [
                    "OPENAI_BASE_URL": "api.x.ai/v1",
                    "OPENAI_API_KEY": "token",
                    "OPENAI_MODEL": "model"
                ]
            )
        } catch CPSLAgentConfigError.invalidValue("OPENAI_BASE_URL") {
            return
        }
        throw CheckFailure("relative OPENAI_BASE_URL should fail validation")
    }

    private static func assertInvalidVisionBaseURLFails() throws {
        do {
            _ = try CPSLAgentConfig.make(values: [
                "OPENAI_BASE_URL": "https://api.x.ai/v1",
                "OPENAI_API_KEY": "token",
                "OPENAI_MODEL": "model",
                "HERM_VISION_BASE_URL": "not-a-url"
            ])
        } catch CPSLAgentConfigError.invalidValue("HERM_VISION_BASE_URL") {
            return
        }
        throw CheckFailure("relative HERM_VISION_BASE_URL should fail validation")
    }

    private static func assertBaseURLQueryFails() throws {
        do {
            _ = try CPSLAgentConfig.make(
                values: [
                    "OPENAI_BASE_URL": "https://api.x.ai/v1?debug=1",
                    "OPENAI_API_KEY": "token",
                    "OPENAI_MODEL": "model"
                ]
            )
        } catch CPSLAgentConfigError.invalidValue("OPENAI_BASE_URL") {
            return
        }
        throw CheckFailure("OPENAI_BASE_URL with query should fail validation")
    }

    private static func assertBaseURLCredentialsFail() throws {
        do {
            _ = try CPSLAgentConfig.make(
                values: [
                    "OPENAI_BASE_URL": "https://user:pass@api.x.ai/v1",
                    "OPENAI_API_KEY": "token",
                    "OPENAI_MODEL": "model"
                ]
            )
        } catch CPSLAgentConfigError.invalidValue("OPENAI_BASE_URL") {
            return
        }
        throw CheckFailure("OPENAI_BASE_URL with credentials should fail validation")
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
