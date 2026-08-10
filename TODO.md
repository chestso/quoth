# crush.el TODO

## Goal

crush.el is a GNU Emacs package for interacting with the [Crush CLI](https://github.com/charmbracelet/crush).

It operates in two ways:

1. **Dedicated chat buffer**: A buffer that sends structured prompts to the Crush CLI and receives responses through the CLI. The buffer maintains a single continuous session across prompts (using `crush run --continue`), so follow-up questions keep context.

2. **Selection-as-context**: In any Emacs buffer, a selection can be used as context. When sent, the selection is formatted as an org-mode source block with file path and line numbers, then inserted into the crush buffer. The user can then add additional context about what to do with the selection before sending the prompt.

## Interaction Model

- **Per-prompt calling**: Each prompt is sent to `crush run` as a separate invocation. The CLI streams the response to stdout and exits.
- **Session continuity**: The first prompt starts a fresh session. Each subsequent prompt passes `--continue`, which continues the active session in the working directory. `crush-new-session` resets this so the next prompt starts a new session.
- **Manual session selection**: Setting `crush--session` passes `--session <id>` to continue a specific session by ID.
- **Context format**: Selections are formatted as org-mode source blocks:

```
#+begin_src text :file src/foo.go :lines 42-58
...selected code...
#+end_src
```

## Roadmap

### Phase 1: Core (complete)

- [x] Skeleton: `crush.el`, `README.md`, `TODO.md`
- [x] Basic prompt sending via `crush run`
- [x] Response streaming into the crush buffer
- [x] Session continuation via `--continue`
- [x] Selection insertion as org source blocks
- [x] Prompt region management (comint field-based prompts)
- [x] Input locking while process runs
- [x] Prompt response header in buffer
- [x] Stderr routing to separate `*crush-errors*` buffer
- [x] Working directory resolution (`crush-working-directory` / project root)
- [x] ERT test suite with mock CLI integration tests
- [x] Minor mode (`crush-minor-mode`) for source buffer keybindings
- [x] `crush-insert-buffer` (whole buffer as context)
- [x] `crush-insert-filepath` (file path as context)
- [x] Context blocks inserted before prompt as attachments
- [x] Context sent to CLI via stdin with explanatory preamble
- [x] Shared buffer init helper (`crush--init-buffer`)
- [x] `format.sh` for elisp, markdown, and shell formatting
- [x] `--quiet` flag to suppress spinner output
- [x] SIGINT handling (show "Interrupted" message)
- [x] Model selection via `crush-model` defcustom (`--model` flag)
- [x] Manual session selection via `crush--session` (`--session` flag)
- [x] Permission behavior documentation (auto-approve warning)

### Phase 1b: Comint integration (complete)

- [x] `comint-output-filter` as process filter
- [x] `comint-send-input` for input handling with custom `comint-input-sender`
- [x] Field-based prompts (`comint-use-prompt-regexp` nil)
- [x] `comint-highlight-prompt` face on prompts
- [x] `comint-input-ring` for input history (M-p/M-n, persisted to file)
- [x] Placeholder process pattern for per-prompt model
- [x] False-prompt suppression via `comint-output-filter-functions`
- [x] Prompt and attachment text property tracking
- [x] Debug logging to `*crush-debug*` buffer

### Phase 1c: Fontification (complete)

- [x] Region-based fontification dispatch (`crush--fontify-region`)
- [x] Markdown fontification of responses via temp-buffer technique
- [x] Org fontification of attachment blocks via temp-buffer technique
- [x] Overlay-based faces (survive `jit-lock` refontification)
- [x] `crush-response-face` and `crush-org-face` fallback faces
- [x] `crush-fontify-responses` and `crush-fontify-attachments` defcustoms
- [x] Region type tagging (`response`, `org`, `separator`)

### Phase 2: Polish

- [ ] Error handling and retry
- [x] Backend abstraction (crush-backend, crush-run-backend, crush-client-backend)
- [ ] Client/server mode for structured output (SSE event stream)
- [ ] Permission request handling via client/server mode
- [ ] Tool call visibility in responses

### Phase 3: Integration

- [ ] `use-package` integration
- [ ] MELPA submission
- [ ] Project.el integration (auto-detect project root)
- [ ] Multiple concurrent crush sessions
- [ ] Keybindings for common operations (switch model, yolo mode, etc.)

### Phase 4: Advanced

- [ ] MCP server support via Emacs
- [ ] Tool call display and approval
- [ ] Diff/patch application from crush responses
- [ ] Context menu for richer selection formatting
- [ ] Transient-based command dispatch
