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
  app/apple/herm/Services/Agent/CPSLAgentProviderSelection.swift
  app/apple/herm/Services/Agent/CPSLPCCMessageMapper.swift
  app/apple/herm/Services/Agent/CPSLAgentChatClient.swift
  app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
  app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
  app/apple/herm/Services/Agent/CPSLConversationStore.swift
  app/apple/herm/Services/Agent/CPSLSkills.swift
  app/apple/herm/Services/CPSLDebugService.swift
  app/apple/herm/Services/CPSLDictationService.swift
  app/apple/herm/Services/CPSLICloudBookmarkAccess.swift
  app/apple/herm/Services/CPSLICloudFileMaterializer.swift
  app/apple/herm/Services/CPSLICloudMountManager.swift
  app/apple/herm/Models/CPSLEvalTypes.swift
  app/apple/herm/Models/CPSLICloudMount.swift
  app/apple/herm/Models/CPSLTypes.swift
  app/apple/herm/Models/CPSLChatModel.swift
  app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
  app/apple/herm/Models/CPSLChatModel+AgentRuntimeTypes.swift
  app/apple/herm/Views/Chat/CPSLConversationDrawerView.swift
  app/apple/herm/Views/Chat/CPSLChatScreen.swift
  app/apple/herm/Views/Chat/CPSLChatTimelineCodeViews.swift
  app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
  app/apple/herm/Views/Files/CPSLFileOverlayPanel.swift
  app/apple/herm/Views/Files/CPSLFileBrowserView.swift
  app/apple/herm/Views/Files/CPSLFilePreviewOverlay.swift
)

required_files=(
  .gitignore
  docs/apple-agent-config.md
  docs/apple-agent-storage.md
  app/apple/herm/Resources/env.example
  app/apple/herm/Skills/beautiful-pdfs/SKILL.md
  app/apple/herm/Skills/beautiful-pdfs/print.css
  app/apple/herm/Skills/image-vision/SKILL.md
  app/apple/herm/herm.entitlements
  app/apple/herm/herm-macOS.entitlements
  app/apple/herm.xcodeproj/project.pbxproj
  scripts/generate-apple-env-constants.sh
  scripts/generate-apple-env-constants.swift
  scripts/dev-apple-macos.sh
  scripts/apply-cpsl-patches.sh
  scripts/cpsl-patches/series
  scripts/test-cpsl-xcframework.sh
  scripts/vet-apple-agent-config.swift
  scripts/vet-apple-agent-concurrency-ui.swift
  scripts/vet-apple-eval-race.swift
  scripts/vet-apple-agent-tool-formatting.swift
  scripts/vet-apple-agent-shared-types.swift
  scripts/vet-apple-icloud-materializer.swift
  scripts/vet-apple-icloud-mounts.swift
  scripts/vet-apple-icloud-mount-manager.swift
  scripts/vet-apple-conversation-store.swift
  scripts/vet-apple-openai-protocol.swift
  scripts/vet-apple-agent-pcc.swift
  scripts/generate-apple-pcc-runtime.sh
  scripts/apple-pcc/CPSLPCCRuntime.full.swift
  scripts/apple-pcc/CPSLPCCRuntime.stub.swift
  external/cpsl/core/src/doc/render.rs
  external/cpsl/core/src/sandbox.rs
  external/cpsl/ffi/src/lib.rs
  "${swift_files[@]}"
)

for path in "${required_files[@]}"; do
  require_file "$path"
done

if [[ -e app/apple/herm/Services/CPSLICloudStagingStorage.swift || \
      -e scripts/vet-apple-icloud-staging.swift ]]; then
  echo "obsolete iCloud staging implementation or vet still exists" >&2
  exit 1
fi

require_match '^\.env$' .gitignore
require_match '^\.env\.local$' .gitignore
require_match 'app/apple/herm/Generated/CPSLEnvConstants\.swift' .gitignore
require_match 'CPSLEnvConstants\.values' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'generated constants should load as the default config' scripts/vet-apple-agent-config.swift
require_match 'OPENAI_BASE_URL=' app/apple/herm/Resources/env.example
require_match 'OPENAI_API_KEY=' app/apple/herm/Resources/env.example
require_match 'OPENAI_MODEL=' app/apple/herm/Resources/env.example
require_match 'HERM_MAX_TOOL_ROUNDS=200' app/apple/herm/Resources/env.example
require_match 'HERM_MAX_OUTPUT_TOKENS=16384' app/apple/herm/Resources/env.example
require_match 'OpenAI-compatible Chat Completions' docs/apple-agent-config.md
require_match 'Private Cloud Compute' docs/apple-agent-config.md
require_match 'PrivateCloudComputeLanguageModel' docs/apple-agent-config.md
require_match 'apple/pcc' docs/apple-agent-config.md
require_match 'private-cloud-compute' docs/apple-agent-config.md
require_match 'contact/request/private-cloud-compute' docs/apple-agent-config.md
require_match 'Do not ship real API tokens in the app bundle as resource files' docs/apple-agent-config.md
require_match 'scripts/dev-apple-macos\.sh.*repo root' docs/apple-agent-config.md
require_match 'Generate Env Constants' docs/apple-agent-config.md
require_match 'Debug and Release' docs/apple-agent-config.md
require_match 'rebuild the app' docs/apple-agent-config.md
require_match 'OPENAI_BASE_URL' docs/apple-agent-config.md
require_match 'OPENAI_API_KEY' docs/apple-agent-config.md
require_match 'OPENAI_MODEL' docs/apple-agent-config.md
require_match 'HERM_MAX_AGENT_DEPTH' docs/apple-agent-config.md
require_match 'main agent may summon sub-agents' docs/apple-agent-config.md
require_match 'validatedBaseURL\(baseURLValue, key: "OPENAI_BASE_URL"\)' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'throw CPSLAgentConfigError\.invalidValue\(key\)' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'make\(' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'parseEnv' scripts/generate-apple-env-constants.swift
require_match '\["http", "https"\]\.contains\(scheme\)' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'OPENAI_MODEL.*!= nil' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'XAI_MODEL.*!= nil' app/apple/herm/Services/Agent/CPSLAgentConfig.swift

