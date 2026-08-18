# crush.el TODO

## Goal

crush.el is a GNU Emacs package for **direct provider interaction**: chatting with AI models over HTTP from an Emacs buffer, without a separate CLI binary. The provider talks to the [Charm Hyper gateway](HYPER-API.md) via streaming chat completions.

It operates in two ways:

1. **Dedicated chat buffer**: A buffer that sends structured prompts to the provider (hyper) and receives streamed responses, including chain-of-thought reasoning. The hyper provider is stateful per buffer; `crush-hyper-history-limit` 0 restores stateless per-prompt requests.

2. **Selection-as-context**: In any Emacs buffer, a selection can be used as context. When sent, the selection is formatted as a markdown fenced code block with file path and line numbers, then inserted into the crush buffer. The user can then add additional context about what to do with the selection before sending the prompt.

## Provider Strategy

crush.el talks to providers through a provider abstraction (`crush-provider-*` generic methods over `cl-defstruct` providers). The protocol and shared base struct live in `crush-provider.el`; the HTTP+SSE wire work lives once in the reusable OpenAI client `crush-openai.el`; the concrete provider is a dedicated, self-contained, **buffer-unaware** file:

- **Charm Hyper provider (`crush-hyper-provider.el`, default)** — direct HTTP calls to the Charm Hyper gateway ([HYPER-API.md](HYPER-API.md)), streaming chat completions, delegating request composition and transport to `crush-openai.el`. This is the **primary** provider.

## Interaction Model

- **Per-prompt calling (hyper)**: Each prompt is a single streaming chat completion against the provider. The hyper provider keeps no conversation state of its own; history round trips are handled by re-sending the buffer's prior turns.
- **Per-root buffers**: Each project (or directory when none) gets its own crush buffer, named after the root's basename (`*crush:name*`, suffix `(2)` on collisions). `crush-minor-mode` commands always target the buffer for the source buffer's project or directory.
- **Context format**: Selections are formatted as markdown fenced code blocks with an attachment header line:

````
**Attachment: src/foo.go (lines 42-58)**

