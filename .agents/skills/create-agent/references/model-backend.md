# Model backend

How the generated instance reaches its model. The agent supports three
routes from `AGENT_SRC_REF` v0.3.2 (`MODEL_*` settings, simple-coding-agent
#164); older refs ignore `MODEL_*` and require `META_API_KEY`. The LiteLLM
route needs no agent code beyond v0.3.2 (simple-coding-agent #171).

## Choosing the route

Ask for the model in step 1 and recommend the route from its family:

| Model | Route | Why |
|---|---|---|
| `muse-*` (e.g. `muse-spark-1.3-contributor`) | **LiteLLM gateway** (recommended) | Meta's prompt cache needs a `prompt_cache_key` affinity key, which Meta's Messages endpoint rejects. LiteLLM translates to Meta's Responses API and derives the key from Claude Code's `session_id`. Measured in simple-coding-agent #169: ~0% cache reuse direct, ~86–99% through the gateway. |
| `muse-*`, direct | Meta (template default) | Still works, but without cache reuse every turn pays full input price. Use only if the user has no gateway or asks for it. |
| `claude-*` | Anthropic API directly | Claude Code speaks the Anthropic API natively; no gateway. |
| anything else | the user's decision | No tested setup exists. Don't recommend a route; ask for the base URL, auth mode, credential and whether it goes through the gateway. |

If an existing instance (`agent-instances/agent-*/.env`, else
`../simple-coding-agent-env/agent-*/.env`) already uses the chosen route,
take its settings from there (step 5); otherwise ask the user for the values
the route needs.

## Settings per route

Keep unused `MODEL_*` keys commented, never present but empty: an empty
`MODEL_BASE_URL` selects the Anthropic API, an empty `MODEL_AUTH_MODE` fails
startup. `MODEL_API_KEY`, when set, takes precedence over `META_API_KEY`.

- **Meta direct**: `META_API_KEY` only, all `MODEL_*` commented out.
- **Anthropic direct**: `MODEL_BASE_URL=` (empty on purpose),
  `MODEL_AUTH_MODE=api_key`, `MODEL_API_KEY=sk-ant-...`, and `MODEL_NAME` as a
  full model ID, not an alias.
- **LiteLLM gateway**: uncomment the template's LiteLLM block:

  ```dotenv
  COMPOSE_FILE=compose.yaml:compose.litellm.yaml
  GATEWAY_NETWORK=<the gateway's external network>
  MODEL_BASE_URL=http://litellm:4000
  MODEL_AUTH_MODE=auth_token
  MODEL_API_KEY=<the gateway's LITELLM_MASTER_KEY>
  MODEL_NAME=<a model_name route in the gateway's config.yaml>
  ```

  and write `compose.litellm.yaml` from `assets/compose.litellm.yaml.template`
  (no placeholders). `META_API_KEY` stays empty: the provider key lives only
  in the gateway.

### LiteLLM details

- The gateway is separate infrastructure (its own compose project). This
  skill never starts or configures it; it only joins its network. `litellm`
  in `MODEL_BASE_URL` is the gateway's alias on that network.
- `GATEWAY_NETWORK` comes from the env file, never hard-coded. Take it from
  an instance that already uses the gateway on the same host, or ask. On the
  target Docker context, `docker network ls` shows whether it exists; if it
  doesn't, the gateway isn't running there.
- `COMPOSE_FILE` in the env file makes every `docker compose` command in the
  instance directory load both files, so the build, start and debug commands
  don't change. Compose also reads it from a file given with `--env-file`.
- `MODEL_NAME` must equal the gateway route exactly. The model the gateway
  reports back must match too; otherwise the agent classes the run as
  `infrastructure_error`.
- When copying from a source instance, carry `COMPOSE_FILE` and
  `GATEWAY_NETWORK` together with the `MODEL_*` keys, and still generate
  `compose.litellm.yaml` from the template.
- Alternative configuration: to keep `.env` on another backend, put the
  LiteLLM settings in `.env.litellm` with `AGENT_ENV_FILE=.env.litellm`, and
  run every command with `--env-file .env.litellm` (step 5, "Alternative
  configurations").

## Budget

`MAX_BUDGET_USD` is checked against `total_cost_usd`, which the CLI prices
by model name. The image copies upstream's `docker/managed-settings.json`
(read it at `AGENT_SRC_REF`); its `modelPricing.overrides` keys are the
models with Meta rates. The rule follows `MODEL_NAME`, not the route:

- `MODEL_NAME` is an override key (unset `MODEL_NAME` means the Meta default,
  `muse-spark-1.3-contributor`): Meta rates, also through LiteLLM, since the
  gateway keeps the model name. Keep
  `MAX_BUDGET_USD >= MAX_BUDGET_TOKENS * $5/MTok`.
- Any other model, including a gateway route under a different name: the
  CLI's own rates, which are higher. Ask the user for `MAX_BUDGET_USD`.

## Verifying the gateway

Offer this after `docker compose build` (step 7), together with the profile
run. It goes through the real compose wiring (network, env file) and never
prints the key:

```bash
cd agent-instances/agent-<name>
docker compose run --rm --no-deps -T --entrypoint python3 agent - <<'EOF'
import json, os, urllib.error, urllib.request
base = os.environ["MODEL_BASE_URL"].rstrip("/")
with urllib.request.urlopen(base + "/health/liveliness", timeout=10) as r:
    print("liveliness", r.status)
body = {"model": os.environ["MODEL_NAME"], "max_tokens": 16,
        "messages": [{"role": "user", "content": "Reply with OK."}]}
req = urllib.request.Request(base + "/v1/messages", json.dumps(body).encode(),
    {"Authorization": "Bearer " + os.environ["MODEL_API_KEY"],
     "content-type": "application/json", "anthropic-version": "2023-06-01"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        model = json.load(r).get("model")
        print("messages", r.status, "model", model,
              "matches" if model == os.environ["MODEL_NAME"] else "MISMATCH")
except urllib.error.HTTPError as e:
    print("messages", e.code, e.read()[:300])
EOF
```

Expect `liveliness 200` and `messages 200 ... matches`. A name resolution
error means the agent isn't on `GATEWAY_NETWORK`, 401 a wrong master key, and
400/404 naming the model a `MODEL_NAME` without a gateway route. With an
alternative env file, add `--env-file .env.litellm`.

Prompt caching can only be judged on a real attempt, not a one-shot request.
After the first one, the `token_budget_reconciled` event in that attempt's
`agent_output.json` has `prompt_cache.main_hit_rate` (expect roughly 0.9
through the gateway; ~0 means caching isn't working), and a
`prompt_cache_ineffective` WARNING means the first responses missed. Cache
behaviour depends on the gateway's LiteLLM version, so repeat this check after
every gateway upgrade. Tell the user it remains to be checked on the first
run.
