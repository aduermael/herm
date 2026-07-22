# herm

[![Tests](https://github.com/aduermael/herm/actions/workflows/test.yml/badge.svg)](https://github.com/aduermael/herm/actions/workflows/test.yml)
[![Prompt Length](https://github.com/aduermael/herm/actions/workflows/prompt-length.yml/badge.svg)](https://github.com/aduermael/herm/actions/workflows/prompt-length.yml)
[![CI Checks](https://github.com/aduermael/herm/actions/workflows/ci-checks.yml/badge.svg)](https://github.com/aduermael/herm/actions/workflows/ci-checks.yml)

Herm is a model-agnostic, general-purpose AI agent built for safe, flexible execution. It natively supports multiple isolation methods (containers, in-process Unix-like sandboxes, and host sandboxes such as `sandbox_exec` on macOS or `bubblewrap` on Linux).

The Herm CLI defaults to containers with self-building environments, so you can run anything safely without approval interruptions.

The logo and mascot feature a hermit crab called Herm, representing the hermetic nature of the agent. 🐚

## Herm CLI

![demo](img/demo.gif)

**Containerized by default:** Use the CLI on your host; the agent itself runs inside Docker containers and can only access files from your current work directory. No permission prompts.

**Multi-provider** — Anthropic, OpenAI, Gemini, Grok, OpenRouter, Ollama, Azure OpenAI, Vertex AI, or Bedrock… You can mix and match models, like Grok as the main agent, Haiku for exploration, and Gemini for vision.

**Self-building dev environments** — Herm extends container environments by writing Dockerfiles dynamically. Environments are scoped per project (current work directory).

**100% open-source** — Everything is open: system prompts, skills, tools. No hidden instructions, no black boxes. You can fork it to make it your own.

### Requirements

- macOS or Linux (arm64 and amd64)
- Docker (through [Docker Desktop](https://www.docker.com/products/docker-desktop/) or [OrbStack](https://orbstack.dev)) when using the default container-based isolation

### Install

Use the install method that suits you:

```sh
curl -fsSL https://hermagent.com/install.sh | sh
```

```sh
brew tap aduermael/herm
brew install herm
```

Or read the instructions to [build from source](CONTRIBUTING.md#setup).

### Run

```
herm
```

## Herm app for iOS/macOS

**TODO**

## Roadmap

Rough priority order, subject to change.

1. **Benchmarks:** measure Herm against Claude Code, Codex, Grok Build and other coding agents.
2. **PR review bot:** Herm bot (GitHub Action) that reviews pull requests.
3. **Safe connectivity:** Let Herm talk to external APIs and databases without ever seeing your credentials. (We'll probably use [SFAE](https://sfae.io) for this)

## Project Structure

```
herm/
├── app/apple/                 iOS and macOS app (SwiftUI)
├── cmd/
│   ├── herm/                  Herm CLI
│   └── debug/                 Debug utilities
├── prompts/                   System prompts and tool docs (embedded)
├── scripts/                   Build helpers
├── tools/                     Repo tooling
├── docs/                      Website (GitHub Pages → hermagent.com)
├── external/
│   ├── langdag/               LLM client/orchestration submodule
│   └── cpsl/                  Native sandbox backend submodule
├── img/                       Demo assets
├── install.sh                 Installer (published at hermagent.com/install.sh)
├── THIRD-PARTY-NOTICES        Third-party license attributions
├── CPSL_BUILD.md
├── CONTRIBUTING.md
├── go.mod
├── LICENSE
└── README.md
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup, tests, CI checks, coding standards, and pull request expectations.

## Community

Join the [Discord](https://discord.gg/WFjcymwtZU) to chat, ask questions, or share feedback.

## License

Herm is distributed under the [MIT License](LICENSE).

Third-party software included with Herm is redistributed under its own licenses. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) for attributions, required NOTICE excerpts, and license texts.
