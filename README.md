# Quoth

A GNU Emacs package for chatting with AI providers directly from an Emacs buffer.

## Motivation

[Crush](https://github.com/charmbracelet/crush) is my go-to coding agent TUI — until now. Quoth started with the observation that the Crush TUI's prompt area is not powerful enough to work with. A prompt is text, and text is the editor's home turf: composing, revising, and reviewing a prompt is editing, and an editor is a much more powerful surface for it than any prompt field. The keyboard is part of the story too — Crush's shortcuts follow Windows/macOS conventions, not Emacs muscle memory. And so the package grew out of a simple wish: to interact with Crush directly from the editor that is already open, Emacs.

Everything else follows from that wish. The conversation lives in a real buffer, so it inherits everything Emacs offers — kill and yank, search, multiple windows, markdown rendering, and project-aware context insertion — instead of a fixed prompt area with a fixed set of keys.

## Goal

Quoth's primary mode of operation is **direct provider interaction**: it talks to the [Charm Hyper gateway](HYPER-API.md) over HTTP+SSE (no separate CLI binary needed). A dedicated Emacs buffer sends prompts and streams the model's response, including chain-of-thought reasoning. On top of that, any buffer selection can be used as context: the selection is formatted as a markdown fenced code block with the file path and line numbers (relative to the project root), then inserted into the quoth buffer as plain user input and sent as part of the prompt.

Each project gets its own quoth buffer (see [Per-Project Buffers](#per-project-buffers)), so work in different projects stays isolated.

See [TODO.md](TODO.md) for the full project goal and roadmap.

## Important: Permission Behavior

Tool calls run without confirmation: the provider executes the `exec_command` tool immediately when the model calls it. Interactive permission prompts for tool execution are on the roadmap.

## Installing

Not yet on MELPA. For now, install from one of the repositories:

- **GitHub**: `https://github.com/chestso/quoth.git`
- **Codeberg**: `https://codeberg.org/chestso/quoth.git`

Both carry version tags (`v0.9.0`). A plain clone gets the latest commit, or pin to a tag for a stable release (see below).

### package-vc (Emacs 29+)

```elisp
(use-package quoth
  :vc (:url "https://github.com/chestso/quoth.git"
        :branch "v0.9.0")            ; omit :branch for latest
  :bind ("C-c c" . quoth)
  :hook (prog-mode . quoth-minor-mode))
```

### straight.el

```elisp
(use-package quoth
  :straight (quoth :type git :host github :repo "chestso/quoth"
                   :branch "v0.9.0")   ; omit :branch for latest
  :bind ("C-c c" . quoth)
  :hook (prog-mode . quoth-minor-mode))
```

### Manual clone

```sh
git clone --branch v0.9.0 https://github.com/chestso/quoth.git
```

Then load with `load-path`:

```elisp
(use-package quoth
  :load-path "/path/to/quoth"
  :bind ("C-c c" . quoth)
  :hook (prog-mode . quoth-minor-mode))
```

Requires Emacs 28.1+. The package spans several files (`quoth.el` plus `quoth-provider.el`, `quoth-openai.el`, `quoth-hyper-provider.el` + `quoth-tools.el`), so point `load-path` at the package directory. For manual `require`s, load `quoth` last to get the full file set loaded. The provider requires only `curl`.

## Configuration

Most of Quoth's behavior is configurable through Emacs customization:

```elisp
M-x customize-group RET quoth
```

The `quoth` group covers the essentials — working directory,
request tuning (`quoth-openai-timeout`, `-max-tokens`, `-temperature`,
`-thinking`, `-reasoning-effort`), history replay
(`quoth-hyper-history-limit`, `quoth-hyper-history-include-reasoning`),
reasoning display (`quoth-reasoning-preview-lines`), image
attachments (`quoth-image-max-raw-bytes`), the system prompt
(`quoth-openai-system-prompt`), debug logging, and the hyper provider
settings (`quoth-hyper-base-url`, `quoth-hyper-token`). Process
handling lives in the `quoth-process` group and tool behavior in the
`quoth-tool` group.

One setting needs setup beyond `M-x customize`: the token.

### quoth-hyper-token

Bearer access token for Hyper. Tokens are prefixed `sk-hyper-`; get one from the Hyper Dashboard. The default looks the token up in `auth-source` (gptel-style), so the recommended setup is a line in `~/.authinfo`:

```text
machine hyper.charm.land login apikey password sk-hyper-xxxxxxxxxxxxxxxxxxxxxxxx
```

The value may also be a string (used verbatim) or a function of no arguments returning the token (or another function):

```elisp
(setq quoth-hyper-token "sk-hyper-xxxxxxxxxxxxxxxxxxxxxxxx")
;; or
(setq quoth-hyper-token (lambda () (getenv "HYPER_API_KEY")))
```

Set it to `nil` to request without a token (useful for local gateways). A missing authinfo entry signals an error with setup instructions rather than silently sending no token.

### Web Search (SearXNG)

quoth includes a `web_search` tool that queries a local SearXNG instance. The tool is enabled by default and expects the server at `http://127.0.0.1:8888`. If SearXNG is unavailable, the tool reports "unreachable" once and short-circuits future calls until the server returns.

To set up a local SearXNG instance, see [SEARXNG.md](SEARXNG.md).

To disable the tool:

```elisp
(setq quoth-searxng-enabled nil)
```

To change the server URL:

```elisp
(setq quoth-searxng-base-url "http://127.0.0.1:9999")
```

## Architecture

Quoth talks to providers through a small provider protocol
(`quoth-provider-*`): the concrete **hyper provider** (default) talks
directly to the [Charm Hyper gateway](HYPER-API.md) over HTTP+SSE — no
CLI binary needed — using the reusable OpenAI client in
`quoth-openai.el` for request composition and streaming, and the local
tools (`exec_command`, `write_stdin`, `write_file`, `read_file`,
`edit_file` in `quoth-tools.el`, `web_search` in `quoth-searxng.el`). The chat buffer behaves identically
whichever provider is active.

Details — how requests are composed and streamed, session continuity,
tool-call replay, buffer metadata internals, and a hacking guide —
live in [ARCHITECTURE.md](ARCHITECTURE.md).

## Usage

### Quoth buffer (chat mode)

- `M-x quoth` — open the quoth interaction buffer for the current project (or directory); each project gets its own buffer, named after the project root (e.g. `*quoth:quoth*`)
- Type a prompt and press `C-c c s` (or `C-return` in graphical Emacs and in terminals that report it, e.g. portty/xterm) to send it to the active provider; `RET` (or `C-j`) inserts a newline for multiline prompts
- `M-p` / `M-n` — navigate input history (previous/next input)
- `TAB` — expand/collapse the reasoning (chain-of-thought) fold at point; otherwise normal TAB
- `C-c c m` — open the model selector (choose a model; toggle thinking, set reasoning effort, or reset to provider defaults)
- `C-c c i` — interrupt the running quoth process
- `C-c c k` — clear the quoth buffer (also starts a fresh session and rotates the session UUID)
- `C-c c r` — expand/collapse the reasoning fold at point
- `C-c c a` — attach an image file to the prompt (see [Image Attachments](#image-attachments))
- `C-c c t` — toggle the image link at point between attachment and plain markdown

### Per-Project Buffers

Each project (or directory, when not in a project) is bound to its own quoth buffer:

- Buffer names are derived from the project root, e.g. `*quoth:myproject*`. When two distinct roots share a basename, a numeric suffix keeps them separate: `*quoth:myproject(2)*`.
- `M-x quoth` and the `quoth-minor-mode` commands (`C-c C-s`, `C-c C-b`, `C-c C-p`, `C-c C-c`) always target the buffer for the current buffer's project or directory, so context and prompts never leak between projects.
- Follow-up prompts in a project's buffer continue that project's session (session continuity via the provider's session id); the input history ring is also per project buffer.

### Source buffers (minor mode)

Enable `quoth-minor-mode` in any buffer where you want to send content to quoth:

```elisp
M-x quoth-minor-mode
```

Or enable it automatically in programming modes:

```elisp
(add-hook 'prog-mode-hook #'quoth-minor-mode)
```

Keybindings (active when `quoth-minor-mode` is enabled):

- `C-c C-c` — open/switch to the quoth buffer
- `C-c C-s` — insert the active region as a markdown fenced code block with a context header
- `C-c C-b` — insert the entire buffer as a markdown fenced code block
- `C-c C-p` — insert the buffer's file path as context
- `C-c C-i` — attach the buffer's image file to the prompt (see [Image Attachments](#image-attachments))

## Inserting Context

Insert context from a source buffer with:

- `C-c C-s` (`quoth-insert-selection`) — the active region
- `C-c C-b` (`quoth-insert-buffer`) — the entire buffer
- `C-c C-p` (`quoth-insert-filepath`) — the file path as a link; with a
  prefix arg the same link is inserted as plain text without wire
  attachment

Inserted content is formatted as a markdown fenced code block with a
`**Source <relpath> (lines N-M)**` header (paths relative to the
project root); `quoth-insert-filepath` inserts a `[relpath](relpath)`
link instead. It is appended as plain user input, so it is sent as part
of the prompt — there is no separate attachment tracking. Image files
are the exception: `C-c C-p` on an image buffer inserts the
[Image Attachments](#image-attachments) link instead of the plain
path link.

### Image Attachments

Attach an image (PNG, JPEG, GIF, or WebP — by extension or magic
bytes) to a prompt and the model sees the pixels:

- `C-c c a` (`quoth-attach-image`) in the chat buffer, or
  `C-c C-i` in a source buffer visiting the image — picks a file,
  inserts a `![name](path)` link as user input, and marks it for wire
  attachment.
- `C-c c t` (`quoth-toggle-image-attach`) on a link flips it between
  attachment (the model sees the image) and plain markdown (the model
  reads the path as text). The buffer looks identical either way;
  only the wire behavior changes.

The buffer holds only the link — the image bytes are re-read from
disk and sent inline (base64 data URL) as an `image_url` content part
at send time, so the buffer stays the single source of truth and
killing/reopening it rebuilds the same request. An image larger than
`quoth-image-max-raw-bytes` (3.75MB raw by default, under the
gateway's 5MB base64 limit) is dropped from the wire with an error
note naming the cap; an unreadable file degrades to a text
placeholder the same way. When the model catalog positively knows the
active model cannot see images (e.g. the deepseek and llama families),
attaching still inserts the link and a warning note — the image is
sent but ignored; switch to a vision model with `C-c c m`.

The model can look at images it finds on its own: an image-aware
`read_file` returns the same `![name](path)` link as its result, and
the wire walk moves the pixels into a follow-up user message (the
gateway drops image content in tool messages). A model without image
support or a past-cap image gets an error result instead, so it can
fall back to describing the file textually.

Prompt/response tagging and metadata are documented in
[ARCHITECTURE.md](ARCHITECTURE.md).

### Header Line Display

The header line shows three clusters joined by `|`: the model name,
session usage, and the region type at point.

```
deepseek-v4-flash | ↑9.0k ↓1.2k $0.0123 42% | response
```

The model is the effective provider model (`quoth-model` if set, else
the provider default). Usage — input (`↑`) and output (`↓`) tokens,
accumulated cost, and cache percentage — appears only after the first
response. The region type updates as the cursor moves: `user` on the
input line, `separator` on a divider, `reasoning` on chain-of-thought
text, `tool` and `tool-output` on tool blocks, and `response` on the
final answer.

### Model selection and persistence

`C-c c m` opens a transient selector: pick a model from the active
provider's catalog, toggle thinking on/off, set a reasoning-effort
level, or use `d` to reset the per-session attributes to the provider
defaults. The catalog is fetched live from the provider, so prices and
context windows show for each model.

The selected model lives in the `quoth-model` variable (a plain
`defvar`, not a Customize option) and is applied to the buffer's
provider at initialization. `quoth-model` is registered with savehist,
so the choice persists across Emacs restarts — mirroring the input
history ring's persistence. Savehist is opt-in, so enable `savehist-mode`
in your init (`(savehist-mode 1)`); when on, it restores `quoth-model`
on startup and writes it back on exit, just as it does for minibuffer
history. Users who want a fixed default instead of a per-session choice
can `(setq quoth-model "...")` in their init after quoth loads, or
customize `quoth-openai-default-model`.

## Rendering

Response text and inserted context are rendered as markdown. `markdown-mode` (when installed as the parent mode) provides native font-lock highlighting — including fenced code blocks — for responses, inserted context, and tool output. When the parent mode is `text-mode` (markdown-mode unavailable), the content is still markdown but no syntax highlighting is applied and Quoth adds no faces of its own.

The language inside context fences is derived from the file extension (`el` → `emacs-lisp`, `go` → `go`, `py` → `python`, `ts` → `typescript`, etc., falling back to `plaintext` for unknown extensions).

## Input History

Each prompt you send is stored in a custom input ring (`quoth-input-ring-size`, default 32) and persisted to `~/.emacs.d/quoth-history`. Use `M-p` and `M-n` to navigate previous inputs; the ring is loaded when the quoth buffer is created and written back after each prompt.

## Stderr Handling

Stderr from Quoth is routed to a separate `*quoth-errors*` buffer to keep the main chat buffer clean. This buffer is created automatically when you send a prompt.

## Debug Logging

When `quoth-debug-mode` is non-nil (default), commands, input, output, and sentinel events are logged to a `*quoth-debug*` buffer. This is useful for diagnosing issues with the provider integration. Disable with:

```elisp
(setq quoth-debug-mode nil)
```

For the hyper provider, each request logs a `request:` line with the URL, model, HTTP status, content type, and whether a token was sent (never the token itself). A non-2xx status is surfaced in the buffer as `[quoth-hyper error: HTTP <code> from <url>]` instead of a generic connection error.

## Contributing

Bug reports, patches, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the workflow (test + format
gate) and [ARCHITECTURE.md](ARCHITECTURE.md) to get oriented in the
code. Ideas are tracked in [TODO.md](TODO.md).

## License

MIT
