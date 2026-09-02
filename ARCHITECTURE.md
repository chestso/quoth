# Quoth Architecture

Developer-facing documentation for the Quoth codebase: how the
package is structured, how each provider works, how the chat buffer
tracks its content, and how to hack on it. User-facing documentation
lives in [README.md](README.md).

## Design Principles

These principles are load-bearing: every file and subsystem follows
them, and new code must too.

1. **The buffer is the single source of truth.** Every outgoing HTTP
   request — the initial send and every tool-loop follow-up — is
   reconstructed from the buffer's tagged regions (text properties) at
   send time. There is no cache, side table, or temporary store holding
   message history or tool state. Killing and reopening the buffer
   rebuilds an identical request. All conversation state lives in the
   buffer; persistence via **file local variables** is the planned
   next step (currently Phase 2 roadmap work — see
   `quoth--session-uuid`).

2. **The buffer is append-only.** The buffer only ever grows at
   point-max; completed content (prompts, responses, tool blocks,
   reasoning) is plain editable text, and history/state is derived
   from its tagged regions. Nothing is made read-only; the whole
   buffer — history included — stays editable, and edits flow into the
   next request because requests are rebuilt from the buffer.

3. **Text properties carry state; overlays are for special UI only.**
   Metadata (region type, prompt id, response linkage, tool-call
   payloads) is stored as text properties so it survives
   font-lock refontification. Overlays are reserved for transient,
   display-only features — the reasoning highlight + fold and the
   `system`-note overlays (transcript annotations; the underlying text
   is buffer text tagged `quoth-region-type` = `system`, never
   display-only).

4. **Protocols live in their own files.** The provider protocol
   (`quoth-provider.el`), the OpenAI chat-completions + tool protocol
   (`quoth-openai.el`), and the process-handler session protocol
   (`quoth-process.el`) are each a dedicated, self-contained file with a
   single dependency direction. `quoth.el` only orchestrates the buffer
   and calls into them.

5. **Providers are abstracted and reuse the protocols.** Every provider
   is a self-contained file implementing the `quoth-provider-*`
   generics. The shared wire work (request composition, SSE parsing,
   curl transport, tool dispatch) is implemented once in
   `quoth-openai.el`; the concrete hyper provider is a thin shim that
   maps its configuration onto that client.

6. **Buffer-unaware, presentation-agnostic layers.** The process
   handler (`quoth-process.el`) and all providers never read or write
   the quoth buffer. They treat the caller as opaque: the send loop in
   `quoth.el` is the only place with buffer access, and it threads
   progress, deltas, and errors through callbacks into those layers.
   Keeping the providers buffer-unaware is a deliberate separation of
   concerns, not an implementation detail.

7. **Everything inserted must be valid markdown.** The chat buffer's
   parent mode is `markdown-mode` (fallback `text-mode`); bodies,
   inserted context, tool blocks, and the input divider are all rendered as
   markdown constructs (fenced code blocks, bold headers, horizontal
   rules) so native font-lock and preview/export stay correct.

8. **No persistent process.** Each prompt fires a new HTTP request.
   Tool execution is the one exception: interactive commands run in PTY
   sessions owned by `quoth-process.el`, scoped per quoth buffer and
   capped at `quoth-process-max-sessions`.

## Project Layout

```
quoth/                  # Package root
  quoth.el              # Core: config, buffer orchestration, chat mode, helpers, commands
  quoth-provider.el     # Provider protocol: base struct + quoth-provider-* generics
  quoth-openai.el       # Reusable OpenAI chat-completions client (compose, SSE, curl transport, tool protocol)
  quoth-hyper-provider.el  # Charm Hyper provider (config + provider methods, thin shim over quoth-openai)
  quoth-select.el      # Transient model selector (UI only; depends on the protocol, not quoth.el)
  quoth-process.el      # Process handler: PTY sessions, output buffering, exit/running reporting, stdin, cleanup
  quoth-tools.el        # Local tool implementations: exec_command, write_stdin, write_file, read_file
  quoth-xxh3.el         # Pure-Elisp XXH3-64 (seed 0): x-session-id / x-session-affinity hashing
  quoth-json.el        # JSON decode/encode abstraction: native C parser when available, json.el fallback
  quoth-debug-tools.el  # On-demand debug commands (region dump, history reconstruction; not loaded by default)
  test/                 # ERT test suite (see "Hacking" below)
```

