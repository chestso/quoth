# crush.el

A GNU Emacs package for interacting with the [Crush CLI](https://github.com/charmbracelet/crush).

## Goal

crush.el provides a dedicated Emacs buffer that sends structured prompts to the Crush CLI and receives streamed responses. On top of that, any buffer selection can be used as context: the selection is formatted as an org-mode source block with file path and line numbers, then inserted into the crush buffer before the prompt as an attachment. When sent, the context blocks and prompt are piped to the Crush CLI via stdin.

See [TODO.md](TODO.md) for the full project goal and roadmap.

## Installation

Not yet on MELPA. For now, clone and load manually:

```elisp
(use-package crush
  :load-path "/path/to/crush.el"
  :bind ("C-c c" . crush)
  :hook (prog-mode . crush-minor-mode))
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

## License

MIT
