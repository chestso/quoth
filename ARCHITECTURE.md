# crush.el Architecture

Developer-facing documentation for the crush.el codebase: how the
package is structured, how each backend works, how the chat buffer
tracks its content, and how to hack on it. User-facing documentation
lives in [README.md](README.md).

## Project Layout

```
crush.el/               # Package root
  crush.el              # Core: config, backend protocol include, chat mode, helpers, commands
  crush-backend.el      # Backend protocol: base struct + crush-backend-* generics
  crush-stream.el       # Facade stream protocol: stream state, progress, error pane
  crush-run-backend.el  # `crush run` CLI backend (struct, defcustoms, methods)
  crush-hyper-backend.el  # Direct HTTP backend to the Charm Hyper gateway (compose, SSE, curl transport)
  crush-xxh3.el         # Pure-Elisp XXH3-64 (seed 0): x-session-id / x-session-affinity hashing
  crush-tool.el         # Tool-call machinery: bash tool, tool loop, permissions
  test/                 # ERT test suite (see "Hacking" below)
```

Dependency direction: `crush-backend.el` has no dependencies; the two
backend files require it; `crush-stream.el` requires `crush-backend`;
`crush-xxh3.el` has no dependencies (pure math); `crush-hyper-backend.el`
requires `crush-backend` + `crush-xxh3`; `crush-tool.el` requires
`crush-backend` but stays buffer- and backend-unaware; `crush.el`
requires all six. Shared runtime plumbing (`crush--output-filter`,
`crush--process-sentinel`, `crush-facade--append-delta`,
`crush--debug-log`) stays in `crush.el` — the backends call it through
buffer-local process references and `declare-function` stubs.

## Backend Abstraction

All provider/CLI interaction goes through a backend protocol
(`crush-backend-send-prompt`, `crush-backend-interrupt`,
`crush-backend-active-p`, `crush-backend-cleanup`,
`crush-backend-grant-permission`). The protocol and shared base struct
live in `crush-backend.el`; each backend is a dedicated,
buffer-unaware file:

- `crush-hyper-backend.el` — the default implementation: direct HTTP
  access to the Charm Hyper gateway (see below).
- `crush-run-backend.el` — the compatibility CLI backend. Spawns
  `crush run --quiet` per prompt.

`cl-defstruct` + `cl-defgeneric`/`cl-defmethod` provide the protocol.
The shared `crush-backend` base struct has slots `buffer`,
`working-directory`, `type`; each backend adds its own slots (the run
backend owns the CLI-related defcustoms and a `process` slot; the
hyper backend owns the hyper defcustoms and its request params).

## Hyper backend (primary)

The hyper backend (default) is crush.el's **primary mode of
operation**: it posts the prompt to Hyper's OpenAI-compatible
chat-completions endpoint (`POST {base-url}/chat/completions`, base URL
defaulting to `https://hyper.charm.land/v1`) and streams the response
directly. It does **not** spawn `crush run`, so it does not need the
Crush CLI installed — only `curl` (used the same way gptel and plz.el
use it).

### How it works

1. `crush-backend-send-prompt` composes the request body
   (`crush--hyper-compose-request`: messages array with a minimal
   system prompt, the user prompt, model, and `stream: t`) and fires a
   `curl --config -` subprocess; the config (URL, `request = POST`,
   JSON content-type, bearer auth header, and `data-binary = @-`) plus
   the JSON body go to curl over stdin. `data-binary = @-` is the
   **last** config line so curl reads the rest of stdin as the body.
2. SSE frames are parsed incrementally in the process filter
   (`crush--hyper-curl-filter` → `crush--hyper-sse-feed`); content
   deltas are emitted to the facade's `:on-delta` callback
   (`crush-facade--append-delta`), which appends them in order and
   drives the reasoning overlay.
3. A final `[DONE]` event, or the process exiting, runs the injected
   completion (`crush-facade--finalize`), which tags the response,
   freezes it, and inserts a fresh `crush> ` prompt. Stream errors
   surface through `:on-error` into a clickable error pane.

### Session continuity

The hyper backend is stateful: prior conversation from the buffer's
tagged regions is folded into each request's messages array as
`[system, prior-user, prior-assistant, ..., current-user]`. Set
`crush-hyper-history-limit` to `0` for stateless per-prompt requests.
Because the buffer is the source of truth, `C-c c k` (clear) starts a
fresh conversation naturally.