require_match 'com.apple.developer.icloud-services' app/apple/herm/herm.entitlements
require_match 'CloudDocuments' app/apple/herm/herm.entitlements
require_match 'com.apple.developer.private-cloud-compute' app/apple/herm/herm.entitlements
require_match 'com.apple.developer.icloud-services' app/apple/herm/herm-macOS.entitlements
require_match 'CloudDocuments' app/apple/herm/herm-macOS.entitlements
require_match 'com.apple.developer.private-cloud-compute' app/apple/herm/herm-macOS.entitlements
require_match 'com.apple.security.app-sandbox' app/apple/herm/herm-macOS.entitlements
require_match 'com.apple.security.network.client' app/apple/herm/herm-macOS.entitlements
require_match 'com.apple.security.files.user-selected.read-write' app/apple/herm/herm-macOS.entitlements
require_match 'com.apple.security.files.bookmarks.app-scope' app/apple/herm/herm-macOS.entitlements
reject_match 'com.apple.security.files.user-selected.read-only' app/apple/herm/herm-macOS.entitlements
reject_match 'com.apple.security.network.client' app/apple/herm/herm.entitlements
require_match 'CODE_SIGN_ENTITLEMENTS = herm/herm.entitlements;' app/apple/herm.xcodeproj/project.pbxproj
require_match 'CODE_SIGN_ENTITLEMENTS\[sdk=macosx\*\].*herm-macOS.entitlements' app/apple/herm.xcodeproj/project.pbxproj
require_match 'ENABLE_USER_SELECTED_FILES = readwrite;' app/apple/herm.xcodeproj/project.pbxproj
reject_match 'ENABLE_USER_SELECTED_FILES = readonly;' app/apple/herm.xcodeproj/project.pbxproj
reject_match 'libsqlite3.tbd' app/apple/herm.xcodeproj/project.pbxproj
require_match 'PBXFileSystemSynchronizedBuildFileExceptionSet' app/apple/herm.xcodeproj/project.pbxproj
require_match '^[[:space:]]*\.env,' app/apple/herm.xcodeproj/project.pbxproj
require_match '^[[:space:]]*\.env\.local,' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Resources/\.env' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Resources/\.env\.local' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Generated/CPSLEnvConstants\.swift' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Generated/CPSLPCCRuntime\.generated\.swift' app/apple/herm.xcodeproj/project.pbxproj
require_match 'Generate Env Constants' app/apple/herm.xcodeproj/project.pbxproj
require_match 'generate-apple-env-constants\.sh' app/apple/herm.xcodeproj/project.pbxproj
require_match 'CPSLEnvConstants\.swift in Sources' app/apple/herm.xcodeproj/project.pbxproj
require_match 'CPSLPCCRuntime\.generated\.swift in Sources' app/apple/herm.xcodeproj/project.pbxproj
require_match 'source_entitlements_path=.*herm-macOS.entitlements' scripts/dev-apple-macos.sh
require_match 'sign_entitlements_path=.source_entitlements_path' scripts/dev-apple-macos.sh
require_match 'cd "\$root"' scripts/dev-apple-macos.sh
require_match 'done <.*series_file' scripts/apply-cpsl-patches.sh
require_match 'allow_webview_pdf_rendering\(webview_pdf_rendering_allowed\(config\)\)' external/cpsl/ffi/src/lib.rs
require_match 'restricted_network_policy_returns_structured_webview_pdf_denials' external/cpsl/ffi/src/lib.rs
require_match 'webview_pdf_rendering_requires_unrestricted_webbrowser_policy' external/cpsl/ffi/src/lib.rs
require_match 'iCloud file-container prototype' docs/apple-agent-storage.md
require_match 'append-only JSONL files' docs/apple-agent-storage.md
require_match 'debug export' docs/apple-agent-storage.md

require_match 'url\(forUbiquityContainerIdentifier: nil\)' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'conversations\.jsonl' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'traces\.jsonl' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'appendJSONLine' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'handle\.seekToEnd\(\)' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'handle\.synchronize\(\)' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'undecodable tail' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'init\(logURL: URL, usesICloudContainer: Bool\)' app/apple/herm/Services/Agent/CPSLConversationStore.swift
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
require_match 'conversations = try await store\.fetchConversationSummaries' app/apple/herm/Models/CPSLChatModel.swift
require_match 'nextSequence' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'parentRequired' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'parentRequired' scripts/vet-apple-conversation-store.swift
require_match 'conversation\.nodes\.contains' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'parentConversationMismatch' scripts/vet-apple-conversation-store.swift
require_match 'recordProviderRequest' app/apple/herm/Services/Agent/CPSLConversationStore.swift
require_match 'recordToolInvocation' app/apple/herm/Services/Agent/CPSLConversationStore.swift

