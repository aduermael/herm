# Deployment-Aware Model Catalog

**Goal:** Separate model identity, API protocol, provider ownership, and deployment/hosting so Herm can support new models served through already-supported APIs without shipping a new app build, while keeping pricing and cost tracking accurate when the same canonical model is served through different deployments.

**Readiness status:** V1 rollout completed through Phase 8. This plan is reopened for post-v1 feedback hardening in Phases 9-12; preserve Phases 0-8 as completed historical work. Phase 12 supersedes the Phase 10 JSON-first routing UX contract with scoped routing overrides and a simpler normal Routing tab. The original implementation did not need to preserve old langdag public APIs for external consumers; Herm is the only app consumer in this repo. Data compatibility for existing Herm configs, model catalog caches, and conversation DBs remains required.

**Execution note:** This plan is expected to change both Herm and the `external/langdag` submodule. Langdag changes should be made on the counterpart submodule branch `aduermael/deployment-provider-api-model`, committed inside `external/langdag`, and then recorded in Herm by updating the parent repo gitlink. Phase commits in Herm should include the relevant Herm changes, plan updates, and the updated langdag submodule pointer.

**Context:**

Herm currently treats models as `Provider + Model ID`. `cmd/herm/models.go` builds `ModelDef` values from langdag's provider-keyed catalog, filters them by configured providers, and uses `computeCost()` to price usage by model ID. `cmd/herm/config.go` stores `active_model` and `exploration_model` as bare model IDs, so a saved model ID becomes ambiguous once multiple deployments can serve the same canonical model. `cmd/herm/agent.go` builds a langdag client for one direct provider based on configured keys.

Langdag already has provider variants for direct Anthropic, Anthropic Vertex, Anthropic Bedrock, direct OpenAI, Azure OpenAI, Grok, direct Gemini, Gemini Vertex, OpenRouter, and Ollama. However, `external/langdag/internal/models/catalog.go` still stores pricing as `provider -> []model`, `external/langdag/internal/provider/provider.go` exposes `Models()` without deployment context, and `external/langdag/internal/provider/filter.go` derives server-tool support from hardcoded provider model lists. The existing runtime catalog refresh in `cmd/herm/wiring.go` fetches provider docs through langdag, but it cannot express deployment-specific native model IDs, deployment-specific pricing, user-configured Azure deployment names, or a new model served through an already-supported API before Herm ships again.

**Working vocabulary:**

- **Provider:** the organization that owns or publishes the model family, such as Anthropic, OpenAI, Google, or xAI.
- **API protocol:** the wire/protocol adapter used to call a model, such as Anthropic Messages, OpenAI Chat Completions, OpenAI Responses, or Gemini generateContent.
- **Deployment:** a concrete routeable hosting surface with its own auth, endpoint rules, native model IDs, capabilities, and pricing, such as Anthropic direct, Anthropic on Bedrock, Anthropic on Vertex, OpenAI direct, Azure OpenAI, Gemini direct, Gemini on Vertex, Grok direct, OpenRouter, or Ollama local.
- **Model:** the canonical model identity independent of where it is hosted.
- **Model offering:** a canonical model served by a deployment. This is the internal catalog unit langdag resolves to when a user targets a canonical model.

**Confirmed v1 deployment list:**

- `anthropic-direct`
- `anthropic-bedrock`
- `anthropic-vertex`
- `openai-direct`
- `openai-azure`
- `gemini-direct`
- `gemini-vertex`
- `grok-direct`
- `openrouter`
- `ollama-local`

**Resolved contract decisions:**

