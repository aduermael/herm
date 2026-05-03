# Deployment-Aware Model Catalog

**Goal:** Separate model identity, API protocol, provider ownership, and deployment/hosting so Herm can support new models served through already-supported APIs without shipping a new app build, while keeping pricing and cost tracking accurate when the same model is served through different deployments.

**Context:**

Herm currently treats models as `Provider + Model ID`. `cmd/herm/models.go` builds `ModelDef` values from langdag's catalog, filters them by configured providers, and uses `computeCost()` to price usage by model ID. `cmd/herm/config.go` stores only `active_model` and `exploration_model`, so a saved model ID becomes ambiguous once multiple deployments can serve the same canonical model. `cmd/herm/agent.go` builds a langdag client for one direct provider based on configured keys.

Langdag already has provider variants for direct Anthropic, Anthropic Vertex, Anthropic Bedrock, direct OpenAI, Azure OpenAI, Grok, direct Gemini, Gemini Vertex, and Ollama. However, `external/langdag/internal/models/catalog.go` still stores pricing as `provider -> []model`, `external/langdag/internal/provider/provider.go` exposes `Models()` without deployment context, and `external/langdag/internal/provider/filter.go` derives server-tool support from hardcoded provider model lists. The existing runtime catalog refresh in `cmd/herm/wiring.go` fetches provider docs through langdag, but it cannot express deployment-specific model IDs, deployment-specific pricing, or a new deployment that uses an existing API protocol.

**Working vocabulary:**

- **Provider:** the organization that owns or publishes the model family, such as Anthropic, OpenAI, Google, or xAI.
- **API:** the wire/protocol adapter used to call a model, such as Anthropic Messages, OpenAI Chat Completions, OpenAI Responses, or Gemini generateContent.
- **Deployment:** a concrete routeable hosting surface with its own auth, endpoint rules, native model IDs, capabilities, and pricing, such as Anthropic direct, Anthropic on Bedrock, Anthropic on Vertex, OpenAI direct, Azure OpenAI, Gemini direct, Gemini on Vertex, Grok direct, or Ollama local.
- **Model:** the canonical model identity independent of where it is hosted.
- **Model offering:** a model served by a deployment. This is the internal catalog unit langdag resolves to when a user targets a canonical model.

**Contract direction:**

Langdag should own the catalog schema, remote refresh, deployment metadata, provider adapter binding, canonical-model-to-deployment resolution, fallback, retry, and compatibility helpers. Herm should let users target canonical models, configure deployment credentials and global routing policy, and compute cost from the exact resolved deployment/offering that served a request. Herm can keep UI copy concise, but internally it should stop assuming that a model ID alone identifies pricing or routing.

**Resolved decisions:**

- Remote catalog v1 is data-only: delivered over HTTPS, strictly schema-validated, and backed by cached/embedded fallback. It can define model offerings, prices, capabilities, aliases, and metadata for known deployments/APIs, but it cannot define arbitrary endpoints, auth behavior, request templates, or new protocol behavior.
- V1 supports catalog-known deployments backed by existing langdag adapters, plus local Ollama discovery. Arbitrary user-defined deployments are deferred until the deployment contract is stable.
- New assistant nodes should store the resolved deployment/model identity and pricing snapshot used at generation time so historical costs remain stable.
- Model lists should show simple input/output pricing for comparison, but live and historical accounting should use the provider-returned usage counters for each response plus the resolved deployment's pricing snapshot. The displayed model-list prices are not the accounting source of truth.
- Langdag's unified usage model should preserve all billable usage dimensions a provider returns, including cached input, cache creation/write, output, reasoning/thought tokens, tool-use prompt tokens, modality-specific tokens, service tier, and built-in tool usage where applicable.
- Users target canonical models. Langdag resolves a canonical model to an eligible deployment/native model using configured deployment credentials, global routing policy, retry, fallback, and capability requirements.
- Herm should expose deployment credentials and non-secret parameters as first-class config. Model availability is derived from configured/valid deployment credentials.
- Fallback policy is global for v1. It is an ordered list of stages; each stage can contain one deployment with 100% weight or several deployments with weighted selection, plus a retry count before falling through to the next stage.
- Herm's config UI should stay progressive: with one configured deployment, do not expose routing complexity; once a second deployment is configured, show the simplest useful global routing/fallback controls.

**Failure modes to cover:**

- Remote catalog unavailable, stale, invalid, or partially generated.
- Catalog knows a deployment, but local credentials or external cloud auth are unavailable.
- Same canonical model exists in multiple deployments with different native model IDs or prices.
- Existing Herm config stores only model IDs from before this change.
- Provider adapters serve a new model through an existing API before Herm ships again.
- Pricing is missing, stale, or effective only after a future date.
- Provider responses include usage token types the current unified `Usage` struct does not preserve.
- A provider exposes aggregate billing APIs, but does not return exact per-response dollar cost synchronously.
- Server-tool capability data is missing for an otherwise callable model.
- Conversation history contains nodes created before deployment metadata existed.