require_match 'maxToolRounds: positiveIntValue' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'defaultMaxToolRounds = 200' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'tools: streamRequest\.tools\.isEmpty \? nil : streamRequest\.tools' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'maxCompletionTokens: streamRequest\.maxTokens' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'appendingPathComponent\("chat"\)' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'appendingPathComponent\("completions"\)' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift

# Main agent prefers Apple PCC on iOS 27+ when available; OpenAI/Grok is fallback.
# 27-only PCC types live only in the full runtime template / generated file — never
# unguarded in 26.5-safe agent sources (so Xcode 26.5 CI typechecks).
require_match 'PrivateCloudComputeLanguageModel' scripts/apple-pcc/CPSLPCCRuntime.full.swift
require_match 'CPSLPCCOuterLoopSignal' scripts/apple-pcc/CPSLPCCRuntime.full.swift
require_match 'CPSLPCCLocalSandboxTool' scripts/apple-pcc/CPSLPCCRuntime.full.swift
require_match 'CPSLPCCAgentTool' scripts/apple-pcc/CPSLPCCRuntime.full.swift
require_match 'local_sandbox_exec' scripts/apple-pcc/CPSLPCCRuntime.full.swift
require_match 'CPSLPCCMessageMapper\.mapPrompt' scripts/apple-pcc/CPSLPCCRuntime.full.swift
require_match 'isCompileTimeSupported: Bool \{ false \}' scripts/apple-pcc/CPSLPCCRuntime.stub.swift
require_match 'generate-apple-pcc-runtime\.sh' scripts/generate-apple-env-constants.sh
require_match 'SDK_VERSION' scripts/generate-apple-pcc-runtime.sh
require_match 'PrivateCloudComputeLanguageModel' scripts/generate-apple-pcc-runtime.sh
reject_match 'PrivateCloudComputeLanguageModel' \
  app/apple/herm/Services/Agent/CPSLAgentProviderSelection.swift \
  app/apple/herm/Services/Agent/CPSLAgentChatClient.swift \
  app/apple/herm/Services/Agent/CPSLPCCMessageMapper.swift
require_match 'CPSLPCCRuntime\.isAvailable' app/apple/herm/Services/Agent/CPSLAgentProviderSelection.swift
require_match 'CPSLPCCRuntime\.streamChat' app/apple/herm/Services/Agent/CPSLAgentChatClient.swift
require_match 'CPSLAgentChatClient' app/apple/herm/Models/CPSLChatModel.swift
require_match 'CPSLAgentChatClient\(config: config\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'actor CPSLAgentChatClient' app/apple/herm/Services/Agent/CPSLAgentChatClient.swift
require_match 'kind == \.applePCC' app/apple/herm/Services/Agent/CPSLAgentChatClient.swift
require_match 'CPSLAgentProviderSelection\.select' app/apple/herm/Services/Agent/CPSLAgentProviderSelection.swift
require_match 'static let pccModelID = "apple/pcc"' app/apple/herm/Services/Agent/CPSLAgentProviderSelection.swift
require_match 'CPSLPCCRuntime\.generated\.swift' app/apple/herm.xcodeproj/project.pbxproj
require_match 'generate-apple-pcc-runtime\.sh' app/apple/herm.xcodeproj/project.pbxproj
require_match 'let modelID: String' app/apple/herm/Models/CPSLChatModel+AgentRuntimeTypes.swift
require_match 'let client: CPSLAgentChatClient' app/apple/herm/Models/CPSLChatModel+AgentRuntimeTypes.swift
reject_match 'let client: CPSLOpenAIClient' app/apple/herm/Models/CPSLChatModel+AgentRuntimeTypes.swift
reject_match 'CPSLOpenAIClient\(config: config\)' app/apple/herm/Models/CPSLChatModel.swift
# Ensure no unguarded 27-only client file remains in the synchronized Agent folder.
if [[ -e app/apple/herm/Services/Agent/CPSLPCCClient.swift ]]; then
  echo "CPSLPCCClient.swift must not ship in Agent/ (PCC types are generated)" >&2
  exit 1