- Remote catalog v1 is data-only: delivered over HTTPS, strictly schema-validated, and backed by cached/embedded fallback. It can define providers, API protocols, deployments, canonical models, offerings, prices, capabilities, aliases, and provenance for known deployments/APIs, but it cannot define arbitrary endpoints, auth behavior, request templates, or new protocol behavior.
- Remote catalog refresh is enabled by default but non-blocking. Startup uses embedded or cached data immediately, refreshes in the background, and only replaces cache after validation. Users can opt out by config/env. Stale cache remains usable with diagnostics. Signing is deferred for v1 while the catalog remains data-only and restricted to known deployment/API IDs.
- V1 includes catalog-known deployments backed by existing langdag adapters, plus local Ollama discovery. Arbitrary user-defined deployments are deferred.
- Canonical IDs are owner-qualified and deployment-independent, for example `openai/gpt-4.1-2025-04-14`.
- Deployment IDs identify route surfaces, for example `openai-direct`, `openai-azure`, and `anthropic-bedrock`.
- Offering IDs are `deployment_id:native_model_id`. Code must split on the first colon only because some native IDs contain colons.
- `native_model_id` is the exact string passed to the adapter for the selected deployment attempt.
- Azure OpenAI requires deployment-scoped `model_mappings` because Azure uses the user's deployment name as the request path segment. Direct OpenAI and Azure OpenAI are separate deployments.
- Users target canonical models. Langdag resolves a canonical model to an eligible deployment/native model using configured deployment credentials, deployment-scoped mappings, routing policy, retry, fallback, and capability requirements.
- Herm keeps user-facing `active_model` and `exploration_model`, but they store canonical model IDs going forward. Old native model IDs are migrated deterministically when possible.
- Deployment credentials, deployment-scoped `model_mappings`, and routing policy are global-only in v1. Project config can override active/exploration canonical models and non-secret behavior only. Project-scoped routing is out of scope.
- Normal routing rules are scoped overrides. `routing.models[canonical_model_id]` applies only to matching canonical models, `routing.providers[provider_id]` applies only to matching model-owner providers, and non-matching models use automatic eligible deployment resolution as if no routing rule existed. `routing.default` remains an advanced JSON-only override for users who deliberately want to replace the automatic baseline, but it is not part of the normal Routing tab flow.
- Routing stages are ordered. Each stage has weighted deployment choices and a retry count. Deployments that cannot serve the selected canonical model are skipped, so an OpenRouter-only model can jump directly to an eligible OpenRouter stage.
- Automatic fallback only happens before any output is streamed/saved. If partial stream output has already been emitted, v1 surfaces the error instead of silently switching deployments.
- Model picker remains canonical-model centric with one row per canonical model. Deployment details are hidden by default and available as diagnostics. Price display shows an exact price, a route-dependent range, `unknown`, or `partial`.
- Capability state is tri-state: `supported`, `unsupported`, `unknown`. Unknown server-tool capability means do not send server tools by default, and carry a diagnostic.
- Pricing state is tri-state plus free: `known`, `partial`, `unknown`, `free`. Unknown pricing must not display as `$0`. Partial pricing computes known dimensions and reports missing dimensions. Zero/free pricing is only shown when explicitly represented as zero/free.
- Catalog pricing is the upfront comparison and fallback estimate source. If a provider/deployment API returns exact per-response billable cost, that provider-returned cost is the accounting source of truth for that response. This must be audited per API because many providers only return usage counters, not exact synchronous dollar cost.
- New assistant nodes store resolved identity and pricing snapshots in typed metadata using the existing `metadata` column first. Add public/helper structs so this is not ad hoc JSON. Dedicated DB columns can follow later if query needs justify them.
- Langdag's unified usage model should preserve all billable usage dimensions a provider returns, including cached input, cache creation/write, output, reasoning/thought tokens, tool-use prompt tokens, modality-specific token details, service tier, built-in tool usage, and an extensible dimensions map.
- Cost calculation returns a structured result, not just `float64`, with status, total, currency, missing dimensions, source, and per-dimension breakdown.
- The catalog JSON is normalized, but in-memory catalog loading should compile indexes and pointer links for easy navigation.

**Catalog v1 shape:**

```json
{
  "schema_version": "model-catalog/v1",
  "generated_at": "2026-05-15T00:00:00Z",
  "stale_after": "2026-06-14T00:00:00Z",
  "providers": {},
  "api_protocols": {},
  "deployments": {},
  "models": {},
  "offerings": []
}
```

Example offering:

```json
{
  "id": "anthropic-bedrock:anthropic.claude-sonnet-4-20250514-v1:0",
  "canonical_model_id": "anthropic/claude-sonnet-4-20250514",
  "deployment_id": "anthropic-bedrock",
  "native_model_id": "anthropic.claude-sonnet-4-20250514-v1:0",
  "capabilities": {
    "server_tools": { "web_search": "supported" }
  },
  "pricing": {
    "status": "known",
    "currency": "USD",
    "rates_per_1m": {
      "input_tokens": 3.0,
      "output_tokens": 15.0
    }
  }
}
```

In-memory indexes:

- `ProvidersByID`
- `ProtocolsByID`
- `DeploymentsByID`
- `ModelsByID`
- `OfferingsByID`
- `OfferingsByCanonicalModel`
- `OfferingsByDeployment`

**Herm config v2 shape:**

