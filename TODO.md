# crush.el TODO

## Goal

crush.el is a GNU Emacs package for interacting with the [Crush CLI](https://github.com/charmbracelet/crush).

It operates in two ways:

1. **Dedicated chat buffer**: A buffer that sends structured prompts to the Crush CLI and receives responses through the CLI. The buffer maintains a single continuous session across prompts (using `crush run --continue`), so follow-up questions keep context.

2. **Selection-as-context**: In any Emacs buffer, a selection can be used as context. When sent, the selection is formatted as a markdown fenced code block with file path and line numbers, then inserted into the crush buffer. The user can then add additional context about what to do with the selection before sending the prompt.

## Backend Strategy

crush.el talks to Crush through a backend abstraction (`crush-backend-*` generic methods over `cl-defstruct` backends):

- **`crush run` CLI backend (`crush-run-backend`)** — implemented. Each prompt spawns a `crush run --quiet` process.
- **Direct API backend (`crush-hyper-backend`, implemented, phase 1)** — direct HTTP calls to the Charm Hyper gateway ([HYPER-API.md](HYPER-API.md)), bypassing the CLI entirely.

## Interaction Model

- **Per-prompt calling**: Each prompt is sent to `crush run` as a separate invocation. The CLI streams the response to stdout and exits.
- **Per-root buffers**: Each project (or directory when none) gets its own crush buffer, named after the root's basename (`*crush:name*`, suffix `(2)` on collisions). `crush-minor-mode` commands always target the buffer for the source buffer's project or directory.
- **Session continuity**: The first prompt starts a fresh session. Each subsequent prompt passes `--continue`, which continues the active session in the working directory. `crush-new-session` resets this so the next prompt starts a new session.
- **Manual session selection**: Setting `crush--session` passes `--session <id>` to continue a specific session by ID.
- **Context format**: Selections are formatted as markdown fenced code blocks with an attachment header line:

````
**Attachment: src/foo.go (lines 42-58)**

```go
...selected code...
````

```

## Roadmap

### Phase 1: Core (complete)

- [x] Skeleton: `crush.el`, `README.md`, `TODO.md`
- [x] Basic prompt sending via `crush run`
- [x] Response streaming into the crush buffer
- [x] Session continuation via `--continue`
- [x] Selection insertion as markdown fenced code blocks
- [x] Prompt region management (marker-based prompt tracking)
- [x] Input locking while process runs
- [x] Prompt response header in buffer
- [x] Stderr routing to separate `*crush-errors*` buffer
- [x] Working directory resolution (`crush-working-directory` / project root)
- [x] ERT test suite with mock CLI integration tests
- [x] Minor mode (`crush-minor-mode`) for source buffer keybindings
- [x] `crush-insert-buffer` (whole buffer as context)
- [x] `crush-insert-filepath` (file path as context)
- [x] Context blocks inserted before prompt as attachments
- [x] Context sent to CLI via stdin with explanatory preamble
- [x] Shared buffer init helper (`crush--init-buffer`)
- [x] `format.sh` for elisp, markdown, and shell formatting
- [x] `--quiet` flag to suppress spinner output
- [x] SIGINT handling (show "Interrupted" message)
- [x] Model selection via `crush-model` defcustom (`--model` flag)
- [x] Manual session selection via `crush--session` (`--session` flag)
- [x] Permission behavior documentation (auto-approve warning)

### Phase 1b: Comint removal & text-mode migration (complete)

The package originally derived from `comint-mode`; it no longer does. Commit `435d89b` removed the comint backend and subsequent commits finished the migration: the buffer's parent mode is now markdown/text-mode with a custom output filter, marker-based prompt tracking, text-property read-only, and the `crush-chat-mode` minor mode.

- [x] `crush-chat-mode` minor mode (keybindings, hooks) on top of a markdown-mode/text-mode parent
- [x] Marker-based prompt tracking (`crush--prompt-start-marker`, `crush--input-start-marker`) replacing comint prompt fields
- [x] Custom output filter (`crush--output-filter`) inserting at the process mark
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

- [x] Moved chat commands under the free `C-c c` prefix (`crush-chat-command-map`): `s` send, `i` interrupt, `k` clear, `n` new session, `a` insert selection
- [x] `RET` still sends; `M-p`/`M-n` still navigate history; `crush-minor-mode` source-buffer keys unchanged

### Phase 1f: Hyper backend phase 1 (complete)

Direct HTTP chat-completions against the Charm Hyper gateway, bypassing the CLI.

- [x] `crush-hyper-backend` struct + `crush-backend-type` `hyper` choice
- [x] Request composition (`crush--hyper-compose-request`): messages array, model, `stream: t`, max tokens, temperature, thinking/reasoning-effort options, no tools yet
- [x] SSE streaming via curl subprocess (gptel/plz pattern): config + body over stdin, `data-binary = @-`, deltas parsed in the process filter
- [x] Response finalization shared with the run backend (`crush--finalize-response`): tag region, fresh prompt, state reset
- [x] Dummy server fixture (`test/hyper-server.py`) mirroring `mock-crush.sh`: capture-file philosophy, per-mode responses (ok-stream/slow/error-http/error-event/malformed)
- [x] Wire integration tests: request capture, delta streaming + finalize, HTTP error surfacing

### Phase 2: Polish

- [ ] Error handling and retry
- [ ] Conversation persistence to plain-text files (gptel-style): save `crush-region-type`/`crush-response-to`/attachment bounds as a file-local, recreate properties on open
- [ ] OAuth device flow in Emacs ([HYPER-API.md §2](HYPER-API.md)): initiate/poll `/device/auth`, exchange at `/token/exchange` (rotating refresh tokens), persist tokens, re-authenticate on 401 (`crush-hyper-token` is currently set manually)
- [ ] Session history: `x-session-id` / `x-session-affinity` headers plus an in-buffer history round trip (send prior `[user, assistant]` messages) ([HYPER-API.md §3.1](HYPER-API.md))
- [ ] Reasoning display: stream `reasoning_content` deltas into a styled region ([HYPER-API.md §3.5](HYPER-API.md))
- [ ] Model catalog from `GET /v1/provider` ([HYPER-API.md §5](HYPER-API.md)): model picker, reasoning-effort selection
- [ ] Tool-call round trip ([HYPER-API.md §3.3](HYPER-API.md)): announce a tool set, execute calls, feed results back as `role: "tool"` messages — plus a permission policy for tool execution (the CLI backend auto-approves; direct mode needs one)
- [ ] Tool call visibility in responses
- [ ] Hypercredit display from `usage.remaining.hypercredits`, with `GET /v1/credits` fallback ([HYPER-API.md §4](HYPER-API.md))
- [ ] Interrupt support for in-flight hyper requests (`crush-backend-interrupt` is currently a cleanup stub; `crush-process` stays nil so `crush-send-input`'s still-running guard does not block)

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

- [CRUSH-SPEC.md](CRUSH-SPEC.md) — Crush CLI protocol (flags, stdin semantics, permission model)
- [HYPER-API.md](HYPER-API.md) — Charm Hyper gateway HTTP API (auth, chat completions, model catalog)
```