Tool calls replay in the OpenAI function-calling shape: a `tool` turn
carrying `(id name args . raw-result)` emits an assistant `tool_calls`
declaration (content `null`) followed by the `role: "tool"` result
message with the matching `tool_call_id`. Only the raw
`<command>/<output>/<exit_code>` result and the stored call id travel —
never the rendered toolbar. Buffers created before the nested
`tool-output` region existed fall back to the bare `(tool . text)` turn
with a legacy `tool_call_id: "unknown"`.

Each buffer also owns an opaque session UUID (rotated by `C-c c k`),
whose XXH3-64 hash is sent as the `x-session-id` /
`x-session-affinity` headers on every hyper request, enabling
server-side prefix/token caching (HYPER-API.md §3.1). The raw UUID
never leaves the machine; only the 16-hex hash goes over TLS. Disable
with `crush-hyper-session-cache-p` (default t).

### Tool calls

When `crush-tools-enabled` is non-nil (default), the model may call a
tool. The tool block is rendered in the buffer as markdown:

**🔧 tool: bash**

**command:** `{"command":"ls"}`  
**exit:** `0`  
**output:**

```
<command>ls</command>
<output>
crush.el
</output>
<exit_code>0</exit_code>
```

The output is enclosed in a fenced code block whose fence length is one
backtick longer than the longest run of backticks in the output, so
nested fences never break the block. The tool block is read-only and
tagged `crush-region-type 'tool'`. Inside it, the raw tool result (the
`<command>/<output>/<exit_code>` text between the fences) is tagged
`crush-region-type 'tool-output'` — a nested region that survives
response re-tagging and region persistence — and the block carries the
call's `crush-tool-call` metadata (id, name, args). When the exchange
enters conversation history, only the raw result and the real
`tool_call_id` travel, never the rendered toolbar.

Tools run without confirmation (`yolo` mode). Up to
`crush-tool-loop-max` (default 8) consecutive tool-call rounds are
supported per prompt; the loop stops after that limit or when the model
produces a content answer instead of tool calls.

### Current limitations

- Manual token only (`crush-hyper-token`); OAuth device flow is planned.
- No model catalog.
- Interrupt is a stub; the "still running" guard does not block during
  hyper requests, so avoid typing another prompt mid-stream.
- `crush-backend-grant-permission` is a no-op (tools run without
  confirmation).

## Run backend (compatibility)

The run backend (`crush-backend-type 'run`) drives the **Crush CLI**
instead: each prompt spawns a new `crush run` process and streams its
stdout into the crush buffer. It requires the `crush` binary on
`exec-path` (`crush-program`).

### How it works

1. `crush-backend-send-prompt` builds the command line:
   `crush run --quiet [--model M] [--session ID | --continue] [prompt]`.
   `--quiet` suppresses the spinner; stderr goes to the `*crush-errors*`
   buffer. `--session` takes precedence over `--continue`.
2. Output is streamed into the buffer by `crush--output-filter` at the
   process mark; on exit the sentinel runs the facade's completion —
   tagging the response, freezing it read-only, and inserting a fresh
   `crush> ` prompt. There is no persistent process.

### How context reaches the model

`crush run` treats stdin as opaque text: the CLI reads all of it and
prepends it verbatim to the prompt, separated by a blank line. It does
not parse attachment headers, `(lines N-M)` ranges, fence languages, or
links, and it never reads or slices the referenced files. With
attachments the backend writes `preamble + attachment blocks + prompt`
to the process's stdin (the prompt is the last stdin line) and closes
it with EOF, because `crush run` reads all of stdin before it starts.

So the blocks crush.el inserts are plain markdown in the LLM message.
The `**Attachment:**` header and line range are hints for the model —
it may re-read a specific range with its `view` tool, or just reason
over the text it was given.

### Session continuity

The run backend sends only the current prompt (and any attached context
blocks) on each invocation; it keeps no conversation state of its own.
Continuity is delegated to the CLI's session store: every prompt is
persisted there, and each new invocation tells the CLI which session to
resume.

The link between prompts lives entirely in two buffer-local variables:

