# crush.el Architecture

Developer-facing documentation for the crush.el codebase: how the
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
   `crush--session-uuid`).

2. **The buffer is append-only and self-freezing.** The buffer only
   ever grows at point-max; completed content (prompts, responses,
   tool blocks, reasoning) is frozen read-only, and history/state is
   enforced on the frozen regions. Read-only is applied via **text
   properties** (`read-only` with `front-sticky`/`rear-nonsticky`
   boundaries), never overlays; the current input area stays editable.

3. **Text properties carry state; overlays are for special UI only.**
   Metadata (region type, prompt id, response linkage, tool-call
   payloads) is stored as text properties so it survives
   font-lock refontification. Overlays are reserved for transient,
   display-only features — the reasoning highlight + fold and the
   clickable error pane — and never carry `read-only`.

4. **Protocols live in their own files.** The provider protocol
   (`crush-provider.el`), the OpenAI chat-completions + tool protocol
   (`crush-openai.el`), the facade stream protocol (`crush-stream.el`),
   and the process-handler session protocol (`crush-process.el`) are
   each a dedicated, self-contained file with a single dependency
   direction. `crush.el` only orchestrates the buffer and calls into
   them.

5. **Providers are abstracted and reuse the protocols.** Every provider
   is a self-contained file implementing the `crush-provider-*`
   generics. The shared wire work (request composition, SSE parsing,
   curl transport, tool dispatch) is implemented once in
   `crush-openai.el`; the concrete hyper provider is a thin shim that
   maps its configuration onto that client.

6. **Buffer-unaware, presentation-agnostic layers.** The facade stream
   protocol (`crush-stream.el`) and the process handler
   (`crush-process.el`) never read or write the crush buffer. They
   treat the caller as opaque: the main loop in `crush.el` is the only
   place with buffer access, and it threads progress, deltas, and
   errors through callbacks into those layers. Keeping the protocols
   and providers buffer-unaware is a deliberate separation of
   concerns, not an implementation detail.

7. **Everything inserted must be valid markdown.** The chat buffer's
   parent mode is `markdown-mode` (fallback `text-mode`); bodies,
   inserted context, tool blocks, and the input divider are all rendered as
   markdown constructs (fenced code blocks, bold headers, horizontal
   rules) so native font-lock and preview/export stay correct.

8. **No persistent process.** Each prompt fires a new HTTP request.
   Tool execution is the one exception: interactive commands run in PTY
   sessions owned by `crush-process.el`, scoped per crush buffer and
   capped at `crush-process-max-sessions`.

## Project Layout

```
crush.el/               # Package root
  crush.el              # Core: config, buffer orchestration, chat mode, helpers, commands
  crush-provider.el     # Provider protocol: base struct + crush-provider-* generics
  crush-openai.el       # Reusable OpenAI chat-completions client (compose, SSE, curl transport, tool protocol)
  crush-stream.el       # Facade stream protocol: stream state, progress, error pane
  crush-hyper-provider.el  # Charm Hyper provider (config + provider methods, thin shim over crush-openai)
  crush-process.el      # Process handler: PTY sessions, output buffering, yield, stdin, cleanup
  crush-tools.el        # Local tool implementations: exec_command + write_stdin (over crush-process)
  crush-xxh3.el         # Pure-Elisp XXH3-64 (seed 0): x-session-id / x-session-affinity hashing
  crush-debug-tools.el  # On-demand debug commands (region dump, history reconstruction; not loaded by default)
  test/                 # ERT test suite (see "Hacking" below)
```

Dependency direction: `crush-provider.el` has no dependencies;
`crush-openai.el` requires no sibling package;
`crush-stream.el` requires `crush-provider`; `crush-xxh3.el` has no
dependencies (pure math); `crush-process.el` requires only `cl-lib`
and `subr-x`; `crush-hyper-provider.el` requires `crush-provider` +
`crush-openai` + `crush-xxh3`; `crush-tools.el` requires
`crush-openai` + `crush-process` and registers its tools at load;
`crush.el` requires all seven. Shared runtime plumbing
(`crush-facade--append-delta`, `crush-facade--record-error`,
`crush--debug-log`) stays in `crush.el` — the providers call it through
buffer-local process references and `declare-function` stubs.

## Provider Abstraction

All provider interaction goes through a provider protocol (the
`cl-defgeneric` methods `crush-provider-send-prompt`,
`crush-provider-interrupt`, `crush-provider-active-p`,
`crush-provider-cleanup`, `crush-provider-grant-permission`, plus the
internal `crush-provider--tool-calls` and
`crush-provider--tool-results` used by the tool loop). The protocol and
the shared `crush-provider` base struct live in `crush-provider.el`;
each concrete provider is a dedicated, buffer-unaware file:

- `crush-hyper-provider.el` — the default implementation: direct HTTP
  to the Charm Hyper gateway (see below).

The shared `crush-provider` base struct has slots `buffer`,
`completion-action`, `working-directory`, `application-count`
(default 1), and `type`. The hyper provider subclasses it and adds its
own slots (base URL, token, model, session-affinity hash, x-crush-id).

