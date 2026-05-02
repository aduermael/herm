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
- **Model offering:** a model served by a deployment. This is the unit Herm should display, select, route, and price.

**Contract direction:**

Langdag should own the catalog schema, remote refresh, deployment metadata, provider adapter binding, and compatibility helpers. Herm should consume a list of model offerings from langdag, store stable offering/deployment identifiers in config, and compute cost from the exact offering that served a request. Herm can keep UI copy concise, but internally it should stop assuming that a model ID alone identifies pricing or routing.

**Failure modes to cover:**

- Remote catalog unavailable, stale, invalid, or partially generated.
- Catalog knows a deployment, but local credentials or external cloud auth are unavailable.
- Same canonical model exists in multiple deployments with different native model IDs or prices.
- Existing Herm config stores only model IDs from before this change.
- Provider adapters serve a new model through an existing API before Herm ships again.
- Pricing is missing, stale, or effective only after a future date.
- Server-tool capability data is missing for an otherwise callable model.
- Conversation history contains nodes created before deployment metadata existed.

**Success criteria:**

- Langdag exposes deployment-aware model offerings with stable IDs, canonical model metadata, native model IDs, API protocol, deployment, capabilities, pricing, and update provenance.
- Herm can select and run a newly published model offering from a refreshed langdag catalog when the offering uses an already-supported API and locally available credentials.
- Herm cost display, traces, and session history price usage by served deployment/offering rather than model ID alone.
- Existing configs and conversations continue to load, with deterministic migration/fallback behavior for ambiguous old model IDs.
- Network failures fall back to cached or embedded catalog data without blocking startup.
- Tests prove direct/Bedrock/Vertex/Azure style pricing ambiguity is handled explicitly.

---

## Phase 1: Define the catalog and identity contract
- [ ] 1a: Document the model/provider/API/deployment/offering vocabulary in the plan-facing langdag docs and map current langdag provider names to the new concepts.
- [ ] 1b: Define the versioned catalog contract in langdag, including stable offering IDs, canonical model IDs, native model IDs, API protocol IDs, deployment IDs, provider IDs, capability metadata, pricing metadata, provenance, and compatibility behavior for the current provider-keyed catalog.
- [ ] 1c: Decide the compatibility rules for old Herm config values that store only `active_model` and `exploration_model`, including deterministic selection when a model ID appears in multiple offerings.
- [ ] 1d: Decide the unknown-capability policy for new catalog entries so server tools are not incorrectly stripped or incorrectly sent when a model is callable but capability metadata is absent.

## Phase 2: Make langdag's catalog deployment-aware
- [ ] 2a: Update `external/langdag/internal/models/catalog.go`, `external/langdag/langdag.go`, and catalog tests so langdag loads, validates, saves, and exports the deployment-aware catalog while still accepting the current embedded provider-keyed shape.
- [ ] 2b: Update `external/langdag/internal/models/update.go` and `external/langdag/internal/models/providers.go` so fetched provider data populates canonical models and model offerings rather than only provider model lists.
- [ ] 2c: Add deployment-specific catalog entries for the provider variants already implemented in langdag, covering at least Anthropic direct, Anthropic Bedrock, Anthropic Vertex, OpenAI direct, Azure OpenAI, Gemini direct, Gemini Vertex, Grok direct, and Ollama/local placeholders.
- [ ] 2d: Add catalog merge and validation behavior for embedded, cached, and remote data, including stale data handling, schema-version checks, and clear diagnostics when an offering is dropped.
- [ ] 2e: Update the langdag `models` CLI in `external/langdag/internal/cli/models.go` to display offerings by deployment/API/provider/model and expose the deployment-aware JSON shape.

## Phase 3: Bind deployments to langdag provider adapters
- [ ] 3a: Update langdag provider construction in `external/langdag/langdag.go` and `external/langdag/internal/config/config.go` so a deployment ID can resolve to an existing API adapter and its required local configuration.
- [ ] 3b: Extend langdag completion and stream metadata so responses and saved nodes can record the actual deployment/offering that served the request in addition to the provider and model fields that already exist.
- [ ] 3c: Move model capability lookup for server-tool filtering from hardcoded provider `Models()` lists toward catalog-backed offering metadata, with a safe fallback for locally discovered providers like Ollama.
- [ ] 3d: Update routing and fallback behavior in `external/langdag/internal/provider/router.go` so routing can preserve the served deployment/offering in metadata when fallback changes the actual host.
- [ ] 3e: Add tests for selecting the same canonical Anthropic model through direct, Bedrock, and Vertex deployments and verifying that the request uses the deployment-native model ID.

