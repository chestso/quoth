# Quoth TODO

## Goal

Quoth is a GNU Emacs package for **direct provider interaction**: chatting with AI models over HTTP from an Emacs buffer, without a separate CLI binary. The provider talks to the [Charm Hyper gateway](HYPER-API.md) via streaming chat completions.

It works like this:

1. **Chat buffer**: `M-x quoth` opens a per-project buffer where prompts and streamed responses (including chain-of-thought reasoning and tool-call rounds) accumulate as ordinary editable markdown. The buffer is the conversation: history is re-sent from its tagged regions on every request, so nothing needs to be saved separately (`quoth-hyper-history-limit` 0 restores stateless per-prompt requests).

2. **Context insertion**: `quoth-minor-mode` commands push context from any buffer into the chat — a selection or whole buffer as a markdown fenced code block with a file-path header, the file path as a link, or an image as a link sent as pixels. Everything inserted is plain user input, so the user can add or edit the surrounding prompt before sending.

## Provider Strategy

Quoth talks to providers through a provider abstraction (`quoth-provider-*` generic methods over `cl-defstruct` providers). The protocol and shared base struct live in `quoth-provider.el`; the HTTP+SSE wire work lives once in the reusable OpenAI client `quoth-openai.el`; the concrete provider is a dedicated, self-contained, **buffer-unaware** file:

- **Charm Hyper provider (`quoth-hyper-provider.el`, default)** — direct HTTP calls to the Charm Hyper gateway ([HYPER-API.md](HYPER-API.md)), streaming chat completions, delegating request composition and transport to `quoth-openai.el`. This is the **primary** provider.

## Interaction Model

- **Per-prompt calling (hyper)**: Each prompt is a single streaming chat completion against the provider. The hyper provider keeps no conversation state of its own; history round trips are handled by re-sending the buffer's prior turns.
- **Per-root buffers**: Each project (or directory when none) gets its own quoth buffer, named after the root's basename (`*quoth:name*`, suffix `(2)` on collisions). `quoth-minor-mode` commands always target the buffer for the source buffer's project or directory.
- **Context format**: Inserted context is plain markdown user input, not a tracked attachment. Selections and whole buffers arrive as fenced code blocks fronted by a bold header naming the file and line span; file paths arrive as `[relpath](relpath)` links. The block itself is ordinary prompt text — only image links are true wire attachments, sent as `image_url` content parts:

````
**Source src/foo.go (lines 42-58)**

