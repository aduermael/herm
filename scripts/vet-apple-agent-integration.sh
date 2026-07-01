#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "missing required file: $path" >&2
    exit 1
  fi
}

require_match() {
  local pattern="$1"
  local path="$2"
  if ! rg -q "$pattern" "$path"; then
    echo "expected pattern not found in $path: $pattern" >&2
    exit 1
  fi
}

reject_match() {
  local pattern="$1"
  shift
  if rg -q "$pattern" "$@"; then
    echo "forbidden pattern found: $pattern" >&2
    rg -n "$pattern" "$@" >&2
    exit 1
  fi
}

swift_files=(
  app/apple/herm/Services/Agent/CPSLAgentConfig.swift
  app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
  app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
  app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
  app/apple/herm/Services/Agent/CPSLConversationStore.swift
  app/apple/herm/Services/CPSLDebugService.swift
  app/apple/herm/Models/CPSLTypes.swift
  app/apple/herm/Models/CPSLChatModel.swift
  app/apple/herm/Views/Chat/CPSLConversationDrawerView.swift
  app/apple/herm/Views/Chat/CPSLChatScreen.swift
  app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
)

required_files=(
  .gitignore
  docs/apple-agent-config.md
  docs/apple-agent-storage.md
  app/apple/herm/Resources/env.example
  app/apple/herm/herm.entitlements
  app/apple/herm/herm-macOS.entitlements
  app/apple/herm.xcodeproj/project.pbxproj
  scripts/generate-apple-env-constants.sh
  scripts/generate-apple-env-constants.swift
  scripts/dev-apple-macos.sh
  scripts/vet-apple-agent-config.swift
  scripts/vet-apple-agent-tool-formatting.swift
  scripts/vet-apple-conversation-store.swift
  scripts/vet-apple-openai-protocol.swift
  "${swift_files[@]}"
)

for path in "${required_files[@]}"; do
  require_file "$path"
done

require_match '^\.env$' .gitignore
require_match '^\.env\.local$' .gitignore
require_match 'app/apple/herm/Generated/CPSLEnvConstants\.swift' .gitignore
require_match 'CPSLEnvConstants\.values' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'generated constants should load as the default config' scripts/vet-apple-agent-config.swift
require_match 'OPENAI_BASE_URL=' app/apple/herm/Resources/env.example
require_match 'OPENAI_API_KEY=' app/apple/herm/Resources/env.example
require_match 'OPENAI_MODEL=' app/apple/herm/Resources/env.example
require_match 'OpenAI-compatible Chat Completions' docs/apple-agent-config.md
require_match 'Do not ship real API tokens in the app bundle as resource files' docs/apple-agent-config.md
require_match 'scripts/dev-apple-macos\.sh.*repo root' docs/apple-agent-config.md
require_match 'Generate Env Constants' docs/apple-agent-config.md
require_match 'Debug and Release' docs/apple-agent-config.md
require_match 'rebuild the app' docs/apple-agent-config.md
require_match 'OPENAI_BASE_URL' docs/apple-agent-config.md
require_match 'OPENAI_API_KEY' docs/apple-agent-config.md
require_match 'OPENAI_MODEL' docs/apple-agent-config.md
require_match 'invalidValue\("OPENAI_BASE_URL"\)' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'make\(' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'parseEnv' scripts/generate-apple-env-constants.swift
require_match '\["http", "https"\]\.contains\(scheme\)' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'OPENAI_MODEL.*!= nil' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'XAI_MODEL.*!= nil' app/apple/herm/Services/Agent/CPSLAgentConfig.swift

