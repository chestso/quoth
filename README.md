# crush.el

A GNU Emacs package for chatting with AI providers directly from an Emacs buffer.

## Motivation

[Crush](https://github.com/charmbracelet/crush) is my go-to coding agent TUI — until now. crush.el started with the observation that the Crush TUI's prompt area is not powerful enough to work with. A prompt is text, and text is the editor's home turf: composing, revising, and reviewing a prompt is editing, and an editor is a much more powerful surface for it than any prompt field. The keyboard is part of the story too — Crush's shortcuts follow Windows/macOS conventions, not Emacs muscle memory. And so the package grew out of a simple wish: to interact with Crush directly from the editor that is already open, Emacs.

Everything else follows from that wish. The conversation lives in a real buffer, so it inherits everything Emacs offers — kill and yank, search, multiple windows, markdown rendering, and project-aware context insertion — instead of a fixed prompt area with a fixed set of keys.

## Goal

crush.el's primary mode of operation is **direct provider interaction**: it talks to the [Charm Hyper gateway](HYPER-API.md) over HTTP+SSE (no separate CLI binary needed). A dedicated Emacs buffer sends prompts and streams the model's response, including chain-of-thought reasoning. On top of that, any buffer selection can be used as context: the selection is formatted as a markdown fenced code block with the file path and line numbers (relative to the project root), then inserted into the crush buffer before the prompt as an attachment.

Each project gets its own crush buffer (see [Per-Project Buffers](#per-project-buffers)), so work in different projects stays isolated.

See [TODO.md](TODO.md) for the full project goal and roadmap.

## Important: Permission Behavior

Tool calls run without confirmation: the provider executes the `bash` tool immediately when the model calls it. Interactive permission prompts for tool execution are on the roadmap. See the [TODO.md](TODO.md) roadmap for details.

## Installing

Not yet on MELPA. For now, clone and load manually:

```elisp
(use-package crush
  :load-path "/path/to/crush.el"
  :bind ("C-c c" . crush)
  :hook (prog-mode . crush-minor-mode))
```

Requires Emacs 28.1+. The package spans several files (`crush.el` plus `crush-provider.el`, `crush-openai.el`, `crush-stream.el`, `crush-hyper-provider.el`, `crush-tools.el`), so point `load-path` at the package directory. For manual `require`s, load `crush` last to get the full file set loaded. The provider requires only `curl`.

## Configuration

### crush-model

Set the default model for Crush:

```elisp
(setq crush-model "claude-sonnet-4-20250514")
```

When set, the model is used for requests. When `nil` (default), the provider falls back to `crush-openai-default-model` (the shared default).

### crush-working-directory

Set the working directory used by crush (resolves selections relative to it):

```elisp
(setq crush-working-directory "/path/to/project")
```

When `nil` (default), uses the project root if available, otherwise `default-directory`.

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

### Model selection

The provider uses `crush-model` (the shared model defcustom), falling back to `crush-openai-default-model` (`deepseek-v4-flash`). Request-level `max_tokens`, `temperature`, and `thinking`/`reasoning_effort` are controlled by the defcustoms below.

### crush-openai-timeout / crush-openai-max-tokens / crush-openai-temperature

Request tuning: timeout in seconds, `max_tokens` (default 64000), and sampling temperature (nil means unset).

### crush-hyper-history-limit / crush-hyper-history-include-reasoning

The provider is stateful: each request re-sends the buffer's completed exchanges — `user`, `assistant`, and `tool` turns — before the new prompt, so the model sees the whole conversation. Tool calls replay in the OpenAI function-calling shape: an assistant `tool_calls` declaration followed by the tool result with the matching `tool_call_id` (only the raw `<command>/<output>/<exit_code>` result and the stored call id travel, never the rendered tool block). The conversation is read from the buffer's tagged regions at send time — nothing is stored client- or server-side. `crush-hyper-history-limit` (default 200) caps how many prior exchanges are sent (the most recent ones are always retained); set it to `0` to disable history and get stateless per-prompt requests.

`crush-hyper-history-include-reasoning` (default nil) controls whether streamed chain-of-thought rides along in history: off, the assistant turn carries only the answer; on, the CoT is re-sent as the `reasoning_content` field of the assistant message, which is what the gateway requires for thinking turns carried across requests.

### crush-openai-thinking / crush-openai-reasoning-effort

When `crush-openai-thinking` is non-nil, the gateway's internal thinking mode is enabled. `crush-openai-reasoning-effort` selects the reasoning level (`low`, `medium`, `high`, `max`); nil uses the model default.

### crush-reasoning-preview-lines

Number of reasoning lines to show in the collapsed preview (default 10). When the reasoning region exceeds this, the first N lines are shown as a preview; the remainder is hidden behind an invisible overlay. Press `TAB` or `C-c c r` on the preview to expand or re-collapse. Set to 0 to always collapse with no preview.

Reasoning is a display aid and is excluded from model-visible history by default; set `crush-hyper-history-include-reasoning` to `t` to re-send it as the `reasoning_content` field on the assistant message (per [HYPER-API.md §3.4](HYPER-API.md)).

### crush-debug-mode

When non-nil (default), log commands, input, output, and sentinel events to a `*crush-debug*` buffer. Set to `nil` to disable logging.

## Architecture

crush.el talks to providers through a small provider protocol
(`crush-provider-*`): the concrete **hyper provider** (default) talks
directly to the [Charm Hyper gateway](HYPER-API.md) over HTTP+SSE — no
CLI binary needed — using the reusable OpenAI client in
`crush-openai.el` for request composition and streaming, and the local
`bash` tool in `crush-tools.el`. The chat buffer behaves identically
whichever provider is active.

Details — how requests are composed and streamed, session continuity,
tool-call replay, buffer metadata and read-only internals, and a
hacking guide — live in [ARCHITECTURE.md](ARCHITECTURE.md).

## Usage

### Crush buffer (chat mode)

- `M-x crush` — open the crush interaction buffer for the current project (or directory); each project gets its own buffer, named after the project root (e.g. `*crush:crush.el*`)
- Type a prompt and press `RET` to send it to the active provider
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
- Follow-up prompts in a project's buffer continue that project's session (session continuity via the provider's session id); the input history ring is also per project buffer.

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

Each prompt is assigned a unique ID when the input divider is
inserted, before you type anything. This ID tracks the user input and
attachments (context blocks) that belong to that prompt, and all
metadata is stored as text properties on the buffer content.

The chat buffer shows a frozen markdown horizontal divider (`---`,
framed by blank lines) above the editable input area; everything below
it is user input, tagged `crush-region-type 'user`. The divider itself
is tagged `'separator` and never reaches the model.

### Attachments

Insert context from a source buffer with:

- `C-c c a` (`crush-insert-selection`) — the active region
- `C-c C-b` (`crush-insert-buffer`) — the entire buffer
- `C-c C-p` (`crush-insert-filepath`) — the file path as a link

Each attachment is a markdown fenced code block with a
`**Attachment: <relpath> (lines N-M)**` header (paths relative to the
project root); `crush-insert-filepath` inserts a
`[relpath](relpath)` link instead. The metadata properties behind
this, plus the API for retrieving prompts/attachments programmatically,
are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

### Header Line Display

The header line shows the current model and the region type at point:

```
model: deepseek-v4-flash   region: response
```

The region type updates as the cursor moves: `prompt` on the input
line, `attachment` on context blocks, `reasoning` on chain-of-thought
text, `tool` on tool blocks, `response` on the final answer, and
`plain` elsewhere. The model is the effective provider model
(`crush-model` if set, else the provider default).

## Rendering

Response text and attachment blocks are rendered as markdown. `markdown-mode` (when installed as the parent mode) provides native font-lock highlighting — including fenced code blocks — for both responses and attachment blocks. When the parent mode is `text-mode` (markdown-mode unavailable), the content is still markdown but no syntax highlighting is applied and crush.el adds no faces of its own.

The language inside attachment fences is derived from the file extension (`el` → `emacs-lisp`, `go` → `go`, `py` → `python`, `ts` → `typescript`, etc., falling back to `plaintext` for unknown extensions).

## Input History

Each prompt you send is stored in a custom input ring (`crush-input-ring-size`, default 32) and persisted to `~/.emacs.d/crush-history`. Use `M-p` and `M-n` to navigate previous inputs; the ring is loaded when the crush buffer is created and written back after each prompt.

## Stderr Handling

Stderr from Crush is routed to a separate `*crush-errors*` buffer to keep the main chat buffer clean. This buffer is created automatically when you send a prompt.

## Debug Logging

When `crush-debug-mode` is non-nil (default), commands, input, output, and sentinel events are logged to a `*crush-debug*` buffer. This is useful for diagnosing issues with the provider integration. Disable with:

```elisp
(setq crush-debug-mode nil)
```

For the hyper provider, each request logs a `request:` line with the URL, model, HTTP status, content type, and whether a token was sent (never the token itself). A non-2xx status is surfaced in the buffer as `[crush-hyper error: HTTP <code> from <url>]` instead of a generic connection error.

## Contributing

Bug reports, patches, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the workflow (test + format
gate) and [ARCHITECTURE.md](ARCHITECTURE.md) to get oriented in the
code. Ideas are tracked in [TODO.md](TODO.md).

## License

MIT