fi
require_match 'encodeNil\(forKey: \.content\)' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'name: "local_sandbox_exec"' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'name: "agent"' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'availableTools\(allowsSubagents' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'maxCompletionTokens = "max_completion_tokens"' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'CPSL, a Unix-like local environment' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'Luau is the command interface instead of Bash' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'only supported execution language' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'Never guess CPSL API signatures' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'fs\.help\(\)' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'Declare variables with local' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'external lua/luau interpreters' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'Bash, Python, shell commands' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'module\.help\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'CPSL is your execution environment: a Unix-like local environment' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Luau is the interface instead of Bash' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Luau essentials' app/apple/herm/Models/CPSLChatModel.swift
require_match 'CPSLOpenAIError\.provider' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'CPSLOpenAIError\.invalidToolCall' scripts/vet-apple-openai-protocol.swift
require_match 'validatedCompletion\(\)' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'toolChoice: streamRequest\.tools\.isEmpty \? nil : "auto"' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'stream: true' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'text/event-stream' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'HERM_VISION_MODEL' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'actor CPSLVisionClient' app/apple/herm/Services/Agent/CPSLOpenAIClient.swift
require_match 'cpsl_session_new_with_host_callbacks_v3' app/apple/herm/Services/CPSLDebugService.swift
require_match 'cpsl_vision_respond' app/apple/herm/Services/CPSLDebugService.swift
require_match 'evaluateLuau' app/apple/herm/Services/CPSLDebugService.swift
require_match 'currentVirtualDirectory' app/apple/herm/Services/CPSLDebugService.swift
require_match 'detachedEvaluations: \[CPSLEvalRaceBox\]' app/apple/herm/Services/CPSLDebugService.swift
require_match 'race\.finishDetachedEvaluation\(\)' app/apple/herm/Services/CPSLDebugService.swift
require_match 'cpsl_session_free\(request\.session\)' app/apple/herm/Services/CPSLDebugService.swift
reject_match 'iCloudMountManager\.(beginUpdate|finishUpdate)\(' app/apple/herm/Services/CPSLDebugService.swift
require_match 'CPSLICloudMountManager\.shared\(' app/apple/herm/Services/CPSLDebugService.swift
require_match 'guard beginUpdate\(\) else' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'activeReaderCount == 0' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match '!writerInProgress' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'beginSessionUse\(\)' app/apple/herm/Services/CPSLDebugService.swift
require_match 'beginReadUse\(for:' app/apple/herm/Services/CPSLDebugService.swift
require_match 'materializePinnedContent\(\)' app/apple/herm/Services/CPSLDebugService.swift
reject_match 'materializeMountsForAccess' \
  app/apple/herm/Services/CPSLDebugService.swift \
  app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'Download-on-demand' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'materializePinnedContent' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'async let mountsReady' app/apple/herm/Models/CPSLChatModel.swift
require_match 'async let conversationsReady' app/apple/herm/Models/CPSLChatModel.swift
require_match 'isLoadingConversations' app/apple/herm/Models/CPSLChatModel.swift
require_match 'CPSLConversationListPresentation' app/apple/herm/Models/CPSLConversationListPresentation.swift
require_match 'Loading conversations' app/apple/herm/Views/Chat/CPSLConversationDrawerView.swift
require_match 'CPSLFileSyncState' app/apple/herm/Services/CPSLICloudFileMaterializer.swift
require_match 'CPSLFileSyncStateBadge' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'accessMode: \.readWrite' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'Keep Downloaded' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'hasVisibleConversations' app/apple/herm/Models/CPSLConversationListPresentation.swift
require_match 'hasVisibleConversations: !sectionGroups\.isEmpty' app/apple/herm/Models/CPSLChatModel.swift
require_match 'prefetchSmallCloudFiles' app/apple/herm/Services/CPSLDebugService.swift
require_match 'beginReadUse\(for: prefetchPath\)' app/apple/herm/Services/CPSLDebugService.swift
require_match 'entry\.path == mount\.virtualPath' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'materializeFile\(at:' app/apple/herm/Services/CPSLDebugService.swift
require_match 'lifetimeToken: mountUseLease' app/apple/herm/Services/CPSLDebugService.swift
require_match 'withExtendedLifetime\(request\.lifetimeToken\)' app/apple/herm/Services/CPSLDebugService.swift
require_match 'sessionMountRevision != mountUseLease\.revision' app/apple/herm/Services/CPSLDebugService.swift
require_match 'resetSessionIfMountRevisionChanged' app/apple/herm/Services/CPSLDebugService.swift
require_match 'filePreviewLifetimeToken' app/apple/herm/Models/CPSLChatModel.swift
require_match 'result\.lifetimeToken' app/apple/herm/Models/CPSLChatModel.swift
require_match 'lifetimeToken: AnyObject\?' app/apple/herm/Models/CPSLTypes.swift
require_match 'activeFilePreviewRequestID' app/apple/herm/Models/CPSLChatModel.swift
require_match 'filePreviewLoadTask\?\.cancel\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'releaseGateRetainingScopes\(\)' app/apple/herm/Services/CPSLDebugService.swift
require_match 'if iCloudMountManager\.hasPreparedState' app/apple/herm/Services/CPSLDebugService.swift
require_match 'iCloudMounts = await service\.activeICloudMounts\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'revision &\+= 1' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'name: CPSLICloudMountStore\.didChangeNotification' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'forName: CPSLICloudMountStore\.didChangeNotification' app/apple/herm/Models/CPSLChatModel.swift
require_match 'refreshICloudMountsAfterChange\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match '"mode": mount\.accessMode\.rawValue' app/apple/herm/Services/CPSLDebugService.swift
require_match 'CPSLICloudMountStore\.load' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'CPSLICloudMountStore\.save' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'migrateLegacyRegistryIfNeeded' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'bookmarkData:' app/apple/herm/Models/CPSLICloudMount.swift
require_match 'hostURL: resolution\.url' app/apple/herm/Services/CPSLICloudMountManager.swift
require_match 'securityScopeAllowOnlyReadAccess' app/apple/herm/Services/CPSLICloudBookmarkAccess.swift
require_match 'options: \.minimalBookmark' app/apple/herm/Services/CPSLICloudBookmarkAccess.swift
require_match 'startAccessingSecurityScopedResource' app/apple/herm/Services/CPSLICloudBookmarkAccess.swift
require_match 'stopAccessingSecurityScopedResource' app/apple/herm/Services/CPSLICloudBookmarkAccess.swift
require_match 'mount\.accessMode\.promptDescription' app/apple/herm/Models/CPSLChatModel.swift
require_match 'startDownloadingUbiquitousItem' app/apple/herm/Services/CPSLICloudFileMaterializer.swift
require_match 'ubiquitousItemDownloadingStatus == \.current' app/apple/herm/Services/CPSLICloudFileMaterializer.swift
reject_match 'forUploading|coordinateFileRead|restoreMounts' \
  app/apple/herm/Services/CPSLICloudMountManager.swift \
  app/apple/herm/Models/CPSLICloudMount.swift
