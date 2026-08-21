# Can the `/model` picker list custom (qBraid gateway GPT) models?

Date: 2026-08-20. Claude Code v2.1.238 (native binary, `~/.local/share/claude/versions/2.1.238`).

## Question

Can the in-session `/model` picker show custom models — the qBraid gateway's GPT models (`gpt-5.6-sol` etc.) — when Claude Code runs against a third-party `ANTHROPIC_BASE_URL`?

## TL;DR verdict

**Yes — two supported, documented mechanisms exist.**

1. `ANTHROPIC_CUSTOM_MODEL_OPTION` (+ `_NAME`, `_DESCRIPTION`) adds **one** unvalidated custom row to the picker. Any model ID works, including `gpt-5.6-sol`.
2. `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` makes Claude Code fetch `GET {ANTHROPIC_BASE_URL}/v1/models?limit=1000` at startup and add the results to the picker — **but only IDs containing `claude` or `anthropic`** (case-insensitive, substring). `gpt-5.6-sol` is silently dropped unless the proxy serves it under an alias that passes the filter (e.g. `anthropic-compat/gpt-5.6-sol`).

A third lever, the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` family (+ `_NAME`, `_DESCRIPTION`), remaps the built-in alias rows to arbitrary IDs with custom labels — up to 4 more slots, at the cost of changing what `opus`/`sonnet`/`haiku`/`fable` mean session-wide.

The `~/.claude.json` caches are readable and unsigned, but seeding them is unsupported and fragile (overwritten by bootstrap). `availableModels` in settings only restricts; it cannot add non-Claude IDs.

## Evidence

### 1. Binary (primary source)

All byte offsets are into `/Users/belazy/.local/share/claude/versions/2.1.238` (306 MB Mach-O with embedded JS; app source region ≈ bytes 283 M–306 M).

**Picker option builder** (`_7b`, offset ≈ 285,100,020 = extract 1,984,500):

```js
function _7b(e,t){
  let r=h7b(e),                       // built-in tier rows
  n=V.ANTHROPIC_CUSTOM_MODEL_OPTION;
  if(n&&!r.some((c)=>c.value===n))
    r.push({value:n,
      label:V.ANTHROPIC_CUSTOM_MODEL_OPTION_NAME??n,
      description:V.ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION??`Custom model (${n})`});
  for(let c of tDn()) ...             // gateway-discovered rows
  if(o==="firstParty"||o==="gateway"){ for(let u of wJe()) ... }  // additionalModelOptionsCache rows
  let{availableModels:i}=Na()??{};    // settings allowlist: adds only anthropic.* (Mantle) or claude-* ids
  ...
}
```

- `ANTHROPIC_CUSTOM_MODEL_OPTION` pushes exactly **one** row, no name filter, no validation. Env registry (offset ≈ 281,631,458) defines only the three vars — no plural form.
- `availableModels` entries can only *add* rows when they start with `anthropic.` (Bedrock Mantle) or match `/^claude-[a-z0-9-]+$/` and contain opus/sonnet/haiku. A `gpt-*` entry never adds a row.

**Gateway discovery for custom base URL** (`Vna`/`dCd`/`tDn`, offsets ≈ 283,557,5xx = extract 442–443 k):

```js
function Vna(){
  if(!V.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY)return!1;
  if(ro()!=="firstParty")return!1;    // no CLAUDE_CODE_USE_* provider set
  if(Nm())return!1;                   // Nm(): base URL host is api.anthropic.com
  if(!V.ANTHROPIC_BASE_URL)return!1;
  return!0
}
// dCd(): GET `${ANTHROPIC_BASE_URL}/v1/models?limit=1000`
//   auth: Bearer ANTHROPIC_AUTH_TOKEN, else x-api-key; ANTHROPIC_CUSTOM_HEADERS honored
//   redirect:"error", timeout lTb=3000 ms
//   FILTER: l.data.data.filter((p)=>/(claude|anthropic)/i.test(p.id))
//   0 survivors -> "[gatewayDiscovery] 0 usable models after filter" -> nothing cached
// cache: <config>/cache/gateway-models.json {baseUrl, fetchedAt, models}
// tDn(): reads cache, requires baseUrl === current ANTHROPIC_BASE_URL,
//   maps to {value:id, label:display_name||id, description:"From gateway"}
```

`dCd(t)` runs once at startup (init sequence, offset ≈ extract 23,555,000). `Nm()` (extract 195,805): returns true only for host `api.anthropic.com` or `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL`. So qbraid-code's loopback proxy qualifies for discovery.

**Cloud-gateway variant** (`ugT`/`pgT`, offsets ≈ 295,005,000): when signed in through a Claude apps gateway (`ro()==="gateway"`, JWT-based), the same env flag gates a `/v1/models` fetch with an extra family filter. Not the qbraid case; noted for completeness.

**Built-in rows and pinned aliases** (`h7b`, extract 1,980,354): each tier row can be replaced by a pinned override (`vep`/`_ep`/`Eep`/`Sep` — the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` values with `_NAME`/`_DESCRIPTION` labels).