Dependency direction: `quoth-provider.el` has no `require`s (it owns
the shared session slots, the active-provider state, and the
`quoth-provider-*` generics, so the OpenAI client and the selector
depend on the protocol, not on `quoth.el`); `quoth-json.el` requires only `json` (a fallback); it exposes `quoth-json-read`
and `quoth-json-write`, preferring the native C `json-parse-string` when
`json-available-p` and keeping `json.el`'s representation contract. Every
file that parses or emits JSON (`quoth-openai`, `quoth-hyper-provider`,
`quoth-searxng`) calls through it. `quoth-openai.el` requires
only `quoth-provider` (for the session slots); `quoth-xxh3.el` has no
dependencies (pure math); `quoth-process.el` requires only `cl-lib`
and `subr-x`; `quoth-hyper-provider.el` requires `quoth-provider` +
`quoth-openai` + `quoth-xxh3`; `quoth-tools.el` requires
`quoth-openai` + `quoth-process` and registers its tools at load;
`quoth-select.el` requires `quoth-provider` + `quoth-openai` (both
leaves) and refreshes the UI through `quoth-after-model-change-hook`
rather than calling core functions — it never requires `quoth.el`;
`quoth.el` requires all of them (including `quoth-select`, for the
`C-c c m` keybinding). Stream state, buffer rendering,
and error handling (`quoth--append-delta`, `quoth--record-error`,
`quoth--stream-transition`, `quoth--debug-log`) all live in
`quoth.el` — the providers call them through buffer-local process
references and `declare-function` stubs.

## Provider Abstraction

