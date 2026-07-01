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
        try assertInvalidBaseURLFails()
        try assertBaseURLQueryFails()
        try assertBaseURLCredentialsFail()
    }

    private static func assertConfigLoadsGeneratedValues() throws {
        let config = try CPSLAgentConfig.load()

        guard config.baseURL.absoluteString == "https://api.x.ai/v1",
              config.token == "generated-token",
              config.model == "generated-model"
        else {
            throw CheckFailure("generated constants should load as the default config")
        }
    }

    private static func assertConfigPrefersFileValues() throws {
        let config = try CPSLAgentConfig.make(
            values: [
                "OPENAI_BASE_URL": " https://api.x.ai/v1 ",
                "OPENAI_API_KEY": " file-token ",
                "OPENAI_MODEL": " file-model "
            ],
            environment: [
                "OPENAI_BASE_URL": "https://wrong.example/v1",
                "OPENAI_API_KEY": "env-token",
                "OPENAI_MODEL": "env-model"
            ]
        )

        guard config.baseURL.absoluteString == "https://api.x.ai/v1",
              config.token == "file-token",
              config.model == "file-model"
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
                "OPENAI_MODEL": "env-model"
            ]
        )

        guard config.baseURL.absoluteString == "https://compatible.example/v1",
              config.token == "env-token",
              config.model == "env-model",
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