```json
{
  "config_version": 2,
  "active_model": "openai/gpt-4.1-2025-04-14",
  "exploration_model": "anthropic/claude-haiku-4-5",
  "deployments": {
    "openai-direct": {
      "api_key": "...",
      "base_url": ""
    },
    "openai-azure": {
      "api_key": "...",
      "endpoint": "https://example.openai.azure.com",
      "api_version": "2024-08-01-preview",
      "model_mappings": {
        "openai/gpt-4.1-2025-04-14": "my-gpt-4-1-prod"
      }
    },
    "openrouter": {
      "api_key": "...",
      "base_url": ""
    },
    "ollama-local": {
      "base_url": "http://localhost:11434"
    }
  },
  "routing": {
    "default": [
      {
        "deployments": [{ "deployment_id": "openrouter", "weight": 100 }],
        "retries": 1
      }
    ],
    "providers": {
      "openai": [
        {
          "deployments": [
            { "deployment_id": "openai-direct", "weight": 70 },
            { "deployment_id": "openai-azure", "weight": 30 }
          ],
          "retries": 1
        },
        {
          "deployments": [{ "deployment_id": "openrouter", "weight": 100 }],
          "retries": 1
        }
      ]
    },
    "models": {
      "openai/gpt-4.1-2025-04-14": [
        {
          "deployments": [{ "deployment_id": "openai-azure", "weight": 100 }],
          "retries": 2
        }
      ]
    }
  }
}
```

**Assistant-node metadata v1 shape:**

```json
{
  "model_resolution": {
    "canonical_model_id": "openai/gpt-4.1-2025-04-14",
    "offering_id": "openai-direct:gpt-4.1-2025-04-14",
    "deployment_id": "openai-direct",
    "provider_id": "openai",
    "api_protocol_id": "openai-chat-completions",
    "native_model_id": "gpt-4.1-2025-04-14"
  },
  "pricing_snapshot": {
    "status": "known",
    "currency": "USD",
    "effective_at": "2026-05-15T00:00:00Z",
    "source": "catalog",
    "rates_per_1m": {
      "input_tokens": 2.0,
      "output_tokens": 8.0,
      "cache_read_input_tokens": 0.5
    }
  }
}
```

If an API returns exact per-response billable cost, store it alongside the usage and pricing snapshot with a source such as `provider_response`. Historical display should prefer exact provider cost over catalog-derived estimates for that response.

**Failure modes to cover:**

- Remote catalog unavailable, stale, invalid, or partially generated.
- Catalog knows a deployment, but local credentials or external cloud auth are unavailable.
- Same canonical model exists in multiple deployments with different native model IDs or prices.
- Azure OpenAI mapping is absent for a canonical model that the selected route wants to use.
- Existing Herm config stores only old native model IDs.
- Existing conversation history contains nodes created before deployment metadata existed.
- Provider adapters serve a new model through an existing API before Herm ships again.
- Pricing is missing, stale, effective only after a future date, partial, or explicitly free.
- Provider responses include usage/cost dimensions the current unified usage struct does not preserve.
- Provider exposes aggregate billing APIs, but does not return exact per-response dollar cost synchronously.
- Server-tool capability data is unknown for an otherwise callable model.
- A stream fails after partial output was emitted.

**Success criteria:**

- Langdag exposes deployment-aware model offerings with stable IDs, canonical model metadata, native model IDs, API protocol, deployment, capabilities, pricing, and update provenance.
- Herm can target and run a newly published canonical model from a refreshed langdag catalog when at least one eligible deployment uses an already-supported API and locally available credentials.
- Herm cost display, traces, and session history price usage by served deployment/offering rather than model ID alone.
- Provider-returned exact per-response cost is used when available; otherwise Herm uses provider-returned usage counters plus the served offering's pricing snapshot.
- Existing configs and conversations continue to load, with deterministic migration/fallback behavior for ambiguous old model IDs.
- Network failures fall back to cached or embedded catalog data without blocking startup.
- Tests prove direct/Bedrock/Vertex/Azure/OpenRouter/Ollama ambiguity is handled explicitly.
- Routing can express provider-level and model-level scoped policies with ordered fallback stages, weighted deployment choice within a stage, and retry counts, while non-matching models continue to use automatic eligible deployment resolution. Advanced JSON config can still express `routing.default` for users who deliberately want a global baseline override.
- Live session costs are computed from actual response usage/cost metadata and deployment-specific pricing rules, while the model list remains a simple comparison view.

---

## Phase 0: Lock compatibility fixtures and current behavior
- [x] 0a: Add golden fixtures for old Herm global config, old project config, old provider-keyed model catalog cache, and old conversation nodes with only provider/model/token fields.
- [x] 0b: Add tests documenting current active/exploration model loading, smart defaults, model picker availability, and basic model-ID cost behavior before replacing those paths.
- [x] 0c: Add fixtures for ambiguous old native model IDs, unambiguous old native model IDs, OpenRouter models, Ollama offline models, and Azure mappings.
- [x] 0d: Record per-phase test commands for langdag and Herm so execution does not defer validation to the final phase.

