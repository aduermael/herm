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

Project model overrides may use canonical model IDs or old bare native model
IDs. Herm normalizes deterministic bare IDs to canonical IDs when it loads or
saves project config. Unknown or ambiguous project model values remain
round-trippable; at runtime Herm reports the configured model and the fallback
model instead of silently running a different default.

Legacy flat credential fields remain readable migration input:

- `anthropic_api_key` migrates to `deployments.anthropic-direct.api_key`.
- `openai_api_key` migrates to `deployments.openai-direct.api_key`.
- `grok_api_key` migrates to `deployments.grok-direct.api_key`.
- `openrouter_api_key` migrates to `deployments.openrouter.api_key`.
- `gemini_api_key` migrates to `deployments.gemini-direct.api_key`.
- `ollama_base_url` migrates to `deployments.ollama-local.base_url`.

Azure OpenAI uses `deployments.openai-azure.model_mappings` because the Azure
deployment name is the native model ID sent in the request path.

Example:

```json
{
  "config_version": 2,
  "active_model": "openai/gpt-4.1-2025-04-14",
  "deployments": {
    "openai-direct": {
      "api_key": "sk-..."
    },
    "openai-azure": {
      "api_key": "...",
      "endpoint": "https://example.openai.azure.com",
      "api_version": "2024-08-01-preview",
      "model_mappings": {
        "openai/gpt-4.1-2025-04-14": "gpt-41-prod"
      }
    },
    "openrouter": {
      "api_key": "sk-or-..."
    },
    "ollama-local": {
      "base_url": "http://localhost:11434"
    }
  }
}
```

Environment variables remain fallback input when config fields are empty:
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`,
`OPENROUTER_API_KEY`, `OLLAMA_BASE_URL`, `OPENAI_BASE_URL`, `XAI_BASE_URL`,
`OPENROUTER_BASE_URL`, `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`,
`AZURE_OPENAI_API_VERSION`, `VERTEX_PROJECT_ID`, `VERTEX_REGION`, and
`AWS_REGION`.

## Routing

Routing supports `routing.default`, `routing.providers[provider_id]`, and
`routing.models[canonical_model_id]`. Exact model routes override provider
routes for matching models. Provider and model rules are scoped: non-matching
models keep using automatic eligible deployment resolution unless an advanced
`routing.default` route is explicitly present in JSON. A matching model or
provider rule is authoritative. If it contains only one stage, Herm and langdag
do not append fallback stages from `routing.default`.

Provider route keys use canonical catalog provider IDs: `anthropic`, `openai`,
`google`, `xai`, `z-ai`, `openrouter`, and `ollama`. Legacy Herm names
`gemini` and `grok` are accepted as migration aliases for `google` and `xai`.

Each stage has weighted deployment choices and a retry count. Unknown
deployment IDs are invalid. Known but locally unavailable deployments produce
diagnostics without hiding canonical models that can still be served through
another deployment. Model-specific routes are also validated against catalog
offerings so an ineligible deployment, such as an Anthropic deployment for an
OpenAI canonical model, is reported before routing.

The normal Herm Routing tab manages only scoped provider/model rules. It shows
`No routing rules. Using default model provider/deployment.` when no scoped
rules exist, and it offers guided Add rule and Delete rule actions. Edit
`routing.default` directly in the global JSON config only when you deliberately
want to replace automatic deployment selection for every unmatched model.

Advanced JSON example with an explicit global default route:

```json
{
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
          "deployments": [{ "deployment_id": "openrouter", "weight": 100 }]
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

Automatic fallback only happens before output is emitted. If a stream has
already produced visible content, Herm surfaces the error instead of switching
deployments and mixing partial responses.

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

## Catalog Refresh

Herm loads model data from the langdag catalog in this order:

1. The embedded catalog bundled with langdag.
2. A best-effort background refresh from langdag's static catalog artifact.

Startup never blocks on the remote refresh, and Herm does not read or write
`~/.herm/model_catalog.json` during catalog startup. A stale local catalog file
therefore cannot override the bundled langdag snapshot. Invalid, stale, or
partially generated remote data cannot replace the in-memory startup catalog.
Users can disable refresh with `LANGDAG_MODEL_CATALOG_REFRESH=false`, point to
another catalog with `LANGDAG_MODEL_CATALOG_URL`, or adjust the fetch limit with
`LANGDAG_MODEL_CATALOG_TIMEOUT`.

## Usage And Cost

New assistant nodes store deployment-aware metadata in the existing node
`metadata` column: canonical model ID, offering ID, deployment ID, native model
ID, normalized usage, pricing snapshot, and optional provider-returned exact
cost. Historical display prefers exact provider cost when it exists. Otherwise
Herm uses the pricing snapshot saved with the response, so future catalog price
changes do not rewrite old session costs. Nodes created before this metadata
existed still load through provider/model/token fallback rules, with ambiguous
old native IDs reported as unknown rather than priced as zero.