## Hyper provider (primary)

The hyper provider (default) is crush.el's **primary mode of
operation**: it posts the prompt to Hyper's OpenAI-compatible
chat-completions endpoint (`POST {base-url}/chat/completions`, base URL
defaulting to `https://hyper.charm.land/v1`) and streams the response
directly. It needs no `crush` binary — only `curl` (used the same way
gptel and plz.el use it). The HTTP+SSE wire work is implemented once in
the reusable OpenAI client `crush-openai.el`; the provider is a thin
shim supplying hyper config (base URL, token, session-affinity hash,
x-crush-id) and mapping the provider protocol onto the client's
`crush-openai-compose-request` and `crush-openai-request`.

### How it works

1. `crush-provider-send-prompt` composes the request body via
   `crush-openai-compose-request` (messages array with a minimal
   system prompt, the user prompt, model, and `stream: t`) and fires a
   `curl --config -` subprocess; the config (URL, `request = POST`,
   JSON content-type, bearer auth header, and `data-binary = @-`) plus
   the JSON body go to curl over stdin. `data-binary = @-` is the
   **last** config line so curl reads the rest of stdin as the body.
2. SSE frames are parsed incrementally in the process filter
   (`crush--hyper-curl-filter` → `crush-openai-sse-feed`); content
   deltas are emitted to the facade's `:on-delta` callback
   (`crush-facade--append-delta`), which appends them in order and
   drives the reasoning overlay.
3. A final `[DONE]` event, or the process exiting, runs the injected
   completion (`crush-facade--finalize`), which tags the response,
   freezes it, and inserts a fresh input divider (`---`, framed by
   blank lines). Stream errors
   surface through `:on-error` into a clickable error pane.

### Session continuity

The hyper provider is stateful: prior conversation from the buffer's
tagged regions is folded into each request's messages array as
`[system, prior-user, prior-assistant, prior-tool, ..., current-user]` (tool
rounds interleave as assistant `tool_calls` + `role: "tool"` result pairs).
Set `crush-hyper-history-limit` to `0` for stateless per-prompt requests.
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
with `crush-hyper-session-cache-p` (default t). Persistence of the UUID
as a file local variable is planned but not yet implemented.

### Tool calls

When `crush-tools-enabled` is non-nil (default), the model may call a
tool. There are two tools, both implemented in `crush-tools.el` as thin
wrappers over the `crush-process.el` session handler:

- `exec_command` — starts a command in a new PTY session, yields for
  the requested window (default `crush-process-yield-ms`, clamped
  250–30000 ms), and reports either `Process exited with code N` or
  `Process running with session ID N` plus the captured output.
- `write_stdin` — writes to a live session (identified by the session
  id echoed by `exec_command`) and returns the output produced since
  the last report.

The tool block is rendered in the buffer as valid markdown:

**🔧 exec_command** — ran `ls`, yield 10s, shell /bin/bash, login no

```
Process exited with code 0
Output:
ARCHITECTURE.md
CONTRIBUTING.md
crush.el
...
```

The output is enclosed in a fenced code block whose fence length is one
backtick longer than the longest run of backticks in the output
(`crush--fence-str`), so nested fences never break the block. The tool
block is read-only and tagged `crush-region-type 'tool'`; inside it,
the raw result text (between the fences) is tagged
`crush-region-type 'tool-output'` — a nested region that survives
response re-tagging — and the block carries the call's
`crush-tool-call` metadata (id, name, args). When the exchange enters
conversation history, only the raw result and the real `tool_call_id`
travel, never the rendered markup.

The tool _protocol_ — the `crush-openai-tool-call` struct, the registry
(`crush-openai-tool-registry`), dispatch (`crush-openai-execute-tool`),
argument parsing, and the execution policy — lives in
`crush-openai.el`; `crush-tools.el` only implements the concrete tools
and registers them at load.

### Process handler (crush-process.el)

General-purpose, model-neutral, buffer-unaware layer that owns PTY
sessions. It handles spawning (with sanitized env: `PAGER=cat`,
`GIT_PAGER=cat`, `TERM=dumb`), output buffering, yield/deadline
draining, stdin writes, and cleanup. Sessions live in a global registry
keyed by session id and are scoped per crush buffer through the `owner`
slot; `crush-clear-buffer` runs `crush-process--cleanup-buffer` to kill
every session owned by the cleared buffer. `crush-process-max-sessions`
(default 128) caps concurrent sessions.

### Current limitations

- Manual token only (`crush-hyper-token`); OAuth device flow is planned.
- No model catalog.
- Interrupt is a stub; the "still running" guard does not block during
  hyper requests, so avoid typing another prompt mid-stream.
- `crush-provider-grant-permission` is a no-op (tools run without
  confirmation).

## Chat Buffer Composition

The crush buffer's major mode is the parent mode (`markdown-mode` if
available, else `text-mode`); `crush-chat-mode` is a **minor mode** that
provides the chat keybindings and hooks. Rendering, prompt tracking,
and fontification are all implemented with text properties, markers,
and markdown native font-lock instead of comint.