All provider interaction goes through a provider protocol (the
`cl-defgeneric` methods `quoth-provider-send-prompt`,
`quoth-provider-interrupt`, `quoth-provider-active-p`,
`quoth-provider-cleanup`, `quoth-provider-grant-permission`,
`quoth-provider-model`, and the internal
`quoth-provider--models-async` + `quoth-provider--models-key`
(the async catalog fetch and its cache key — see the catalog cache
below), `quoth-provider--apply-model`, and `quoth-provider--tool-calls`
(reading the SSE stream's accumulated tool calls off the finished
transport). The protocol and
the shared `quoth-provider` base struct live in `quoth-provider.el`;
each concrete provider is a dedicated, buffer-unaware file:

- `quoth-hyper-provider.el` — the default implementation: direct HTTP
  to the Charm Hyper gateway (see below).

### Model catalog cache

The protocol module owns a **global** catalog cache:
`quoth-provider--models-cache`, keyed by
`quoth-provider--models-key` (provider type + resolved base URL for
hyper), shared across buffers of the same provider. All UI reads go
through `quoth-provider-models-cached` (never a fetch); a fresh entry
(inside `quoth-provider-models-ttl`, default 600 s) returns directly,
a stale entry returns immediately and kicks exactly one background
refresh (stale-while-revalidate, deduplicated in flight), and a
successful refresh runs `quoth-provider-models-hook`. Refreshes ride
the async `quoth-provider--models-async` generic; a failed fetch keeps
the cached entry. The selector's `g` suffix force-refreshes, buffer
initialization prefetches (`quoth-provider-models-prefetch`), and
`quoth-select-model` falls back to the static list on a cold cache.

The shared `quoth-provider` base struct has slots `buffer`,
`completion-action`, `working-directory`, `transport-process` (the live
transport process owned by the provider, set by `send-prompt`),
`application-count` (default 1), and `type`. The hyper provider
subclasses it and adds its own slots (base URL, token, model,
session-affinity hash, x-crush-id).

Process control is a provider responsibility, routed through the
protocol: `quoth-send-input` consults `quoth-provider-active-p` for its
"still running" guard, `quoth-interrupt` calls
`quoth-provider-interrupt`, and `quoth-clear-buffer` calls
`quoth-provider-cleanup`. The core never reads or kills a transport
process directly.

## The send loop

The send loop in `quoth.el` is the buffer-facing orchestration layer
that sits between the provider (wire work) and the chat buffer (source
of truth). It is the **single place that owns the buffer** and drives
the lifecycle of one prompt → response cycle.

| Function                                              | Role                                                                                             |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `quoth--phase-set` / `quoth--busy-p`                  | The single writer of / reader for the phase machine (`idle`/`preparing`/`streaming`/`tools`)     |
| `quoth--schedule`                                     | The 0-timer hop: buffer surgery and follow-up sends never run on a filter/sentinel stack         |
| `quoth--send-prompt`                                  | Start a request, inject the callbacks, transition to `streaming`                                 |
| `quoth--append-delta`                                 | Consume streamed `(delta kind)` chunks and insert them at point-max (the only buffer writer)     |
| `quoth--finalize-response`                            | On completion (via the hop): accumulate usage, then arm the round dispatch or close the response |
| `quoth--round-dispatch`                               | Insert placeholder blocks for every pending call, then run the registry entries                  |
| `quoth--round-complete`                               | Fill the completing call's block; the last completion schedules the follow-up                    |
| `quoth--round-followup`                               | Rebuild the continuation from the buffer's tool rounds, clear the old transport, re-send         |
| `quoth--round-abandon` / `--round-cancel`             | Interrupt/clear/kill: cancel pending waits, fill interrupted results, clear the round            |
| `quoth--tool-block-placeholder` / `--tool-block-fill` | Render a pending tool block with a live status line and swap in the fenced result on completion  |
| `quoth--close-response`                               | Tag the response region, insert a fresh `---` divider                                            |
| `quoth--record-error`                                 | On failure: set `quoth--pending-interrupt` = `error` and insert the `> **Error:**` system pane   |
| `quoth--insert-system-note`                           | Shared `system`-region inserter (error pane / `> **Interrupted.**` note), tagged at insert time  |
| `quoth--tag-response-region`                          | Tag response (and reasoning) spans; stamp `quoth-interrupted`; skip `tool`/`reasoning`/`system`  |
| `quoth--stream-progress` / `--stream-clear`           | Read the phase machine for UI consumers / reset it to a fresh `idle`                             |

### Why the boundary exists

The send loop is a **separation-of-concerns boundary** (design
principle #6). Three motivations:

1. **The provider must never touch the buffer.** The provider (and the
   OpenAI client, SSE parser, and curl transport beneath it) only
   knows how to send bytes and emit callbacks. It receives the buffer
   as an _opaque data object_ — never read, never switched to.
2. **The buffer is the single source of truth.** Requests are rebuilt
   from text properties at send time. If the provider wrote directly
   to the buffer, wire logic would entangle with buffer layout and
   break that invariant.
3. **One choke point for "stream event → buffer edit".** The send loop
   is the only place with buffer access, so the streaming hot path
   (`quoth--insert-at-eof` with `inhibit-modification-hooks`) and the
   reasoning-overlay logic live in exactly one place.

The mechanism is **dependency inversion via callbacks**: the send loop
passes `:completion`, `:on-delta`, and `:on-error` closures _into_ the
provider. The provider invokes them blindly; each closure captures the
buffer and re-enters it. The provider therefore "signals" stream
completion without knowing what a buffer is.

### Presentation-agnostic by design

The provider protocol is deliberately **presentation-agnostic**: the
same buffer-unaware provider can back different consumers. The current
`quoth.el` send loop is just _one_ consumer of that protocol;
alternatives are a matter of writing a new consumer, not touching the
wire layer:

- **A transient/posframe or minibuffer UI** — deltas rendered into a
  transient popup instead of a markdown chat buffer; only the
  `:on-delta` consumer changes.
- **A batch/scripting consumer** — deltas accumulated into a plain
  string and returned to a caller (a synchronous-ish `quoth-ask`),
  with no buffer, markers, or reasoning overlay.
- **A log/timeline consumer** — append-only transcript to a
  `*quoth-log*` buffer or file, no input area or dividers.
- **A completion/at-point consumer** — stream the answer inline into a
  _different_ buffer than the one holding the prompt (region-replace
  style), rather than a dedicated chat buffer.
- **An Org-mode consumer** — metadata in `:PROPERTIES:` drawers and
  tool output in Org source blocks instead of text properties and
  markdown fences.

In every case the provider protocol, SSE parsing, curl transport, and
tool dispatch are reused unchanged; only the buffer-aware consumer
differs.

## Hyper provider (primary)

The hyper provider (default) is Quoth's **primary mode of
operation**: it posts the prompt to Hyper's OpenAI-compatible
chat-completions endpoint (`POST {base-url}/chat/completions`, base URL
defaulting to `https://hyper.charm.land/v1`) and streams the response
directly. It needs no `quoth` binary — only `curl` (used the same way
gptel and plz.el use it). The HTTP+SSE wire work is implemented once in
the reusable OpenAI client `quoth-openai.el`; the provider is a thin
shim supplying hyper config (base URL, token, session-affinity hash,
x-crush-id) and mapping the provider protocol onto the client's
`quoth-openai-compose-request` and `quoth-openai-request`.

### How it works

1. `quoth-provider-send-prompt` composes the request body via
   `quoth-openai-compose-request` (messages array with a minimal
   system prompt, the user prompt, model, and `stream: t`) and fires a
   `curl --config -` subprocess; the config (URL, `request = POST`,
   JSON content-type, bearer auth header, and `data-binary = @-`) plus
   the JSON body go to curl over stdin. `data-binary = @-` is the
   **last** config line so curl reads the rest of stdin as the body.
2. SSE frames are parsed incrementally in the process filter
   (`quoth--hyper-curl-filter` → `quoth-openai-sse-feed`); content
   deltas are emitted to the `:on-delta` callback
   (`quoth--append-delta`), which appends them in order and
   drives the reasoning overlay.
3. A final `[DONE]` event, or the process exiting, runs the injected
   completion (`quoth--finalize-response`), which tags the response and
   inserts a fresh input divider (`---`, framed by blank lines). Stream
   errors and user interrupts both finalize the interrupted turn
   immediately through that same unified path: `:on-error` inserts and
   tags a `system` pane (`> **Error:** …` for a failure, `>
**Interrupted.**` for `quoth-interrupt`) and sets
   `quoth--pending-interrupt`; `quoth--finalize-response` then stamps
   `quoth-interrupted` on the partial and closes it. The `system` pane
   is real buffer text (visible on save/preview), tagged at insert time
   so it is never swept into a `response` region or a wire message.

### Session continuity

The hyper provider is stateful: prior conversation from the buffer's
tagged regions is folded into each request's messages array as
`[system, prior-user, prior-assistant, prior-tool, ..., current-user]` (tool
rounds interleave as assistant `tool_calls` + `role: "tool"` result pairs).
Set `quoth-hyper-history-limit` to `0` for stateless per-prompt requests.
Because the buffer is the source of truth, `C-c c k` (clear) starts a
fresh conversation naturally.

Tool calls replay in the OpenAI function-calling shape: an assistant
`tool_calls` declaration (content `null`) followed by a
`role: "tool"` result message with the matching `tool_call_id`. Only
the raw result text — Codex prose convention, `Process exited with
code N`/`Output:` — and the stored call id travel, never the rendered
tool block. Buffers created before the nested `tool-output` region
existed fall back to the bare `(tool . text)` turn with a legacy
`tool_call_id: "unknown"`.

Each buffer also owns an opaque session UUID (rotated by `C-c c k`),
whose XXH3-64 hash is sent as the `x-session-id` /
`x-session-affinity` headers on every hyper request, enabling
server-side prefix/token caching (HYPER-API.md §3.1). The raw UUID
never leaves the machine; only the 16-hex hash goes over TLS. Disable
with `quoth-hyper-session-cache-p` (default t). Persistence of the UUID
as a file local variable is planned but not yet implemented.

### Tool calls

When `quoth-tools-enabled` is non-nil (default), the model may call a
tool. There are five tools: two process-backed ones in `quoth-tools.el`
wrapping the `quoth-process.el` session handler, two immediate file
tools in `quoth-tools.el`, and `web_search` in `quoth-searxng.el`:

- `exec_command` — starts a command in a new PTY session and arms a
  running-report window for the requested duration (default
  `quoth-process-yield-ms`, clamped 250–30000 ms): the session
  sentinel reports `Process exited with code N` when the command
  finishes; the window timer reports `Process running with session
ID N` plus the captured output while it is still live. Both deliver
  exactly once; a cancelled wait abandons the reports without killing
  the session.
- `write_stdin` — writes to a live session (identified by the session
  id echoed by `exec_command`) and arms the same read window for the
  output produced since the last report. A session whose process
  already exited reports its final output immediately.

Two do byte-exact file I/O (no process involved):

- `write_file` — writes the `content` arg byte-exact to `path`,
  creating missing parent directories and replacing an existing file
  unless `overwrite` is false; fresh-file writes go through a temp
  file and atomic rename so no reader observes a half-written file.
- `read_file` — reads the file at `path` byte-exact (a `\r\n` on disk
  stays `\r\n`), errors on non-UTF-8 content, and truncates
  over-long results to `quoth-tool-max-output` without trimming
  trailing newlines.
- `web_search` — queries the local SearXNG instance (`quoth-searxng.el`)
  asynchronously: `url-retrieve` plus a `quoth-searxng-timeout` timer
  that deletes the retrieval and delivers an error result; the cancel
  thunk deletes the process and its timer. The search request doubles
  as the health probe cached in `quoth-searxng--healthy`; an
  `unreachable` cache short-circuits with no HTTP request.

The tool block is rendered in the buffer as valid markdown:

**🔧 exec_command** — yield 10s, shell /bin/bash, login no

ran:

```text
ls
```

in: /tmp

```text
Process exited with code 0
Output:
ARCHITECTURE.md
CONTRIBUTING.md
quoth.el
...
```

The header line carries the tool icon, name, and scalar clauses
(yield, shell, login, session, max, etc.). Free-text argument values
(cmd, workdir, input, query) are rendered below the header as
`label: value` lines, or as fenced code blocks when they span multiple
lines. The `exec_command` command (`ran`) is always fenced — single- or
multi-line — so the command text is a proper code block. Other values
fence only when multiline. The fence length is one
backtick longer than the longest run of backticks in the enclosed text
(`quoth--fence-str`), so nested fences never break the block. The tool block is
tagged `quoth-region-type 'tool'`; inside it, the raw result text
(between the output fences) is tagged `quoth-region-type 'tool-output'`
— a nested region that survives response re-tagging — and the block
carries the call's `quoth-tool-call` metadata (id, name, args). When
the exchange enters conversation history, only the raw result and the
real `tool_call_id` travel, never the rendered markup.

The tool _protocol_ — the `quoth-openai-tool-call` struct, the registry
(`quoth-openai-tool-registry`), dispatch (`quoth-openai-execute-tool`),
argument parsing, and the execution policy — lives in
`quoth-openai.el`; `quoth-tools.el` only implements the concrete tools
and registers them at load. A registry entry takes a tool call and an
`on-done` reporter, delivering `(RESULT . EXIT-OR-NIL)` exactly once —
inline for immediate tools (`read_file`, `write_file`), from a window
timer or the session sentinel for process-backed ones — and returns a
cancel thunk (abandon the wait) or nil.

The **round orchestrator** in `quoth.el` owns the event chain: on
finalize with pending calls it moves the phase to `tools`, inserts a
placeholder block (header, argument blocks, live `⏳ running…`
status) for each call in the SSE vector's declared order, and runs the
entries. Each completion hops through the 0-timer hop, fills its own
block's status span with the fenced result (tagging the raw result
`tool-output`), and decrements the round's pending count; the last
completion rebuilds the wire continuation from the buffer
(`quoth--tool-rounds`) and sends the follow-up. Interrupt mid-round
cancels every pending wait and fills the still-pending blocks with the
interrupted result so the buffer holds a valid wire `role: "tool"`
content for every call the model already emitted.

### Process handler (quoth-process.el)

General-purpose, model-neutral, buffer-unaware layer that owns PTY
sessions. It handles spawning (with sanitized env: `PAGER=cat`,
`GIT_PAGER=cat`, `TERM=dumb`), output buffering, event-driven exit
reports (a real process sentinel delivering `(CHUNK . EXIT-CODE)` on
the `quoth--schedule` hop), one-shot running-report window timers
(`quoth-process--arm-window`), non-blocking stdin writes, and cleanup.
Sessions live in a global registry keyed by session id and are scoped
per quoth buffer through the `owner` slot; `quoth-clear-buffer` runs
`quoth-process--cleanup-buffer` to kill every session owned by the
cleared buffer, and the buffer's `kill-buffer-hook` does the same on
kill. A session whose wait was abandoned stays registered when its
process exits on its own, so a later `write_stdin` poll still collects
the final output. `quoth-process-max-sessions` (default 128) caps
concurrent sessions.

### Current limitations

- Manual token only (`quoth-hyper-token`); OAuth device flow is planned.
- `quoth-provider-grant-permission` is a no-op (tools run without
  confirmation).

## Chat Buffer Composition

The quoth buffer's major mode is the parent mode (`markdown-mode` if
available, else `text-mode`); `quoth-chat-mode` is a **minor mode** that
provides the chat keybindings and hooks. Rendering, prompt tracking,
and fontification are all implemented with text properties, markers,
and markdown native font-lock instead of comint.