**`availableModels` setting** (offset ≈ 86,300,350): schema description reads "Allowlist of models that users can select… If undefined, all models are available." It is a restriction, enforced client-side; it also bounds what discovery and the custom option can add.

### 2. `~/.claude.json` caches (read-only inspection)

| Key | Shape on this machine | Verdict on seeding |
|---|---|---|
| `additionalModelOptionsCache` | `[{value:"claude-fable-5[1m]", label:"Fable", description:"…"}]` | Read unsigned by `wJe()` (extract 1,044,105) with shape validation only; rows shown when provider is firstParty/gateway. **But** it is a server bootstrap cache: `vvt()` (offset ≈ 295,007,700) overwrites it from `{base}/api/claude_cli/bootstrap` responses. Seeding works mechanically, survives only until the next successful bootstrap. Unsupported. |
| `additionalModelCostsCache` | `{}` | Pricing display only. |
| `modelAccessCache` | `[]` | Entitlements `[{apiName, entitled}]` (`bHr`); used to gate/disable rows, not add them. |
| `orgModelDefaultCache` | `null` | Org default model; not additive. |
| `customApiKeyResponses` | `{approved:[], rejected:["6cvg…"]}` | API-key trust prompts. Nothing to do with models. |

No signing or expiry on any of them. `~/.claude/cache/gateway-models.json` does not exist yet on this machine (discovery flag never set).

### 3. Official docs

