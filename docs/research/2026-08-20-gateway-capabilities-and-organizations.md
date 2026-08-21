# Gateway capabilities, organizations, and multi-key switching

Research date: 2026-08-20; sources rechecked 2026-08-21 UTC. Claude Code tested locally at v2.1.238. qBraid source citations are pinned to `qbraid-api` commit `ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f` and `qbraid-account` commit `db748ee78f3c9bdabe08ecee90b53bbbb129eb85`.

## Question

How should qbraid-code safely support one Anthropic-compatible Claude Code entry point across qBraid's OpenAI-style GPT/Sol models and Claude Opus models, expose the active qBraid organization beside credits, and switch explicitly among API keys bound to different organizations?

This report does not repeat the picker mechanics already established in [2026-08-20-model-picker.md](./2026-08-20-model-picker.md). That report proves the custom-row and `/v1/models` discovery options, including Claude Code's `claude|anthropic` ID filter.

## Executive verdict

1. **Keep one local proxy as the protocol boundary, not as the source of Claude Code's process-wide policy.** It must route per model, translate Anthropic requests/responses for OpenAI-style models, preserve Claude behavior for Opus, stream SSE without long silent gaps, count tokens, and emit Anthropic-compatible errors. qBraid's own direct Anthropic endpoint is intentionally Claude/Bedrock-only; its OpenAI models use different surfaces because mixing provider wire formats breaks tool-call round-tripping ([qBraid AI Gateway docs](https://docs.qbraid.com/v2/ai/integrations/ai-gateway.md), [qBraid source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/docs/AI-PROXY.md#L16-L26)).
2. **Treat context and thinking as capabilities, not model-name guesses.** Claude Code's gateway discovery reads only `id` and `display_name`; it does not discover context size or reasoning support. Worse, it treats an unknown gateway alias as a current Claude model and can send `thinking: {"type":"adaptive"}` ([gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol#feature-pass-through), [model configuration](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)). The proxy therefore needs a per-model capability manifest, while each Claude Code process needs a conservative or exact context policy.
3. **Do not hot-swap organizations inside a running Claude Code process.** Credential environment variables are process-scoped, settings-file `env` values can override shell values, and `apiKeyHelper` caches for five minutes or until a 401. Claude Code exposes no documented immediate “switch gateway credential” operation ([gateway connection](https://code.claude.com/docs/en/llm-gateway-connect#set-the-base-url-and-credential), [authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence)). qbraid-code should own named profiles and start a new process/session for an explicit profile switch.
4. **The status line cannot discover organization identity from Claude Code.** Its JSON includes model, context, cost, session, effort, and thinking fields, but no account, credential, or organization field ([status-line schema](https://code.claude.com/docs/en/statusline#available-data)). qbraid-code must supply a non-secret organization/profile label and cached credit snapshot out of band.
5. **Store keys in an OS secret store; migrate metadata, not secrets.** Keep profile name, organization ID/label, model policy, and secret reference in a portable manifest. Keep API keys in Keychain, Credential Locker, or Secret Service, with a `0600` file only as a documented headless fallback ([Apple Keychain](https://developer.apple.com/documentation/security/keychain-services), [Windows Credential Locker](https://learn.microsoft.com/en-us/windows/apps/develop/security/credential-locker), [Secret Service](https://specifications.freedesktop.org/secret-service-spec/latest/)).

## Evidence by topic

### 1. Claude Code's gateway contract and capability assumptions

#### Protocol, model selection, and discovery

`ANTHROPIC_BASE_URL` selects the Anthropic Messages wire format. The required inference endpoint is `/v1/messages`; `/v1/messages/count_tokens` is optional. Inference must stream SSE, keep-alive pings must survive, and Claude Code aborts a custom-base-URL stream after 300 seconds of silence by default ([gateway protocol: API formats and streaming](https://code.claude.com/docs/en/llm-gateway-protocol#api-formats)). This makes buffering or “translate after the full answer” unsafe, especially during long reasoning pauses.

Model selection is client-side: `--model`, `/model`, settings, and model environment variables select an ID that Claude Code sends in `model`. Gateway discovery is startup-only, requests `GET /v1/models?limit=1000`, and reads only each entry's `id` and optional `display_name` ([gateway discovery](https://code.claude.com/docs/en/llm-gateway-protocol#model-discovery)). It carries no context-window or capability schema. See the existing [model-picker report](./2026-08-20-model-picker.md) for discovery filtering, aliases, caching, and picker integration.

qBraid documents separate OpenAI and Anthropic surfaces: `/chat/completions`, `/responses`, and `/models` for OpenAI clients; `/v1/messages` and `/v1/messages/count_tokens` for Anthropic clients ([qBraid AI Gateway](https://docs.qbraid.com/v2/ai/integrations/ai-gateway.md#endpoints)). First-party source explicitly provider-locks the surfaces because routing Claude onto Responses or GPT onto Anthropic wire “silently breaks tool-call round-tripping” ([qBraid source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/docs/AI-PROXY.md#L16-L26)). Therefore qbraid-code, not the remote Anthropic endpoint, must translate Claude Code traffic for GPT/Sol models.

qBraid's OpenAI `/models` response currently includes private `_qbraid` metadata such as `maxTokens`, capabilities, aliases, provider, and supported endpoints ([serializer](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/models/models.routes.ts#L45-L82), [registry](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/shared/models.registry.ts#L83-L84)). Its Anthropic `/v1/models` shape contains only `id`, `created_at`, `display_name`, and `type`, and includes only models supported on the Messages surface ([source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/models/anthropic-models.service.ts#L10-L55)). `_qbraid` is useful first-party evidence for a proxy capability catalog, but it is not in qBraid's published OpenAPI contract.

#### Context windows and token counting

Claude Code has no per-model context metadata handshake. For an unrecognized gateway ID, `CLAUDE_CODE_MAX_CONTEXT_TOKENS` declares the window Claude Code should assume; otherwise it compacts at its inferred window. Recognized `claude-*` IDs and `[1m]` IDs have special rules, so aliases are not neutral ([custom-model window rules](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)). A single environment value applies to the process, so one process cannot represent several unknown models with different exact windows.

Anthropic currently documents 1M-token windows for Claude Opus 4.6 and later, while other Claude models may use 200K. All request content and generated output, including thinking, count toward the window ([Anthropic context windows](https://platform.claude.com/docs/en/build-with-claude/context-windows#context-window-sizes-by-model)). The actual qBraid catalog is more granular: the pinned registry declares 1,050,000 for GPT-5.6 variants, 400,000 for several other GPT variants, 1,000,000 for current Opus/Sonnet entries, and 200,000 for Haiku ([qBraid registry](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/shared/models.registry.ts#L102-L159), [later entries](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/shared/models.registry.ts#L166-L375)). Those values can change and should be refreshed, versioned, and fail closed when absent.

Claude Code prefers `/v1/messages/count_tokens`, but falls back to an inference request when the endpoint is absent ([gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol#optional-endpoints-and-startup-traffic)). Anthropic calls token counts estimates that can differ slightly from actual usage and recommends counting against the exact target model ([Anthropic token counting](https://platform.claude.com/docs/en/build-with-claude/token-counting#how-to-count-message-tokens)). qBraid's pinned implementation is also explicitly an estimate: it serializes Anthropic content, uses `cl100k_base`, and applies a calibration factor rather than calling the provider tokenizer ([qBraid source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/messages/count-tokens.util.ts#L1-L27)). Context policy therefore needs headroom and must still handle authoritative upstream overflow errors.

#### Extended and adaptive thinking

Claude Code sends gateway requests as if the endpoint were Anthropic. For Claude 4.6 and later it can send `thinking: {"type":"adaptive"}`; unknown gateway aliases are treated as current models that receive that field. Capability declarations through `ANTHROPIC_DEFAULT_*_MODEL_SUPPORTED_CAPABILITIES` do not affect an `ANTHROPIC_BASE_URL` gateway ([gateway feature pass-through](https://code.claude.com/docs/en/llm-gateway-protocol#feature-pass-through)). A non-Claude model behind the gateway must therefore not trust Claude Code's model detection.

Thinking behavior differs materially by Claude generation. Fixed `thinking.type: "enabled"` uses `budget_tokens`, requires at least 1,024, and is rejected by Claude 4.7 and later; adaptive thinking uses `thinking.type: "adaptive"` and `output_config.effort`, may skip thinking, and interleaves around tools automatically ([extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking), [adaptive thinking](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)). `MAX_THINKING_TOKENS` controls fixed budgets; nonzero values are ignored on adaptive models unless adaptive thinking is disabled where supported. `CLAUDE_CODE_DISABLE_THINKING=1` omits the field for compatibility, while `MAX_THINKING_TOKENS=0` also omits it on third-party providers ([Claude Code environment variables](https://code.claude.com/docs/en/env-vars)).

The safe division is:

- The **proxy** classifies the target model, passes valid Claude thinking fields through, translates effort/reasoning only where the OpenAI-style model and qBraid surface support an equivalent, and removes unsupported fields otherwise.
- A **process bound to non-Claude-only models** may set `CLAUDE_CODE_DISABLE_THINKING=1` as a compatibility backstop.
- A **mixed-model process** cannot use that backstop without also disabling Claude thinking. It needs proxy normalization and a conservative shared client policy.

#### Errors and retries

Claude Code retries some rejected capabilities and disables them for the conversation. It can recover from rejections of `thinking`, thinking signatures, and mid-conversation system messages. It does not automatically retry every context-management or tool-schema rejection. Its retry matching depends on the upstream error text, so an Anthropic upstream's error body must be forwarded unmodified ([automatic retry](https://code.claude.com/docs/en/llm-gateway-protocol#automatic-retry-and-error-forwarding)).

For a non-Anthropic upstream, the proxy must instead translate deliberately into Anthropic status, envelope, request ID, streaming error event, and recognized wording. In particular, Claude Code's context recovery recognizes Anthropic's `400 invalid_request_error` with “prompt is too long”; arbitrary gateway wording can prevent compact-and-retry ([context overflow](https://platform.claude.com/docs/en/build-with-claude/context-windows#context-window-overflow-behavior), [gateway troubleshooting](https://code.claude.com/docs/en/llm-gateway-connect#troubleshoot-gateway-errors)). The proxy must not emit HTTP 200 before provider acceptance when it can avoid doing so; after the first SSE byte, later failures must become Anthropic `event: error` frames.

### 2. Proxy concerns versus Claude Code process concerns

| Concern | Normalize in qbraid-code proxy | Configure per Claude Code process |
| --- | --- | --- |
| Model route and wire format | Yes. Claude/Bedrock uses Messages; GPT/Sol uses OpenAI and requires translation. | Select the initial model and limit picker choices to a compatible set. |
| Context truth | Fetch/cache per-model qBraid capability data; enforce actual upstream limit. | Set the exact active window, or the minimum safe window across every selectable model. |
| Token counting | Expose `/v1/messages/count_tokens`; route or estimate per target model; add safety headroom. | No separate counter. Let Claude Code consume the proxy endpoint. |
| Thinking/effort | Pass through for compatible Claude models; map or strip for OpenAI-style models. | Use effort/thinking flags only when the process's whole selectable model set supports them. |
| Tools and system blocks | Preserve Anthropic ordering/signatures for Claude; translate tool IDs and deltas for GPT. | Avoid process-wide experimental features only when the proxy cannot support them. |
| Errors and streaming | Own Anthropic envelopes, request IDs, pings, usage blocks, and context-overflow semantics. | Configure timeouts only; do not rely on client retry to repair bad translations. |
| Model discovery | Serve Claude Code's `/v1/models` shape and aliases. | Enable discovery at launch. See the [picker report](./2026-08-20-model-picker.md). |
| qBraid key | Resolve the selected named profile and inject `X-API-Key` upstream. | Prefer an ephemeral local-proxy token, not the qBraid key itself. |
| Organization and credits | Validate the key's organization; refresh a non-secret status snapshot asynchronously. | Pass only snapshot path/profile label to the status-line process. |

The unavoidable boundary is client-side compaction: the proxy knows the actual model on every request, but Claude Code decides when to compact from process-visible model/context information. For materially different windows, either launch one process per capability profile or advertise only the minimum common window in a mixed process.

### 3. Status-line organization identity and credits

Claude Code pipes JSON to a shell command. The documented fields include model, working directory, cost, context, effort, thinking, session, and version. They do not include account, login, credential source, organization, or arbitrary gateway metadata ([status-line schema](https://code.claude.com/docs/en/statusline#available-data)). Thus the status line cannot derive qBraid identity safely from stdin.

The status command runs frequently, can be canceled when a newer refresh starts, and Anthropic recommends caching expensive operations ([status-line execution and caching](https://code.claude.com/docs/en/statusline#how-status-lines-work), [examples](https://code.claude.com/docs/en/statusline#cache-expensive-operations)). It should not make an authenticated network request on every render.

A safe data path is:

1. The launcher resolves a named profile and validates its key before starting Claude Code.
2. A trusted qbraid-code component writes an atomic, non-secret snapshot containing profile label, organization ID, organization display name if verified, spendable credits, and `updated_at`.
3. The status line combines Claude's stdin model/context fields with that snapshot. It never reads the API key.
4. Credits refresh asynchronously and retain the last known value with a visible stale marker after failures.

Display the organization ID when no verified name exists; a user-supplied profile label may accompany it but must not masquerade as server-verified identity. Label the balance precisely. qBraid's current balance source returns the authenticated organization member's `qbraidCredits`, not necessarily the organization's central wallet pool ([balance controller](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/billing/credits/credits.controller.ts#L234-L315), [organization credit model](https://docs.qbraid.com/v2/account/organizations/credits.md)). “Spendable credits” is safer than “organization wallet.”

### 4. Credentials, precedence, and explicit switching

Documented Claude Code precedence is cloud-provider credentials, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`, OAuth token, Anthropic profiles/federation, then saved `/login` credentials ([authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence)). A gateway credential overrides a saved Claude login; unsetting it returns to the saved login ([gateway conflicts](https://code.claude.com/docs/en/llm-gateway-connect#conflicts-with-an-existing-login)).

Shell exports apply only to that terminal and child processes. A Claude settings-file `env` value wins over the same shell variable, which can silently defeat a wrapper's selected profile ([gateway connection](https://code.claude.com/docs/en/llm-gateway-connect#set-the-base-url-and-credential)). qbraid-code should therefore avoid persisting qBraid keys in `~/.claude/settings.json` and should remove or isolate stale gateway `env` entries.

`apiKeyHelper` is for dynamic or rotating credentials. Claude Code caches its output for five minutes by default and reruns it after a 401; no documented command immediately invalidates that cache for an organization switch ([gateway helper](https://code.claude.com/docs/en/llm-gateway-connect#rotate-credentials-with-apikeyhelper)). A helper can technically return a different key later, but that is not an atomic, user-visible switch. Requests already in flight, status data, model policy, and billing attribution can straddle organizations.

Claude Code supports side-by-side configuration roots through `CLAUDE_CONFIG_DIR`, explicitly citing multiple accounts as a use case ([environment variables](https://code.claude.com/docs/en/env-vars)). qbraid-code can use one config root per named profile when isolation of settings, caches, transcripts, or remembered API-key approvals matters. The qBraid profile switch should still create a new process. Existing sessions should remain bound to the profile recorded at launch.

**Documented fact:** one process has one resolved active credential at a time. `/login` can change OAuth identity in-session, and a helper can refresh a credential, but Claude Code documents no multi-qBraid-key profile picker or immediate helper-cache invalidation.

**Recommendation:** `profile use` changes only future launches. `profile switch` starts a new Claude Code process and normally a new conversation. Resuming a transcript under another organization should require an explicit warning because one logical conversation would span two billing and audit contexts.

### 5. qBraid key ownership, organization identity, and balances

qBraid's public account documentation says API keys grant access to credits/resources, are shown once, and must be stored like passwords ([API key guide](https://docs.qbraid.com/v2/account/api-keys.md)). qBraid's account UI is workspace-scoped, with one default workspace plus organizations and an explicit workspace switcher ([account overview](https://docs.qbraid.com/v2/account/overview.md#qbraid-default-vs-organizations)).

Pinned first-party source is more precise:

- Every API-key record carries `userId`, `organizationId`, and `orgUserId` ([API-key model](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/apikey/model.ts#L6-L15)). Authentication sets `currentOrganizationId` from the key, so the key establishes the billing tenant ([API-key strategy](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/shared/services/auth/strategies/apikey-strategy.service.ts#L184-L205)). The AI proxy likewise states that API keys bill the user and organization bound to the credential ([AI proxy contract](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/docs/AI-PROXY.md#L42-L52)).
- `GET /users/verify` returns the authenticated `organizationId`, user identity, roles, permissions, and subscription tier, but no organization display name ([controller](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/user/core/user.controller.ts#L160-L209)).
- `GET /billing/credits/balance` returns `qbraidCredits`, `awsCredits`, `autoRecharge`, `organizationId`, and `userId` for the authenticated member in that organization ([route](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/billing/credits/credits.routes.ts#L52-L58)).
- The qBraid account source tells users that API keys are unique to each organization they belong to ([account UI](https://github.com/qBraid/qbraid-account/blob/db748ee78f3c9bdabe08ecee90b53bbbb129eb85/src/components/organizations/org-api-keys-section.tsx#L194-L204)).

The public REST OpenAPI currently documents only devices and jobs; it contains no account, organization, API-key, billing, or credit-balance path ([public OpenAPI](https://docs.qbraid.com/openapi-v2.json)). The public AI Gateway docs support `GET /quota`, but describe it as LLM subscription state and remaining quota, not organization identity or general credit balance ([AI Gateway quota](https://docs.qbraid.com/v2/ai/integrations/ai-gateway.md#check-your-quota)). The CLI publicly offers `qbraid account credits`, but its endpoint/schema is not documented ([CLI reference](https://docs.qbraid.com/v2/cli/api-reference/qbraid_account.md)).

**Gap:** current first-party source proves internal contracts, but there is no public, versioned key-auth endpoint that returns `{organization: {id, name}, spendableCredits}`. qbraid-code should not guess an organization name from browser state, email domain, key name, or locally cached history. Prefer formalizing a supported endpoint or extending `/ai/quota`; until then, pin/test the internal contract and show organization ID plus an explicitly user-defined profile label.

### 6. Security, storage, and migration

qBraid says keys are shown once, rotation invalidates the old value immediately, and keys should live in environment variables or a secrets manager rather than source control ([API key guide](https://docs.qbraid.com/v2/account/api-keys.md)). Claude Code itself uses macOS Keychain, a `0600` credentials file on Linux, and a user-profile ACL-protected file on Windows ([Claude credential management](https://code.claude.com/docs/en/authentication#credential-management)).

For qbraid-code profiles:

- **macOS:** store each key as a Keychain item. Apple describes Keychain as an encrypted database for small secrets ([Apple](https://developer.apple.com/documentation/security/keychain-services)).
- **Windows:** store each key by stable profile/resource name in Credential Locker. Microsoft documents multiple credentials per app and secure retrieval ([Microsoft](https://learn.microsoft.com/en-us/windows/apps/develop/security/credential-locker)).
- **Linux desktop:** use the Secret Service API when available ([freedesktop specification](https://specifications.freedesktop.org/secret-service-spec/latest/)). For headless systems without a secret service, use a separate `0600` secret file, fail on broader permissions, and never place it inside a repository.

Keep a versioned non-secret manifest separate from the vault. It may contain profile ID, display label, verified organization ID/name and verification time, default model, context/thinking policy, and the vault lookup key. It must not contain the qBraid key.

Migration should export/import only that manifest. The destination re-prompts for each key or creates/rotates keys through qBraid. This avoids pretending Keychain, Credential Locker, Secret Service, and file ACLs are portable. It also prevents a profile archive from becoming a reusable bearer-secret bundle.

The Claude process should ideally receive only a short-lived random credential for the loopback proxy. The proxy retrieves the selected qBraid key from the vault and injects `X-API-Key` upstream. This reduces exposure through Claude settings, status-line scripts, child shells, hooks, process listings, crash logs, and project configuration. Bind the proxy to loopback and scope the local token to one launch/profile.

## Facts vs recommendations

| Topic | Documented or source-backed fact | Recommendation for qbraid-code |
| --- | --- | --- |
| Gateway capabilities | Unknown aliases can receive adaptive-thinking fields; discovery has no context/capability metadata ([protocol](https://code.claude.com/docs/en/llm-gateway-protocol#feature-pass-through)). | Maintain a per-model capability manifest and normalize every request at the proxy. |
| Context | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is process-wide for unknown IDs ([model config](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)). | Bind materially different windows to separate processes, or use the minimum selectable window. |
| Token count | Counts are estimates; qBraid's current counter is calibrated `cl100k_base` ([Anthropic](https://platform.claude.com/docs/en/build-with-claude/token-counting), [qBraid](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/messages/count-tokens.util.ts#L1-L27)). | Add headroom and preserve recognized overflow errors for recovery. |
| Thinking | Claude and OpenAI-style models accept different reasoning controls ([Anthropic thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)). | Translate only supported semantics; otherwise omit. Never infer from a friendly model name alone. |
| Status line | No organization/account field exists ([schema](https://code.claude.com/docs/en/statusline#available-data)). | Read a non-secret qbraid-code snapshot; do not give the script the key. |
| Credential switching | Environment credentials are process-scoped; helper output is cached ([gateway docs](https://code.claude.com/docs/en/llm-gateway-connect)). | Named profiles; switching starts a new process/session. |
| Key ownership | A qBraid key is bound to one user/org membership ([source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/apikey/model.ts#L6-L15)). | Validate and record the organization at profile creation; never let “active browser org” override it. |
| Org name and credits API | Internal first-party routes exist, but no public versioned account-context schema exists ([OpenAPI](https://docs.qbraid.com/openapi-v2.json)). | Formalize one endpoint; until then show verified ID and mark cached/internal data clearly. |
| Secret storage | qBraid keys are password-equivalent and shown once ([qBraid](https://docs.qbraid.com/v2/account/api-keys.md)). | Use OS vaults; plaintext `0600` only as headless fallback. |
| Migration | OS secret stores differ; qBraid rotation immediately revokes the old key ([qBraid](https://docs.qbraid.com/v2/account/api-keys.md#rotate-a-key)). | Export metadata only; re-provision secrets on the destination. |

## Architectural implications

A safe design has four explicit ownership layers:

1. **Profile manager:** owns named qBraid profiles. Each profile maps a non-secret label to a vault reference, verified organization identity, default model, and compatibility policy. “Current profile” affects future launches only.
2. **Launch coordinator:** resolves one profile, validates the key/organization, obtains model capabilities, chooses exact or conservative context/thinking environment, creates a per-launch local token, and starts both proxy and Claude Code. It does not persist the qBraid key in Claude settings.
3. **Protocol normalizer:** owns upstream credentials, model routing, Anthropic↔OpenAI translation, thinking/effort normalization, token counting, usage translation, SSE pings, and error semantics. It rejects unknown capabilities instead of silently dropping behavior that changes answers or billing.
4. **Status adapter:** reads Claude's documented stdin plus a qbraid-code snapshot. Suggested semantics are `profile · verified org name (short ID) · spendable credits · stale age`, with no secret access.

Session rules follow from those boundaries:

- Allow `/model` switching within one process only when every advertised model fits the process's declared context and compatibility envelope. Otherwise require a new launch.
- A key/profile switch always starts a new process. Keep the old process pinned to its original organization until it exits.
- Do not silently resume the same transcript under another organization. Require an explicit cross-organization resume action and preserve both profile IDs in audit metadata.
- Cache the qBraid catalog and status snapshot with timestamps, but revalidate on launch. If capability metadata is missing, choose the smaller safe window and disable unsupported optional fields rather than assuming Claude behavior.
- Separate **LLM quota** from **spendable qBraid credits**. `/quota` and `/billing/credits/balance` describe different resources and should not share one unlabeled number.

## Risks/open questions

1. **Public contract gap:** which qBraid endpoint will be supported for key-authenticated organization display name and spendable balance? Current source is usable internally but not public/versioned.
2. **Balance semantics:** confirm whether the desired status number is the member wallet spendable by that key, the central organization wallet, remaining monthly AI quota, or all three.
3. **Capability schema ownership:** should qBraid formally publish `_qbraid.maxTokens`, reasoning modes, maximum output, tool limits, and supported surfaces on `/models`? Claude Code will not consume them, but qbraid-code can.
4. **Mixed-process context:** if mid-session GPT↔Opus switching remains a requirement, accept the minimum common context or add an explicit relaunch workflow. There is no exact per-model context discovery channel in Claude Code today.
5. **Thinking fidelity:** define model-by-model mappings among Claude adaptive/fixed thinking, OpenAI reasoning effort, and models with no equivalent. “Drop and continue” can materially change quality and cost.
6. **Tokenizer drift:** qBraid's current count endpoint is deliberately approximate. Establish a safety margin and tests against actual provider usage for every new model family.
7. **Long reasoning streams:** verify the proxy emits pings during provider silence and preserves thinking signatures/tool block ordering for Claude models.
8. **Error conformance:** regression-test exact pre-stream HTTP errors and post-stream SSE error frames. A cosmetically wrapped error can disable Claude Code's recovery.
9. **Headless Linux storage:** define behavior when no Secret Service is running. The fallback must fail closed on weak permissions and support noninteractive secret injection without writing the key into Claude settings.
10. **Windows vault roaming:** Credential Locker may roam some credentials and has platform limits. Decide whether qbraid-code disables roaming expectations and always treats destination enrollment as explicit.
11. **Local proxy trust:** an ephemeral loopback token reduces exposure but does not defeat a same-user attacker. Bind narrowly, rotate per launch, avoid diagnostic secret output, and shut down when the session ends.
12. **Claude Code release drift:** beta headers and body fields change across releases. Keep the proxy's Anthropic request handling open to new fields, then gate/translate them per upstream capability ([gateway open-list rule](https://code.claude.com/docs/en/llm-gateway-protocol#forward-as-open-lists)).

## Sources

Accessed 2026-08-21 unless a pinned commit is shown.

### Claude Code and Anthropic

- [Gateway protocol reference](https://code.claude.com/docs/en/llm-gateway-protocol)
- [Connect Claude Code to an LLM gateway](https://code.claude.com/docs/en/llm-gateway-connect)
- [Model configuration](https://code.claude.com/docs/en/model-config)
- [Environment variables](https://code.claude.com/docs/en/env-vars)
- [Authentication](https://code.claude.com/docs/en/authentication)
- [Status line](https://code.claude.com/docs/en/statusline)
- [Context windows](https://platform.claude.com/docs/en/build-with-claude/context-windows)
- [Token counting](https://platform.claude.com/docs/en/build-with-claude/token-counting)
- [Extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)
- [Adaptive thinking](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)

### qBraid

- [AI Gateway](https://docs.qbraid.com/v2/ai/integrations/ai-gateway.md)
- [Account overview](https://docs.qbraid.com/v2/account/overview.md)
- [API keys](https://docs.qbraid.com/v2/account/api-keys.md)
- [Organization credits](https://docs.qbraid.com/v2/account/organizations/credits.md)
- [CLI account commands](https://docs.qbraid.com/v2/cli/api-reference/qbraid_account.md)
- [Public Runtime OpenAPI](https://docs.qbraid.com/openapi-v2.json)
- [AI proxy contract, pinned source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/docs/AI-PROXY.md)
- [Model registry, pinned source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/ai/shared/models.registry.ts)
- [API-key model and auth strategy, pinned source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/apikey/model.ts)
- [User verification, pinned source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/user/core/user.controller.ts)
- [Credit balance route, pinned source](https://github.com/qBraid/qbraid-api/blob/ba86f9419fe68e6ef02d37d8ce500597d1e1eb4f/src/features/billing/credits/credits.routes.ts)

### Secret storage

- [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [Microsoft Credential Locker](https://learn.microsoft.com/en-us/windows/apps/develop/security/credential-locker)
- [freedesktop Secret Service API](https://specifications.freedesktop.org/secret-service-spec/latest/)