### Append-Only Handling

The buffer only grows at point-max (streamed deltas, responses, tool
blocks, and new input dividers are all inserted at EOF). Nothing is
made read-only: the entire buffer — history, dividers, tool blocks,
and the current input area alike — stays editable, and any edits are
reflected in the next request because requests are rebuilt from the
buffer's tagged regions at send time. A font-lock guard
(`font-lock-unfontify-region-function`) preserves the reasoning fold's
`keymap`/`quoth-fold-mark` properties across markdown-mode
refontification.

The **sanctioned overlay exceptions** (they carry faces and display
properties):

- **Reasoning (CoT) highlight + fold.** The reasoning span is
  highlighted by an overlay and, when longer than
  `quoth-reasoning-preview-lines`, folded via a two-overlay model: an
  always-visible preview overlay over the first N lines, and a body
  overlay carrying `invisible` + a display-only `before-string` marker.
  No buffer text is inserted or deleted during toggle, keeping the
  buffer-as-database intact.
- **System notes.** Stream errors and user interrupts insert a
  `system`-tagged blockquote pane (`> **Error:** …` / `> **Interrupted.**`)
  at point-max, with a display-only overlay carrying the `face`, a
  `help-echo`, and a `quoth-system-detail` plist (`:kind` `user` or
  `error`). The pane is inert (no dismiss keymap): the turn finalizes on
  its own, and the text is buffer text saved with the buffer. Overlays
  are tagged `quoth-overlay` so `quoth-clear-buffer` sweeps them. The
  `system` text is skipped by history reconstruction and
  `quoth--tag-response-region`, so it never becomes a response or a
  wire message.