require_match 'com.apple.developer.icloud-services' app/apple/herm/herm.entitlements
require_match 'CloudDocuments' app/apple/herm/herm.entitlements
require_match 'com.apple.developer.icloud-services' app/apple/herm/herm-macOS.entitlements
require_match 'CloudDocuments' app/apple/herm/herm-macOS.entitlements
require_match 'com.apple.security.app-sandbox' app/apple/herm/herm-macOS.entitlements
require_match 'com.apple.security.network.client' app/apple/herm/herm-macOS.entitlements
reject_match 'com.apple.security.network.client' app/apple/herm/herm.entitlements
require_match 'CODE_SIGN_ENTITLEMENTS = herm/herm.entitlements;' app/apple/herm.xcodeproj/project.pbxproj
require_match 'CODE_SIGN_ENTITLEMENTS\[sdk=macosx\*\].*herm-macOS.entitlements' app/apple/herm.xcodeproj/project.pbxproj
require_match 'libsqlite3.tbd' app/apple/herm.xcodeproj/project.pbxproj
require_match 'PBXFileSystemSynchronizedBuildFileExceptionSet' app/apple/herm.xcodeproj/project.pbxproj
require_match '^[[:space:]]*\.env,' app/apple/herm.xcodeproj/project.pbxproj
require_match '^[[:space:]]*\.env\.local,' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Resources/\.env' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Resources/\.env\.local' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Generated/CPSLEnvConstants\.swift' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Generate Env Constants' app/apple/herm.xcodeproj/project.pbxproj
require_match 'generate-apple-env-constants\.sh' app/apple/herm.xcodeproj/project.pbxproj
require_match 'CPSLEnvConstants\.swift in Sources' app/apple/herm.xcodeproj/project.pbxproj
require_match 'source_entitlements_path=.*herm-macOS.entitlements' scripts/dev-apple-macos.sh
require_match 'sign_entitlements_path=.source_entitlements_path' scripts/dev-apple-macos.sh
require_match 'cd "\$root"' scripts/dev-apple-macos.sh
require_match 'iCloud file-container prototype' docs/apple-agent-storage.md
require_match 'not Apple.s standard robust' docs/apple-agent-storage.md
require_match 'CloudKit-backed persistence' docs/apple-agent-storage.md

require_match 'url\(forUbiquityContainerIdentifier: nil\)' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'PRAGMA journal_mode=DELETE' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'PRAGMA synchronous=FULL' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'BEGIN IMMEDIATE TRANSACTION' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'sqlite3_busy_timeout' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'init\(databaseURL: URL, usesICloudContainer: Bool\)' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'addColumnIfMissing' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'PRAGMA table_info' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'ALTER TABLE' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'backfillLegacyConversationPointers' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'legacy conversation pointers did not backfill' scripts/vet-apple-conversation-store.swift
require_match 'model: String\?' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'updateConversationModelIfMissing' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'updateConversationModelIfMissing' app/apple/herm/Models/CPSLChatModel.swift
require_match 'systemPrompt: String' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'currentSystemPrompt = conversation\.systemPrompt' app/apple/herm/Models/CPSLChatModel.swift
require_match 'systemPrompt: replaySystemPrompt' app/apple/herm/Models/CPSLChatModel.swift
require_match 'storeLoadTask: Task<CPSLConversationStore, Error>' app/apple/herm/Models/CPSLChatModel.swift
require_match 'private func loadStore\(\) async throws -> CPSLConversationStore' app/apple/herm/Models/CPSLChatModel.swift
require_match 'let store = try await loadStore\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'store = try await loadStore\(\)' app/apple/herm/Models/CPSLChatModel.swift
reject_match 'guard let store else' app/apple/herm/Models/CPSLChatModel.swift
require_match 'conversations = try await store\.loadSummaries\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'sequence = try nextSequence' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'parentRequired' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'parentRequired' scripts/vet-apple-conversation-store.swift
require_match 'assertParentBelongsToConversation' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'parentConversationMismatch' scripts/vet-apple-conversation-store.swift
require_match 'CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_conversation_sequence_unique' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'CREATE INDEX IF NOT EXISTS idx_nodes_parent' app/apple/herm/Services/Agent/CPSLConversationStore.swift

require_match 'tools: \[CPSLOpenAITool.localSandboxExec\]' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'appendingPathComponent\("chat"\)' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'appendingPathComponent\("completions"\)' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'encodeNil\(forKey: \.content\)' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'name: "local_sandbox_exec"' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'Never guess sandbox tool signatures' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'fs\.help\(\)' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'Declare variables with local' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'Bash, Python, shell commands' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'fs\.help\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Luau essentials' app/apple/herm/Models/CPSLChatModel.swift
require_match 'CPSLOpenAIError\.provider' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'CPSLOpenAIError\.invalidToolCall' scripts/vet-apple-openai-protocol.swift
require_match 'validatedCompletion\(\)' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'toolChoice: "auto"' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'stream: true' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'text/event-stream' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'evaluateLuau' app/apple/herm/Services/CPSLDebugService.swift
require_match '"language": "luau"' app/apple/herm/Services/CPSLDebugService.swift
require_match '"language": language' app/apple/herm/Services/CPSLDebugService.swift
require_match 'CPSLAgentToolFormatting\.providerContent' app/apple/herm/Models/CPSLChatModel.swift
require_match 'CPSLAgentToolFormatting\.displayBody' app/apple/herm/Models/CPSLChatModel.swift
require_match 'object\.keys\.sorted\(\) == \["source"\]' app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
require_match 'unknown fields should not decode' scripts/vet-apple-agent-tool-formatting.swift
require_match 'truncatedText' app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
require_match 'ffi_error' app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
require_match 'func selectConversation\(id: String\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'model\.selectConversation\(id: conversation\.id\)' app/apple/herm/Views/Chat/CPSLConversationDrawerView.swift
require_match 'isRunning = true' app/apple/herm/Models/CPSLChatModel.swift
require_match 'defer \{' app/apple/herm/Models/CPSLChatModel.swift
require_match 'typewriterTask = nil' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Provider returned an empty response' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Stopped after.*tool rounds' app/apple/herm/Models/CPSLChatModel.swift
require_match 'let errorNode = try await store\.appendNode' app/apple/herm/Models/CPSLChatModel.swift
require_match 'appendProviderLoopError' app/apple/herm/Models/CPSLChatModel.swift
require_match 'appendAgentError' app/apple/herm/Models/CPSLChatModel.swift
require_match 'persistStreamingAssistantIfNeeded' app/apple/herm/Models/CPSLChatModel.swift
require_match 'onParentIDChange\(parentID\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'model: nil' app/apple/herm/Models/CPSLChatModel.swift

