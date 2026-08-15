# crush.el Architecture

Developer-facing documentation for the crush.el codebase: how the
package is structured, how each provider works, how the chat buffer
tracks its content, and how to hack on it. User-facing documentation
lives in [README.md](README.md).

## Project Layout

```
crush.el/               # Package root
  crush.el              # Core: config, provider protocol include, chat mode, helpers, commands
  crush-provider.el     # Provider protocol: base struct + crush-provider-* generics
  crush-openai.el       # Reusable OpenAI chat-completions client (compose, SSE, curl transport, tool protocol)
  crush-stream.el       # Facade stream protocol: stream state, progress, error pane
  crush-hyper-provider.el  # Charm Hyper provider (config + provider methods, thin shim over crush-openai)
  crush-xxh3.el         # Pure-Elisp XXH3-64 (seed 0): x-session-id / x-session-affinity hashing
  crush-tools.el        # Local tool implementations: the bash tool (registers into the tool registry)
  test/                 # ERT test suite (see "Hacking" below)
```

Dependency direction: `crush-provider.el` has no dependencies;
`crush-openai.el` requires `crush-provider` (for the context preamble);
`crush-stream.el` requires `crush-provider`; `crush-xxh3.el` has no
dependencies (pure math); `crush-hyper-provider.el` requires
`crush-provider` + `crush-openai` + `crush-xxh3`; `crush-tools.el`
requires `crush-openai` and registers its bash tool into the tool
registry at load; `crush.el` requires all six. Shared runtime plumbing
(`crush-facade--append-delta`, `crush-facade--record-error`,
`crush--debug-log`) stays in `crush.el` — the providers call it through
buffer-local process references and `declare-function` stubs.

## Provider Abstraction

All provider interaction goes through a provider protocol
(`crush-provider-send-prompt`, `crush-provider-interrupt`,
`crush-provider-active-p`, `crush-provider-cleanup`,
`crush-provider-grant-permission`). The protocol and shared base struct
live in `crush-provider.el`; the concrete provider is a dedicated,
buffer-unaware file:

- `crush-hyper-provider.el` — the default implementation: direct HTTP
  to the Charm Hyper gateway (see below).

`cl-defstruct` + `cl-defgeneric`/`cl-defmethod` provide the protocol.
The shared `crush-provider` base struct has slots `buffer`,
`working-directory`, `type`; the hyper provider adds its own slots
(base URL, token, model).

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
   (`crush--hyper-curl-filter` → `crush--hyper-sse-feed`); content
   deltas are emitted to the facade's `:on-delta` callback
   (`crush-facade--append-delta`), which appends them in order and
   drives the reasoning overlay.
3. A final `[DONE]` event, or the process exiting, runs the injected
   completion (`crush-facade--finalize`), which tags the response,
   freezes it, and inserts a fresh `crush> ` prompt. Stream errors
   surface through `:on-error` into a clickable error pane.

### Session continuity

The hyper provider is stateful: prior conversation from the buffer's
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
ARCHITECTURE.md
CONTRIBUTING.md
crush.el
crush-hyper-provider.el
crush-openai.el
crush-provider.el
CRUSH-SPEC.md
crush-stream.el
crush-tools.el
crush-xxh3.el
format.sh
HYPER-API.md
LICENSE
README.md
TODO.md
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
- `crush-provider-grant-permission` is a no-op (tools run without
  confirmation).

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
- Provider protocol names: `crush-provider-*` generics; the concrete
  provider struct is `crush-hyper-provider`.
- Test names: `crush-test/<topic>` under `ert-deftest`; helpers
  `crush-test--...`, traveling with their topic file.
- Docstrings follow checkdoc conventions.
- Pre-alpha: no backwards-compatibility constraint — change things
  breakingly when a cleaner design is clear.