### Metadata

All metadata is stored as **text properties** on buffer content;
highlighting is left to markdown-mode's native font-lock.

| Text Region                           | Property                                                                                               | Value                                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| Input separator (`---` divider)       | `quoth-prompt-id` + `quoth-region-type 'separator`                                                     | Markdown divider above the input area                                                       |
| User input (typed + inserted context) | `quoth-prompt-id` + `quoth-region-type 'user`                                                          | Editable input; inserted context appended as user input                                     |
| Tool blocks                           | `quoth-region-type 'tool` + `quoth-prompt-id` + `quoth-response-to` + `quoth-tool-call` (id/name/args) | Displayed tool call                                                                         |
| Tool raw result                       | `quoth-region-type 'tool-output` (nested) + `quoth-prompt-id` + `quoth-response-to`                    | Raw result sent in history                                                                  |
| Response text                         | `quoth-response-to` + `quoth-region-type 'response` (+ `quoth-interrupted` when the turn was cut off)  | The prompt ID being answered; `quoth-interrupted` is `user`/`error` for an interrupted turn |
| Reasoning text                        | `quoth-region-type 'reasoning` + `quoth-prompt-id` + `quoth-response-to`                               | Chain-of-thought sub-span                                                                   |
| System notes (error / interrupt)      | `quoth-region-type 'system`                                                                            | A transcript annotation: error pane or `> **Interrupted.**` note                            |