- `code.claude.com/docs/en/model-config#add-a-custom-model-option`: "Use `ANTHROPIC_CUSTOM_MODEL_OPTION` to add a single custom entry to the `/model` picker… Claude Code skips validation for the model ID… For LLM gateway deployments, Claude Code can populate the picker from the gateway's `/v1/models` endpoint when `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` is set."
- `code.claude.com/docs/en/llm-gateway-protocol#model-discovery`: request is `GET /v1/models?limit=1000`, 3 s timeout, redirects = failure; sends exactly one credential header (`ANTHROPIC_AUTH_TOKEN` bearer preferred); "Claude Code keeps an entry when its `id` contains `claude` or `anthropic` anywhere in the string, matched case-insensitively, and ignores the rest" (substring match since v2.1.223; prefix-only before). Rows are labeled "From gateway"; duplicates fold into built-in alias rows (v2.1.197+); cache at `~/.claude/cache/gateway-models.json`, refreshed each startup, stale cache used on fetch failure. "If your gateway serves Claude models under aliases that don't match the discovery filter, developers can add those aliases manually with the model configuration variables."
- `code.claude.com/docs/en/env-vars`: documents all of `ANTHROPIC_CUSTOM_MODEL_OPTION{,_NAME,_DESCRIPTION}`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL{,_NAME,_DESCRIPTION}`, `ANTHROPIC_CUSTOM_HEADERS`. (`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` is documented on the protocol page, not the env-vars page.)
- `model-config`: `availableModels` "restricts which named models users can select"; the only additive exception is Mantle `anthropic.*` IDs. Discovery is "off by default so that gateways backed by a shared API key don't surface every model the key can access to every user."

## Mechanisms evaluated

| Mechanism | Adds GPT models to picker? | Evidence |
|---|---|---|
| `ANTHROPIC_CUSTOM_MODEL_OPTION` (+`_NAME`,`_DESCRIPTION`) | **Yes — one model, any ID, no validation** | `_7b` @ extract 1,984,500; docs model-config#add-a-custom-model-option |
| `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` + proxy `/v1/models` | **Yes, many — but only IDs containing `claude`/`anthropic`**; plain `gpt-5.6-sol` filtered out | `dCd` filter @ extract 442,9xx; docs llm-gateway-protocol#model-discovery |
| `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` (+`_NAME`,`_DESCRIPTION`) | **Yes — remaps up to 4 built-in rows** to arbitrary IDs with custom labels; changes alias meaning session-wide (haiku slot also serves background traffic) | `h7b` pinned overrides @ extract 1,980,354; docs env-vars |
| Seed `additionalModelOptionsCache` in `~/.claude.json` | Works mechanically (unsigned, shape-checked only) but **unsupported**; overwritten by server bootstrap | `wJe` @ extract 1,044,105; `vvt` cache write @ 295,007,700 |
| `availableModels` settings key | **No** — allowlist only; additive only for `anthropic.*` (Mantle) and `claude-*` IDs | schema @ 86,300,350; docs model-config#restrict-model-selection |
| `modelAccessCache` / `orgModelDefaultCache` / `customApiKeyResponses` | No — entitlements / org default / API-key trust | `bHr`; jq inspection |
| A `--models` flag | Does not exist | `claude --help`; env registry |

## Recommendation for qbraid-code

Layered, all from the installer/wrapper env — no config-file writes:

1. **Today, zero-risk:** export `ANTHROPIC_CUSTOM_MODEL_OPTION="gpt-5.6-sol"`, `ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="GPT-5.6 Sol"`, `ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="qBraid gateway · OpenAI GPT-5.6"` in the `qbraid-code` launcher before exec'ing `claude`. One GPT model becomes selectable in `/model` immediately. If the wrapper knows which GPT model the user launched with (`--model gpt-…`), set the custom option to that model so the active model always has a picker row.
2. **For the full GPT roster:** implement `GET /v1/models` on the loopback proxy (:8320) and export `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`. To pass the filter, serve the GPT models under IDs containing `anthropic` or `claude` — e.g. `id: "anthropic-compat/gpt-5.6-sol"`, `display_name: "GPT-5.6 Sol"` — and have the proxy accept those IDs on `/v1/messages` (strip the prefix before translating). Serve the endpoint directly: no redirect, respond < 3 s, accept the same `ANTHROPIC_AUTH_TOKEN` bearer. Rows appear labeled "From gateway".
3. **Optional:** repurpose alias rows via `ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5.6-sol` + `_NAME`/`_DESCRIPTION` for up to 4 labeled rows. Only do this if changing what `opus`/`sonnet`/`haiku` mean (subagents, background haiku traffic) is acceptable — probably not as a default.
4. Do **not** seed `~/.claude.json` caches; do not rely on `availableModels` to add models.
5. Upstream ask, if the prefix trick feels too ugly: a feature request to relax the discovery filter (opt-in "trust my gateway's full model list") — the filter exists only to hide shared-key upsell, and the docs already acknowledge the alias workaround.

## Open questions

- Filter-passing alias format: `anthropic-compat/gpt-5.6-sol` vs `qbraid-anthropic/gpt-5.6-sol` — pick one, proxy must accept it on inference.
- Does picking a "From gateway" GPT row keep `ANTHROPIC_SMALL_FAST_MODEL` / subagent model routing sane? (Picker only sets main model; verify proxy handles haiku background calls.)
- Multiple `ANTHROPIC_CUSTOM_MODEL_OPTION` rows: only one env slot exists; >1 static GPT rows need the discovery path or alias-slot remaps.
- Discovery + claude.ai-subscription auth mix: qbraid-code sets `ANTHROPIC_AUTH_TOKEN`, so bearer path is used; untested whether an active claude.ai login alongside changes bootstrap overwrite timing of `additionalModelOptionsCache` (irrelevant unless seeding, which is not recommended).