## Phase 4: Publish and refresh catalog data without app updates
- [ ] 4a: Choose the remote distribution path for the catalog, preferring a static langdag-hosted JSON artifact generated by automation unless a server is needed for a concrete requirement.
- [ ] 4b: Add langdag support for loading the remote catalog with cache-first startup semantics, background refresh, timeout handling, and opt-out/configurable endpoint behavior.
- [ ] 4c: Add automation in the langdag submodule to refresh the catalog from source data on a schedule, validate it, and publish the artifact only when the new catalog passes compatibility checks.
- [ ] 4d: Add provenance and freshness reporting so Herm can show or log whether model data came from embedded, cached, or remote catalog data without making startup noisy.
- [ ] 4e: Add tests for remote success, remote timeout, invalid remote schema, stale cache fallback, and embedded fallback.

## Phase 5: Teach Herm to consume model offerings
- [ ] 5a: Update `cmd/herm/models.go` so `ModelDef` represents a model offering with deployment/API/provider/canonical model fields and prices from langdag's deployment-aware catalog.
- [ ] 5b: Update provider filtering and configured-provider detection in `cmd/herm/config.go` so availability is based on deployment credential requirements rather than only direct provider API-key fields.
- [ ] 5c: Update model selection, smart defaults, and exploration model resolution so Herm stores and resolves stable offering IDs while migrating old model-only config values deterministically.
- [ ] 5d: Update `cmd/herm/agent.go` and related client-switching paths so selecting a model offering creates or reuses a langdag client for that offering's deployment.
- [ ] 5e: Update the model picker and config editor so users can distinguish model, deployment, API, provider, price, and context without crowding the menu.

## Phase 6: Price usage by served offering
- [ ] 6a: Update Herm cost calculation in `cmd/herm/models.go`, `cmd/herm/tree.go`, `cmd/herm/agentui.go`, and trace aggregation so cost lookup uses served offering/deployment metadata when available.
- [ ] 6b: Extend pricing metadata to cover cache read/write, reasoning, and deployment-specific price variants without assuming Anthropic direct cache pricing applies to every Anthropic-compatible deployment.
- [ ] 6c: Add backward-compatible cost fallback for old nodes that have provider/model but no deployment/offering metadata, including an explicit ambiguous/unknown behavior.
- [ ] 6d: Add tests where the same canonical model has different direct, Bedrock, and Vertex prices and verify session cost, tree cost, and trace cost use the served offering.
- [ ] 6e: Add tests for missing pricing, zero pricing, stale pricing, and cache-token pricing differences by deployment.

## Phase 7: End-to-end compatibility and rollout
- [ ] 7a: Add langdag integration tests that exercise dynamic catalog refresh, deployment selection, provider fallback, and metadata persistence with mock providers.
- [ ] 7b: Add Herm integration tests for startup with embedded-only catalog, cached catalog, refreshed remote catalog, and migrated old model config.
- [ ] 7c: Update docs and examples in Herm and langdag to describe deployments, model offerings, custom/openAI-compatible endpoints, and the catalog refresh lifecycle.
- [ ] 7d: Verify the existing smart-defaults behavior still chooses sensible active and exploration offerings when multiple deployments can serve the same canonical model.
- [ ] 7e: Run the relevant langdag and Herm test suites and record any intentionally deferred gaps.

---

**Open questions:**

- Should the remote catalog be signed, checksum-pinned, or simply schema-validated with HTTPS and an embedded fallback?
- Should arbitrary user-defined deployments be supported through Herm config immediately, or should the first pass cover catalog-known deployments plus existing local Ollama discovery?
- Should pricing history be stored per node so old conversations keep the price that was current at generation time, or should historical displays use the latest catalog with a visible caveat?
- How should Herm present credential setup for dynamic deployments whose auth is external to Herm, such as AWS Bedrock and Google Vertex?
- Should langdag expose both canonical model IDs and deployment-native model IDs to callers, or keep native IDs internal except in diagnostics?