The `system` region is a distinct `quoth-region-type`, never reconstructed
into a wire message: `quoth-get-response-text`, `quoth--tool-rounds`, and
`quoth--tag-response-region` all skip it (like `reasoning` and tool
spans). The interruption kind is carried on the **response** span via
`quoth-interrupted` (not on the `system` region) so a future reader-only
change can tell the model that a prior turn was cut off.

### History Retrieval Functions

```elisp
;; Get the prompt ID of the current pending prompt
(and (boundp 'quoth--prompt-id) quoth--prompt-id)
;; => "20260805-091012-abc123"

;; Get all prompt IDs in buffer
(quoth-get-all-prompts)
;; => ("20260805-091012-abc123" "20260805-091000-xyz789")
```

### Programmatic Access

Text properties can be accessed directly:

```elisp
;; Get property at point
(get-text-property (point) 'quoth-prompt-id)
(get-text-property (point) 'quoth-region-type)
(get-text-property (point) 'quoth-response-to)
```

## Hacking

### Prerequisites

- Emacs 28.1+ (the package requirement)
- `markdown-mode` (optional — installed via MELPA; the chat buffer
  falls back to `text-mode` without it, and markdown-dependent tests
  are skipped)

### Running the tests

```sh
make check               # version gate + byte-compile all sources + run the ERT suite
emacs --batch -L . -L test \
  --eval "(ert-run-tests-batch-and-exit \"quoth-test/region-label\")"   # run a subset
```

