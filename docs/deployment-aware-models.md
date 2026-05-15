# Deployment-Aware Models

Herm stores user-facing model choices as canonical model IDs, such as
`openai/gpt-4.1-2025-04-14`. Langdag resolves that canonical ID to an eligible
deployment and native model ID at call time.

## Config V2

Deployment-aware config uses `config_version: 2`, top-level `active_model` and
`exploration_model`, global `deployments`, and global `routing`. Project config
can override active/exploration model and non-secret behavior only. Deployment
credentials, deployment-scoped `model_mappings`, and routing are global-only.
Existing non-secret global settings such as model sort preferences, turn limits,
personality, history limits, debug mode, and thinking remain top-level config
fields and are preserved during migration.

Legacy flat credential fields remain readable migration input:

- `anthropic_api_key` migrates to `deployments.anthropic-direct.api_key`.
- `openai_api_key` migrates to `deployments.openai-direct.api_key`.
- `grok_api_key` migrates to `deployments.grok-direct.api_key`.
- `openrouter_api_key` migrates to `deployments.openrouter.api_key`.
- `gemini_api_key` migrates to `deployments.gemini-direct.api_key`.
- `ollama_base_url` migrates to `deployments.ollama-local.base_url`.

Azure OpenAI uses `deployments.openai-azure.model_mappings` because the Azure
deployment name is the native model ID sent in the request path.

## Routing

Routing supports `routing.default`, `routing.providers[provider_id]`, and
`routing.models[canonical_model_id]`. Exact model routes override provider
routes, provider routes override the default route, and overrides are
authoritative. If a model or provider route contains only one stage, Herm and
langdag do not append fallback stages from the default route.

Provider route keys use canonical catalog provider IDs: `anthropic`, `openai`,
`google`, `xai`, `z-ai`, `openrouter`, and `ollama`. Legacy Herm names
`gemini` and `grok` are accepted as migration aliases for `google` and `xai`.

Each stage has weighted deployment choices and a retry count. Unknown
deployment IDs are invalid. Known but locally unavailable deployments produce
diagnostics without hiding canonical models that can still be served through
another deployment. Model-specific routes are also validated against catalog
offerings so an ineligible deployment, such as an Anthropic deployment for an
OpenAI canonical model, is reported before routing.

## Migration

Old saved model IDs migrate in this order:

1. If the value is already a canonical model ID in the catalog, keep it.
2. If it uniquely matches one canonical model through native/offering IDs, use
   that canonical model.
3. If it matches multiple canonical models, record an ambiguity diagnostic and
   use the smart default.
4. If it cannot be mapped, record a diagnostic and use the smart default.

## Model Picker

The picker shows one row per canonical model. The owner provider is shown as a
column, while deployment/offering details remain hidden until diagnostics are
needed. Price display is exact when every eligible route has the same known
price, a range when eligible deployments differ, partial when only some billed
dimensions are known, unknown when no reliable estimate exists, and free only
when zero pricing is explicitly represented. With one configured deployment,
diagnostics stay out of the way unless that deployment cannot serve the selected
canonical model.