- `crush--continue` — set to `t` by the run backend immediately after
  the first prompt is spawned. It is passed to the next invocation as
  `--continue`, which resumes the most recent session for the working
  directory — in practice, the prior conversation travels along with
  the new prompt.
- `crush--session` — a manual session id, passed as `--session <id>`;
  takes precedence over `--continue` and resumes a specific session
  instead.

Session IDs can be: full UUID, full XXH3 hash, or hash prefix. List
sessions with `crush session list --json`. Clear manual selection with
`(setq-local crush--session nil)`.

### Assuming permissions

`crush run` auto-approves every tool permission — functionally `--yolo`
(see README's [Important: Permission Behavior](README.md#important-permission-behavior)).
There is no prompt-by-prompt approval in the run backend;
`crush-backend-grant-permission` is a no-op.

## Chat Buffer Composition

The crush buffer's major mode is the parent mode (`markdown-mode` if
available, else `text-mode`); `crush-chat-mode` is a **minor mode** that
provides the chat keybindings and hooks. Rendering, prompt tracking,
and fontification are all implemented with text properties, markers,
and markdown native font-lock instead of comint.

### Read-Only Handling

Prompt text and completed exchanges are made read-only via **text
properties** (`read-only` with `front-sticky`/`rear-nonsticky`
boundaries), so the history can't be edited while the current input
area stays fully editable. A font-lock guard
(`font-lock-unfontify-region-function`) and a `post-command-hook`
re-assert the boundaries after markdown-mode refontifies the buffer.

### Metadata

All metadata is stored as **text properties** on buffer content;
highlighting is left to markdown-mode's native font-lock.

| Text Region             | Property                                                                                                       | Value                        |
| ----------------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| `crush> ` prompt marker | `crush-prompt-id` + `read-only`                                                                                | Unique ID for the prompt     |
| User input after prompt | `crush-prompt-id`                                                                                              | Same ID as the prompt marker |
| Attachment blocks       | `crush-attachment-id` + `crush-prompt-id` + `crush-region-type 'attachment` + `crush-filename` + `crush-lines` | Metadata for the attachment  |
| Tool blocks             | `crush-region-type 'tool` + `crush-prompt-id` + `crush-response-to` + `crush-tool-call` (id/name/args)         | Displayed tool call          |
| Tool raw result         | `crush-region-type 'tool-output` (nested) + `crush-prompt-id` + `crush-response-to`                            | Raw result sent in history   |
| Response text           | `crush-response-to` + `crush-region-type 'response`                                                            | The prompt ID being answered |
| Reasoning text          | `crush-region-type 'reasoning` + `crush-prompt-id` + `crush-response-to`                                       | Chain-of-thought sub-span    |

### History Retrieval Functions

```elisp
;; Get prompt ID at current point
(crush-get-prompt-at-point)
;; => "20260805-091012-abc123"

;; Get all attachment regions for a specific prompt
(crush-get-attachments-for-prompt "20260805-091012-abc123")
;; => ((start end "attach-id-1") (start end "attach-id-2"))

;; Get all prompt IDs in buffer
(crush-get-all-prompts)
;; => ("20260805-091012-abc123" "20260805-091000-xyz789")
```

### Programmatic Access

Text properties can be accessed directly:

```elisp
;; Get property at point
(get-text-property (point) 'crush-prompt-id)
(get-text-property (point) 'crush-attachment-id)
(get-text-property (point) 'crush-filename)
(get-text-property (point) 'crush-lines)
(get-text-property (point) 'crush-region-type)
(get-text-property (point) 'crush-response-to)
```

## Hacking

### Prerequisites

- Emacs 28.1+ (the package requirement)
- `markdown-mode` (optional — installed via MELPA; the chat buffer
  falls back to `text-mode` without it, and markdown-dependent tests
  are skipped)
- Maude: `sh test/run-tests.sh` runs everything; see below.

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
- Backend protocol names: `crush-backend-*` generics; per-backend
  structs `crush-(run|hyper)-backend`.
- Test names: `crush-test/<topic>` under `ert-deftest`; helpers
  `crush-test--...`, traveling with their topic file.
- Docstrings follow checkdoc conventions.
- Pre-alpha: no backwards-compatibility constraint — change things
  breakingly when a cleaner design is clear.