Phase validation commands:

- Herm: `go test ./...`
- Langdag: `(cd external/langdag && go test ./...)`
- Compatibility targeted smoke: `go test ./cmd/herm -run 'Test(Old|Smart|ModelPicker|Ollama|OpenRouter|Azure)' -count=1`
- Compatibility targeted langdag smoke: `(cd external/langdag && go test ./internal/models ./internal/conversation ./internal/storage/sqlite -run 'Test.*(Old|Compatibility|Legacy)' -count=1)`

## Phase 1: Define catalog, config, routing, pricing, and persistence contracts
- [x] 1a: Document the provider/API protocol/deployment/model/offering vocabulary in langdag docs and map current langdag provider variant names to the new concepts.
- [x] 1b: Define the exact `CatalogV1` Go structs and JSON schema, including stable ID rules, provenance, aliases, stale/freshness metadata, tri-state capability metadata, tri-state pricing metadata, and compatibility loading for old provider-keyed catalog caches.
- [x] 1c: Define provider, API protocol, deployment, canonical model, and offering examples for all confirmed v1 deployments: Anthropic direct/Bedrock/Vertex, OpenAI direct/Azure, Gemini direct/Vertex, Grok direct, OpenRouter, and Ollama local.
- [x] 1d: Define the deployment/adapter binding table: `deployment_id`, `provider_id`, `api_protocol_id`, adapter constructor, credential requirements, native model ID source, and whether native IDs are catalog-known, discovered, or user-configured.
- [x] 1e: Define Herm config v2 structs, global-only deployment credentials, deployment-scoped `model_mappings`, env var fallback behavior, old flat credential field loading, and project/global merge rules.
- [x] 1f: Define routing structs and validation rules for `routing.default`, `routing.providers`, and `routing.models`, including override precedence, no implicit cascade from overrides to default, weighted stages, retries, missing deployments, and unavailable deployments.
- [x] 1g: Define canonical-model migration rules for old `active_model` and `exploration_model` values: canonical match, unique native/offering match, ambiguous match diagnostic, and smart-default fallback.
- [x] 1h: Define usage and cost structs, including common usage fields, extensible usage dimensions, provider-returned exact cost metadata, structured cost result status, missing dimensions, free/zero pricing, partial pricing, unknown pricing, currency, and display rules.
- [x] 1i: Audit supported provider APIs to determine which can return exact per-response billable cost versus only usage counters; record source-of-truth behavior per deployment.
- [x] 1j: Define typed assistant-node metadata structs for model resolution, normalized usage, pricing snapshot, and optional provider-returned exact cost. Use the existing node `metadata` column first.
- [x] 1k: Define model picker semantics: one canonical-model row, provider owner column, exact/range/partial/unknown price display, hidden route diagnostics, and behavior with one configured deployment.
- [x] 1l: Add schema and resolver golden tests for catalog validation, catalog compile/indexing, old catalog compatibility, old config migration, routing selection, and cost-result status.

Phase validation commands:

- Herm: `go test ./...`
- Langdag: `(cd external/langdag && go test ./...)`
- Catalog/config contract smoke: `go test ./cmd/herm -run 'Test(DeploymentAware|RoutingPolicy|StoredModelID|Old|Smart|ModelPicker|Ollama|OpenRouter|Azure|Catalog|Compute|Assistant)' -count=1`
- Langdag contract smoke: `(cd external/langdag && go test ./internal/models ./types -run 'Test(Catalog|DeploymentBindings|NormalizedUsage|ComputeCost|AssistantNode)' -count=1)`

## Phase 2: Make langdag's catalog deployment-aware
- [x] 2a: Replace `external/langdag/internal/models/catalog.go` and exported catalog aliases in `external/langdag/langdag.go` with the deployment-aware catalog model, removing or replacing old provider-keyed public APIs as needed for Herm.
- [x] 2b: Implement catalog JSON loading, strict validation, save behavior, normalized-to-indexed in-memory compile, pointer links, and diagnostics for dropped offerings.
- [x] 2c: Implement compatibility loading for old embedded/provider-keyed catalog JSON and old cache files into the new canonical/offering shape.
- [x] 2d: Update `external/langdag/internal/models/update.go` and `external/langdag/internal/models/providers.go` so fetched provider data populates canonical models and model offerings rather than provider model lists.
- [x] 2e: Add curated/generated deployment-specific catalog entries for all confirmed v1 deployments, including Azure placeholders that require user `model_mappings`, OpenRouter dynamic/aggregator behavior, and Ollama local placeholders.
- [x] 2f: Update the langdag `models` CLI in `external/langdag/internal/cli/models.go` to display canonical models and offerings by deployment/API/provider/model and expose the deployment-aware JSON shape.
- [x] 2g: Add tests for catalog schema validation, in-memory indexes, stale data diagnostics, provider-keyed cache migration, OpenRouter scope, Ollama placeholders, and Azure mapping-required offerings.