reject_match 'persistent staged copies|persistent iCloud Drive copy|changes do not sync back' \
  app/apple/herm/Models/CPSLChatModel.swift \
  app/apple/herm/Views/Files/CPSLFileBrowserView.swift \
  app/apple/herm/Views/Chat/CPSLChatScreen.swift
reject_match 'case \.copying' \
  app/apple/herm/Models/CPSLChatModel.swift \
  app/apple/herm/Views/Chat/CPSLChatScreen.swift
require_match 'func currentDirectory\(\) -> String' app/apple/herm/Services/CPSLDebugService.swift
require_match 'func availableSkills\(\) -> \[CPSLAgentSkill\]' app/apple/herm/Services/CPSLDebugService.swift
require_match 'restoreCurrentDirectory' app/apple/herm/Services/CPSLDebugService.swift
require_match 'shellDoubleQuoted' app/apple/herm/Services/CPSLDebugService.swift
require_match 'nonisolated enum CPSLSkillCatalog' app/apple/herm/Services/Agent/CPSLSkills.swift
require_match 'metadata.short-description' app/apple/herm/Services/Agent/CPSLSkills.swift
require_match 'systemSkillMounts' app/apple/herm/Services/Agent/CPSLSkills.swift
require_match '"skills"' app/apple/herm/Services/CPSLDebugService.swift
require_match '"virtual": mount.virtualPath' app/apple/herm/Services/CPSLDebugService.swift
require_match '"mode": "ro"' app/apple/herm/Services/CPSLDebugService.swift
require_match 'Copy Bundled Skills' app/apple/herm.xcodeproj/project.pbxproj
require_match 'SRCROOT.*/herm/Skills' app/apple/herm.xcodeproj/project.pbxproj
require_match 'UNLOCALIZED_RESOURCES_FOLDER_PATH.*/Skills' app/apple/herm.xcodeproj/project.pbxproj
require_match 'cp -R.*src.*dst' app/apple/herm.xcodeproj/project.pbxproj
require_match 'The following skills are available' app/apple/herm/Models/CPSLChatModel.swift
require_match '\$0\.path' app/apple/herm/Models/CPSLChatModel.swift
reject_match 'iCloudRestrictedSkillNames|Network access is disabled while these mounts are active' \
  app/apple/herm/Models/CPSLChatModel.swift
require_match 'let callbackBox = CPSLWebBrowserCallbackBox\(service: webBrowser\)' \
  app/apple/herm/Services/CPSLDebugService.swift
