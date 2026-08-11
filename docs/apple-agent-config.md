# Apple Agent Configuration

## Main agent provider selection

On **iOS 27+ / macOS 27+** (and matching visionOS), when Apple **Private Cloud Compute**
is available at runtime, the main agent completion path uses Foundation Models
`PrivateCloudComputeLanguageModel` (`apple/pcc`) instead of Grok/xAI.

PCC is gated by:

- compile/runtime availability of the iOS 27 FoundationModels PCC APIs
- `PrivateCloudComputeLanguageModel().isAvailable`
- the `com.apple.developer.private-cloud-compute` entitlement on the app target

When PCC is unavailable (older OS, ineligible device, missing entitlement, or
Apple Intelligence / PCC not ready), the agent falls back to the OpenAI-compatible
path below. Vision and other non-agent OpenAI clients are unchanged.

## OpenAI-compatible fallback (and vision)

Configure the OpenAI-compatible Chat Completions fallback (and vision) with a
local `.env` file:

```dotenv
OPENAI_BASE_URL=https://api.x.ai/v1
OPENAI_API_KEY=replace-with-token
OPENAI_MODEL=replace-with-model
HERM_MAX_TOOL_ROUNDS=200
HERM_MAX_OUTPUT_TOKENS=16384
HERM_EXPLORE_SUBAGENT_TURNS=15
HERM_GENERAL_SUBAGENT_TURNS=20
HERM_MAX_AGENT_DEPTH=1
```

`OPENAI_BASE_URL` must be an absolute HTTP or HTTPS base URL without embedded
credentials, query, or fragment. The client appends `/chat/completions`.

`HERM_MAX_AGENT_DEPTH` controls whether the main agent may summon sub-agents
through the `agent` tool. The default template value is `1`, which allows the
main agent to spawn one helper level. Set it to `0` to remove the `agent` tool
from provider requests. `HERM_EXPLORE_SUBAGENT_TURNS` and
`HERM_GENERAL_SUBAGENT_TURNS` control the turn budget for helper agents.

Round limits are fail-safe ceilings, not targets. Herm starts nudging the main
agent to synthesize at rounds 8 and 12, reserves the last helper turn for a
tool-free result, and clears stale tool output when replay reaches four output
budgets (or 80% of a configured context window, whichever comes first). This
keeps routine runs short without cutting off an unusually long task.

Local credential files are ignored by git and excluded from the Xcode target:

- `.env`
- `.env.local`
- `app/apple/herm/.env`
- `app/apple/herm/.env.local`
- `app/apple/herm/Resources/.env`
- `app/apple/herm/Resources/.env.local`

`app/apple/herm/Resources/env.example` is a safe template and may be packaged.
Do not ship real API tokens in the app bundle as resource files. The Xcode target
has a `Generate Env Constants` script phase that runs before Swift compilation in
Debug and Release. It reads local `.env` files and writes
`app/apple/herm/Generated/CPSLEnvConstants.swift`, which is also ignored by git.

The generator checks these locations, with later files overriding earlier values:

- Repo-root `.env`
- `app/apple/herm/.env`
- `app/apple/herm/Resources/.env`
- Repo-root `.env.local`
- `app/apple/herm/.env.local`
- `app/apple/herm/Resources/.env.local`

For macOS development, `scripts/dev-apple-macos.sh` changes to the repo root
before launching the app, but environment values are compiled at build time. If
you change `.env`, rebuild the app so the constants are regenerated. This keeps
credentials out of the public repo and out of copied bundle resources, but it is
not a production credential strategy because client-side constants can still be
extracted from the app binary. Move provider tokens server-side before shipping.
