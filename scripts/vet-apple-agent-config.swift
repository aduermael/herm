import Foundation

@main
private struct CPSLAgentConfigChecks {
    static func main() throws {
        try assertEnvParsing()
        try assertConfigPrefersFileValues()
        try assertEnvironmentFallbacks()
        try assertSourceResourcesEnvLoad()
        try assertInvalidBaseURLFails()
        try assertBaseURLQueryFails()
        try assertBaseURLCredentialsFail()
    }

    private static func assertEnvParsing() throws {
        let values = CPSLEnvLoader.parse(
            """
            # comment
            export OPENAI_BASE_URL = "https://api.x.ai/v1"
            OPENAI_API_KEY='token=value'
            OPENAI_MODEL=grok-test # inline comment
            HASHED_VALUE="model#variant"
            IGNORED_LINE
            EMPTY_VALUE=
            """
        )

        guard values["OPENAI_BASE_URL"] == "https://api.x.ai/v1",
              values["OPENAI_API_KEY"] == "token=value",
              values["OPENAI_MODEL"] == "grok-test",
              values["HASHED_VALUE"] == "model#variant",
              values["IGNORED_LINE"] == nil,
              values["EMPTY_VALUE"] == ""
        else {
            throw CheckFailure(".env parsing did not preserve expected assignments")
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
            throw CheckFailure("file .env values should win over process environment")
        }
    }

    private static func assertEnvironmentFallbacks() throws {
        let config = try CPSLAgentConfig.make(
            values: [:],
            environment: [
                "API_URL": "https://compatible.example/v1",
                "TOKEN": "env-token",
                "XAI_MODEL": "env-model"
            ]
        )

        guard config.baseURL.absoluteString == "https://compatible.example/v1",
              config.token == "env-token",
              config.model == "env-model",
              CPSLEnvLoader.hasProcessEnvironmentFallback(environment: ["MODEL": "env-model"])
        else {
            throw CheckFailure("environment fallback keys did not resolve")
        }
    }

    private static func assertSourceResourcesEnvLoad() throws {
        let fileManager = FileManager.default
        let originalDirectory = fileManager.currentDirectoryPath
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("herm-env-vet-\(UUID().uuidString)", isDirectory: true)
        let resources = directory
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("apple", isDirectory: true)
            .appendingPathComponent("herm", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        OPENAI_BASE_URL=https://api.x.ai/v1
        OPENAI_API_KEY=source-token
        OPENAI_MODEL=source-model
        """.write(to: resources.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        defer {
            _ = fileManager.changeCurrentDirectoryPath(originalDirectory)
            try? fileManager.removeItem(at: directory)
        }
        guard fileManager.changeCurrentDirectoryPath(directory.path) else {
            throw CheckFailure("could not enter temporary env directory")
        }

        let loaded = try CPSLEnvLoader.load()
        let config = try CPSLAgentConfig.make(values: loaded, environment: [:])
        guard config.baseURL.absoluteString == "https://api.x.ai/v1",
              config.token == "source-token",
              config.model == "source-model"
        else {
            throw CheckFailure("source Resources/.env was not loaded from repo-style working directory")
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