```go
...selected code...
````

## Roadmap

### Phase 1: Core (complete)

- [x] Skeleton: `quoth.el`, `README.md`, `TODO.md`
- [x] Response streaming into the quoth buffer
- [x] Session continuity via the buffer's tagged regions + session-affinity headers
- [x] Selection insertion as markdown fenced code blocks
- [x] Prompt region management (marker-based prompt tracking)
- [x] Input locking while process runs
- [x] Prompt response header in buffer
- [x] Stderr routing to separate `*quoth-errors*` buffer
- [x] Working directory resolution (`quoth-working-directory` / project root)
- [x] ERT test suite with mock HTTP integration tests
- [x] Minor mode (`quoth-minor-mode`) for source buffer keybindings
- [x] `quoth-insert-buffer` (whole buffer as context)
- [x] `quoth-insert-filepath` (file path as context)
- [x] Context blocks inserted before prompt as attachments
- [x] Context sent as literal markdown inside the LLM message with an explanatory preamble
- [x] Shared buffer init helper (`quoth--init-buffer`)
- [x] Formatting pipeline (`make format`, scripts under `scripts/`)
- [x] Model selection via `quoth-model` defcustom
- [x] Manual session selection via `quoth--session`
- [x] Tool execution policy (`quoth-tool-policy`, `yolo` in v1)

### Phase 1b: Comint removal & text-mode migration (complete)

The package originally derived from `comint-mode`; it no longer does. Commit `435d89b` removed the comint backend and subsequent commits finished the migration: the buffer's parent mode is now markdown/text-mode with a custom output filter, marker-based prompt tracking, and the `quoth-chat-mode` minor mode.

- [x] `quoth-chat-mode` minor mode (keybindings, hooks) on top of a markdown-mode/text-mode parent
- [x] Marker-based prompt tracking (`quoth--prompt-start-marker`, `quoth--input-start-marker`) replacing comint prompt fields
- [x] Custom output filter (`quoth--openai-curl-filter`) inserting at the process mark
- [x] Custom input ring (M-p/M-n) persisted to `~/.emacs.d/quoth-history`
- [x] Font-lock guard so markdown refontification preserves reasoning fold properties
- [x] Debug logging to `*quoth-debug*` buffer
- [x] Removal-assertion tests (no `(require 'comint)`, no `quoth-mode`, no `quoth--build-command`, no separator region type)

### Phase 1c: Fontification (complete — superseded by 1d)

The overlay/temp-buffer fontification described here was later removed entirely; see Phase 1d.

- [x] Region-based fontification dispatch (`quoth--fontify-region`)
- [x] Responses: markdown parent mode with native font-lock, `quoth-response-face` fallback in text-mode
- [x] Attachments: org fontification via temp-buffer technique
- [x] Overlay-based faces (survive `jit-lock` refontification)
- [x] `quoth-fontify-responses` and `quoth-fontify-attachments` defcustoms
- [x] Region type tagging (`response`, `org`)

### Phase 1d: Markdown attachments (complete)

Attachments are rendered as markdown (fenced blocks with a header line, or links), so the parent mode's font-lock highlights them; the org temp-buffer fontification machinery, `quoth-response-face`/`quoth-org-face`, and the `quoth-fontify-*` defcustoms were removed.

- [x] Selections formatted as markdown fenced code blocks with `**Source <relpath> (lines N-M)**` header; `quoth-insert-filepath` inserts a link
- [x] Paths resolved relative to the project root (or `default-directory`); language derived from file extension (`quoth--lang-from-extension`, fallback `plaintext`)
- [x] `quoth-region-type` taxonomy reduced to `attachment` / `response`; `quoth-filename` / `quoth-lines` metadata properties
- [x] Org fontify functions, faces, and defcustoms removed; `org-mode` dependency dropped

### Phase 1e: Markdown-mode key conflicts (complete)

Chat commands are all reachable via keys that markdown-mode does not bind.

- [x] Chat commands live under the free `C-c c` prefix (`quoth-chat-command-map`): `s` send, `i` interrupt, `k` clear, `r` toggle reasoning, `m` select model
- [x] `RET`/`C-j` fall through to the parent mode's newline editing; `C-return` sends in graphical/kitty terminals, and `M-p`/`M-n` navigate input history; `quoth-minor-mode` source-buffer keys unchanged

### Phase 1f: Hyper provider phase 1 — primary path (complete)

Direct HTTP streaming chat-completions against the Charm Hyper gateway. This is Quoth's primary mode of operation.

- [x] `quoth-hyper-provider` struct + default provider
- [x] Request composition (`quoth-openai-compose-request`): messages array, model, `stream: t`, max tokens, temperature, thinking/reasoning-effort options (tools now live in the reusable schema regardless of provider)
- [x] SSE streaming via curl subprocess (gptel/plz pattern): config + body over stdin, `data-binary = @-`, deltas parsed in the process filter
- [x] Response finalization (`quoth--finalize-response`): tag region, fresh prompt, state reset (providers emit deltas/errors through callbacks)
- [x] Reasoning display: `reasoning_content` deltas streamed into a styled, collapsible region (overlay + fold marker)
- [x] Dummy server fixture (`test/hyper-server.py`): capture-file philosophy, per-mode responses (ok-stream/slow/error-http/error-event/malformed/not-found/reasoning)
- [x] Wire integration tests: request capture, delta streaming + finalize, HTTP error surfacing, reasoning highlighting

### Phase 2: Provider features (primary roadmap)

- [x] Token storage via `auth-source` (`machine hyper.charm.land login apikey password sk-hyper-...`), gptel-style; `quoth-hyper-token` accepts string/function/nil
- [x] Header-line usage: input (`↑`) and output (`↓`) tokens shown separately, cost (currency via `quoth-hyper-usage-currency`), and cache-hit percentage (cached ÷ input tokens; session-wide via `quoth--usage-acc`)
- [x] In-buffer history round trip (default on): prior `[user, assistant (and tool)]` turns are read from the buffer's tagged regions and re-sent with each request (tool calls replay as the OpenAI-conformant assistant `tool_calls` + tool result pair with the real `tool_call_id`) (`quoth-hyper-history-limit` caps the tail; 0 disables; `quoth-hyper-history-include-reasoning` opts the CoT back in as `reasoning_content`)
- [x] `x-session-id` / `x-session-affinity` headers for server-side prefix/token caching ([HYPER-API.md §3.1](HYPER-API.md)), via a dedicated pure-Elisp XXH3-64 (`quoth-xxh3.el`, seed 0, big-endian, 16-hex); per-buffer UUID (`quoth--session-uuid`), rotated by `quoth-clear-buffer`, gate `quoth-hyper-session-cache-p`
- [x] Tool-call round trip ([HYPER-API.md §3.3](HYPER-API.md)): announce a tool set, execute calls, feed results back as `role: "tool"` messages. Two tools: `exec_command` and `write_stdin`
  - [x] Tool blocks rendered as markdown in the buffer (bold 🔧 tool name, inline parameter summary, fenced code block for output)
  - [x] Tool blocks are tagged `quoth-region-type 'tool'` and carry `quoth-tool-call` for wire resume; the raw result span inside the block is tagged `quoth-region-type 'tool-output'` so history sends the raw result text (never the rendered toolbar)
  - [x] Tool loop: up to `quoth-tool-loop-max` (8) consecutive rounds, each round sends the assistant message with `tool_calls` plus `role: "tool"` results
  - [x] Tool output fenced code blocks escape nested fences via longest-backtick-run detection
  - [x] Tools run without confirmation (yolo)
  - [x] Stateful sessions for tool calls via `quoth-process.el`: `exec_command` starts a PTY session and `write_stdin` feeds it, preserving cwd and environment within the session
  - [x] Event-driven operation: the session layer reports exits through a sentinel and running output through one-shot window timers (never a blocking yield); the tool round is an event chain (placeholders with a live `⏳ running…` status filled on completion, exactly-once delivery, follow-up composed from the buffer), and buffer surgery never runs on a process filter/sentinel stack (0-timer hops through `quoth--schedule`)
  - [ ] Long-running command lifecycle: explicit session close/kill and idle-session reaping beyond `write_stdin`
- [x] Event-driven sends end to end: the system prompt stages asynchronously (`quoth-openai--system-prompt-async` — one marker-delimited git process with `quoth-openai-git-timeout` abort-and-degrade, cache hit inline, buffer-init prefetch), the send enters `preparing` until the staged prompt delivers and curl fires, and the provider returns a request handle `(:stage-process/:curl/:done-p)` stored in the `request` slot so `active-p`/`interrupt`/`cleanup`/usage and tool-call reads cover both stages; the runtime sources carry no blocking process/network primitives (lint-enforced, `test/quoth-test-stage.el`)
- [ ] OAuth device flow in Emacs ([HYPER-API.md §2](HYPER-API.md)): initiate/poll `/device/auth`, exchange at `/token/exchange` (rotating refresh tokens), persist tokens, re-authenticate on 401 (tokens currently come from `auth-source` via `quoth-hyper-token`)
- [x] Model catalog fetched asynchronously with a global TTL cache (`quoth-provider-models-cached` / `-refresh`, stale-while-revalidate, in-flight dedup, `quoth-provider-models-hook`); the selector and `quoth-select-model` read the cache only (never a blocking fetch), a `g` suffix on the C-c c m transient force-refreshes, and new buffers prefetch the catalog at init
- [ ] Model catalog — closes when the model cache is seeded from a bundled snapshot: ship the current `/v1/provider` payload in the package (Crush's own `go:generate wget -O provider.json` trick), prime the provider's cache from it before the first network refresh, and let the live refresh override it, so a first-ever `C-c c m` lists every model with prices and effort levels instead of the single static default. The endpoint question behind this item is settled and recorded in [HYPER-API.md §5](HYPER-API.md): `/v1/models` is live and public with the same id set as `/v1/provider`, neither needs a token, and quoth keeps `/v1/provider` because `quoth-hyper--normalize-model` already speaks its schema (`/v1/models` would need a second normalizer: `reasoning.effort_levels` as `{value, display}` objects, `capabilities.vision`, `pricing.*`). Per-model reasoning-effort selection already works (`e` in `C-c c m`); the seed only removes the cold-cache window the buffer-init prefetch narrows.
- [x] Error handling: HTTP non-2xx, SSE `error` payloads, streams closed before `[DONE]`, and tool errors all surface in the buffer as a `> **Error:** …` system pane (wire-tested; see ARCHITECTURE.md principle 9 for the deliberate no-automatic-retry stance — re-sending is always the user's explicit `C-c c s`)
- [ ] Hypercredit display from `usage.remaining.hypercredits`, with `GET /v1/credits` fallback ([HYPER-API.md §4](HYPER-API.md)). The per-request `cost.hypercredits` is already surfaced in the header line as `hc` (see `quoth-hyper-usage-currency`); this item is only about adding the _remaining_ balance from the credits endpoint
- [x] Interrupt support for in-flight hyper requests (`quoth-interrupt` aborts the provider transport; `quoth-send-input` blocks while the provider is active)
- [x] Tool call visibility in responses
- [ ] Conversation persistence to plain-text files (gptel-style, deferred): save `quoth-region-type`/`quoth-response-to`/attachment bounds plus `quoth--session-uuid` as file-locals, recreate properties and recompute `quoth--session-id` on open. Only the 16-hex XXH3 hash ever goes over the wire (to Hyper).

### Phase 3: Integration

- [ ] `use-package` integration
- [ ] MELPA submission
- [x] Project.el integration (auto-detect project root via `project-current`)
- [ ] Multiple concurrent quoth sessions
- [ ] Keybindings for common operations beyond `C-c c` (permission handling for a future `ask`/`allowlist`, interrupt is already `C-c c i`; model selection via `C-c c m`)

### Phase 4: Advanced

- [ ] MCP server support via Emacs
- [ ] Diff/patch application from quoth responses
- [ ] Context menu for richer selection formatting
- [ ] Transient-based command dispatch

## Reference Docs

- [HYPER-API.md](HYPER-API.md) — Charm Hyper gateway HTTP API (auth, chat completions, model catalog)
