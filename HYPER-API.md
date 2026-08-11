# Hyper Provider API Specification

This document specifies the **HTTP API of the Charm Hyper gateway** — the
provider that Crush (and other clients) call to proxy LLM requests. It is
not the Crush CLI protocol (see `CRUSH-SPEC.md`); it describes Hyper's
server-side endpoints as consumed by the OpenAI-compatible provider
in Crush. The gateway's OpenAI-compatible chat-completions API lives
under `/v1`; tokens (`sk-hyper-` prefixed) come from the Hyper
Dashboard.

crush.el consumes this API through the hyper backend (`crush-backend-type
'hyper`): curl subprocess transport with SSE parsed in the process filter
(see the transport section in `crush-hyper-backend.el` and the integration
fixture `test/hyper-server.py`).

Source of truth: [`internal/agent/hyper/`](https://github.com/charmbracelet/crush/tree/main/internal/agent/hyper),
[`internal/oauth/hyper/device.go`](https://github.com/charmbracelet/crush/blob/main/internal/oauth/hyper/device.go),
and the embedded [`provider.json`](https://github.com/charmbracelet/crush/blob/main/internal/agent/hyper/provider.json).

## 1. Overview

| Field              | Value                                                               |
| ------------------ | ------------------------------------------------------------------- |
| Base URL (default) | `https://hyper.charm.land/v1`                                       |
| Override           | `$HYPER_URL` — when set, Chat + provider endpoints use `$HYPER_URL` |
| Auth               | `Authorization: Bearer sk-hyper-...` (except device-flow endpoints) |
| Content type       | `application/json`                                                  |
| User-Agent         | `crush` (device/token/introspect endpoints)                         |

The chat-completions, credits, and model-catalog endpoints live under
`{base}` = `https://hyper.charm.land/v1` (or `$HYPER_URL` when set).
The OAuth device endpoints in §2 are served from the auth service root,
not under `/v1`.

---

## 2. Authentication — OAuth device flow

Crush authenticates to Hyper via a **device authorization flow**
(RFC 8628-style), then exchanges the resulting refresh token for an access
token. Each token exchange **rotates** the refresh token (the previous one
is consumed), so a `401` on an LLM request means the refresh token was
already used and the user must re-authenticate.

### 2.1 Initiate device auth

```
POST /device/auth
```

Body:

```json
{ "device_name": "Crush (myhostname)" }
```

`device_name` defaults to `Crush (<hostname>)`, or `Crush` when the hostname
is unavailable.

Response `200` — `DeviceAuthResponse`:

```jsonc
{
  "device_code": "abc...",
  "user_code": "WDJB-MJHT",
  "verification_url": "https://charm.land/hyper/device",
  "expires_in": 600, // seconds the device_code remains valid
}
```

### 2.2 Poll for authorization

```
GET /device/auth/{device_code}
```

Polled by the client every `5s` until authorization completes or the code
expires (`expires_in`). Response `200` — `TokenResponse`:

```jsonc
// Pending:
{ "error": "authorization_pending", "error_description": "..." }

// Complete (refresh_token present):
{
  "refresh_token":     "rf_...",
  "user_id":           "usr_...",
  "organization_id":   "org_...",
  "organization_name": "Acme"
}

// Failure:
{ "error": "...", "error_description": "..." }
```

Flow on the client:

- `refresh_token != ""` → authorization complete; use the refresh token.
- `error == "authorization_pending"` → keep polling.
- anything else → fail with `error_description`.

### 2.3 Exchange refresh token for access token

```
POST /token/exchange
```

Body:

```json
{ "refresh_token": "rf_..." }
```

Response `200` — a token object (consumed by Crush as `internal/oauth.Token`),
with `expires_at` set from the reported lifetime. On non-`200`, Hyper returns
an exchange error; Crush surfaces a `TokenExchangeError`.

**Rotation note:** this endpoint consumes the presented refresh token. The
new refresh token (if any) replaces it for the next exchange.

### 2.4 Token introspection

```
POST /token/introspect
```

OAuth2 Token Introspection (RFC 7662). Body:

```json
{ "token": "<access_token>" }
```

Response `200` — `IntrospectTokenResponse`:

```jsonc
{
  "active": true,
  "sub": "usr_...",
  "org_id": "org_...",
  "exp": 1700000000,
  "iat": 1699990000,
  "iss": "https://hyper.charm.land",
  "jti": "...",
}
```

---

## 3. Chat completions

```
POST {base}/chat/completions
Authorization: Bearer <access_token>
```

Hyper exposes the **OpenAI Chat Completions** wire format with a few
Hyper-specific fields. This is the endpoint crush.el targets.

### 3.1 Headers

In addition to auth, Crush sends **session-affinity** headers on every LLM
request so a conversation's requests are routed to the same upstream cache:

```
x-session-id:        <xxh3 hash of the session UUID>
x-session-affinity:  <xxh3 hash of the session UUID>
```

The value is a deterministic XXH3 hash of the Crush session UUID (not the
raw UUID), so it is opaque and stable for the life of the session. This is
what enables **server-side prefix/token caching** across turns.

### 3.2 Request body

```jsonc
{
  "model": "qwen3.7-plus",
  "stream": true,
  "reasoning_effort": "high", // depth of reasoning; only matters when thinking is true
  "thinking": false, // master switch: false = no chain-of-thought, effort is inert
  "max_tokens": 64000,
  "temperature": 0.7, // optional
  "tool_choice": "auto", // optional
  "tools": [
    /* function tool announcements, see 3.3 */
  ],
  "messages": [
    /* the conversation, see 3.4 */
  ],
}
```

**Hyper-specific / notable fields:**

| Field              | Meaning                                                                                                                                                                                                                                                                                                                                                               |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reasoning_effort` | Reasoning level for models that support it; defaults come from the model catalog (`default_reasoning_effort`, e.g. `high`, `max`).                                                                                                                                                                                                                                    |
| `thinking`         | Master switch for chain-of-thought reasoning (deepseek-style thinking mode). When `true` the model emits a `reasoning_content` trace before the final answer; `false` skips reasoning and answers directly, making `reasoning_effort` a no-op. Equivalent to DeepSeek's `{"thinking": {"type": "enabled"}}`. Sent as a bare boolean by Crush on the `hyper` provider. |
| `extra_body`       | Additional provider-specific fields are merged into the body for openai-compatible providers.                                                                                                                                                                                                                                                                         |

### 3.3 Tool announcements

Tools are announced on **every** request using the OpenAI function format
(`tools` is always sent by Crush since it always registers its tool catalogue):

```jsonc
{
  "type": "function",
  "function": {
    "name": "glob",
    "description": "Find files by name/pattern, sorted by modification time; max 100 results...",
    "parameters": {
      "type": "object",
      "properties": {
        "pattern": {
          "type": "string",
          "description": "The glob pattern to match files against",
        },
        "path": {
          "type": "string",
          "description": "Directory to search in. Defaults to cwd.",
        },
      },
      "required": ["pattern"],
    },
    "strict": false,
  },
}
```

`tool_choice` accepts `"auto"`, `"none"`, `"required"`, or `{ "type":
"function", "function": { "name": "<tool>" } }`.

### 3.4 Message roles

| Role        | Content                    | Notes                                                                      |
| ----------- | -------------------------- | -------------------------------------------------------------------------- |
| `system`    | string                     | Agent system prompt (critical rules + project context + MCP instructions). |
| `user`      | string                     | User prompt; may include attachments or shell-command context inline.      |
| `assistant` | string and/or `tool_calls` | Final answer, or a tool-call block.                                        |
| `tool`      | string                     | Tool result; always paired with the preceding `tool_call_id`.              |

Assistant tool calls use the OpenAI shape:

```jsonc
{
  "role": "assistant",
  "content": null,
  "tool_calls": [
    {
      "id": "call_abc123",
      "type": "function",
      "function": {
        "name": "grep",
        "arguments": "{\"pattern\":\"...\",\"include\":\"*.go\"}",
      },
    },
  ],
}
```

Tool results use `role: "tool"` with `tool_call_id`:

```jsonc
{
  "role": "tool",
  "tool_call_id": "call_abc123",
  "content": "language_model_hooks.go:531: case openai.MessageRoleTool:...",
}
```

### 3.5 Response / streaming

`stream: true` returns an SSE stream of Chat Completions chunks with the
standard `delta` fields (`content`, `tool_calls.arguments`, `finish_reason`).
`finish_reason` is one of `stop`, `tool_calls`, `length`, or content-filter
values.

Non-streamed response (`choices[0].message`, OpenAI shape):

```jsonc
{
  "choices": [{
    "message": { "role": "assistant", "content": "...", "tool_calls": [ ... ] },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 1521, "completion_tokens": 38, "total_tokens": 1559 }
}
```

**Reasoning content:** models with `can_reason` may return a
`reasoning_content` field on the assistant message. This field carries the
model's chain-of-thought trace, produced only when `thinking: true` (the
on/off switch). Crush reads it from the raw JSON and surfaces it as a
thinking/reasoning trace (streamed via `reasoning_content` deltas before the
final `content` deltas), distinct from the visible `content`. `reasoning_effort`
is not independent of `thinking`: it only selects how deep that reasoning
goes, and has no effect when `thinking` is false. When thinking is enabled, the trace must be echoed back — as
`reasoning_content` on the assistant message — on any subsequent request that
carries that turn (including tool-call rounds); some providers require it
present (or empty) on assistant tool-call messages in the history.

**Tool-call round trip:** the assistant turn with `tool_calls` and
`finish_reason: "tool_calls"` is persisted and re-sent on the next request,
immediately followed by `tool` role messages carrying each result. This
whole block is treated as one assistant + tool exchange in the history.

---

## 4. Credits

```
GET /v1/credits
Authorization: Bearer <access_token>
```

Response `200`:

```jsonc
{ "balance": 12345 } // hypercredits remaining
```

Special cases:

- `{ "balance": null }` — the team has **hypercredit display disabled**;
  Hyper reports the balance in dollars instead, so no hypercredit figure is
  shown. Crush returns `nil` (no balance) rather than `0`.
- Crush normally avoids this call entirely: it extracts remaining
  hypercredits from the `usage.remaining.hypercredits` field of chat
  response metadata and only falls back to `GET /v1/credits` when no cached
  value is available from the last response.

---

## 5. Model catalog

The embedded `provider.json` is the model catalog Crush ships with and is
refreshed via:

```
GET /v1/provider        // go:generate wget -O provider.json https://hyper.charm.land/v1/provider
```

Top-level shape:

```jsonc
{
  "name": "Charm Hyper",
  "id": "hyper",
  "api_endpoint": "https://hyper.charm.land/v1/chat/completions",
  "type": "hyper",
  "default_large_model_id": "qwen3.7-plus",
  "default_small_model_id": "deepseek-v4-flash-0731",
  "models": [
    {
      /* see below */
    },
  ],
}
```

Each model entry:

| Field                      | Type     | Meaning                                                                    |
| -------------------------- | -------- | -------------------------------------------------------------------------- |
| `id`                       | string   | Model id passed as `model` in requests.                                    |
| `name`                     | string   | Display name.                                                              |
| `cost_per_1m_in`           | number   | Uncached input cost per 1M tokens.                                         |
| `cost_per_1m_out`          | number   | Output cost per 1M tokens.                                                 |
| `cost_per_1m_in_cached`    | number   | **Cached** input cost per 1M tokens (0 = free cache hits).                 |
| `cost_per_1m_out_cached`   | number   | Cached output cost per 1M tokens.                                          |
| `context_window`           | integer  | Context window in tokens.                                                  |
| `default_max_tokens`       | integer  | Default `max_tokens` to send.                                              |
| `can_reason`               | bool     | Whether the model supports reasoning/thinking.                             |
| `reasoning_levels`         | string[] | Supported reasoning levels (`low`, `medium`, `high`, `max`, `xhigh`, ...). |
| `default_reasoning_effort` | string   | Reasoned effort used when unset.                                           |
| `supports_attachments`     | bool     | Whether the model accepts file/image attachments.                          |

---

## 6. Gotchas & caching behavior

- **Full context is re-sent every turn.** Crush resends the entire message
  history plus the full tool catalogue on each request; only the new tail
  differs. The identical prefix (system prompt + prior turns) is what allows
  server-side prefix caching, billed at `cost_per_1m_in_cached`.
- **Affinity by session.** The `x-session-id` / `x-session-affinity` headers
  keep a conversation pinned to the same upstream cache node.
- **Rotating refresh tokens.** Because each `/token/exchange` consumes the
  presented refresh token, an HTTP `401` on an LLM request indicates the
  refresh token is stale/consumed and the client must re-run the device
  flow (`crush auth`).
- **`thinking` gates `reasoning_effort`.** `thinking` (boolean) is the master
  switch for chain-of-thought reasoning: `true` makes the model emit
  `reasoning_content` deltas before the answer, `false` skips reasoning
  entirely. `reasoning_effort` (`low`/`medium`/`high`/`max`) only tunes how
  deep that reasoning goes, and is inert while `thinking` is false. Hyper
  maps the boolean to the DeepSeek thinking-mode format
  (`{"thinking": {"type": "enabled"}}`). Crush sets `thinking` from the
  per-model `think` config and injects a default `reasoning_effort` for
  reasoning-capable models.
- **Provider-family quirks.** Because Hyper is openai-compatible, Crush's
  OpenAI/`openaicompat` hooks apply: media tool results are fanned out into
  separate messages (an OpenAI `tool` message cannot carry images/audio), and
  tool-call JSON is validated/repaired before execution.

---

## References

- Hyper provider implementation: [`internal/agent/hyper/provider.go`](https://github.com/charmbracelet/crush/blob/main/internal/agent/hyper/provider.go)
- Model catalog: [`internal/agent/hyper/provider.json`](https://github.com/charmbracelet/crush/blob/main/internal/agent/hyper/provider.json)
- OAuth device flow: [`internal/oauth/hyper/device.go`](https://github.com/charmbracelet/crush/blob/main/internal/oauth/hyper/device.go)
- Provider/chat request assembly: [`internal/agent/coordinator.go`](https://github.com/charmbracelet/crush/blob/main/internal/agent/coordinator.go)
- Session affinity & caching: [`internal/agent/agent.go`](https://github.com/charmbracelet/crush/blob/main/internal/agent/agent.go)
- Provider abstraction: `providers/openaicompat`, `providers/openai` (OpenAI-compatible)