### Append-Only and Read-Only Handling

The buffer only grows at point-max (streamed deltas, responses, tool
blocks, and new input dividers are all inserted at EOF). Prompt text
and completed exchanges are frozen read-only via **text properties**
(`read-only` with `front-sticky`/`rear-nonsticky` boundaries), so the
history can't be edited while the current input area stays fully
editable. A font-lock guard
(`font-lock-unfontify-region-function`) and a `post-command-hook`
re-assert the boundaries after markdown-mode refontifies the buffer.

The **sanctioned overlay exceptions** (they carry faces and display
properties, never `read-only`):

- **Reasoning (CoT) highlight + fold.** The reasoning span is
  highlighted by an overlay and, when longer than
  `crush-reasoning-preview-lines`, folded via a two-overlay model: an
  always-visible preview overlay over the first N lines, and a body
  overlay carrying `invisible` + a display-only `before-string` marker.
  No buffer text is inserted or deleted during toggle, keeping the
  buffer-as-database intact.
- **Error pane.** Stream errors render as a clickable, read-only
  overlay at point-max carrying `crush-error-action`; `RET` dismisses
  it. Both overlay kinds are tagged `crush-overlay` so
  `crush-clear-buffer` sweeps them.

### Metadata

All metadata is stored as **text properties** on buffer content;
highlighting is left to markdown-mode's native font-lock.

| Text Region                           | Property                                                                                               | Value                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| Input separator (`---` divider)       | `crush-prompt-id` + `crush-region-type 'separator` + `read-only`                                       | Frozen markdown divider above the input area            |
| User input (typed + inserted context) | `crush-prompt-id` + `crush-region-type 'user`                                                          | Editable input; inserted context appended as user input |
| Tool blocks                           | `crush-region-type 'tool` + `crush-prompt-id` + `crush-response-to` + `crush-tool-call` (id/name/args) | Displayed tool call                                     |
| Tool raw result                       | `crush-region-type 'tool-output` (nested) + `crush-prompt-id` + `crush-response-to`                    | Raw result sent in history                              |
| Response text                         | `crush-response-to` + `crush-region-type 'response`                                                    | The prompt ID being answered                            |
| Reasoning text                        | `crush-region-type 'reasoning` + `crush-prompt-id` + `crush-response-to`                               | Chain-of-thought sub-span                               |

### History Retrieval Functions

```elisp
;; Get the prompt ID of the current pending prompt
(and (boundp 'crush--prompt-id) crush--prompt-id)
;; => "20260805-091012-abc123"

;; Get all prompt IDs in buffer
(crush-get-all-prompts)
;; => ("20260805-091012-abc123" "20260805-091000-xyz789")
```

### Programmatic Access

Text properties can be accessed directly:

```elisp
;; Get property at point
(get-text-property (point) 'crush-prompt-id)
(get-text-property (point) 'crush-region-type)
(get-text-property (point) 'crush-response-to)
```

## Hacking

### Prerequisites

- Emacs 28.1+ (the package requirement)
- `markdown-mode` (optional — installed via MELPA; the chat buffer
  falls back to `text-mode` without it, and markdown-dependent tests
  are skipped)

### Running the tests

```sh
sh test/run-tests.sh      # byte-compile all sources + run the ERT suite
emacs --batch -L . -L test \
  --eval "(ert-run-tests-batch-and-exit \"crush-test/region-label\")"   # run a subset
```

The runner byte-compiles first (compiler warnings are treated as
errors-in-waiting — do not introduce new ones) and sets
`load-prefer-newer t` so fresh source beats stale `.elc` files. When
`markdown-mode` is installed, the runner adds it to the load path so
the fontification regression tests run under the markdown parent.

Run a single topic file with its own harness helpers; test files load
`crush` via `require` with a fallback to the repo root.

### Formatting

```sh
sh format.sh   # Elisp via Emacs indent-region, Markdown via prettier,
               # Shell via shfmt, Python (test server) via black
```

Always run it before committing.

### Debugging

- Read-only bugs: many only reproduce under markdown-mode — run with
  it installed.
- Region/tagging bugs: check which text properties (`crush-region-type`,
  `crush-prompt-id`, `crush-response-to`) are applied where, using
  `get-text-property` or the header line's `region:` label.
- Backend wire tests use `test/hyper-server.py` (started as a
  subprocess per test) — inspect the capture file for request bodies.
- Lisp paren issues: never hand-count — use
  `parinfer-rust -l lisp -m paren FILE` to validate and
  `-m indent` to repair from indentation.

### Conventions

- `crush-` prefix: public commands, defcustoms, defgroup, faces.
- `crush--` prefix: internal functions, state variables, markers.
- Provider protocol names: `crush-provider-*` generics; the concrete
  provider struct is `crush-hyper-provider`.
- Test names: `crush-test/<topic>` under `ert-deftest`; helpers
  `crush-test--...`, traveling with their topic file.
- Docstrings follow checkdoc conventions.
- Pre-alpha: no backwards-compatibility constraint — change things
  breakingly when a cleaner design is clear.
