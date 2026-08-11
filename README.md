# crush.el

A GNU Emacs package for interacting with the [Crush CLI](https://github.com/charmbracelet/crush).

## Goal

crush.el provides a dedicated Emacs buffer that sends structured prompts to the Crush CLI and receives streamed responses. On top of that, any buffer selection can be used as context: the selection is formatted as a markdown fenced code block with the file path and line numbers (relative to the project root), then inserted into the crush buffer before the prompt as an attachment. When sent, the context blocks and prompt are piped to the Crush CLI via stdin.

See [TODO.md](TODO.md) for the full project goal and roadmap.

## Important: Permission Behavior

This package currently uses `crush run` mode, which **auto-approves all permissions**. Tools like `edit`, `write`, and `bash` execute immediately without prompting for user confirmation. This is functionally equivalent to running `crush --yolo`.

Permission prompts are planned for the direct API backend (not yet implemented). See the [TODO.md](TODO.md) roadmap and [CRUSH-SPEC.md](CRUSH-SPEC.md) for details.

## Installing

Not yet on MELPA. For now, clone and load manually:

```elisp
(use-package crush
  :load-path "/path/to/crush.el"
  :bind ("C-c c" . crush)
  :hook (prog-mode . crush-minor-mode))
```

Requires Emacs 28.1+.

## Configuration

### crush-model

Set the default model for Crush:

```elisp
(setq crush-model "claude-sonnet-4-20250514")
```

When set, the model is passed to `crush run --model`. When `nil` (default), uses Crush's default model.

### crush-working-directory

Set the working directory for the Crush CLI:

```elisp
(setq crush-working-directory "/path/to/project")
```

When `nil` (default), uses the project root if available, otherwise `default-directory`.

### crush-args

Additional command-line arguments passed to the Crush CLI:

```elisp
(setq crush-args '("--verbose"))
```

### Rendering

Response text is rendered as markdown. When the parent mode is `markdown-mode` (default when installed), native font-lock provides syntax highlighting including fenced code blocks. When the parent mode is `text-mode` (no markdown-mode), the content is still markdown but without syntax highlighting — crush.el applies no faces of its own.

Attachment blocks are also markdown fenced code blocks (` ``` <language>`) with a `**Attachment: <relpath> (lines N-M)**` header line, so they are highlighted by markdown-mode alongside responses. Paths are always relative to the project root (or the buffer's `default-directory` when not in a project).

### crush-backend-type

Which Crush backend to use:

```elisp
(setq crush-backend-type 'run)
```

- `run` (default) — standalone `crush run` mode. Each prompt spawns a new process. Fully implemented.
- `hyper` — direct HTTP access to the Charm Hyper gateway (OAuth device flow, SSE streaming, reasoning traces, permission prompts). Planned, not yet implemented. See [HYPER-API.md](HYPER-API.md).

### crush-debug-mode

When non-nil (default), log commands, input, output, and sentinel events to a `*crush-debug*` buffer. Set to `nil` to disable logging.

## Architecture

### Per-Prompt Process Model

Each prompt spawns a **new** `crush run` process; there is no persistent process:

1. Pressing `RET` spawns `crush run` with the prompt as a CLI argument (or via stdin, when context blocks are attached)
2. Output is streamed into the buffer by a custom output filter
3. When the process exits, the sentinel tags and freezes the response, then inserts a new `crush> ` prompt

Session continuity is handled by the Crush CLI's `--continue` flag, not by keeping a process alive.

### Backend Abstraction

All CLI interaction goes through a backend protocol (`crush-backend-send-prompt`, `crush-backend-interrupt`, `crush-backend-active-p`, `crush-backend-cleanup`, `crush-backend-grant-permission`) with two structs:

- `crush-run-backend` — the current implementation. Spawns `crush run --quiet` per prompt.
- `crush-client-backend` — stub struct (`host`, `workspace-id`, `client-id`, `sse-process`) whose methods all error "not yet implemented". The planned replacement is a `crush-hyper-backend` that calls the Charm Hyper chat-completions API directly (see [HYPER-API.md](HYPER-API.md)).

### Chat Buffer Composition

The crush buffer's major mode is the parent mode (`markdown-mode` if available, else `text-mode`); `crush-chat-mode` is a **minor mode** that provides the chat keybindings and hooks. Rendering, prompt tracking, and fontification are all implemented with text properties, markers, and markdown native font-lock instead of comint.

### Read-Only Handling

Prompt text and completed exchanges are made read-only via **text properties** (`read-only` with `front-sticky`/`rear-nonsticky` boundaries), so the history can't be edited while the current input area stays fully editable. A font-lock guard (`font-lock-unfontify-region-function`) and a `post-command-hook` re-assert the boundaries after markdown-mode refontifies the buffer.

### Metadata

All metadata is stored as **text properties** on buffer content; highlighting is left to markdown-mode's native font-lock.

## Usage

### Crush buffer (chat mode)

- `M-x crush` — open the crush interaction buffer
- Type a prompt and press `RET` to send it to the Crush CLI
- `M-p` / `M-n` — navigate input history (previous/next input)
- `C-c c i` — interrupt the running crush process
- `C-c c k` — clear the crush buffer (also starts a fresh session)
- `C-c c n` — start a new session
- `C-c c a` — insert the current buffer selection as context into the crush buffer

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

## Session Management

Crush maintains session state per working directory. The crush.el package manages this through two flags:

### `--continue` (automatic)

After sending your first prompt, `crush--continue` is set to `t`. All subsequent prompts automatically include `--continue`, which tells Crush to continue the most recent session in the working directory.

This means:

- The first prompt starts a new session
- All follow-up prompts in the same buffer continue that session
- The session persists across Emacs restarts (stored in Crush's database)

To start a fresh session:

- `C-c c n` (`crush-new-session`) — resets `crush--continue` to `nil`, so the next prompt starts a new session
- `C-c c k` (`crush-clear-buffer`) — clears the buffer **and** starts a fresh session

### `--session <id>` (manual)

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

### Session Flow Example

```
Buffer state         Command sent
----------------     --------------------------
crush--continue=nil  crush run --quiet "first prompt"
                     ↓ (crush--continue set to t)
crush--continue=t    crush run --quiet --continue "follow up"
crush--continue=t    crush run --quiet --continue "another"
C-c c n pressed      (crush--continue reset to nil)
crush--continue=nil  crush run --quiet "new session"
```

With manual session ID:

```
crush--session="abc123"  crush run --quiet --session abc123 "resume"
```

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

The language inside attachment fences is derived from the file extension (`el` → `emacs-lisp`, `go` → `go`, `py` → `python`, `ts` → `typescript`, etc., falling back to `text` for unknown extensions).

## Input History

Each prompt you send is stored in a custom input ring (`crush-input-ring-size`, default 32) and persisted to `~/.emacs.d/crush-history`. Use `M-p` and `M-n` to navigate previous inputs; the ring is loaded when the crush buffer is created and written back after each prompt.

## Stderr Handling

Stderr from Crush is routed to a separate `*crush-errors*` buffer to keep the main chat buffer clean. This buffer is created automatically when you send a prompt.

## Debug Logging

When `crush-debug-mode` is non-nil (default), commands, input, output, and sentinel events are logged to a `*crush-debug*` buffer. This is useful for diagnosing issues with the Crush CLI integration. Disable with:

```elisp
(setq crush-debug-mode nil)
```

## License

MIT
