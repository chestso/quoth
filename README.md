# Quoth

A GNU Emacs package for chatting with AI providers directly from an Emacs
buffer.

## Motivation

[Crush](https://github.com/charmbracelet/crush) is my go-to coding agent TUI —
until now. Quoth started with the observation that the Crush TUI's prompt area
is not powerful enough to work with. A prompt is text, and text is the editor's
home turf: composing, revising, and reviewing a prompt is editing, and an editor
is a much more powerful surface for it than any prompt field. The keyboard is
part of the story too — Crush's shortcuts follow Windows/macOS conventions, not
Emacs muscle memory. And so the package grew out of a simple wish: to interact
with Crush directly from the editor that is already open, Emacs.

Everything else follows from that wish. The conversation lives in a real buffer,
so it inherits everything Emacs offers — kill and yank, search, multiple
windows, markdown rendering, and project-aware context insertion — instead of a
fixed prompt area with a fixed set of keys.

## Goal

Quoth's primary mode of operation is **direct provider interaction**: it talks
to AI providers over HTTP+SSE (no separate CLI binary needed) — the
[Charm Hyper gateway](HYPER-API.md) by default, or
[Ollama Cloud](OLLAMA-CLOUD-API.md). A dedicated Emacs buffer sends prompts and
streams the model's response, including chain-of-thought reasoning. On top of
that, any buffer selection can be used as context: the selection is formatted as
a markdown fenced code block with the file path and line numbers (relative to
the project root), then inserted into the quoth buffer as plain user input and
sent as part of the prompt.

Internally, providers plug in through a small provider protocol. Two ship with
the package — hyper (the default) and ollama — and both are thin shims over a
reusable OpenAI client for request composition and streaming, plus a set of
local tools (`exec_command`, `write_stdin`, `write_file`, `read_file`,
`edit_file`, `web_search`). The chat buffer behaves identically whichever
provider is active. How requests are composed and streamed, session continuity,
tool-call replay, buffer metadata internals, and a hacking guide are documented
in [ARCHITECTURE.md](ARCHITECTURE.md).

Each project gets its own quoth buffer (see
[Per-Project Buffers](#per-project-buffers)), so work in different projects
stays isolated.

See [TODO.md](TODO.md) for the full project goal and roadmap.

## Important: Permission Behavior

Tool calls run without confirmation: the provider executes the `exec_command`
tool immediately when the model calls it. Interactive permission prompts for
tool execution are on the roadmap.

## Installing

Not yet on MELPA. For now, install from one of the repositories:

- **GitHub**: `https://github.com/chestso/quoth.git`
- **Codeberg**: `https://codeberg.org/chestso/quoth.git`

Both carry version tags (`v0.9.0`). A plain clone gets the latest commit, or pin
to a tag for a stable release (see below).

### package-vc (Emacs 29+)

```elisp
(use-package quoth
  :vc (:url "https://github.com/chestso/quoth.git"
        :branch "v0.9.0")            ; omit :branch for latest
  :hook (prog-mode . quoth-minor-mode))
```

### straight.el

```elisp
(use-package quoth
  :straight (quoth :type git :host github :repo "chestso/quoth"
                   :branch "v0.9.0")   ; omit :branch for latest
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
  :hook (prog-mode . quoth-minor-mode))
```

Requires Emacs 28.1+. The package spans several files (`quoth.el` plus
`quoth-provider.el`, `quoth-openai.el`, `quoth-hyper-provider.el`,
`quoth-ollama-provider.el`, `quoth-tools.el`), so point `load-path` at the
package directory. For manual `require`s, load `quoth` last to get the full file
set loaded. The providers require only `curl`.

## Configuration

Most of Quoth's behavior is configurable through Emacs customization:

```elisp
M-x customize-group RET quoth
```

The `quoth` group covers the essentials — the provider defaults for new buffers
(`quoth-default-provider`, `quoth-default-model`, `quoth-default-thinking`,
`quoth-default-reasoning-effort`), history replay (`quoth-history-limit`,
`quoth-hyper-history-include-reasoning`), reasoning display
(`quoth-reasoning-preview-lines`), image attachments
(`quoth-image-max-raw-bytes`), the system prompt (`quoth-openai-system-prompt`),
request tuning (`quoth-openai-timeout`, `-max-tokens`, `-temperature`), debug
logging, and the provider settings (`quoth-hyper-base-url`, `quoth-hyper-token`,
`quoth-ollama-base-url`, `quoth-ollama-token`). Process handling lives in the
`quoth-process` group and tool behavior in the `quoth-tool` group.

One setting needs setup beyond `M-x customize`: the provider token.

### quoth-hyper-token

Bearer access token for Hyper. Tokens are prefixed `sk-hyper-`; get one from the
Hyper Dashboard. The default looks the token up in `auth-source` (gptel-style),
so the recommended setup is a line in `~/.authinfo`:

```text
machine hyper.charm.land login apikey password sk-hyper-xxxxxxxxxxxxxxxxxxxxxxxx
```

The value may also be a string (used verbatim) or a function of no arguments
returning the token (or another function):

```elisp
(setq quoth-hyper-token "sk-hyper-xxxxxxxxxxxxxxxxxxxxxxxx")
;; or
(setq quoth-hyper-token (lambda () (getenv "HYPER_API_KEY")))
```

Set it to `nil` to request without a token (useful for local gateways). A
missing authinfo entry signals an error with setup instructions rather than
silently sending no token.

### Ollama Cloud (quoth-ollama-token)

The ollama provider targets Ollama Cloud (`https://ollama.com/v1`, the
OpenAI-compatible surface; see [OLLAMA-CLOUD-API.md](OLLAMA-CLOUD-API.md)).
Create an API key at `https://ollama.com/settings/keys` and add an authinfo
line, the same pattern as hyper:

```text
machine ollama.com login apikey password <your-ollama-key>
```

The `quoth-ollama-token` default looks that entry up; it also accepts a string
or a function, or `nil` to send no token. `quoth-ollama-base-url` overrides the
server (also honored: the `OLLAMA_URL` environment variable) — pointing it at a
local daemon such as `http://localhost:11434/v1` makes the provider talk to that
server instead of the cloud, a plain configuration change since the local daemon
speaks the same protocol.

### Providers and sessions

Each quoth buffer holds its own session: the active provider, model, thinking,
and reasoning-effort are buffer-local, seeded at buffer creation from the global
defaults (`quoth-default-provider`, `quoth-default-model`,
`quoth-default-thinking`, `quoth-default-reasoning-effort`). Switching provider
inside a buffer is `p` in the model selector (`C-c " m`): it changes only that
buffer, aborts any running request on the old provider, and re-seeds the model
from the new provider's chain (the last model you used on it, else the
provider's built-in default, else the global default). Thinking and effort carry
over — they are provider-agnostic.

The model you pick is remembered per provider across Emacs restarts via
`savehist` (when `savehist-mode` is enabled), so a new buffer on a provider
starts with the model you last used there. The provider default for new buffers
changes only through Customize or `setq` (`quoth-default-provider`), never from
inside a chat buffer.

### Web Search (SearXNG)

quoth includes a `web_search` tool that queries a local SearXNG instance. The
tool is enabled by default and expects the server at `http://127.0.0.1:8888`. If
SearXNG is unavailable, the tool reports "unreachable" once and short-circuits
future calls until the server returns.

To set up a local SearXNG instance, see [SEARXNG.md](SEARXNG.md).

To disable the tool:

```elisp
(setq quoth-searxng-enabled nil)
```

To change the server URL:

```elisp
(setq quoth-searxng-base-url "http://127.0.0.1:9999")
```

## Usage

### Quoth buffer (chat mode)

- `M-x quoth` — open the quoth interaction buffer for the current project (or
  directory); each project gets its own buffer, named after the project root
  (e.g. `*quoth:quoth*`)
- Type a prompt and press `C-c " s` (or `C-return` in graphical Emacs and in
  terminals that report it, e.g. portty/xterm) to send it to the active
  provider; `RET` (or `C-j`) inserts a newline for multiline prompts
- `M-p` / `M-n` — navigate input history (previous/next input)
- `TAB` — expand/collapse the reasoning (chain-of-thought) fold at point;
  otherwise normal TAB
- `C-c " m` — open the model selector: pick a model, switch the active provider
  (`p`), toggle thinking, set a reasoning-effort level, or use `d` to reset the
  per-session attributes to the provider defaults
- `C-c " i` — interrupt the running quoth process
- `C-c " k` — clear the quoth buffer (also starts a fresh session and rotates
  the session UUID)
- `C-c " r` — expand/collapse the reasoning fold at point
- `C-c " a` — attach an image file to the prompt (see
  [Image Attachments](#image-attachments))
- `C-c " t` — toggle the image link at point between attachment and plain
  markdown

### Per-Project Buffers

Each project (or directory, when not in a project) is bound to its own quoth
buffer:

- Buffer names are derived from the project root, e.g. `*quoth:myproject*`. When
  two distinct roots share a basename, a numeric suffix keeps them separate:
  `*quoth:myproject(2)*`.
- `M-x quoth` and the `quoth-minor-mode` commands (`C-c " f`, `C-c " b`,
  `C-c " p`, `C-c " "`) always target the buffer for the current buffer's
  project or directory, so context and prompts never leak between projects.
- Follow-up prompts in a project's buffer continue the same conversation, and
  the input history ring is also per project buffer.

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

- `C-c " "` — open/switch to the quoth buffer
- `C-c " f` — insert the active region as a markdown fenced code block with a
  context header
- `C-c " b` — insert the entire buffer as a markdown fenced code block
- `C-c " p` — insert the buffer's file path as context
- `C-c " a` — attach the buffer's image file to the prompt (see
  [Image Attachments](#image-attachments))

### Customizing the keybindings

Both modes share the `C-c "` prefix, the punctuation space the Emacs key-binding
conventions allocate to minor modes (it is unbound in text-mode, markdown-mode,
and the common programming modes). The command letters live in two keymap
variables, one per mode:

- `quoth-chat-command-map` — chat-buffer commands (`s` send, `i` interrupt, `k`
  clear, `r` reasoning fold, `m` model selector, `a` attach image, `t` toggle
  image link)
- `quoth-minor-command-map` — source-buffer commands (`f` selection, `b` buffer,
  `p` file path, `a` attach image, `"` open the quoth buffer)

Each mode map hangs its command map under the prefix, so moving the whole prefix
is one re-parenting pair per mode. To use `C-c q` everywhere instead, put this
in your init after quoth loads:

```elisp
(with-eval-after-load 'quoth
  ;; Chat buffer: C-c q s, C-c q i, ...
  (define-key quoth-chat-mode-map (kbd "C-c q") quoth-chat-command-map)
  (define-key quoth-chat-mode-map (kbd "C-c \"") nil)
  ;; Source buffers: C-c q f, C-c q b, ... and C-c q q opens the buffer.
  (define-key quoth-minor-mode-map (kbd "C-c q") quoth-minor-command-map)
  (define-key quoth-minor-mode-map (kbd "C-c \"") nil))
```

Rebinding works live, including in buffers where the modes are already active.
Single keys can be rebound the usual way, e.g.:

```elisp
(define-key quoth-chat-command-map (kbd "S") #'quoth-send-input)
```

One caveat: org-mode binds `C-c " a` and `C-c " g` for table plotting, so pick a
different prefix if you enable `quoth-minor-mode` in org buffers.

## Inserting Context

Insert context from a source buffer with:

- `C-c " f` (`quoth-insert-selection`) — the active region
- `C-c " b` (`quoth-insert-buffer`) — the entire buffer
- `C-c " p` (`quoth-insert-filepath`) — the file path as a link; with a prefix
  arg the same link is inserted as plain text without wire attachment

Inserted content is formatted as a markdown fenced code block with a
`**Source <relpath> (lines N-M)**` header (paths relative to the project root);
`quoth-insert-filepath` inserts a `[relpath](relpath)` link instead. It is
appended as plain user input, so it is sent as part of the prompt. Image files
are the exception: `C-c " p` on an image buffer inserts the
[Image Attachments](#image-attachments) link instead of the plain path link.

### Image Attachments

Attach an image (PNG, JPEG, GIF, or WebP) to a prompt and the model sees the
pixels:

- `C-c " a` (`quoth-attach-image`) in the chat buffer, or `C-c " a` in a source
  buffer visiting the image — picks a file and inserts a `![name](path)` link as
  user input.
- `C-c " t` (`quoth-toggle-image-attach`) on a link flips it between attachment
  (the model sees the image) and plain markdown (the model reads the path as
  text). The buffer looks identical either way.

An image that is too large or unreadable is skipped with an error note in the
buffer. When the active model cannot see images, attaching still inserts the
link along with a warning note — the image is sent but ignored; switch to a
vision model with `C-c " m`. The model can also look at image files it reads on
its own with `read_file`, the same way.

How attachments travel to the provider is documented in
[ARCHITECTURE.md](ARCHITECTURE.md).

### Header Line Display

The header line shows up to four clusters joined by two spaces: the model name,
session usage, capacity, and the region type at point.

```
deepseek-v4-flash  ↑9.0k ↓1.2k $0.0123 42%  ctx 7%  response
```

The model is the active provider's model (the buffer's session model, set at
buffer creation from the provider's model chain and updated by the model
selector). Usage — input (`↑`) and output (`↓`) tokens, accumulated cost, and
cache percentage — appears after the first response completes and totals the
whole session (tokens, cost, and cache percentage across all prompts and tool
rounds; cleared by `C-c " k`). Providers that report no cost (ollama does not)
show tokens only. The capacity cluster (`ctx 7%` in the example) shows the
**last request's** share of the model's context window — its input and output
tokens divided by the window from the model catalog. It appears once a round has
finished and the catalog reports the window, and it disappears for models the
catalog knows no window for. The last cluster is the region type at point, or
`-` on untagged text, which includes the input area before its first send.

### Model selection and persistence

`C-c " m` opens a transient selector: pick a model from the active provider's
catalog, switch the buffer to another provider (`p`), toggle thinking on/off,
set a reasoning-effort level, or use `d` to reset the per-session attributes to
the provider defaults. The catalog is seeded from a bundled snapshot of the
provider's model list (regenerated by `make models`), so prices and context
windows show for each model even before the first fetch, and a live refresh (`g`
in the selector) keeps it current.

The last model used on each provider persists across Emacs restarts via
`savehist` when `savehist-mode` is enabled. Savehist is opt-in, so enable it in
your init (`(savehist-mode 1)`) if you want the choice to persist. Users who
want a fixed default instead of the per-provider memory can set
`quoth-default-model`, the cross-provider fallback for buffers that have not
chosen a model.

## Rendering

Response text and inserted context are rendered as markdown. `markdown-mode`
(when installed as the parent mode) provides native font-lock highlighting —
including fenced code blocks — for responses, inserted context, and tool output.
When the parent mode is `text-mode` (markdown-mode unavailable), the content is
still markdown but no syntax highlighting is applied and Quoth adds no faces of
its own.

The language inside context fences is derived from the file extension (`el` →
`emacs-lisp`, `go` → `go`, `py` → `python`, `ts` → `typescript`, etc., falling
back to `plaintext` for unknown extensions).

## Input History

Each prompt you send is stored in a custom input ring (`quoth-input-ring-size`,
default 32) and persisted to `~/.emacs.d/quoth-history`. Use `M-p` and `M-n` to
navigate previous inputs; the ring is loaded when the quoth buffer is created
and written back after each prompt.

## Stderr Handling

Stderr from Quoth is routed to a separate `*quoth-errors*` buffer to keep the
main chat buffer clean. This buffer is created automatically when you send a
prompt.

## Debug Logging

When `quoth-debug-mode` is non-nil (default), commands, input, output, and
sentinel events are logged to a `*quoth-debug*` buffer. This is useful for
diagnosing issues with the provider integration — the log never contains your
token. Disable with:

```elisp
(setq quoth-debug-mode nil)
```

Errors are surfaced in the chat buffer itself: a failed request shows a
`> **Error:** HTTP <code> from <url>` note instead of a generic connection
error.

## Contributing

Bug reports, patches, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the workflow (test + format gate) and
[ARCHITECTURE.md](ARCHITECTURE.md) to get oriented in the code. Ideas are
tracked in [TODO.md](TODO.md).

## License

MIT