## Phase 3: Preserve usage, pricing snapshots, and served identity
- [x] 3a: Extend langdag `types.Usage`, storage-facing structs, SDK structs, REST/OpenAPI types, and provider mappings so all billable usage dimensions returned by supported APIs are preserved.
- [x] 3b: Add provider-response exact cost support where APIs expose it, with clear source metadata and fallback to catalog-derived estimates when exact cost is unavailable.
- [x] 3c: Add typed model-resolution, normalized-usage, pricing-snapshot, and optional exact-cost metadata to `CompletionResponse`, stream done events, assistant node metadata, traces where applicable, and SDK/REST surfaces.
- [x] 3d: Update conversation save paths so new assistant nodes store canonical model ID, offering ID, deployment ID, provider ID, API protocol ID, native model ID, pricing snapshot, normalized usage, and exact provider cost when available.
- [x] 3e: Add old-node fallback behavior for nodes with only provider/model/token fields, including explicit ambiguous/unknown behavior.
- [x] 3f: Replace Herm's `computeCost()` float-only behavior with a structured cost result that can represent known, partial, unknown, and free costs with a per-dimension breakdown.
- [x] 3g: Add tests for usage dimension preservation, exact provider-cost precedence, catalog-estimate fallback, missing pricing, zero/free pricing, stale pricing, partial pricing, cache-token pricing, and old-node cost fallback.

Phase validation commands:

- Herm: `go test ./...`
- Langdag: `(cd external/langdag && go test ./...)`
- Langdag Go SDK: `(cd external/langdag/sdks/go && GOWORK=off GOCACHE=/private/tmp/herm-gocache go test ./...)`

## Phase 4: Bind deployments, canonical resolution, and routing to adapters
- [x] 4a: Update langdag provider construction in `external/langdag/langdag.go` and `external/langdag/internal/config/config.go` so deployment IDs resolve to existing API adapters and required local configuration.
- [x] 4b: Redefine internal provider/adapter naming so model owner provider IDs and deployment route IDs are not conflated in diagnostics, routing, filtering, or saved metadata.
- [x] 4c: Implement canonical-model resolution before adapter execution: select an eligible offering per attempt, copy the request with `native_model_id`, call the adapter, and attach served metadata.
- [x] 4d: Update routing and fallback behavior in `external/langdag/internal/provider/router.go` so routing stages select weighted eligible deployments, retry a stage, fall through to the next explicit stage, and skip deployments that cannot serve the canonical model.
- [x] 4e: Enforce v1 stream failure semantics: automatic fallback only before any output is emitted/saved; partial stream errors are surfaced without switching deployments.
- [x] 4f: Move server-tool filtering from hardcoded provider `Models()` lists to catalog-backed offering capability metadata, with safe unknown-capability behavior and a local-discovery fallback for Ollama.
- [x] 4g: Add tests for direct/Bedrock/Vertex native ID resolution, Azure `model_mappings`, OpenRouter-only model routing, model/provider/default route override precedence, weighted selection, retries, missing credentials, missing mappings, unknown capabilities, and partial stream failure.

## Phase 5: Publish and refresh catalog data without app updates
- [x] 5a: Choose the remote distribution path for the catalog, preferring a static langdag-hosted JSON artifact generated by automation unless a server is needed for a concrete requirement.
- [x] 5b: Add langdag support for embedded-or-cache-first startup, background remote refresh, timeout handling, opt-out/configurable endpoint behavior, cache TTL/staleness diagnostics, and strict schema validation before cache replacement.
- [x] 5c: Add automation in the langdag submodule to refresh the catalog from source data on a schedule, validate it, and publish the artifact only when the new catalog passes compatibility checks.
- [x] 5d: Add provenance and freshness reporting so Herm can show or log whether model data came from embedded, cached, or remote catalog data without making startup noisy.
- [x] 5e: Add tests for remote success, opt-out, timeout, invalid schema, stale cache fallback, embedded fallback, partial generated remote data, and cache replacement only after validation.