require_match 'let allowedDomains = \["\*"\]' app/apple/herm/Services/CPSLDebugService.swift
require_match 'do not use require to load them' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Skills are markdown instruction files' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Never require\("apple-context"\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'fs\.read\("/skills/apple-context/SKILL\.md"\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'print\(\) serializes tables as JSON' app/apple/herm/Models/CPSLChatModel.swift
require_match 'location\.status\(\) / location\.current\(\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'fs\.read its skill file path' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Skills are not require\(\)-able modules' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Do \*\*not\*\* `require\("apple-context"\)`' app/apple/herm/Skills/apple-context/SKILL.md
require_match 'here\.location\.latitude' app/apple/herm/Skills/apple-context/SKILL.md
require_match 'print\(here\)' app/apple/herm/Skills/apple-context/SKILL.md
require_match 'format_return_value' external/cpsl/core/src/sandbox.rs
require_match 'print_table_serialized_as_json' external/cpsl/core/src/sandbox/tests.rs
require_match 'help\(\).*authoritative module list' app/apple/herm/Skills/webbrowser/SKILL.md
require_match 'Treat CPSL as its own Luau ecosystem' app/apple/herm/Models/CPSLChatModel.swift
require_match 'APIs from other Lua/Luau environments' app/apple/herm/Models/CPSLChatModel.swift
require_match 'do not assign help output to a variable' app/apple/herm/Models/CPSLChatModel.swift
require_match 'external renderers' app/apple/herm/Models/CPSLChatModel.swift
require_match 'name: beautiful-pdfs' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'doc.renderFile' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'Do not call `require`' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'pdf-smoke.html' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'fs\.read\("/skills/beautiful-pdfs/print\.css"\)' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'fs\.write\("/tmp/report\.html", html\)' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'print\(fs\.exists\("/home/herm/report\.pdf"\)\)' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'platform not supported' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'no PDF was produced' app/apple/herm/Skills/beautiful-pdfs/SKILL.md
require_match 'name: image-vision' app/apple/herm/Skills/image-vision/SKILL.md
require_match 'mode = "vision"' app/apple/herm/Skills/image-vision/SKILL.md
require_match 'doc\.readAsync' app/apple/herm/Skills/image-vision/SKILL.md
require_match 'vision callback .* not available' app/apple/herm/Skills/image-vision/SKILL.md
require_match 'Never claim to have seen or analyzed' app/apple/herm/Skills/image-vision/SKILL.md
require_match 'target_os = "ios"' external/cpsl/modules/native-webview-pdf/src/lib.rs
require_match '@page' app/apple/herm/Skills/beautiful-pdfs/print.css
require_match 'Current CPSL directory' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'currentDirectory: sandboxDirectory' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'requestDirectory: sandboxDirectory' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'promptPathLiteral' app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
require_match 'localSandboxExec\(currentDirectory' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match '"language": "luau"' app/apple/herm/Services/CPSLDebugService.swift
require_match '"language": language' app/apple/herm/Services/CPSLDebugService.swift
require_match 'CPSLAgentToolFormatting\.providerContent' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'CPSLAgentToolFormatting\.displayBody' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'CPSLAgentToolFormatting\.agentInput' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'nonNegativeIntValue' app/apple/herm/Services/Agent/CPSLAgentConfig.swift
require_match 'Set\(object\.keys\)\.isSubset\(of: \["source", "intent"\]\)' app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
require_match 'unknown fields should not decode' scripts/vet-apple-agent-tool-formatting.swift
require_match 'agent tool input was not decoded' scripts/vet-apple-agent-tool-formatting.swift
require_match 'truncatedText' app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
require_match 'ffi_error' app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
require_match 'func selectConversation\(id: String\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'model\.selectConversation\(id: conversation\.id\)' app/apple/herm/Views/Chat/CPSLConversationDrawerView.swift
require_match 'isRunning = true' app/apple/herm/Models/CPSLChatModel.swift
require_match 'defer \{' app/apple/herm/Models/CPSLChatModel.swift
require_match 'typewriterTask = nil' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Provider returned an empty response' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'Reached maximum tool rounds' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'synthesizeAfterToolLimit' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'role: \.toolStatus' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'pendingFailures' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'supersedeActiveToolStatus' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'finishActiveToolStatus\(as: \.failed\)' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'as: \.interrupted' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'role: \.hidden' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'runSubAgent' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'makeConversationJSONTraceShareFile' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Share debug JSON' app/apple/herm/Views/Chat/CPSLChatScreen.swift
require_match 'struct CPSLProviderLoopContext' app/apple/herm/Models/CPSLChatModel+AgentRuntimeTypes.swift
require_match 'struct CPSLPendingConversationContext' app/apple/herm/Models/CPSLChatModel+AgentRuntimeTypes.swift
require_match 'let errorNode = try await context\.store\.appendNode' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'appendProviderLoopError' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'appendAgentError' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'persistStreamingAssistantIfNeeded' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'onParentIDChange\(context\.parentID\)' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'model: nil' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Task\.detached\(priority: \.utility\)' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Task\.detached\(priority: \.userInitiated\)' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'CPSLAgentRequestPreparationBuilder' app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift
require_match 'DispatchQueue\.global\(qos: \.userInitiated\)\.async' app/apple/herm/Services/CPSLDebugService.swift
require_match 'guard !Thread\.isMainThread else' app/apple/herm/Services/CPSLDebugService.swift
require_match 'CPSLAgentWorkingIndicatorView' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'CPSLAgentWorkingIndicatorView\(\)' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'Text\(payload\.summary\)' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'TimelineView\(\.animation\)' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'CPSLActivityDisplayItem\.items' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'expandedEntryIDs: expansion\.expandedEntryIDs' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match '#if DEBUG' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match '\.allowsHitTesting\(canExpand\)' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'CPSLHeightLimitedExpandedBlock' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
reject_match '\.disabled\(!canExpand\)' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'cycleDuration: TimeInterval = 0\.84' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
require_match 'dotBounceOffset' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
reject_match 'return trimmed\.isEmpty \? "Thinking" : trimmed' app/apple/herm/Views/Chat/CPSLChatTimelineView.swift
reject_match 'agentActivitySummary|setAgentActivitySummary|clearAgentActivitySummary' \
  app/apple/herm/Models/CPSLChatModel.swift \
  app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift \
  app/apple/herm/Views/Chat/CPSLChatTimelineView.swift

require_match 'static let home = "/home/herm"' app/apple/herm/Models/CPSLTypes.swift
require_match 'static let temporary = "/tmp"' app/apple/herm/Models/CPSLTypes.swift
require_match 'static let initialDirectory = home' app/apple/herm/Models/CPSLTypes.swift
require_match '"home/herm"' app/apple/herm/Services/CPSLDebugService.swift
require_match '"tmp"' app/apple/herm/Services/CPSLDebugService.swift
require_match '"etc"' app/apple/herm/Services/CPSLDebugService.swift
require_match '"initial_cwd": CPSLVirtualPath\.initialDirectory' app/apple/herm/Services/CPSLDebugService.swift
require_match '"virtual": "/"' app/apple/herm/Services/CPSLDebugService.swift
require_match '"virtual": CPSLVirtualPath\.iCloudRoot' app/apple/herm/Services/CPSLDebugService.swift
reject_match 'workdir|/workdir' \
  app/apple/herm/Services/CPSLDebugService.swift \
  app/apple/herm/Models/CPSLChatModel.swift \
  app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
  app/apple/herm/Views/Files/CPSLFileBrowserView.swift \
  app/apple/herm/Views/Chat/CPSLChatScreen.swift

require_match 'Use /home/herm as the default home' app/apple/herm/Models/CPSLChatModel.swift
require_match 'Use /home/herm for durable user-created files' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'other Unix-style directories under / remain available' app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift
require_match 'private func isBrowserPathAllowed' app/apple/herm/Models/CPSLChatModel.swift
require_match 'normalized == CPSLVirtualPath\.home' app/apple/herm/Models/CPSLChatModel.swift
require_match 'normalized\.hasPrefix.*CPSLVirtualPath\.home.*/' app/apple/herm/Models/CPSLChatModel.swift
require_match 'normalized == CPSLVirtualPath\.temporary' app/apple/herm/Models/CPSLChatModel.swift
require_match 'normalized\.hasPrefix.*CPSLVirtualPath\.temporary.*/' app/apple/herm/Models/CPSLChatModel.swift
require_match 'private struct CPSLFileLocationsView' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'title: "Home"' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'systemName: "house\.fill"' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'title: "Temporary"' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'title: "iCloud"' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'systemName: "icloud\.fill"' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'title: "Cloud Drives"' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'actionTitle: "Connect"' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'model\.dictation\.finish\(\)' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'guard isICloudImporterPending, !model\.dictation\.isActive else' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
reject_match 'isICloudAccessModePickerPresented|iCloud Folder Access' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'Make Read Only' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'Make Read & Write' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'CPSLICloudMountAccessBadge' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'iCloudMount\(containing: preview\.path\).*accessMode' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'iCloudMount\(containing: model\.browserPath\).*accessMode' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'try Task\.checkCancellation\(\)' app/apple/herm/Services/CPSLDictationService.swift
require_match 'await pendingStartTask\?\.value' app/apple/herm/Services/CPSLDictationService.swift
require_match 'await captureStopTask\.value' app/apple/herm/Services/CPSLDictationService.swift
require_match 'self\.state = \.idle' app/apple/herm/Services/CPSLDictationService.swift
require_match 'case googleDrive' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'case dropbox' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'case oneDrive' app/apple/herm/Views/Files/CPSLFileBrowserView.swift

require_match 'CPSLChatTimelineView' app/apple/herm/Views/Chat/CPSLChatScreen.swift
require_match 'private struct CPSLFileBrowserOverlay' app/apple/herm/Views/Chat/CPSLChatScreen.swift
require_match 'AnyTransition\.move\(edge: \.trailing\)\.combined\(with: \.opacity\)' app/apple/herm/Views/Chat/CPSLChatScreen.swift
require_match 'static let duration = 0\.2' app/apple/herm/Views/Chat/CPSLChatScreen.swift
require_match 'struct CPSLFileOverlayPanel' app/apple/herm/Views/Files/CPSLFileOverlayPanel.swift
require_match 'struct CPSLFileOverlayStage' app/apple/herm/Views/Files/CPSLFileOverlayPanel.swift
require_match 'dimOpacity: 0\.001' app/apple/herm/Views/Chat/CPSLChatScreen.swift

require_match 'func previewFile' app/apple/herm/Services/CPSLDebugService.swift
require_match 'case \.text:' app/apple/herm/Services/CPSLDebugService.swift
require_match 'case \.pdf:' app/apple/herm/Services/CPSLDebugService.swift
require_match 'textPreviewByteLimit = 1_000_000' app/apple/herm/Services/CPSLDebugService.swift
require_match 'filePreview = preview' app/apple/herm/Models/CPSLChatModel.swift
require_match 'func closeFilePreview' app/apple/herm/Models/CPSLChatModel.swift
require_match 'CPSLFilePreviewContentView\(preview: preview\)' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'struct CPSLFilePreviewHeaderTitle' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'model\.closeFilePreview\(\)' app/apple/herm/Views/Files/CPSLFileBrowserView.swift
require_match 'struct CPSLFilePreviewContentView' app/apple/herm/Views/Files/CPSLFilePreviewOverlay.swift
require_match 'CPSLTextFilePreview' app/apple/herm/Views/Files/CPSLFilePreviewOverlay.swift
require_match 'CPSLPDFFilePreview' app/apple/herm/Views/Files/CPSLFilePreviewOverlay.swift
reject_match 'isFullscreen|Full Screen|arrow\.up\.left\.and\.arrow\.down\.right|arrow\.down\.right\.and\.arrow\.up\.left' \
  app/apple/herm/Views/Files/CPSLFilePreviewOverlay.swift \
  app/apple/herm/Views/Files/CPSLFileOverlayPanel.swift \
  app/apple/herm/Views/Files/CPSLFileBrowserView.swift \
  app/apple/herm/Views/Chat/CPSLChatScreen.swift

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
  swift scripts/generate-apple-env-constants.swift "$tmp_env_dir/CPSLEnvConstantsEmpty.swift"
  require_match 'static let values: \[String: String\] = \[:\]' "$tmp_env_dir/CPSLEnvConstantsEmpty.swift"
fi

if command -v swiftc >/dev/null 2>&1; then
  # Stub PCC runtime for Linux / pre-27 SDK hosts so agent sources typecheck.
  HERM_FORCE_PCC_RUNTIME=0 bash scripts/generate-apple-pcc-runtime.sh
  swiftc -typecheck \
    scripts/vet-apple-agent-shared-types.swift \
    app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
    app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift
  swiftc -typecheck app/apple/herm/Services/Agent/CPSLAgentConfig.swift "$tmp_env_dir/CPSLEnvConstants.swift"
  swiftc app/apple/herm/Services/Agent/CPSLAgentConfig.swift scripts/vet-apple-agent-config.swift -o /tmp/herm-vet-agent-config
  /tmp/herm-vet-agent-config
  swiftc \
    scripts/vet-apple-agent-shared-types.swift \
    app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
    app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift \
    scripts/vet-apple-agent-tool-formatting.swift \
    -o /tmp/herm-vet-agent-tool-formatting
  /tmp/herm-vet-agent-tool-formatting
  swiftc \
    app/apple/herm/Services/Agent/CPSLAgentConfig.swift \
    scripts/vet-apple-agent-shared-types.swift \
    app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
    app/apple/herm/Services/Agent/CPSLOpenAIClient.swift \
    app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift \
    scripts/vet-apple-openai-protocol.swift \
    -o /tmp/herm-vet-openai-protocol
  /tmp/herm-vet-openai-protocol
  swiftc \
    scripts/vet-apple-agent-shared-types.swift \
    app/apple/herm/Services/Agent/CPSLAgentConfig.swift \
    app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
    app/apple/herm/Services/Agent/CPSLOpenAIClient.swift \
    app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift \
    app/apple/herm/Generated/CPSLPCCRuntime.generated.swift \
    app/apple/herm/Services/Agent/CPSLAgentProviderSelection.swift \
    app/apple/herm/Services/Agent/CPSLPCCMessageMapper.swift \
    scripts/vet-apple-agent-pcc.swift \
    -o /tmp/herm-vet-agent-pcc
  /tmp/herm-vet-agent-pcc
  swiftc -parse-as-library scripts/vet-apple-agent-concurrency-ui.swift -o /tmp/herm-vet-agent-concurrency-ui
  /tmp/herm-vet-agent-concurrency-ui
  swiftc \
    app/apple/herm/Models/CPSLICloudMount.swift \
    scripts/vet-apple-icloud-mounts.swift \
    -o /tmp/herm-vet-icloud-mounts
  /tmp/herm-vet-icloud-mounts
  swiftc \
    app/apple/herm/Services/CPSLICloudFileMaterializer.swift \
    scripts/vet-apple-icloud-materializer.swift \
    -o /tmp/herm-vet-icloud-materializer
  /tmp/herm-vet-icloud-materializer
  swiftc \
    app/apple/herm/Models/CPSLEvalTypes.swift \
    scripts/vet-apple-eval-race.swift \
    -o /tmp/herm-vet-eval-race
  /tmp/herm-vet-eval-race
  swiftc \
    app/apple/herm/Models/CPSLEvalTypes.swift \
    scripts/vet-apple-stop-control.swift \
    -o /tmp/herm-vet-stop-control
  /tmp/herm-vet-stop-control
  swiftc -parse-as-library \
    scripts/vet-apple-file-info-media-mainthread.swift \
    -o /tmp/herm-vet-file-info-media
  /tmp/herm-vet-file-info-media
  swiftc \
    app/apple/herm/Models/CPSLICloudMount.swift \
    app/apple/herm/Services/CPSLICloudBookmarkAccess.swift \
    app/apple/herm/Services/CPSLICloudFileMaterializer.swift \
    app/apple/herm/Services/CPSLICloudMountManager.swift \
    scripts/vet-apple-icloud-mount-manager.swift \
    -o /tmp/herm-vet-icloud-mount-manager
  /tmp/herm-vet-icloud-mount-manager
  swiftc \
    app/apple/herm/Models/CPSLConversationListPresentation.swift \
    scripts/vet-apple-bootstrap-loading.swift \
    -o /tmp/herm-vet-bootstrap-loading
  /tmp/herm-vet-bootstrap-loading
  swiftc \
    app/apple/herm/Services/CPSLICloudFileMaterializer.swift \
    scripts/vet-apple-icloud-sync-policy.swift \
    -o /tmp/herm-vet-icloud-sync-policy
  /tmp/herm-vet-icloud-sync-policy
  swiftc \
    app/apple/herm/Models/CPSLICloudMount.swift \
    app/apple/herm/Services/CPSLICloudBookmarkAccess.swift \
    app/apple/herm/Services/CPSLICloudFileMaterializer.swift \
    app/apple/herm/Services/CPSLICloudMountManager.swift \
    scripts/vet-apple-icloud-on-demand.swift \
    -o /tmp/herm-vet-icloud-on-demand
  /tmp/herm-vet-icloud-on-demand
  if [[ "$(uname -s)" == "Darwin" ]]; then
    swiftc \
      app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift \
      app/apple/herm/Models/CPSLTypes.swift \
      app/apple/herm/Services/Agent/CPSLAgentToolFormatting.swift \
      app/apple/herm/Services/Agent/CPSLConversationStore.swift \
      scripts/vet-apple-conversation-store.swift \
      -o /tmp/herm-vet-conversation-store
    /tmp/herm-vet-conversation-store
  fi
  swiftc -parse "$tmp_env_dir/CPSLEnvConstants.swift" "${swift_files[@]}"
fi

echo "apple agent integration checks passed"