```go
...selected code...
````

## Roadmap

### Phase 1: Core (complete)

- [x] Skeleton: `crush.el`, `README.md`, `TODO.md`
- [x] Response streaming into the crush buffer
- [x] Session continuity via the buffer's tagged regions + session-affinity headers
- [x] Selection insertion as markdown fenced code blocks
- [x] Prompt region management (marker-based prompt tracking)
- [x] Input locking while process runs
- [x] Prompt response header in buffer
- [x] Stderr routing to separate `*crush-errors*` buffer
- [x] Working directory resolution (`crush-working-directory` / project root)
- [x] ERT test suite with mock HTTP integration tests
- [x] Minor mode (`crush-minor-mode`) for source buffer keybindings
- [x] `crush-insert-buffer` (whole buffer as context)
- [x] `crush-insert-filepath` (file path as context)
- [x] Context blocks inserted before prompt as attachments
- [x] Context sent as literal markdown inside the LLM message with an explanatory preamble
- [x] Shared buffer init helper (`crush--init-buffer`)
- [x] `format.sh` for elisp, markdown, and shell formatting
- [x] Model selection via `crush-model` defcustom
- [x] Manual session selection via `crush--session`
- [x] Tool execution policy (`crush-tool-policy`, `yolo` in v1)

### Phase 1b: Comint removal & text-mode migration (complete)

The package originally derived from `comint-mode`; it no longer does. Commit `435d89b` removed the comint backend and subsequent commits finished the migration: the buffer's parent mode is now markdown/text-mode with a custom output filter, marker-based prompt tracking, text-property read-only, and the `crush-chat-mode` minor mode.

- [x] `crush-chat-mode` minor mode (keybindings, hooks) on top of a markdown-mode/text-mode parent
- [x] Marker-based prompt tracking (`crush--prompt-start-marker`, `crush--input-start-marker`) replacing comint prompt fields
- [x] Custom output filter (`crush--openai-curl-filter`) inserting at the process mark
- [x] Custom input ring (M-p/M-n) persisted to `~/.emacs.d/crush-history`
- [x] Read-only prompt and history via text properties (`rear-nonsticky` boundaries)
- [x] Font-lock guard and post-command re-assertion so markdown refontification cannot break input editability
- [x] Debug logging to `*crush-debug*` buffer
- [x] Removal-assertion tests (no `(require 'comint)`, no `crush-mode`, no `crush--build-command`, no separator region type)

### Phase 1c: Fontification (complete — superseded by 1d)

The overlay/temp-buffer fontification described here was later removed entirely; see Phase 1d.

- [x] Region-based fontification dispatch (`crush--fontify-region`)
- [x] Responses: markdown parent mode with native font-lock, `crush-response-face` fallback in text-mode
- [x] Attachments: org fontification via temp-buffer technique
- [x] Overlay-based faces (survive `jit-lock` refontification)
- [x] `crush-fontify-responses` and `crush-fontify-attachments` defcustoms
- [x] Region type tagging (`response`, `org`)

### Phase 1d: Markdown attachments (complete)

Attachments are rendered as markdown (fenced blocks with a header line, or links), so the parent mode's font-lock highlights them; the org temp-buffer fontification machinery, `crush-response-face`/`crush-org-face`, and the `crush-fontify-*` defcustoms were removed.

- [x] Selections formatted as markdown fenced code blocks with `**Attachment: <relpath> (lines N-M)**` header; `crush-insert-filepath` inserts a link
- [x] Paths resolved relative to the project root (or `default-directory`); language derived from file extension (`crush--lang-from-extension`, fallback `plaintext`)
- [x] `crush-region-type` taxonomy reduced to `attachment` / `response`; `crush-filename` / `crush-lines` metadata properties
- [x] Org fontify functions, faces, and defcustoms removed; `org-mode` dependency dropped

### Phase 1e: Markdown-mode key conflicts (complete)

Chat commands are all reachable via keys that markdown-mode does not bind.

- [x] Moved chat commands under the free `C-c c` prefix (`crush-chat-command-map`): `s` send, `i` interrupt, `k` clear, `a` insert selection
- [x] `RET` still sends; `M-p`/`M-n` still navigate history; `crush-minor-mode` source-buffer keys unchanged

### Phase 1f: Hyper provider phase 1 — primary path (complete)

Direct HTTP streaming chat-completions against the Charm Hyper gateway. This is crush.el's primary mode of operation.

- [x] `crush-hyper-provider` struct + default provider
- [x] Request composition (`crush-openai-compose-request`): messages array, model, `stream: t`, max tokens, temperature, thinking/reasoning-effort options, no tools yet
- [x] SSE streaming via curl subprocess (gptel/plz pattern): config + body over stdin, `data-binary = @-`, deltas parsed in the process filter
- [x] Response finalization via the facade (`crush-facade--finalize`): tag region, fresh prompt, state reset (buffer-unaware backend emits deltas/errors through callbacks)
- [x] Reasoning display: `reasoning_content` deltas streamed into a styled, collapsible region (overlay + fold marker)
- [x] Dummy server fixture (`test/hyper-server.py`): capture-file philosophy, per-mode responses (ok-stream/slow/error-http/error-event/malformed/not-found/reasoning)
- [x] Wire integration tests: request capture, delta streaming + finalize, HTTP error surfacing, reasoning highlighting

### Phase 2: Provider features (primary roadmap)

- [x] Token storage via `auth-source` (`machine hyper.charm.land login apikey password sk-hyper-...`), gptel-style; `crush-hyper-token` accepts string/function/nil
- [x] In-buffer history round trip (default on): prior `[user, assistant (and tool)]` turns are read from the buffer's tagged regions and re-sent with each request (tool calls replay as the OpenAI-conformant assistant `tool_calls` + tool result pair with the real `tool_call_id`) (`crush-hyper-history-limit` caps the tail; 0 disables; `crush-hyper-history-include-reasoning` opts the CoT back in as `reasoning_content`)
- [x] `x-session-id` / `x-session-affinity` headers for server-side prefix/token caching ([HYPER-API.md §3.1](HYPER-API.md)), via a dedicated pure-Elisp XXH3-64 (`crush-xxh3.el`, seed 0, big-endian, 16-hex); per-buffer UUID (`crush--session-uuid`), rotated by `crush-clear-buffer`, gate `crush-hyper-session-cache-p`
- [x] Tool-call round trip ([HYPER-API.md §3.3](HYPER-API.md)): announce a tool set, execute calls, feed results back as `role: "tool"` messages. Two tools: `exec_command` and `write_stdin`
  - [x] Tool blocks rendered as markdown in the buffer (bold 🔧 tool name, inline parameter summary, fenced code block for output)
  - [x] Tool blocks are read-only, tagged `crush-region-type 'tool'`, and carry `crush-tool-call` for wire resume; the raw result span inside the block is tagged `crush-region-type 'tool-output'` so history sends the raw result text (never the rendered toolbar)
  - [x] Tool loop: up to `crush-tool-loop-max` (8) consecutive rounds, each round sends the assistant message with `tool_calls` plus `role: "tool"` results
  - [x] Tool output fenced code blocks escape nested fences via longest-backtick-run detection
  - [x] Tools run without confirmation (yolo)
  - [x] Stateful sessions for tool calls via `crush-process.el`: `exec_command` starts a PTY session and `write_stdin` feeds it, preserving cwd and environment within the session
  - [ ] Long-running command lifecycle: explicit session close/kill and idle-session reaping beyond `write_stdin`
- [ ] OAuth device flow in Emacs ([HYPER-API.md §2](HYPER-API.md)): initiate/poll `/device/auth`, exchange at `/token/exchange` (rotating refresh tokens), persist tokens, re-authenticate on 401 (tokens currently come from `auth-source` via `crush-hyper-token`)
- [ ] Model catalog from `GET /v1/models` (public, no auth): model picker, reasoning-effort selection
- [ ] Error handling and retry
- [ ] Hypercredit display from `usage.remaining.hypercredits`, with `GET /v1/credits` fallback ([HYPER-API.md §4](HYPER-API.md))
- [ ] Interrupt support for in-flight hyper requests (currently a cleanup stub; the "still running" guard does not block)
- [x] Tool call visibility in responses
- [ ] Conversation persistence to plain-text files (gptel-style, deferred): save `crush-region-type`/`crush-response-to`/attachment bounds plus `crush--session-uuid` as file-locals, recreate properties and recompute `crush--session-id` on open. Only the 16-hex XXH3 hash ever goes over the wire (to Hyper).

### Phase 3: Integration

- [ ] `use-package` integration
- [ ] MELPA submission
- [x] Project.el integration (auto-detect project root via `project-current`)
- [ ] Multiple concurrent crush sessions
- [ ] Keybindings for common operations (switch model, permission handling, etc.)

### Phase 4: Advanced

- [ ] MCP server support via Emacs
- [ ] Diff/patch application from crush responses
- [ ] Context menu for richer selection formatting
- [ ] Transient-based command dispatch

## Reference Docs

- [HYPER-API.md](HYPER-API.md) — Charm Hyper gateway HTTP API (auth, chat completions, model catalog)