## Phase 6: Teach Herm to consume canonical models and deployment-aware metadata
- [x] 6a: Update `cmd/herm/models.go` so Herm renders canonical models from langdag's deployment-aware catalog while retaining route/offering/deployment metadata for availability, diagnostics, and pricing display.
- [x] 6b: Update provider filtering and configured-provider detection in `cmd/herm/config.go` so model availability is based on deployment credential requirements, `model_mappings`, and local discovery rather than direct provider API-key fields.
- [x] 6c: Update model selection, smart defaults, and exploration model resolution so Herm stores canonical model IDs, migrates old model-only config values deterministically, and lets langdag resolve deployments.
- [x] 6d: Update `cmd/herm/agent.go` and related client-switching paths so targeted canonical models are sent to langdag with the current global routing policy instead of preselecting a Herm-side provider.
- [x] 6e: Update `cmd/herm/tree.go`, `cmd/herm/agentui.go`, trace aggregation, `/usage`, and session history so live and historical cost display uses the structured cost result, exact provider cost when present, and pricing snapshots otherwise.
- [x] 6f: Update the model picker so it remains canonical-model centric, shows owner provider and exact/range/partial/unknown prices, and exposes route/deployment diagnostics only when useful.
- [x] 6g: Add Herm tests for canonical picker rows, old active/exploration migration, smart defaults, OpenRouter-only availability, Ollama offline behavior, Azure mappings, route-dependent price ranges, exact provider-cost display, and old-node history cost fallback.

## Phase 7: Add deployment configuration and global routing UX
- [x] 7a: Extend Herm config to read/write config v2 with global deployment credentials, non-secret deployment parameters, deployment-scoped `model_mappings`, and global routing policy.
- [x] 7b: Preserve legacy flat credential fields as readable input for migration, but write new deployment config shape on save.
- [x] 7c: Add a deployment config surface that starts simple for one configured deployment and reveals global fallback/routing controls only after multiple eligible deployments exist.
- [x] 7d: Add global routing config UI for default, provider-level, and model-level route stages, weighted deployment choices, and retry count per stage.
- [x] 7e: Validate routing config against currently configured deployments and canonical model availability, gracefully flagging unavailable deployments without hiding canonical models that remain callable through another deployment.
- [x] 7f: Add tests for one-deployment UI behavior, two-deployment routing controls, provider/model override behavior, no cascade to default from overrides, weighted-stage parsing, retry validation, Azure mapping validation, and availability changing when deployment credentials are added or removed.

## Phase 8: End-to-end rollout and docs
- [x] 8a: Add langdag integration tests that exercise dynamic catalog refresh, canonical-model targeting, deployment resolution, provider fallback, retry, exact cost when mocked, pricing snapshot persistence, and metadata persistence with mock providers.
- [x] 8b: Add Herm integration tests for startup with embedded-only catalog, cached catalog, refreshed remote catalog, migrated old model config, old conversation DBs, changing deployment credentials, and route-specific model selection.
- [x] 8c: Update docs and examples in Herm and langdag to describe deployments, canonical model selection, global routing, fallback stages, credentials, Azure `model_mappings`, OpenRouter, Ollama, pricing accuracy, and the catalog refresh lifecycle.
- [x] 8d: Verify existing smart-default behavior still chooses sensible active and exploration canonical models when multiple deployments can serve the same model.
- [x] 8e: Run the relevant langdag and Herm test suites after each phase and record any intentionally deferred gaps.

Phase validation commands:

- Herm: `go test ./...` - pass
- Langdag: `(cd external/langdag && go test ./...)` - pass
- Langdag Go SDK: `(cd external/langdag/sdks/go && GOWORK=off GOCACHE=/private/tmp/herm-gocache go test ./...)` - pass
- Deferred gaps: none recorded for v1 rollout.

## Phase 9: Rebaseline post-v1 feedback and regressions
- [x] 9a: Capture the routing config complexity feedback and define the new Routing tab contract as read-mostly: a simple generated explanation, a pretty JSON preview of the `routing` object, capped preview height with an ellipsis when truncated, diagnostics, and one advanced edit key.
- [x] 9b: Capture the Project config active-model regression as blocking: a project `active_model` such as `claude-opus-4-6` must resolve to the same canonical model used by the header and agent runtime, never silently fall back to `claude-sonnet-4-6`.
- [x] 9c: Add failing regression coverage before implementation for routing preview rendering, routing explanation generation, routing JSON truncation, advanced JSON edit entry, project/global model merge behavior, bare-to-canonical model migration, and startup/runtime model agreement.
- [x] 9d: Record targeted baseline validation commands and the current failures for the feedback scope.

Phase 9 rebaseline notes:

- Routing tab contract: the normal Routing tab is read-mostly. It must show a short explanation that routing is global, model routes override provider routes, provider routes override the default route, overrides do not implicitly cascade, stages are tried in order, deployment choices are weighted, and retries apply per stage. It must show a pretty JSON preview of only the `routing` object, never deployment credentials or secrets. Long previews are capped and end with `...` plus a remaining-line indicator. Existing diagnostics remain visible below the preview, capped. The normal tab exposes one advanced edit entry/key only: `Ctrl+E=edit global JSON`.
- Routing UI regression baseline: the current UI still renders editable fields such as `Default Route`, `OpenAI Route`, model route rows, and the route mini-language help line. Phase 10 must remove those primary controls and satisfy the read-mostly preview/explanation contract.
- Project active-model regression baseline: a project `active_model` saved as a bare native ID such as `claude-opus-4-6` currently remains bare after project load/merge. Phase 11 must normalize it to `anthropic/claude-opus-4-6` wherever possible so startup display, config context, `startAgent`, exploration/compact paths, traces, and saved metadata all use the same resolved canonical model.

Phase 9 baseline validation results:

- `go test ./cmd/herm -run 'Test(BuildConfigRows|Routing|ProjectConfig|ResolveActiveModel|ModelChange|StartAgent|DeploymentAware)' -count=1` - intentionally fails on the new Phase 9 tests: `TestBuildConfigRowsRoutingReadOnlyPreviewContract`, `TestRoutingJSONPreviewTruncatesLongPolicies`, `TestRoutingAdvancedJSONEditKeyIsOnlyRoutingEditEntry`, `TestProjectConfigBareModelMigrationKeepsOpusOverride`, `TestResolveActiveModelProjectBareOverrideBeatsGlobalAndSmartDefault`, and `TestStartAgentStartupAndRuntimeUseProjectBareCanonicalModel`.
- `go test ./...` - intentionally fails on the same new `cmd/herm` Phase 9 regression tests. No separate non-Phase-9 failure was identified in this run.

Phase validation commands:

- Herm targeted config/routing smoke: `go test ./cmd/herm -run 'Test(BuildConfigRows|Routing|ProjectConfig|ResolveActiveModel|ModelChange|StartAgent|DeploymentAware)' -count=1`
- Herm full suite: `go test ./...`

## Phase 10: Replace routing form controls with a concise JSON-first view
- [x] 10a: Remove the normal Routing tab's custom per-route editing fields and route mini-language from the primary UI; keep routing setup positioned as an advanced global-only feature.
- [x] 10b: Render a deterministic plain-English explanation from the current routing policy, covering precedence, default/provider/model overrides, fallback stages, weighted choices, retries, and the empty-routing case without implying that most users need to configure it.
- [x] 10c: Render only the `routing` JSON object as pretty JSON, never secrets or deployment credentials, with a stable max line count and an ellipsis or remaining-line indicator when the preview is too tall.
- [x] 10d: Add an advanced key on the Routing tab that opens the global config JSON file for editing, handles unsaved drafts deliberately, reloads valid edits, and reports invalid JSON without clobbering the existing in-memory config.
- [x] 10e: Keep existing routing diagnostics visible below the explanation and preview, capped so they do not dominate the config screen.
- [x] 10f: Add tests for empty routing, simple default routing, provider/model override summaries, multi-stage fallback summaries, weighted/retry display, preview truncation, diagnostics, editor key dispatch, editor failure, and malformed JSON reload behavior.

Phase validation commands:

- Herm routing UI smoke: `go test ./cmd/herm -run 'Test(BuildConfigRowsRouting|RoutingSummary|RoutingJSONPreview|RoutingEditor|RoutingDiagnostics)' -count=1`
- Herm config editor suite: `go test ./cmd/herm -run 'Test(BuildConfigRows|HandleConfigByte|ConfigEditor|Routing)' -count=1`
- Herm full suite: `go test ./...`

## Phase 11: Make project active-model overrides authoritative
- [x] 11a: Fix project config load, migration, merge, and save paths so project `active_model` and `exploration_model` overrides are preserved and normalized to the matching canonical model when possible, including bare native IDs such as `claude-opus-4-6`.
- [x] 11b: Ensure project config cannot introduce deployment credentials, routing policy, or other global-only secret/deployment state, while still using effective global deployments to validate and display model availability.
- [x] 11c: Make startup model display, config header/context display, `startAgent`, compact/exploration paths, traces, and saved assistant metadata all use the same resolved effective project/global model IDs.
- [x] 11d: When a configured project model is unavailable or ambiguous, surface an explicit diagnostic that names the configured model and the fallback model instead of silently displaying or running another Anthropic default.
- [x] 11e: Add tests for project `claude-opus-4-6` resolving to `anthropic/claude-opus-4-6`, invalid project model fallback diagnostics, project save/load round trips, unknown-but-catalog-valid IDs, old bare IDs, global hint display, and no accidental global credential or routing overwrite.
- [x] 11f: Update docs or config help text to state that routing/deployments are global-only in v1 and project config may override active/exploration models plus non-secret behavior only.