The runner byte-compiles first (compiler warnings are treated as
errors-in-waiting — do not introduce new ones) and sets
`load-prefer-newer t` so fresh source beats stale `.elc` files. When
`markdown-mode` is installed, the runner adds it to the load path so
the fontification regression tests run under the markdown parent.

Run a single topic file with its own harness helpers; test files load
`quoth` via `require` with a fallback to the repo root.

### Formatting

```sh
make format    # Elisp via Emacs indent-region, Markdown via prettier,
               # Shell via shfmt, Python (test server) via black
```

Always run it before committing.

### Debugging

- Read-only bugs: many only reproduce under markdown-mode — run with
  it installed.
- Region/tagging bugs: check which text properties (`quoth-region-type`,
  `quoth-prompt-id`, `quoth-response-to`) are applied where, using
  `get-text-property` or the header line's `region:` label.
- Backend wire tests use `test/hyper-server.py` (started as a
  subprocess per test) — inspect the capture file for request bodies.
- Lisp paren issues: never hand-count — use
  `parinfer-rust -l lisp -m paren FILE` to validate and
  `-m indent` to repair from indentation.

### Conventions

- `quoth-` prefix: public commands, defcustoms, defgroup, faces.
- `quoth--` prefix: internal functions, state variables, markers.
- Provider protocol names: `quoth-provider-*` generics; the concrete
  provider struct is `quoth-hyper-provider`.
- Test names: `quoth-test/<topic>` under `ert-deftest`; helpers
  `quoth-test--...`, traveling with their topic file.
- Docstrings follow checkdoc conventions.
- Pre-alpha: no backwards-compatibility constraint — change things
  breakingly when a cleaner design is clear.
