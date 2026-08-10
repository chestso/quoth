# crush.el

A GNU Emacs package for interacting with the [Crush CLI](https://github.com/charmbracelet/crush).

## Goal

crush.el provides a dedicated Emacs buffer that sends structured prompts to the Crush CLI and receives streamed responses. On top of that, any buffer selection can be used as context: the selection is formatted as an org-mode source block with file path and line numbers, then inserted into the crush buffer before the prompt as an attachment. When sent, the context blocks and prompt are piped to the Crush CLI via stdin.

See [TODO.md](TODO.md) for the full project goal and roadmap.

## Important: Permission Behavior

This package uses `crush run` mode, which **auto-approves all permissions**. Tools like `edit`, `write`, and `bash` execute immediately without prompting for user confirmation. This is functionally equivalent to running `crush --yolo`.

If you need permission prompts, you would need to use client/server mode (not currently implemented in this package). See [CRUSH-SPEC.md](CRUSH-SPEC.md) for details.

## Installation

Not yet on MELPA. For now, clone and load manually:

```elisp
(use-package crush
  :load-path "/path/to/crush.el"
  :bind ("C-c c" . crush)
  :hook (prog-mode . crush-minor-mode))
```

## Configuration

### crush-model

Set the default model for Crush:

```elisp
(setq crush-model "claude-sonnet-4-20250514")
```

When set, the model is passed to `crush run --model`. When `nil`, uses Crush's default model.

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

### crush-fontify-responses

When non-nil (default), fontify response text using `markdown-mode` if available, with native syntax highlighting for fenced code blocks. When nil, only the fallback face is applied.

### crush-fontify-attachments

When non-nil (default), fontify attachment blocks using `org-mode` if available. When nil, only the fallback face is applied.

### crush-debug-mode

When non-nil (default), log commands, input, output, and sentinel events to a `*crush-debug*` buffer. Set to `nil` to disable logging.

## Usage

### Crush buffer (major mode)

- `M-x crush` — open the crush interaction buffer
- Type a prompt and press `RET` to send it to the Crush CLI
- `M-p` / `M-n` — navigate input history (previous/next input)
- `C-c C-c` — interrupt the running crush process
- `C-c C-k` — clear the crush buffer (also starts a fresh session)
- `C-c C-s` — start a new session
- `C-c C-i` — insert the current buffer selection as context into the crush buffer

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
- `C-c C-s` — insert the active region as an org source block
- `C-c C-b` — insert the entire buffer as an org source block
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

- `C-c C-s` (`crush-new-session`) — resets `crush--continue` to `nil`, so the next prompt starts a new session
- `C-c C-k` (`crush-clear-buffer`) — clears the buffer **and** starts a fresh session

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
C-c C-s pressed      (crush--continue reset to nil)
crush--continue=nil  crush run --quiet "new session"
```

With manual session ID:

```
crush--session="abc123"  crush run --quiet --session abc123 "resume"
```

## Prompt IDs and Attachments

Each prompt is assigned a unique ID when the `crush> ` prompt is created, before you type anything. This ID is used to track attachments (context blocks) that belong to that prompt. All metadata is stored as text properties on the buffer content, so it persists across sessions and can be retrieved at any time.

### Text Properties

| Text Region             | Property                                  | Value                                   |
| ----------------------- | ----------------------------------------- | --------------------------------------- |
| `crush> ` prompt marker | `crush-prompt-id`                         | Unique ID for the prompt                |
| User input after prompt | `crush-prompt-id`                         | Same ID as the prompt marker            |
| Attachment org blocks   | `crush-attachment-id` + `crush-prompt-id` | Unique attachment ID + parent prompt ID |
| Response text           | `crush-response-to`                       | The prompt ID being answered            |

### Header Line Display

The header line shows the prompt ID at point and attachment count:

```
Prompt: 20260805-091012-abc123 (2 attach)
```

The ID changes based on where your cursor is - if you move to an older prompt or response, the header line shows that prompt's ID.

### Attachments

When you insert context via:

- `C-c C-s` (`crush-insert-selection`)
- `C-c C-b` (`crush-insert-buffer`)
- `C-c C-p` (`crush-insert-filepath`)

Each attachment is tagged with text properties (`crush-attachment-id` and `crush-prompt-id`) that persist in the buffer.

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
(get-text-property (point) 'crush-response-to)
```

## Fontification

Response text is highlighted by `markdown-mode` (if installed), using its native syntax highlighting and fenced-code support — no overlays are added for responses. When `markdown-mode` is unavailable and the buffer falls back to `text-mode`, the `crush-response-face` is applied to responses so they stay visually distinct.

Attachment blocks are fontified as org using `org-mode` (if installed), via a temp-buffer technique with overlay-based faces that survive `jit-lock` refontification. When org is unavailable, the `crush-org-face` fallback is applied:

- `crush-response-face` — background face for response text in the text-mode fallback (gray20 dark / gray90 light)
- `crush-org-face` — background face for attachment blocks (gray15 dark / gray95 light)

Disable fontification with:

```elisp
(setq crush-fontify-responses nil
      crush-fontify-attachments nil)
```

## Input History

Input history is managed by comint's built-in `comint-input-ring`. Use `M-p` and `M-n` to navigate previous inputs. History is persisted to `~/.emacs.d/crush-history` and loaded on buffer creation.

## Stderr Handling

Stderr from Crush is routed to a separate `*crush-errors*` buffer to keep the main chat buffer clean. This buffer is created automatically when you send a prompt.

## Debug Logging

When `crush-debug-mode` is non-nil (default), commands, input, output, and sentinel events are logged to a `*crush-debug*` buffer. This is useful for diagnosing issues with the Crush CLI integration. Disable with:

```elisp
(setq crush-debug-mode nil)
```

## License

MIT