Phase validation commands:

- Herm project config smoke: `GOCACHE=/private/tmp/herm-gocache go test ./cmd/herm -run 'Test(ProjectConfig|ResolveActiveModel|ModelChange|StartAgent|DeploymentAwareCompatibility|HermCatalog|ProjectModel)' -count=1` - pass
- Herm routing/project regression smoke: `GOCACHE=/private/tmp/herm-gocache go test ./cmd/herm -run 'Test(BuildConfigRows|Routing|ProjectConfig|ResolveActiveModel|ModelChange|StartAgent|DeploymentAware|ProjectModel)' -count=1` - pass
- Herm full suite: `GOCACHE=/private/tmp/herm-gocache go test ./...` - pass
- Langdag regression check: `(cd external/langdag && GOCACHE=/private/tmp/herm-gocache go test ./...)` - pass

## Phase 12: Make routing overrides scoped and simplify the normal UI
- [x] 12a: Add regression coverage for scoped routing semantics: provider/model rules apply only to matching canonical models, non-matching models remain visible and use automatic eligible deployment resolution, explicit advanced `routing.default` still works when present, and missing default routes no longer produce no-effective-route diagnostics.
- [x] 12b: Update Herm availability and routing diagnostics so configured provider/model routes filter only matching models; unmatched models fall back to the same automatic eligible deployment set used when no routing policy is configured.
- [x] 12c: Update langdag deployment routing so a model with no matching model/provider rule falls back to automatic eligible deployment stages, while preserving explicit `routing.default` behavior for advanced JSON configs.
- [x] 12d: Simplify the normal Routing tab to show the empty state `No routing rules. Using default model provider/deployment.`, a concise scoped-rule summary, Add rule and Delete rule actions, and no default-route step. Keep `routing.default` available only through direct JSON editing for advanced use cases.
- [x] 12e: Define the guided Add rule flow for provider/model rules: choose scope, choose provider or canonical model, choose primary deployment, choose optional fallback deployment, review, and save to the existing routing schema without exposing the route mini-language.
- [x] 12f: Update docs and config help text to state that normal routing rules are scoped by provider/model, non-matching models resolve automatically, and `routing.default` is advanced JSON-only.

Phase 12 decision notes:

- Scoped overrides are the product contract: routing should affect a model only when that model matches a configured model or provider rule.
- The normal Routing tab should not require or teach a default route. Automatic eligible deployment resolution is the default behavior.
- `routing.default` can remain in the JSON schema for advanced users who deliberately edit config directly, but it is not a backward-compatibility constraint for the normal UX.
- A matching scoped rule remains authoritative for its matching model/provider scope. If it cannot serve the selected model, surface diagnostics clearly rather than silently routing around the rule; unrelated models must still be callable through automatic deployment resolution.

Phase validation commands:

- Herm routing smoke: `GOCACHE=/private/tmp/herm-gocache go test ./cmd/herm -run 'Test(BuildConfigRowsRouting|Routing|DeploymentAware|ConfigModels|ScopedRouting)' -count=1` - pass
- Langdag routing smoke: `(cd external/langdag && GOCACHE=/private/tmp/herm-gocache go test ./internal/provider ./internal/api ./internal/cli -run 'TestDeploymentRouter.*Routing|TestDeploymentRouter.*Default|TestDeploymentRouter.*Eligible|TestDeploymentRouterScoped|TestDeploymentRouterExplicit|TestAPIRoutingPolicyPreservesExplicitEmptyDefault|TestConvertRoutingStagesPreservesExplicitEmptyDefault' -count=1)` - pass
- Herm full suite: `GOCACHE=/private/tmp/herm-gocache go test ./...` - pass
- Langdag full suite: `(cd external/langdag && GOCACHE=/private/tmp/herm-gocache go test ./...)` - pass
- End-of-phase systematic review: 3 xhigh agents reviewed Herm routing/UI, langdag routing, and tests/docs/plan consistency. Findings were addressed before completion: explicit empty default preservation, truthful default-route UI copy, provider-rule candidate filtering, model-scope coverage, model Add rule coverage, and advanced-default documentation labeling.

---

**Deferred post-v1 questions:**

- Should the remote catalog be signed if it grows beyond data-only metadata for known deployments?
- Which arbitrary user-defined deployments should be supported after v1, and how should user-owned pricing/capability metadata be validated?
- Should project-scoped routing be added if users ask for it?
- Should frequently queried model-resolution metadata move from typed node metadata into dedicated DB columns?