**Success criteria:**

- Langdag exposes deployment-aware model offerings with stable IDs, canonical model metadata, native model IDs, API protocol, deployment, capabilities, pricing, and update provenance.
- Herm can target and run a newly published canonical model from a refreshed langdag catalog when at least one eligible deployment uses an already-supported API and locally available credentials.
- Herm cost display, traces, and session history price usage by served deployment/offering rather than model ID alone.
- Existing configs and conversations continue to load, with deterministic migration/fallback behavior for ambiguous old model IDs.
- Network failures fall back to cached or embedded catalog data without blocking startup.
- Tests prove direct/Bedrock/Vertex/Azure style pricing ambiguity is handled explicitly.
- Global routing can express ordered fallback stages, weighted deployment choice within a stage, and retry counts.
- Live session costs are computed from actual response usage counters and deployment-specific pricing rules, while the model list remains a simple input/output price comparison view.

---

## Phase 1: Define the catalog and identity contract
- [ ] 1a: Document the model/provider/API/deployment/offering vocabulary in the plan-facing langdag docs and map current langdag provider names to the new concepts.
- [ ] 1b: Define the versioned catalog contract in langdag, including stable offering IDs, canonical model IDs, native model IDs, API protocol IDs, deployment IDs, provider IDs, capability metadata, pricing metadata, provenance, and compatibility behavior for the current provider-keyed catalog.
- [ ] 1c: Define compatibility rules for old Herm config values that store only `active_model` and `exploration_model`, mapping them to canonical model IDs and letting langdag apply global deployment routing.
- [ ] 1d: Define the unknown-capability policy for new catalog entries so server tools are not incorrectly stripped or incorrectly sent when a model is callable but capability metadata is absent.
- [ ] 1e: Define the global routing policy schema: ordered fallback stages, weighted deployments within each stage, retry count per stage, and validation rules for missing or invalid deployments.

## Phase 2: Make langdag's catalog deployment-aware
- [ ] 2a: Update `external/langdag/internal/models/catalog.go`, `external/langdag/langdag.go`, and catalog tests so langdag loads, validates, saves, and exports the deployment-aware catalog while still accepting the current embedded provider-keyed shape.
- [ ] 2b: Update `external/langdag/internal/models/update.go` and `external/langdag/internal/models/providers.go` so fetched provider data populates canonical models and model offerings rather than only provider model lists.
- [ ] 2c: Add deployment-specific catalog entries for the provider variants already implemented in langdag, covering at least Anthropic direct, Anthropic Bedrock, Anthropic Vertex, OpenAI direct, Azure OpenAI, Gemini direct, Gemini Vertex, Grok direct, and Ollama/local placeholders.
- [ ] 2d: Add catalog merge and validation behavior for embedded, cached, and remote data, including stale data handling, schema-version checks, and clear diagnostics when an offering is dropped.
- [ ] 2e: Update the langdag `models` CLI in `external/langdag/internal/cli/models.go` to display offerings by deployment/API/provider/model and expose the deployment-aware JSON shape.

## Phase 3: Bind deployments and routing to langdag provider adapters
- [ ] 3a: Update langdag provider construction in `external/langdag/langdag.go` and `external/langdag/internal/config/config.go` so a deployment ID can resolve to an existing API adapter and its required local configuration.
- [ ] 3b: Extend langdag completion and stream metadata so responses and saved nodes can record the actual deployment/offering that served the request in addition to the provider and model fields that already exist.
- [ ] 3c: Move model capability lookup for server-tool filtering from hardcoded provider `Models()` lists toward catalog-backed offering metadata, with a safe fallback for locally discovered providers like Ollama.
- [ ] 3d: Update routing and fallback behavior in `external/langdag/internal/provider/router.go` so global fallback stages can choose among weighted deployments, retry a stage, fall through to the next stage, and preserve the served deployment/offering in metadata.
- [ ] 3e: Add canonical-model resolution so callers provide a canonical model ID and langdag maps it to an eligible deployment-native model ID using configured credentials, capability requirements, and global routing policy.
- [ ] 3f: Add tests for targeting the same canonical Anthropic model through direct, Bedrock, and Vertex deployments and verifying that langdag chooses the expected deployment-native model ID.

