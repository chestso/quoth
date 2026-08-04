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

## Usage

### Crush buffer (major mode)

- `M-x crush` — open the crush interaction buffer
- Type a prompt and press `RET` to send it to the Crush CLI
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

## Stderr Handling

Stderr from Crush is routed to a separate `*crush-errors*` buffer to keep the main chat buffer clean. This buffer is created automatically when you send a prompt.

## License

MIT