reject_match 'web_search|web_search_preview|server.*tool|parallel_tool_calls|stream_options' \
  app/apple/herm/Services/Agent/CPSLOpenAIClient.swift \
  app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
  app/apple/herm/Models/CPSLChatModel.swift

if command -v plutil >/dev/null 2>&1; then
  plutil -lint app/apple/herm/herm.entitlements app/apple/herm/herm-macOS.entitlements app/apple/herm.xcodeproj/project.pbxproj >/dev/null
fi

tmp_env_dir=""
if command -v swift >/dev/null 2>&1; then
  tmp_env_dir="$(mktemp -d)"
  trap 'if [[ -n "$tmp_env_dir" ]]; then rm -rf "$tmp_env_dir"; fi' EXIT
  printf '%s\n' \
    '# comment' \
    'export OPENAI_BASE_URL = "https://api.x.ai/v1"' \
    "OPENAI_API_KEY='token=value'" \
    'OPENAI_MODEL=base-model # inline comment' \
    'HASHED_VALUE="model#variant"' \
    'IGNORED_LINE' \
    'EMPTY_VALUE=' \
    >"$tmp_env_dir/.env"
  printf '%s\n' \
    'OPENAI_MODEL=local-model' \
    >"$tmp_env_dir/.env.local"
  swift scripts/generate-apple-env-constants.swift \
    "$tmp_env_dir/CPSLEnvConstants.swift" \
    "$tmp_env_dir/.env" \
    "$tmp_env_dir/.env.local"
  require_match '"OPENAI_BASE_URL": "https://api.x.ai/v1"' "$tmp_env_dir/CPSLEnvConstants.swift"
  require_match '"OPENAI_API_KEY": "token=value"' "$tmp_env_dir/CPSLEnvConstants.swift"
  require_match '"OPENAI_MODEL": "local-model"' "$tmp_env_dir/CPSLEnvConstants.swift"
  require_match '"HASHED_VALUE": "model#variant"' "$tmp_env_dir/CPSLEnvConstants.swift"
  require_match '"EMPTY_VALUE": ""' "$tmp_env_dir/CPSLEnvConstants.swift"
  reject_match 'base-model|IGNORED_LINE' "$tmp_env_dir/CPSLEnvConstants.swift"
fi

if command -v swiftc >/dev/null 2>&1; then
  swiftc -typecheck app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
  swiftc -typecheck app/apple/herm/Services/Agent/CPSLAgentConfig.swift "$tmp_env_dir/CPSLEnvConstants.swift"
  swiftc app/apple/herm/Services/Agent/CPSLAgentConfig.swift scripts/vet-apple-agent-config.swift -o /tmp/herm-vet-agent-config
  /tmp/herm-vet-agent-config
  swiftc \
    app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
    app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift \
    scripts/vet-apple-agent-tool-formatting.swift \
    -o /tmp/herm-vet-agent-tool-formatting
  /tmp/herm-vet-agent-tool-formatting
  swiftc app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift scripts/vet-apple-openai-protocol.swift -o /tmp/herm-vet-openai-protocol
  /tmp/herm-vet-openai-protocol
  if [[ "$(uname -s)" == "Darwin" ]]; then
    swiftc \
      app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
      app/apple/herm/Models/CPSLTypes.swift \
      app/apple/herm/Services/Agent/CPSLConversationStore.swift \
      scripts/vet-apple-conversation-store.swift \
      -lsqlite3 \
      -o /tmp/herm-vet-conversation-store
    /tmp/herm-vet-conversation-store
  fi
  swiftc -parse "$tmp_env_dir/CPSLEnvConstants.swift" "${swift_files[@]}"
fi

echo "apple agent integration checks passed"