## Phase 4: Publish and refresh catalog data without app updates
- [ ] 4a: Choose the remote distribution path for the catalog, preferring a static langdag-hosted JSON artifact generated by automation unless a server is needed for a concrete requirement.
- [ ] 4b: Add langdag support for loading the remote catalog with cache-first startup semantics, background refresh, timeout handling, and opt-out/configurable endpoint behavior.
- [ ] 4c: Add automation in the langdag submodule to refresh the catalog from source data on a schedule, validate it, and publish the artifact only when the new catalog passes compatibility checks.
- [ ] 4d: Add provenance and freshness reporting so Herm can show or log whether model data came from embedded, cached, or remote catalog data without making startup noisy.
- [ ] 4e: Add tests for remote success, remote timeout, invalid remote schema, stale cache fallback, and embedded fallback.

## Phase 5: Teach Herm to consume model offerings
- [ ] 5a: Update `cmd/herm/models.go` so Herm can render canonical models from langdag's deployment-aware catalog while retaining resolved offering/deployment metadata for availability, diagnostics, and pricing.
- [ ] 5b: Update provider filtering and configured-provider detection in `cmd/herm/config.go` so model availability is based on deployment credential requirements rather than only direct provider API-key fields.
- [ ] 5c: Update model selection, smart defaults, and exploration model resolution so Herm stores canonical model IDs and lets langdag resolve deployments, while migrating old model-only config values deterministically.
- [ ] 5d: Update `cmd/herm/agent.go` and related client-switching paths so targeted canonical models are sent to langdag with the current deployment routing policy instead of preselecting a Herm-side deployment.
- [ ] 5e: Update the model picker so it remains model-centric by default, while exposing deployment availability and resolved-route diagnostics only when useful.

## Phase 6: Add deployment configuration and global routing UX
- [ ] 6a: Extend Herm config to store deployment credentials and non-secret parameters for catalog-known deployments, including direct API keys, cloud credential selectors, endpoints, regions, project IDs, and local Ollama URLs as applicable.
- [ ] 6b: Add a deployment config surface that starts simple for one configured deployment and reveals global fallback/routing controls only after multiple eligible deployments exist.
- [ ] 6c: Add global routing config with ordered stages, weighted deployment choices within each stage, and retry count per stage.
- [ ] 6d: Validate routing config against currently configured deployments, gracefully ignoring or flagging unavailable deployments without hiding canonical models that remain callable through another deployment.
- [ ] 6e: Add tests for one-deployment UI behavior, two-deployment routing controls, weighted-stage parsing, retry validation, and model availability changing when deployment credentials are added or removed.

## Phase 7: Price usage by served offering
- [ ] 7a: Audit and extend langdag's unified usage model, storage, SDK structs, and provider mappings so all billable usage counters returned by supported APIs are preserved, including cached input, cache creation/write, output, reasoning/thought tokens, tool-use prompt tokens, modality-specific token details, service tier, and built-in tool usage where applicable.
- [ ] 7b: Update the catalog pricing model so each deployment offering can define rates for the usage dimensions it bills, while preserving simple input/output prices for model-list display.
- [ ] 7c: Update Herm cost calculation in `cmd/herm/models.go`, `cmd/herm/tree.go`, `cmd/herm/agentui.go`, and trace aggregation so live cost is computed from actual provider-returned usage counters plus served offering/deployment pricing metadata.
- [ ] 7d: Store resolved deployment/model identity, raw normalized usage counters, and pricing snapshots on new assistant nodes so historical cost displays do not change when the remote catalog changes.
- [ ] 7e: Add backward-compatible cost fallback for old nodes that have provider/model but no deployment/offering metadata, including an explicit ambiguous/unknown behavior.
- [ ] 7f: Add tests where the same canonical model has different direct, Bedrock, and Vertex prices and verify session cost, tree cost, and trace cost use the served offering.
- [ ] 7g: Add tests for missing pricing, zero pricing, stale pricing, missing usage dimensions, and cache-token pricing differences by deployment.

## Phase 8: End-to-end compatibility and rollout
- [ ] 8a: Add langdag integration tests that exercise dynamic catalog refresh, canonical-model targeting, deployment resolution, provider fallback, retry, and metadata persistence with mock providers.
- [ ] 8b: Add Herm integration tests for startup with embedded-only catalog, cached catalog, refreshed remote catalog, migrated old model config, and changing deployment credentials.
- [ ] 8c: Update docs and examples in Herm and langdag to describe deployments, canonical model selection, global routing, fallback stages, credentials, and the catalog refresh lifecycle.
- [ ] 8d: Verify the existing smart-defaults behavior still chooses sensible active and exploration canonical models when multiple deployments can serve the same model.
- [ ] 8e: Run the relevant langdag and Herm test suites and record any intentionally deferred gaps.

---

**Deferred questions:**

- Should the remote catalog be signed later if it grows beyond data-only metadata for known deployments?
- What is the exact minimal config format for each deployment's credentials and non-secret parameters?
- Which arbitrary user-defined deployments should be supported after v1, and how should user-owned pricing/capability metadata be validated?
