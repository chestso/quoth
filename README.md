# crush.el

A GNU Emacs package for chatting with AI providers directly from an Emacs buffer.

## Motivation

[Crush](https://github.com/charmbracelet/crush) is my go-to coding agent TUI — until now. crush.el started with the observation that the Crush TUI's prompt area is not powerful enough to work with. A prompt is text, and text is the editor's home turf: composing, revising, and reviewing a prompt is editing, and an editor is a much more powerful surface for it than any prompt field. The keyboard is part of the story too — Crush's shortcuts follow Windows/macOS conventions, not Emacs muscle memory. And so the package grew out of a simple wish: to interact with Crush directly from the editor that is already open, Emacs.

Everything else follows from that wish. The conversation lives in a real buffer, so it inherits everything Emacs offers — kill and yank, search, multiple windows, markdown rendering, and project-aware context insertion — instead of a fixed prompt area with a fixed set of keys.

## Goal

crush.el's primary mode of operation is **direct provider interaction**: it talks to the [Charm Hyper gateway](HYPER-API.md) over HTTP+SSE (no separate CLI binary needed). A dedicated Emacs buffer sends prompts and streams the model's response, including chain-of-thought reasoning. On top of that, any buffer selection can be used as context: the selection is formatted as a markdown fenced code block with the file path and line numbers (relative to the project root), then inserted into the crush buffer before the prompt as an attachment.

A compatibility backend drives the [Crush CLI](https://github.com/charmbracelet/crush) (`crush run`) for users who prefer it; it is not required for the default provider mode.

Each project gets its own crush buffer (see [Per-Project Buffers](#per-project-buffers)), so work in different projects stays isolated.

See [TODO.md](TODO.md) for the full project goal and roadmap.

## Important: Permission Behavior

Both backends currently run tools without confirmation. The hyper backend (default) executes the `bash` tool immediately when the model calls it, and the `crush run` backend auto-approves all permissions, including `edit`, `write`, and `bash`. This is functionally equivalent to running `crush --yolo`.

Interactive permission prompts for tool execution are on the roadmap. See the [TODO.md](TODO.md) roadmap for details.

## Installing

Not yet on MELPA. For now, clone and load manually:

```elisp
(use-package crush
  :load-path "/path/to/crush.el"
  :bind ("C-c c" . crush)
  :hook (prog-mode . crush-minor-mode))
```

Requires Emacs 28.1+. The package spans several files (`crush.el` plus `crush-backend.el`, `crush-stream.el`, `crush-run-backend.el`, `crush-hyper-backend.el`), so point `load-path` at the package directory. For manual `require`s, load `crush` last to get the full file set loaded. The default hyper backend requires only `curl`; the optional `run` backend requires the `crush` binary.

## Configuration

### crush-model

Set the default model for Crush:

```elisp
(setq crush-model "claude-sonnet-4-20250514")
```

When set, the model is used as the hyper request model (default backend) or passed to `crush run --model` (run backend). When `nil` (default), each backend falls back to its own default (`crush-hyper-default-model` for hyper, or the CLI's configured model).

### crush-working-directory

Set the working directory used by crush (resolves selections relative to it):

```elisp
(setq crush-working-directory "/path/to/project")
```

When `nil` (default), uses the project root if available, otherwise `default-directory`.

### crush-args

Additional command-line arguments passed to the Crush CLI (run backend only):

```elisp
(setq crush-args '("--verbose"))
```

### crush-backend-type

Which crush backend to use:

```elisp
(setq crush-backend-type 'hyper)
```

- `hyper` (default) — direct HTTP access to the Charm Hyper gateway, bypassing the CLI entirely; the package's primary mode of operation (see [Hyper backend](#hyper-backend)). Requires only `curl`. Supports conversation history, tool calls, and session caching. OAuth is still on the roadmap.
- `run` — standalone `crush run` mode (compatibility with the Crush CLI). Each prompt spawns a new process. Fully implemented.

### crush-hyper-base-url

Base URL of the Charm Hyper gateway (default `https://hyper.charm.land/v1`). Requests go to `BASE-URL/chat/completions` (the OpenAI-compatible endpoint). Overridden by the `HYPER_URL` environment variable when set.

### crush-hyper-token

Bearer access token for Hyper. Tokens are prefixed `sk-hyper-`; get one from the Hyper Dashboard. The default looks the token up in `auth-source` (gptel-style), so the recommended setup is a line in `~/.authinfo`:

```text
machine hyper.charm.land login apikey password sk-hyper-xxxxxxxxxxxxxxxxxxxxxxxx
```

The value may also be a string (used verbatim) or a function of no arguments returning the token (or another function):

```elisp
(setq crush-hyper-token "sk-hyper-xxxxxxxxxxxxxxxxxxxxxxxx")
;; or
(setq crush-hyper-token (lambda () (getenv "HYPER_API_KEY")))
```

Set it to `nil` to request without a token (useful for local gateways). A missing authinfo entry signals an error with setup instructions rather than silently sending no token.

### Model selection for hyper

The hyper backend uses `crush-model` (the shared model defcustom), falling back to the constant `crush-hyper-default-model` (`deepseek-v4-flash`). Request-level `max_tokens`, `temperature`, and `thinking`/`reasoning_effort` are controlled by the defcustoms below.

### crush-hyper-timeout / crush-hyper-max-tokens / crush-hyper-temperature

Request tuning: timeout in seconds, `max_tokens` (default 64000), and sampling temperature (nil means unset).

### crush-hyper-history-limit / crush-hyper-history-include-reasoning

The hyper backend is stateful: each request re-sends the buffer's completed exchanges as `user` and `assistant` messages before the new prompt, so the model sees the whole conversation. The conversation is read from the buffer's tagged regions at send time — nothing is stored client- or server-side. `crush-hyper-history-limit` (default 200) caps how many prior exchanges are sent (the most recent ones are always retained); set it to `0` to disable history and get phase-1 stateless per-prompt requests.

`crush-hyper-history-include-reasoning` (default nil) controls whether streamed chain-of-thought rides along in history: off, the assistant turn carries only the answer; on, the CoT is re-sent as the `reasoning_content` field of the assistant message, which is what Hyper requires for thinking turns carried across requests.

### crush-hyper-thinking / crush-hyper-reasoning-effort

When `crush-hyper-thinking` is non-nil, Hyper's internal thinking mode is enabled. `crush-hyper-reasoning-effort` selects the reasoning level (`low`, `medium`, `high`, `max`); nil uses the model default.

### crush-reasoning-preview-lines

Number of reasoning lines to show in the collapsed preview (default 10). When the reasoning region exceeds this, the first N lines are shown with a `…` ellipsis toggle; the remainder is hidden behind an invisible overlay. Press `TAB` or `C-c c r` on the ellipsis to expand or re-collapse. Set to 0 to always collapse with no preview.

Reasoning is a display aid and is excluded from model-visible history by default; set `crush-hyper-history-include-reasoning` to `t` to re-send it as the `reasoning_content` field on the assistant message (per [HYPER-API.md §3.4](HYPER-API.md)).

### crush-debug-mode

When non-nil (default), log commands, input, output, and sentinel events to a `*crush-debug*` buffer. Set to `nil` to disable logging.

## Architecture

### Backend Abstraction

All provider/CLI interaction goes through a backend protocol (`crush-backend-send-prompt`, `crush-backend-interrupt`, `crush-backend-active-p`, `crush-backend-cleanup`, `crush-backend-grant-permission`). The protocol and shared base struct live in `crush-backend.el`; each backend is a dedicated, buffer-unaware file:

- `crush-hyper-backend.el` — the default implementation: direct HTTP access to the Charm Hyper gateway (see [Hyper backend](#hyper-backend)).
- `crush-run-backend.el` — the compatibility CLI backend (see [Run backend](#run-backend)). Spawns `crush run --quiet` per prompt.

### Hyper backend

The hyper backend (default) is crush.el's **primary mode of operation**: it posts the prompt to Hyper's OpenAI-compatible chat-completions endpoint (`POST {base-url}/chat/completions`, base URL defaulting to `https://hyper.charm.land/v1`) and streams the response directly. It does **not** spawn `crush run`, so it does not need the Crush CLI installed — only `curl` (which is used the same way gptel and plz.el use it).

#### How it works

1. `crush-backend-send-prompt` composes the request body (`crush--hyper-compose-request`: messages array with a minimal system prompt, the user prompt, model, and `stream: t`) and fires a `curl --config -` subprocess; the config (URL, `request = POST`, JSON content-type, bearer auth header, and `data-binary = @-`) plus the JSON body go to curl over stdin. `data-binary = @-` is the **last** config line so curl reads the rest of stdin as the body.
2. SSE frames are parsed incrementally in the process filter (`crush--hyper-curl-filter` → `crush--hyper-sse-feed`); content deltas are emitted to the facade's `:on-delta` callback (`crush-facade--append-delta`), which appends them in order and drives the reasoning overlay.
3. A final `[DONE]` event, or the process exiting, runs the injected completion (`crush-facade--finalize`), which tags the response, freezes it, and inserts a fresh `crush> ` prompt. Stream errors surface through `:on-error` into a clickable error pane.

#### Session continuity

The hyper backend is stateful: prior conversation from the buffer's tagged regions is folded into each request's messages array as `[system, prior-user, prior-assistant, ..., current-user]`. Set `crush-hyper-history-limit` to `0` for stateless per-prompt requests. Because the buffer is the source of truth, `C-c c k` (clear) starts a fresh conversation naturally, and the same conversation is what you see in the buffer.

Each buffer also owns an opaque session UUID (rotated by `C-c c k`), whose XXH3-64 hash is sent as the `x-session-id` / `x-session-affinity` headers on every hyper request, enabling server-side prefix/token caching (HYPER-API.md §3.1). The raw UUID never leaves the machine; only the 16-hex hash goes over TLS. Disable with `crush-hyper-session-cache-p` (default t).

#### Tool calls

The hyper backend supports tool calls when `crush-tools-enabled` is non-nil (the default). When the model calls a tool, the tool block is rendered in the buffer as markdown:

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

The output is enclosed in a fenced code block whose fence length is one backtick longer than the longest run of backticks in the output, so nested fences never break the block. The tool block is read-only and tagged `crush-region-type 'tool'`.

Tools run without confirmation (`yolo` mode). Up to `crush-tool-loop-max` (default 8) consecutive tool-call rounds are supported per prompt; the loop stops after that limit or when the model produces a content answer instead of tool calls.

#### Configuration

- `crush-tools-enabled` — toggle tool support (default `t`)
- `crush-tool-loop-max` — maximum tool-call rounds per prompt (default 8)
- `crush-tool-timeout` — maximum seconds a tool command may run (default 60)
- `crush-tool-max-output` — maximum characters of tool output to display (default 30000)
- `crush-bash-program` — shell to use for the `bash` tool (default nil, uses `shell-file-name`)

#### Current limitations

- Manual token only (`crush-hyper-token`); OAuth device flow is planned.
- No model catalog.
- Interrupt is a stub; the "still running" guard does not block during hyper requests, so avoid typing another prompt mid-stream.
- `crush-backend-grant-permission` is a no-op (tools run without confirmation).

### Run backend

The run backend (compatibility, `crush-backend-type 'run`) drives the **Crush CLI** instead: each prompt spawns a new `crush run` process and streams its stdout into the crush buffer. It requires the `crush` binary on `exec-path` (`crush-program`).

#### How it works

1. `crush-backend-send-prompt` builds the command line: `crush run --quiet [--model M] [--session ID | --continue] [prompt]`. `--quiet` suppresses the spinner; stderr goes to the `*crush-errors*` buffer. `--session` takes precedence over `--continue`.
2. Output is streamed into the buffer by `crush--output-filter` at the process mark; on exit the sentinel runs the facade's completion — tagging the response, freezing it read-only, and inserting a fresh `crush> ` prompt. There is no persistent process.

#### How context reaches the model

`crush run` treats stdin as opaque text: the CLI reads all of it and prepends it verbatim to the prompt, separated by a blank line. It does not parse attachment headers, `(lines N-M)` ranges, fence languages, or links, and it never reads or slices the referenced files. With attachments the backend writes `preamble + attachment blocks + prompt` to the process's stdin (the prompt is the last stdin line) and closes it with EOF, because `crush run` reads all of stdin before it starts.

So the blocks crush.el inserts are plain markdown in the LLM message. The `**Attachment:**` header and line range are hints for the model — it may re-read a specific range with its `view` tool, or just reason over the text it was given.

#### Session continuity

The run backend sends only the current prompt (and any attached context blocks) on each invocation; it keeps no conversation state of its own. Continuity is delegated to the CLI's session store: every prompt is persisted there, and each new invocation tells the CLI which session to resume.

The link between prompts lives entirely in two buffer-local variables:

- `crush--continue` — set to `t` by the run backend immediately after the first prompt is spawned (`crush-backend-send-prompt`). It is passed to the next invocation as `--continue`, which resumes the most recent session for the working directory — in practice, the prior conversation travels along with the new prompt.
- `crush--session` — a manual session id, passed as `--session <id>`; takes precedence over `--continue` and resumes a specific session instead.

#### Session management

##### `--continue` (automatic)

After sending your first prompt, `crush--continue` is set to `t`. All subsequent prompts automatically include `--continue`, which tells Crush to continue the most recent session in the working directory.

This means:

- The first prompt starts a new session
- All follow-up prompts in the same buffer continue that session
- The session persists across Emacs restarts (stored in Crush's database)

To start a fresh session:

- `C-c c k` (`crush-clear-buffer`) — clears the buffer, starts a fresh session, and rotates the session UUID so the next prompt gets a cold cache

##### `--session <id>` (manual)

To continue a specific session by ID, set `crush--session`:

```elisp
(setq-local crush--session "abc123")
```

This passes `--session abc123` to Crush, which:

- Takes precedence over `--continue`
- Allows resuming a specific session from your history
- Session IDs can be: full UUID, full XXH3 hash, or hash prefix

To list available sessions:

```bash
crush session list --json
```

To clear manual session selection and return to automatic `--continue` behavior:

```elisp
(setq-local crush--session nil)
```

##### Session Flow Example

```
Buffer state         Command sent
----------------     --------------------------
crush--continue=nil  crush run --quiet "first prompt"
                     ↓ (crush--continue set to t)
crush--continue=t    crush run --quiet --continue "follow up"
crush--continue=t    crush run --quiet --continue "another"
C-c c k pressed      (buffer cleared, crush--continue reset to nil)
crush--continue=nil  crush run --quiet "new session"
```

With manual session ID:

```
crush--session="abc123"  crush run --quiet --session abc123 "resume"
```

#### Assuming permissions

`crush run` auto-approves every tool permission — functionally `--yolo` (see [Important: Permission Behavior](#important-permission-behavior)). There is no prompt-by-prompt approval in the run backend; `crush-backend-grant-permission` is a no-op.

### Chat Buffer Composition

The crush buffer's major mode is the parent mode (`markdown-mode` if available, else `text-mode`); `crush-chat-mode` is a **minor mode** that provides the chat keybindings and hooks. Rendering, prompt tracking, and fontification are all implemented with text properties, markers, and markdown native font-lock instead of comint.

### Read-Only Handling

Prompt text and completed exchanges are made read-only via **text properties** (`read-only` with `front-sticky`/`rear-nonsticky` boundaries), so the history can't be edited while the current input area stays fully editable. A font-lock guard (`font-lock-unfontify-region-function`) and a `post-command-hook` re-assert the boundaries after markdown-mode refontifies the buffer.

### Metadata

All metadata is stored as **text properties** on buffer content; highlighting is left to markdown-mode's native font-lock.

## Usage

### Crush buffer (chat mode)

- `M-x crush` — open the crush interaction buffer for the current project (or directory); each project gets its own buffer, named after the project root (e.g. `*crush:crush.el*`)
- Type a prompt and press `RET` to send it to the active backend (provider or CLI)
- `M-p` / `M-n` — navigate input history (previous/next input)
- `TAB` — expand/collapse the reasoning (chain-of-thought) fold at point; otherwise normal TAB
- `C-c c i` — interrupt the running crush process
- `C-c c k` — clear the crush buffer (also starts a fresh session and rotates the session UUID)
- `C-c c a` — insert the current buffer selection as context into the crush buffer
- `C-c c r` — expand/collapse the reasoning fold at point

### Per-Project Buffers

Each project (or directory, when not in a project) is bound to its own crush buffer:

- Buffer names are derived from the project root, e.g. `*crush:myproject*`. When two distinct roots share a basename, a numeric suffix keeps them separate: `*crush:myproject(2)*`.
- `M-x crush` and the `crush-minor-mode` commands (`C-c C-s`, `C-c C-b`, `C-c C-p`, `C-c C-c`) always target the buffer for the current buffer's project or directory, so context and prompts never leak between projects.
- Follow-up prompts in a project's buffer continue that project's session (`--continue`), because Crush tracks sessions per working directory; the input history ring is also per project buffer.

### Source buffers (minor mode)

Enable `crush-minor-mode` in any buffer where you want to send content to crush:

```elisp
M-x crush-minor-mode
```

Or enable it automatically in programming modes:

```elisp
(add-hook 'prog-mode-hook #'crush-minor-mode)
```

Keybindings (active when `crush-minor-mode` is enabled):

- `C-c C-c` — open/switch to the crush buffer
- `C-c C-s` — insert the active region as a markdown fenced code block with an attachment header
- `C-c C-b` — insert the entire buffer as a markdown fenced code block
- `C-c C-p` — insert the buffer's file path as context

## Prompt IDs and Attachments

Each prompt is assigned a unique ID when the `crush> ` prompt is created, before you type anything. This ID is used to track attachments (context blocks) that belong to that prompt. All metadata is stored as text properties on the buffer content, so it persists and can be retrieved at any time.

### Text Properties

| Text Region             | Property                                                                                                       | Value                        |
| ----------------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| `crush> ` prompt marker | `crush-prompt-id` + `read-only`                                                                                | Unique ID for the prompt     |
| User input after prompt | `crush-prompt-id`                                                                                              | Same ID as the prompt marker |
| Attachment blocks       | `crush-attachment-id` + `crush-prompt-id` + `crush-region-type 'attachment` + `crush-filename` + `crush-lines` | Metadata for the attachment  |
| Response text           | `crush-response-to` + `crush-region-type 'response`                                                            | The prompt ID being answered |

### Header Line Display

The header line shows the prompt ID at point and attachment count:

```
Prompt: 20260805-091012-abc123 (2 attach)
```

The ID changes based on where your cursor is - if you move to an older prompt or response, the header line shows that prompt's ID.

### Attachments

When you insert context via:

- `C-c c a` (`crush-insert-selection`)
- `C-c C-b` (`crush-insert-buffer`)
- `C-c C-p` (`crush-insert-filepath`)

Each attachment is tagged with text properties that persist in the buffer: `crush-attachment-id` (unique ID), `crush-prompt-id` (the pending prompt), `crush-region-type` (`attachment`), `crush-filename` (path relative to the project root), and `crush-lines` (line range, when the attachment is a selection block). `crush-insert-filepath` inserts a markdown link `[relpath](relpath)` instead of a code block (no `crush-lines`).

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

## Rendering

Response text and attachment blocks are rendered as markdown. `markdown-mode` (when installed as the parent mode) provides native font-lock highlighting — including fenced code blocks — for both responses and attachment blocks. When the parent mode is `text-mode` (markdown-mode unavailable), the content is still markdown but no syntax highlighting is applied and crush.el adds no faces of its own.

The language inside attachment fences is derived from the file extension (`el` → `emacs-lisp`, `go` → `go`, `py` → `python`, `ts` → `typescript`, etc., falling back to `plaintext` for unknown extensions).

## Input History

Each prompt you send is stored in a custom input ring (`crush-input-ring-size`, default 32) and persisted to `~/.emacs.d/crush-history`. Use `M-p` and `M-n` to navigate previous inputs; the ring is loaded when the crush buffer is created and written back after each prompt.

## Stderr Handling

Stderr from Crush is routed to a separate `*crush-errors*` buffer to keep the main chat buffer clean. This buffer is created automatically when you send a prompt.

## Debug Logging

When `crush-debug-mode` is non-nil (default), commands, input, output, and sentinel events are logged to a `*crush-debug*` buffer. This is useful for diagnosing issues with the backend integration. Disable with:

```elisp
(setq crush-debug-mode nil)
```

For the hyper backend, each request logs a `request:` line with the URL, model, HTTP status, content type, and whether a token was sent (never the token itself). A non-2xx status is surfaced in the buffer as `[crush-hyper error: HTTP <code> from <url>]` instead of a generic connection error.

## License

MIT
