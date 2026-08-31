;;; quoth.el --- Chat with AI providers from GNU Emacs  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Version: 0.3.0
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience
;;; Prefix: quoth-

;;; This file is not part of GNU Emacs.

;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;; of this software and associated documentation files (the "Software"), to deal
;;; in the Software without restriction, including without limitation the rights
;;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;;; copies of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:

;;; The above copyright notice and this permission notice shall be included in all
;;; copies or substantial portions of the Software.

;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

;;; Commentary:

;; quoth.el is a GNU Emacs package for direct provider interaction: a
;; dedicated interactive buffer that sends structured prompts to AI
;; models over HTTP and receives streamed responses.  The provider talks
;; to the Charm Hyper gateway (https://hyper.charm.land) via streaming
;; chat completions.
;;
;; In addition to the dedicated chat buffer, any buffer selection can
;; be used as context.  The selection is formatted as a markdown fenced
;; code block with the file path and line numbers, then inserted
;; into the quoth buffer where the user can add additional context
;; about what to do with it.
;;
;; See TODO.md for the full project goal and roadmap.

;;; Code:

(require 'subr-x)
(require 'project)
(require 'seq)
(require 'cl-lib)
(require 'ring)
(require 'json)

;;; Configuration

(defgroup quoth nil
  "Chat with AI providers from GNU Emacs."
  :group 'tools
  :prefix "quoth-")

(defgroup quoth-openai nil
  "Reusable OpenAI-compatible client."
  :group 'quoth
  :prefix "quoth-openai-")

(defgroup quoth-hyper nil
  "Charm Hyper gateway provider."
  :group 'quoth
  :prefix "quoth-hyper-")

(defface quoth-reasoning-face
  '((t :inherit region :extend t))
  "Face for streamed chain-of-thought reasoning text.
Applied via an overlay (not a text property) so markdown-mode
refontification cannot strip it.  Inherits the theme's `region'
background, a neutral dark tint that leaves markdown's text colors
visible on top.  `:extend t' paints the background across the full
window width on every line the reasoning covers."
  :group 'quoth)

;;; Buffer-local state

;;; `quoth--continue', `quoth--session-uuid', `quoth--session-id', and
;;; `quoth--response-start' are the shared buffer-local state; providers
;;; must not touch them.  The provider owns its transport process in
;;; `quoth-provider-transport-process' — the buffer side never touches a
;;; process directly.

(defcustom quoth-reasoning-preview-lines 10
  "Number of reasoning lines to show in the collapsed preview.
When a reasoning region contains more than this many lines, the first
N lines are shown as a preview and the rest are hidden behind a fold
marker.  Set to 0 to always collapse with no preview.
Must be a non-negative integer."
  :type 'integer
  :group 'quoth)

(defvar-local quoth--continue nil
  "Whether the next prompt continues the conversation session.
When non-nil, the next prompt continues the active session.
Set to nil by `quoth-clear-buffer' so the next prompt starts a fresh
session.")

(defcustom quoth-working-directory nil
  "Working directory for the quoth provider.
When nil, uses the project root if `project-current' is non-nil,
otherwise `default-directory'."
  :type '(choice (const nil) directory)
  :group 'quoth)

(defcustom quoth-input-ring-size 32
  "Maximum number of prompts stored in the input ring."
  :type 'integer
  :group 'quoth)

(defcustom quoth-debug-mode t
  "When non-nil, log commands, input, and output to a *quoth-debug* buffer."
  :type 'boolean
  :group 'quoth)

(defvar-local quoth--session nil
  "Session ID to pass to the provider.
When non-nil, continues a specific session by ID.
Takes precedence over `quoth--continue'.")

(defvar-local quoth--session-uuid nil
  "Opaque UUID identifying this quoth buffer's session.
Generated in `quoth--init-buffer' and rotated by `quoth-clear-buffer'.
The hyper provider hashes it (XXH3-64) for the x-session-id /
x-session-affinity cache-affinity headers; the raw UUID is never sent
to the network.  Persistence (as a file-local) is Phase 2 roadmap work.
Buffer-local.")

(defvar-local quoth--session-id nil
  "The 16-hex XXH3-64 of `quoth--session-uuid'.
Computed lazily by the hyper provider on request; kept here so the hash
is stable for the session's life, and to trace as `SESS' in the debug
log.  Buffer-local.")

(defvar-local quoth--response-start nil
  "Marker for where response text starts.
Set when prompt is sent, used by sentinel to tag response text.")

;;; Stream state (idle/active/done/error), progress, and the error pane.
;;; Buffer-local; these track the lifecycle of one prompt-response cycle.

(defvar-local quoth--stream-state nil
  "Stream state plist: (:status STATUS :error ERR :count N).
STATUS is `idle', `active', `done', or `error'.  ERR is the error
message when STATUS is `error', and COUNT is the application count,
meaning the runnable pipeline, inflight, and blocked applications.
Buffer-local.")

(defun quoth--stream-transition (status &optional count error)
  "Move the stream state to STATUS with optional COUNT and ERROR.
Records the transition in `quoth--stream-state'."
  (setq-local quoth--stream-state
              (list :status status
                    :error error
                    :count (or count
                               (plist-get quoth--stream-state :count)
                               1))))

(defun quoth--stream-progress ()
  "Return the stream state plist (status, error, applications).
Reads `quoth--stream-state', defaulting to a fresh `idle' state with one
application when the buffer never sent anything.  Exposes `:applications'
as the runnable-pipeline/inflight/blocked count for UI consumers."
  (let* ((state (or quoth--stream-state
                    (list :status 'idle :error nil :count 1)))
         (count (or (plist-get state :count)
                    (when (and quoth-active-provider
                               (quoth-provider-p quoth-active-provider))
                      (quoth-provider-application-count quoth-active-provider))
                    1)))
    (plist-put (copy-sequence state) :applications count)))

(defun quoth--stream-clear ()
  "Reset the stream state to a fresh `idle' state."
  (setq-local quoth--stream-state
              (list :status 'idle :error nil :count 1)))

(defun quoth--record-error (message)
  "Record an error MESSAGE on the stream and render the error pane.
Marks the stream `error' and inserts a clickable error pane overlay at
point-max carrying `quoth-error-action' (so `quoth-clear-buffer' sweeps
it)."
  (quoth--stream-transition 'error nil message)
  (let ((pos (point-max)))
    (save-excursion
      (goto-char pos)
      (newline)
      (let ((start (point)))
        (insert (format "[quoth error: %s]" message))
        (let ((ov (make-overlay start (point) (current-buffer) t nil)))
          (overlay-put ov 'face 'error)
          (overlay-put ov 'quoth-overlay t)
          (overlay-put ov 'quoth-error-action #'quoth--dismiss-error-pane)
          (overlay-put ov 'keymap (let ((map (make-sparse-keymap)))
                                    (define-key map (kbd "RET")
                                                #'quoth--dismiss-error-pane)
                                    map)))))))

(defun quoth--dismiss-error-pane ()
  "Dismiss the error pane overlay at point (or the most recent one)."
  (interactive)
  (let ((ov (or (cl-find-if
                 (lambda (o) (overlay-get o 'quoth-error-action))
                 (overlays-at (point)))
                (cl-find-if
                 (lambda (o) (overlay-get o 'quoth-error-action))
                 (overlays-in (point-min) (point-max))))))
    (when (overlayp ov)
      (delete-region (overlay-start ov) (1+ (overlay-end ov)))
      (delete-overlay ov)
      (quoth--stream-clear)
      (message "Error dismissed"))))

(defvar quoth--prompt-id nil
  "Unique ID for the current pending prompt.
Generated when prompt marker is created, used when prompt is sent.
Buffer-local.")

(defvar quoth--initialized nil
  "Non-nil once a quoth buffer has been initialized.
Used to make `quoth--init-buffer' idempotent regardless of the active
parent mode (which may be `markdown-mode' or `text-mode').
Buffer-local.")

(defvar quoth--prompt-start-marker nil
  "Marker at the start of the input separator line.
Buffer-local.")

(defvar quoth--reasoning-start nil
  "Marker at the start of the current reasoning region, or nil.
Set by the hyper provider on the first reasoning delta streamed for
the current prompt.  Buffer-local.")

(defvar quoth--reasoning-end nil
  "Marker at the end of the reasoning region, or nil.
Set on the first content delta (reasoning stops where the answer
begins).  Buffer-local.")

(defvar quoth--reasoning-overlay nil
  "Overlay highlighting the current reasoning region, or nil.
Carries `quoth-reasoning-face' and the `quoth-overlay' property so
`quoth-clear-buffer' removes it.  Buffer-local.")

(defvar quoth--input-start-marker nil
  "Marker at the start of the editable input region.
This is right after the input separator line.
Buffer-local.")

(defvar quoth--project-root nil
  "Canonical project root (or `default-directory') this buffer serves.
Set at initialization; determines the buffer name and the working
directory for the quoth provider.  Buffer-local.")

(defvar quoth--input-ring nil
  "Ring of previously entered prompts.
Buffer-local.")

(defvar quoth--input-ring-index 0
  "Position in `quoth--input-ring' for previously-entered inputs.
Navigated with `quoth--input-previous' / `quoth--input-next'.
Buffer-local.")

(defvar quoth--input-ring-file-name
  (expand-file-name "quoth-history" user-emacs-directory)
  "File where input history is persisted.")

;;; Backend abstraction

;;; The `quoth-provider' base struct and the `quoth-provider-*' protocol
;;; live in `quoth-provider.el'; the reusable OpenAI client in
;;; `quoth-openai.el'; the concrete provider in `quoth-hyper-provider.el'
;;; (direct HTTP to the Charm Hyper gateway).
;;; The dependency files sit next to this file but are not guaranteed to
;;; be on `load-path': package.el adds the package dir, while direct
;;; `load' or flycheck's batch byte-compile do not.  Try `require'
;;; first, then fall back to loading from this file's own directory so
;;; both setups work.
(eval-and-compile
  (dolist (dep '("quoth-provider" "quoth-openai" "quoth-xxh3"
                 "quoth-process" "quoth-hyper-provider" "quoth-tools"
                 "quoth-searxng"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              ;; In a flycheck byte-compile child the source path lives in
              ;; `buffer-file-name'; under `load' it is `load-file-name'.
              ;; `default-directory' is a last resort for eval-buffer.
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defvar quoth-active-provider nil
  "The active quoth provider for this buffer.
Set during buffer initialization; `quoth--send-prompt' and
`quoth-interrupt' dispatch through it.  Buffer-local.")
(declare-function markdown-mode "markdown-mode" ())
(declare-function quoth-xxh3-hash64 "quoth-xxh3" (input))
(declare-function quoth-provider--tool-calls "quoth-provider" (provider process))
(declare-function quoth-provider--tool-results "quoth-provider" (provider tool-calls))
(declare-function quoth-process--cleanup-buffer "quoth-process" (owner))
(declare-function quoth-openai-parse-tool-args "quoth-openai" (args-json))
(declare-function quoth-process--shell-type "quoth-process" (shell-path))
(declare-function quoth-hyper--fetch-models "quoth-hyper-provider" (base-url &optional token))
(declare-function quoth-hyper--model-choices "quoth-hyper-provider" (catalog))
(declare-function quoth-hyper-provider-p "quoth-hyper-provider" (object))
(declare-function quoth-hyper-provider-model "quoth-hyper-provider" (object))
(declare-function quoth-provider-transport-process "quoth-provider" (provider))

;;; Buffer naming

(defvar quoth--root-buffer-alist nil
  "Alist mapping canonical project root directories to quoth buffer names.
Each entry is (ROOT . NAME) where ROOT is an absolute directory path
with a trailing slash.  Entries survive buffer kills so that re-opening
a root keeps its original buffer name, including any collision suffix.")

(defun quoth--canonical-root (root)
  "Return ROOT as a canonical absolute directory path with trailing slash."
  (file-name-as-directory (expand-file-name root)))

(defun quoth--buffer-name-for-root (root)
  "Return a stable, unique quoth buffer name for project/directory ROOT.
The name is based on the basename of ROOT, e.g. \"*quoth:foo*\".  When
another distinct root already resolved to that name, an incrementing
suffix is appended: \"*quoth:foo(2)*\", \"*quoth:foo(3)*\", and so on.
The mapping is recorded in `quoth--root-buffer-alist' so the same ROOT
always resolves to the same name."
  (let* ((canonical (quoth--canonical-root root))
         (existing (cdr (assoc canonical quoth--root-buffer-alist))))
    (if existing
        existing
      (let* ((base (file-name-nondirectory
                    (directory-file-name canonical)))
             (base (if (string-empty-p base) "root" base))
             (name (format "*quoth:%s*" base))
             (counter 2))
        (while (member name (mapcar #'cdr quoth--root-buffer-alist))
          (setq name (format "*quoth:%s(%d)*" base counter))
          (setq counter (1+ counter)))
        (push (cons canonical name) quoth--root-buffer-alist)
        name))))

(defun quoth--current-root ()
  "Return the canonical project root for the current buffer, if any.
Returns the `project-root' when the current buffer is inside a project,
otherwise `default-directory'.  Both as canonical directory paths."
  (let ((proj (project-current)))
    (quoth--canonical-root
     (or (when proj (project-root proj))
         default-directory))))

(defun quoth--current-quoth-buffer ()
  "Return the quoth buffer associated with the current context.
The root is the project root when in a project, otherwise
`default-directory'.  Creates and initializes the buffer if needed."
  (let* ((root (quoth--current-root))
         (name (quoth--buffer-name-for-root root))
         (buf (get-buffer-create name)))
    (quoth--init-buffer buf)
    buf))

;;; Major mode

(defvar quoth--parent-mode
  (if (require 'markdown-mode nil t)
      'markdown-mode
    'text-mode)
  "Parent mode for the quoth buffer.
Uses `markdown-mode' if available, otherwise `text-mode'.")

;;; Chat minor mode

(defvar quoth-chat-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'quoth-send-input)
    (define-key map (kbd "i") #'quoth-interrupt)
    (define-key map (kbd "k") #'quoth-clear-buffer)
    (define-key map (kbd "r") #'quoth-reasoning-toggle)
    (define-key map (kbd "m") #'quoth-select-model)
    map)
  "Keymap under `C-c c' for quoth chat-buffer commands.")

(defvar quoth-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'quoth--reasoning-tab)
    ;; `C-return' is the main send binding in graphical Emacs and on
    ;; terminals that report modifyOtherKeys/kitty CSI-u (e.g. portty).
    ;; `C-c c s' remains the portable send binding.
    (define-key map (kbd "<C-return>") #'quoth-send-input)
    (define-key map (kbd "C-c c") quoth-chat-command-map)
    (define-key map (kbd "M-p") #'quoth--input-previous)
    (define-key map (kbd "M-n") #'quoth--input-next)
    map)
  "Keymap for `quoth-chat-mode'.")

(define-minor-mode quoth-chat-mode
  "Minor mode for interactive Quoth chat in a buffer.

When enabled, provides keybindings for sending prompts,
interrupting, clearing, and session management.

\\{quoth-chat-mode-map}"
  :lighter " Chat"
  :group 'quoth
  :keymap quoth-chat-mode-map
  (if quoth-chat-mode
      (add-hook 'post-command-hook #'quoth--update-header-line nil t)
    (remove-hook 'post-command-hook #'quoth--update-header-line t)))

;;; Internal helpers

(defun quoth--debug-log (category message)
  "Log MESSAGE with CATEGORY to *quoth-debug* buffer.
Only logs when `quoth-debug-mode' is non-nil."
  (when quoth-debug-mode
    (with-current-buffer (get-buffer-create "*quoth-debug*")
      (goto-char (point-max))
      (insert (format "[%s] %s: %s\n"
                      (format-time-string "%H:%M:%S")
                      category message)))))

(defun quoth--generate-id ()
  "Generate a unique ID for a prompt."
  (format "%s-%s"
          (format-time-string "%Y%m%d-%H%M%S")
          (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))

(defun quoth--input-ring-read ()
  "Read input history from `quoth--input-ring-file-name'."
  (setq quoth--input-ring (make-ring quoth-input-ring-size))
  (when (file-readable-p quoth--input-ring-file-name)
    (let ((lines nil))
      (with-temp-buffer
        (insert-file-contents quoth--input-ring-file-name)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p line)
              (push line lines))
            (forward-line 1))))
      (dolist (line (nreverse lines))
        (ring-insert quoth--input-ring line)))))

(defun quoth--input-ring-write ()
  "Write input history to `quoth--input-ring-file-name'."
  (when (and quoth--input-ring (ring-p quoth--input-ring))
    (let ((ring quoth--input-ring)
          (file quoth--input-ring-file-name))
      (with-temp-buffer
        (dotimes (i (ring-length ring))
          (insert (ring-ref ring i) "\n"))
        (write-region (point-min) (point-max) file nil 'quiet)))))

(defun quoth--input-ring-add (input)
  "Add INPUT to the input ring, skipping duplicates."
  (when (and quoth--input-ring (ring-p quoth--input-ring)
             (not (string-empty-p input)))
    (unless (and (> (ring-length quoth--input-ring) 0)
                 (string= input (ring-ref quoth--input-ring 0)))
      (ring-insert quoth--input-ring input))))

(defun quoth--input-previous ()
  "Insert the previous input from the input ring."
  (interactive)
  (when (and quoth--input-ring (ring-p quoth--input-ring)
             (> (ring-length quoth--input-ring) 0))
    (let ((input-start (marker-position quoth--input-start-marker)))
      (when input-start
        (delete-region input-start (point-max))
        (goto-char input-start)
        (insert (ring-ref quoth--input-ring quoth--input-ring-index))
        (setq-local quoth--input-ring-index
                    (min (1+ quoth--input-ring-index)
                         (1- (ring-length quoth--input-ring))))))))

(defun quoth--input-next ()
  "Insert the next input from the input ring."
  (interactive)
  (when (and quoth--input-ring (ring-p quoth--input-ring)
             (> (ring-length quoth--input-ring) 0))
    (let ((input-start (marker-position quoth--input-start-marker)))
      (when input-start
        (delete-region input-start (point-max))
        (goto-char input-start)
        (if (<= quoth--input-ring-index 0)
            (setq-local quoth--input-ring-index 0)
          (setq-local quoth--input-ring-index (1- quoth--input-ring-index))
          (insert (ring-ref quoth--input-ring quoth--input-ring-index)))))))

(defun quoth--header-model ()
  "Return the effective model name for the header line, or nil.
Reads the provider's model slot (derived from `quoth-model' at buffer
init); falls back to `quoth-openai-default-model' for hyper providers."
  (let ((model (and (quoth-hyper-provider-p quoth-active-provider)
                    (quoth-hyper-provider-model quoth-active-provider))))
    (or model
        (and (quoth-hyper-provider-p quoth-active-provider)
             quoth-openai-default-model))))

(defun quoth--region-label-at-point ()
  "Return the `quoth-region-type' at point as a string, or nil.
Any region type symbol maps to its name, so new region types (e.g. the
nested `tool-output' span and the input `separator') label themselves
without a static list.  Returns nil when the point carries no region
type, so untagged space is never mistaken for `user'."
  (let ((type (get-text-property (point) 'quoth-region-type)))
    (when (and type (symbolp type))
      (symbol-name type))))

(defun quoth--header-model-segment ()
  "Return the model cluster for the header line, or nil.
The model name only; the model's cost definition joins here later."
  (let ((model (quoth--header-model)))
    (or model "-")))

(defun quoth--header-usage-segment ()
  "Return the usage cluster for the header line, or nil.
Session usage (tokens, cost, cache%); nil until the first response."
  (quoth--usage-header-segment))

(defun quoth--header-buffer-segment ()
  "Return the buffer cluster for the header line, or nil.
The region type at point; the right-most cluster."
  (or (quoth--region-label-at-point) "-"))

(defun quoth--update-header-line ()
  "Update the header line from its model, usage, and buffer clusters.
Each cluster is built by a dedicated segment function; non-nil segments
are joined by ` | ' so related info stays adjacent."
  (let ((segments (delq nil
                        (list (quoth--header-model-segment)
                              (quoth--header-usage-segment)
                              (quoth--header-buffer-segment)))))
    (setq header-line-format
          (list (propertize (mapconcat #'identity segments " | ")
                            'face 'bold)))))

(defun quoth--lang-from-extension (filename)
  "Return the markdown language identifier for FILENAME's extension.
Uses `file-name-extension' so paths and dotfiles resolve; falls back to
`plaintext' for unknown extensions."
  (let ((ext (file-name-extension filename)))
    (pcase ext
      ("el" "emacs-lisp")
      ("elc" "emacs-lisp")
      ("go" "go")
      ("py" "python")
      ("js" "javascript")
      ("jsx" "jsx")
      ("ts" "typescript")
      ("tsx" "tsx")
      ("rs" "rust")
      ("c" "c")
      ("h" "c")
      ("cpp" "cpp")
      ("cc" "cpp")
      ("hpp" "cpp")
      ("sh" "bash")
      ("zsh" "bash")
      ("bash" "bash")
      ("md" "markdown")
      ("markdown" "markdown")
      ("json" "json")
      ("jsonc" "json")
      ("toml" "toml")
      ("yaml" "yaml")
      ("yml" "yaml")
      ("css" "css")
      ("html" "html")
      ("sql" "sql")
      ("rb" "ruby")
      ("java" "java")
      ("kt" "kotlin")
      ("swift" "swift")
      ("php" "php")
      ("lua" "lua")
      ("r" "r")
      ("clj" "clojure")
      (_ "plaintext"))))

(defconst quoth--input-separator-text "---"
  "Text of the markdown horizontal divider.
This precedes the editable input area.")

(defun quoth--insert-input-separator ()
  "Insert the input divider (`---') at point, framed by blank lines.
The editable input area starts right after the divider's trailing
blank line.  At `bobp' no blank line is inserted above the divider.
`quoth--prompt-start-marker' (insertion type t) anchors the divider's
start so attachments and prior content can be inserted before it;
`quoth--input-start-marker' marks where typed input begins."
  (unless (bobp)
    (insert "\n"))
  (let ((start (point)))
    (insert quoth--input-separator-text "\n\n")
    (put-text-property start (point)
                       'quoth-region-type 'separator)
    (put-text-property start (point) 'quoth-prompt-id quoth--prompt-id)
    (setq-local quoth--prompt-start-marker (copy-marker start))
    (set-marker-insertion-type quoth--prompt-start-marker t)
    (setq-local quoth--input-start-marker (point-marker))
    (set-marker-insertion-type quoth--input-start-marker nil)))

(defun quoth--insert-user-separator ()
  "Insert a horizontal divider marking the end of the user input.
Renders the same `---' as `quoth--input-separator-text' and frames it
with a blank line above and below, mirroring
`quoth--insert-input-separator'.  It is a display-only seam between the
user leg and the assistant leg of a turn, not an editable input prompt:
inserted at point (on the line after the user's prompt, before the
response starts).  It carries no face; markdown renders the `---'
itself as a horizontal rule.  Tagged `quoth-region-type'
`user-separator' so the history/continuation readers
\(`quoth--user-turn-text', `quoth-get-response-text', `quoth--tool-rounds'\)
all skip it; it carries `quoth-prompt-id' but never `quoth-response-to',
so it belongs to the turn yet never leaks into the assistant response
region."
  (unless (bobp)
    (insert "\n"))
  (let ((start (point)))
    (insert quoth--input-separator-text "\n\n")
    (put-text-property start (point) 'quoth-region-type 'user-separator)
    (put-text-property start (point) 'quoth-prompt-id quoth--prompt-id)))

(defvar-local quoth--follow-p nil
  "Whether the quoth buffer's window is following the stream.
Set by `quoth--insert-at-eof' when the `window-point' was at point-max
before insertion.  Persists across rapid `process-filter' invocations
where `window-point' is stale (redisplay hasn't run yet).  Reset to
nil when the user scrolls back (`window-point' diverges from
point-max on a redisplay cycle).")

(defvar-local quoth--last-follow-point 0
  "Last point-max value set by `quoth--insert-at-eof' when following.
Used to detect stale `window-point' during rapid process output:
if `window-point' is behind this, the user scrolled back.")

(defun quoth--insert-at-eof (text &optional props position)
  "Insert TEXT at POSITION (default point-max), applying PROPS.
PROPS is a plist of text properties applied to the inserted text.
Returns the new point-max.

If the cursor is at POSITION, advance it to the new end and let the
window auto-scroll naturally.  Otherwise preserve the cursor position
and every window's scroll position, so a user who has scrolled back
can keep reading while content streams in.

Uses `window-point' (not buffer point) because the process filter and
sentinel run in other buffers, where the quoth buffer's saved point is
stale.  This mirrors comint's `comint-adjust-window-point' pattern.

Modification hooks are suppressed so per-delta streaming does not
schedule a font-lock refontify for every character; font-lock never
clobbers the region tags (it only manages `face'), so the suppression
is purely a performance measure for this hot path.

When following, sets `quoth--follow-p' so the next call (which may run
before redisplay updates `window-point') continues to follow.  When
`window-point' is behind POSITION AND behind the last follow position,
the user scrolled back: stop following."
  (let* ((inhibit-modification-hooks t)
         (position (or position (point-max)))
         (windows (get-buffer-window-list (current-buffer) nil t))
         (selected-win (or (get-buffer-window (current-buffer) 'visible)
                           (car windows)))
         (snapshots (mapcar (lambda (w)
                              (list w (window-start w) (window-point w)))
                            windows))
         (win-point (if selected-win
                        (window-point selected-win)
                      (point)))
         ;; Follow when window-point is at POSITION, OR when we were
         ;; following and window-point hasn't diverged (stale redisplay
         ;; keeps window-point at the old position, which is < POSITION).
         ;; If we were following but window-point is now well behind
         ;; (the user scrolled back during a redisplay cycle), stop.
         (follow (or (= win-point position)
                     (and quoth--follow-p
                          (<= win-point position)
                          (>= win-point (or quoth--last-follow-point 0))))))
    (goto-char position)
    (insert text)
    (when props
      (add-text-properties position (point) props))
    (if follow
        (progn
          (setq-local quoth--follow-p t)
          (setq-local quoth--last-follow-point (point-max))
          (goto-char (point-max))
          (when selected-win
            (set-window-point selected-win (point-max))))
      (setq-local quoth--follow-p nil)
      (dolist (s snapshots)
        (set-window-start (nth 0 s) (nth 1 s) nil)
        (set-window-point (nth 0 s) (nth 2 s)))
      (goto-char win-point))
    (point-max)))

(defun quoth-get-all-prompts ()
  "Return list of all unique prompt IDs in buffer."
  (let ((pos (point-min))
        prompts)
    (while (< pos (point-max))
      (let ((prompt-id (get-text-property pos 'quoth-prompt-id)))
        (when (and prompt-id (not (member prompt-id prompts)))
          (push prompt-id prompts))
        (setq pos (or (next-single-property-change pos 'quoth-prompt-id nil (point-max))
                      (point-max)))))
    (nreverse prompts)))

(defun quoth-get-response-text (prompt-id)
  "Return the assistant answer text for PROMPT-ID, or nil.
The text tagged `quoth-response-to' equal to PROMPT-ID, excluding the
streamed reasoning (CoT) span, the reasoning-fold marker line, and any
tool blocks (display decoration around tool results).  Reasoning
streams before the answer, and tool blocks may interrupt it, so the
answer is the concatenation of the non-reasoning, non-tool runs.
Returns nil when no such region exists."
  (let ((pos (text-property-any (point-min) (point-max)
                                'quoth-response-to prompt-id)))
    (when pos
      (let* ((end (or (next-single-property-change pos 'quoth-response-to
                                                   nil (point-max))
                      (point-max)))
             (chunks nil)
             (p pos))
        ;; Walk the response, skipping reasoning and tool spans.
        (while (< p end)
          (let ((type (get-text-property p 'quoth-region-type))
                (run-end (or (next-single-property-change p 'quoth-region-type
                                                          nil end)
                             end)))
            (unless (memq type '(reasoning tool tool-output))
              (push (buffer-substring-no-properties p run-end) chunks))
            (setq p run-end)))
        (let ((text (string-join (nreverse chunks) "")))
          (string-trim text))))))

(defun quoth-get-reasoning-text (prompt-id)
  "Return the streamed reasoning (CoT) text for PROMPT-ID, or nil.
The span tagged `quoth-region-type' `reasoning' within the response
region for PROMPT-ID, trimmed.  Returns nil when the model produced
no chain-of-thought."
  (let ((pos (text-property-any (point-min) (point-max)
                                'quoth-response-to prompt-id)))
    (when pos
      (let ((end (or (next-single-property-change pos 'quoth-response-to
                                                  nil (point-max))
                     (point-max))))
        (let ((rs (text-property-any pos end 'quoth-region-type 'reasoning)))
          (when rs
            (let ((re (or (next-single-property-change rs 'quoth-region-type
                                                       nil end)
                          end)))
              (let ((text (string-trim
                           (buffer-substring-no-properties rs re))))
                (when (> (length text) 0)
                  text)))))))))

(defun quoth--user-turn-text (prompt-id)
  "Return the user-side text for PROMPT-ID: typed input + inserted context.
The text is the buffer content tagged `quoth-region-type' `user' within
the region tagged `quoth-prompt-id' PROMPT-ID, in buffer order.  The
separator line, the response, and reasoning regions (which share
the `quoth-prompt-id' tag but belong to the assistant) are excluded.
Returns nil when nothing remains."
  (let ((pos (text-property-any (point-min) (point-max)
                                'quoth-prompt-id prompt-id))
        (chunks nil))
    (while pos
      (let* ((prompt-end (or (next-single-property-change pos 'quoth-prompt-id
                                                          nil (point-max))
                             (point-max)))
             (type-end (or (next-single-property-change pos 'quoth-region-type
                                                        nil prompt-end)
                           prompt-end))
             (end type-end))
        (when (and (< pos end)
                   (eq (get-text-property pos 'quoth-region-type) 'user))
          (push (buffer-substring-no-properties pos end) chunks))
        (setq pos (and (< end (point-max))
                       (text-property-any end (point-max)
                                          'quoth-prompt-id prompt-id)))))
    (let ((text (string-join (nreverse chunks) "")))
      (when (> (length (string-trim text)) 0)
        (string-trim text)))))

(defun quoth--history-turns (prompt-id)
  "Return the conversation history for PROMPT-ID as message alists.
Iterate the buffer's prompts in order, stopping at PROMPT-ID (the pending
prompt is being sent and never part of history).  Each prior exchange is
reconstructed from the buffer's tagged regions: the user message via
`quoth--user-turn-text', the assistant/tool messages via
`quoth--tool-rounds' (which yields message alists directly).  When
`quoth-hyper-history-include-reasoning' is non-nil, the CoT text is folded
into the exchange's trailing assistant message as `reasoning_content'.
Returns nil when PROMPT-ID is the first prompt, or when
`quoth-hyper-history-limit' is 0.  This is a pure buffer->wire read."
  (if (= quoth-hyper-history-limit 0)
      nil
    (let* ((prompts (quoth-get-all-prompts))
           (reached-current nil)
           (messages nil))
      (dolist (id prompts)
        (if (string= id prompt-id)
            (setq reached-current t)
          (unless reached-current
            (let ((exchange nil))
              (let ((user-text (quoth--user-turn-text id)))
                (when user-text
                  (setq exchange
                        (append exchange
                                (list (list (cons 'role "user")
                                            (cons 'content user-text)))))))
              (let ((round-msgs (quoth--tool-rounds id)))
                (if round-msgs
                    (setq exchange (append exchange round-msgs))
                  (let ((resp-text (quoth-get-response-text id)))
                    (when resp-text
                      (setq exchange
                            (append exchange
                                    (list (list (cons 'role "assistant")
                                                (cons 'content resp-text)))))))))
              (when quoth-hyper-history-include-reasoning
                (let ((reasoning-text (quoth-get-reasoning-text id)))
                  (when (and reasoning-text (> (length reasoning-text) 0))
                    (let ((assistant (car (last exchange))))
                      (when (and assistant
                                 (string= (cdr (assoc 'role assistant)) "assistant"))
                        (setcdr (last assistant)
                                (list (cons 'reasoning_content reasoning-text))))))))
              (setq messages (append messages exchange))))))
      (let* ((ordered messages)
             (exchanges (cl-count-if (lambda (m) (string= (cdr (assoc 'role m)) "user"))
                                     ordered)))
        (if (and (> quoth-hyper-history-limit 0)
                 (> exchanges quoth-hyper-history-limit))
            (let ((to-cut (- exchanges quoth-hyper-history-limit))
                  (cut 0)
                  (i 0))
              (while (and (< i (length ordered))
                          (if (string= (cdr (assoc 'role (nth i ordered))) "user")
                              (< cut to-cut)
                            t))
                (when (string= (cdr (assoc 'role (nth i ordered))) "user")
                  (setq cut (1+ cut)))
                (setq i (1+ i)))
              (seq-subseq ordered i))
          ordered)))))

(defun quoth--history-for (buffer)
  "Return BUFFER's history without its pending prompt.
The pending prompt is the one about to be sent (its ID lives in
BUFFER's `quoth--prompt-id'); the transcript stops at the last
completed exchange.  Entering BUFFER is this function's job, which
keeps the provider buffer-free."
  (with-current-buffer buffer
    (quoth--history-turns quoth--prompt-id)))

(defun quoth--tool-block-raw-result (start end)
  "Return the raw tool result for the tool block spanning START..END.
The nested `tool-output' span is the wire `role: \"tool\"' content;
fall back to the trimmed block text for legacy blocks without it."
  (let ((raw-pos (text-property-any start end 'quoth-region-type 'tool-output)))
    (string-trim
     (buffer-substring-no-properties
      (or raw-pos start)
      (if raw-pos
          (or (next-single-property-change raw-pos 'quoth-region-type nil end)
              end)
        end)))))

(defun quoth--tool-call-alist (plist)
  "Return the wire element for `quoth-tool-call' PLIST, or nil.
The element is the `tool_calls' field.  PLIST carries :id :name
:args-json; a missing id or name yields nil so a legacy block degrades
to a bare tool message."
  (when (and (stringp (plist-get plist :id))
             (stringp (plist-get plist :name)))
    (list (cons 'id (plist-get plist :id))
          (cons 'type "function")
          (cons 'function
                (list (cons 'name (plist-get plist :name))
                      (cons 'arguments (or (plist-get plist :args-json) "")))))))

(defun quoth--tool-rounds (prompt-id &optional start end)
  "Return the assistant/tool message alists for PROMPT-ID's response.
Walk the response region's `quoth-region-type' spans in order and
reconstruct the OpenAI messages the model produced: `response' spans
accumulate assistant content; each `tool' span contributes an assistant
`tool_calls' message (carrying any accumulated leading content) followed
by its `role: \"tool\"' result.  Contiguous `tool' spans share one
assistant message (parallel invocation in a round).  Reasoning and the nested
`tool-output' spans are skipped.  START/END bound the walk, defaulting to
the whole response region for PROMPT-ID.  This is the single buffer->wire
reconstruction used by both history replay and the live tool loop."
  (let* ((start (or start
                    (text-property-any (point-min) (point-max)
                                       'quoth-response-to prompt-id)))
         (end (or end
                  (and start
                       (or (next-single-property-change start 'quoth-response-to
                                                        nil (point-max))
                           (point-max))))))
    (if (not start)
        nil
      (let ((pos start)
            (prev nil)
            (pending nil)        ; accumulated response text, reverse order
            (calls nil)          ; (call-alist id raw) triples, forward order
            (messages nil))      ; message alists, forward order
        (cl-labels
            ((flush-tools
               ()
               (when calls
                 (let* ((text (string-trim (apply #'concat (nreverse pending))))
                        (content (and (> (length text) 0) text))
                        (tcs (vconcat (mapcar #'car calls))))
                   (setq messages
                         (append messages
                                 (list (append
                                        (list (cons 'role "assistant")
                                              (cons 'content content))
                                        (list (cons 'tool_calls tcs))))))
                   (dolist (entry calls)
                     (setq messages
                           (append messages
                                   (list (list (cons 'role "tool")
                                               (cons 'tool_call_id (nth 1 entry))
                                               (cons 'content (nth 2 entry)))))))
                   (setq calls nil
                         pending nil)))))
          (while (< pos end)
            (let* ((call-plist (get-text-property pos 'quoth-tool-call))
                   (call-end (or (next-single-property-change pos 'quoth-tool-call
                                                              nil end)
                                 end))
                   (type (get-text-property pos 'quoth-region-type))
                   (region-end (or (next-single-property-change pos 'quoth-region-type
                                                                nil end)
                                   end)))
              (cond
               ;; A tool block: `quoth-tool-call' spans it contiguously, even
               ;; though the nested `tool-output' span splits region-type.  A
               ;; legacy block has `tool' type but no `quoth-tool-call' span.
               ((or call-plist (eq type 'tool))
                (if (quoth--tool-call-alist call-plist)
                    ;; One tool call per assistant message, preserving round
                    ;; boundaries (no merging of sequential rounds).
                    (progn
                      (setq calls
                            (list (list (quoth--tool-call-alist call-plist)
                                        (plist-get call-plist :id)
                                        (quoth--tool-block-raw-result pos call-end))))
                      (flush-tools))
                  ;; Legacy or metadata-less block: emit a bare tool message
                  ;; only when it carries real result text.
                  (let ((raw (quoth--tool-block-raw-result pos call-end)))
                    (when (> (length raw) 0)
                      (flush-tools)
                      (setq messages
                            (append messages
                                    (list (list (cons 'role "tool")
                                                (cons 'tool_call_id "unknown")
                                                (cons 'content raw))))))))
                (setq pos (if call-plist call-end region-end)))
               ;; Assistant content span.
               ((eq type 'response)
                (let ((run-end (min region-end call-end)))
                  (setq pending (cons (buffer-substring-no-properties pos run-end)
                                      pending))
                  (setq pos run-end)))
               ;; Reasoning, nested tool-output, or anything else: skip.
               (t
                (setq pos (min region-end call-end)))))
            ;; A tool block ended exactly where the next span begins; guard
            ;; against a zero-length advance.
            (when (and prev (= pos prev))
              (setq pos (min end (1+ pos))))
            (setq prev pos))
          (flush-tools)
          ;; Trailing assistant content after the last tool run is a plain
          ;; answer with no tool_calls.
          (when pending
            (let ((text (string-trim (apply #'concat (nreverse pending)))))
              (when (> (length text) 0)
                (setq messages
                      (append messages
                              (list (list (cons 'role "assistant")
                                          (cons 'content text))))))))
          messages)))))

(defun quoth--install-font-lock-guard (&optional enable)
  "Protect reasoning fold properties from font-lock in the current buffer.
markdown-mode (and other modes) include `keymap' and arbitrary text
properties in `font-lock-extra-managed-props', so font-lock strips them
from the reasoning fold marker during refontification, breaking the
fold's TAB/RET toggle.  This installs a buffer-local
`font-lock-unfontify-region-function' that preserves `keymap' and
`quoth-fold-mark' when unfontifying.
ENABLE non-nil (or omitted) installs the guard.  ENABLE nil restores
the default."
  (if (called-interactively-p 'any)
      (setq enable (not (local-variable-p 'font-lock-unfontify-region-function))))
  (if enable
      (setq-local font-lock-unfontify-region-function
                  (lambda (beg end)
                    (let ((props (remove 'keymap
                                         (remove 'quoth-fold-mark
                                                 (append font-lock-extra-managed-props
                                                         '(face font-lock-multiline))))))
                      (remove-list-of-text-properties beg end props))))
    (kill-local-variable 'font-lock-unfontify-region-function)))

(defun quoth--init-session-uuid ()
  "Generate a fresh session UUID and its cached XXH3-64 hash.
Sets `quoth--session-uuid' to an opaque random string and
`quoth--session-id' to the 16-hex XXH3-64 of it.  The UUID is
buffer-local and never leaves via the network; only the hash is sent."
  (setq-local quoth--session-uuid
              (format "crs-%s-%s-%s"
                      (format-time-string "%Y%m%d%H%M%S")
                      (substring (md5 (format "%s%s" (random) (current-time))) 0 8)
                      (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))
  (setq-local quoth--session-id (quoth-xxh3-hash64 quoth--session-uuid)))

(defun quoth--init-buffer (buf)
  "Initialize BUF as a quoth buffer if not already initialized."
  (with-current-buffer buf
    (unless quoth--initialized
      ;; Establish the buffer's major mode directly (markdown-mode or
      ;; text-mode). There is no separate quoth-mode major mode.
      (funcall (symbol-function
                (if (and (memq quoth--parent-mode '(markdown-mode text-mode))
                         (fboundp quoth--parent-mode))
                    quoth--parent-mode
                  'text-mode)))
      ;; Initialize quoth state AFTER mode setup, since the mode may have
      ;; run kill-all-local-variables.
      ;; Generate prompt ID BEFORE inserting the marker.
      (setq-local quoth--prompt-id (quoth--generate-id))
      (setq-local quoth--continue nil)
      (quoth--init-session-uuid)
      (setq-local quoth--response-start nil)
      (setq-local quoth-active-provider nil)
      (setq-local quoth--prompt-start-marker nil)
      (setq-local quoth--input-start-marker nil)
      (setq-local quoth--input-ring nil)
      (setq-local quoth--input-ring-index 0)
      (setq-local quoth--tool-loop-count 0)
      (quoth-chat-mode 1)
      (quoth--install-font-lock-guard t)
      (quoth--update-header-line)
      ;; Named invisibility spec: collapsed reasoning is hidden from
      ;; display but visible to buffer-reading tools (export, preview).
      (add-to-invisibility-spec 'quoth-reasoning-fold)
      (erase-buffer)
      (quoth--insert-input-separator)
      (setq-local buffer-undo-list nil)
      (quoth--input-ring-read)
      (setq-local default-directory
                  (file-name-as-directory
                   (or quoth-working-directory
                       (when-let ((proj (project-current)))
                         (project-root proj))
                       default-directory)))
      (setq-local quoth--project-root
                  (quoth--canonical-root default-directory))
      (setq-local quoth-active-provider
                  (quoth-make-hyper-provider
                   :buffer buf
                   :working-directory default-directory
                   :base-url quoth-hyper-base-url
                   :token quoth-hyper-token
                   :model quoth-model))
      ;; Mark initialized only after mode setup so the flag is not wiped
      ;; by the parent mode (which calls kill-all-local-variables).
      (setq-local quoth--initialized t))))

(defun quoth--append-as-user-input (buf formatted)
  "Insert FORMATTED content into BUF as user input.
Appends after `quoth--input-start-marker' (or at point-max), tagging
the region `quoth-region-type' `user' with the current
`quoth--prompt-id' so it reads back as typed input.  Delegates to
`quoth--insert-at-eof' so the insertion preserves a scrolled-back
window's point like every other append."
  (with-current-buffer buf
    (let ((start (if (and quoth--input-start-marker
                          (markerp quoth--input-start-marker))
                     (marker-position quoth--input-start-marker)
                   (point-max))))
      (quoth--insert-at-eof
       (concat formatted "\n\n")
       (list 'quoth-region-type 'user
             'quoth-prompt-id quoth--prompt-id)
       start))))

(defun quoth--relative-file (file)
  "Return FILE relative to the project root or the default directory.
Resolves against `project-root' when in a project, otherwise
`default-directory'.  Returns nil when FILE is nil."
  (when file
    (file-relative-name
     file
     (or (when-let ((proj (project-current)))
           (project-root proj))
         default-directory))))

(defun quoth--format-selection (file relative-file start end)
  "Format the selection as a markdown fenced code block.
FILE is the file path, RELATIVE-FILE is its pre-resolved project-relative
path (or nil to re-resolve), START and END are the position bounds."
  (let* ((start-line (save-excursion
                       (goto-char start)
                       (line-number-at-pos)))
         (end-line (save-excursion
                     (goto-char end)
                     (line-number-at-pos)))
         (selected-text (buffer-substring-no-properties start end))
         (relative-file (or relative-file (quoth--relative-file file) "(no file)"))
         (lang (quoth--lang-from-extension (file-name-nondirectory relative-file)))
         (fence (quoth--fence-str selected-text)))
    (format "**Attachment: %s (lines %d-%d)**\n\n%s%s\n%s\n%s"
            relative-file start-line end-line fence lang selected-text fence)))

(defun quoth--reasoning-start-region ()
  "Start a reasoning region at point-max if none is active.
Creates the reasoning overlay and the start marker on the first
reasoning delta streamed for the current prompt.  Returns the
overlay.  Inert once content has started or when an active
overlay is already open."
  (unless (or quoth--reasoning-overlay
              (markerp quoth--reasoning-end))
    (let ((pos (point)))
      (setq-local quoth--reasoning-start (copy-marker pos nil))
      (setq-local quoth--reasoning-overlay
                  (make-overlay pos pos nil nil nil))
      (overlay-put quoth--reasoning-overlay 'quoth-overlay t)
      (overlay-put quoth--reasoning-overlay 'quoth-reasoning t)
      (overlay-put quoth--reasoning-overlay 'face 'quoth-reasoning-face)
      quoth--reasoning-overlay)))

(defun quoth--reasoning-extend-overlay ()
  "Extend the reasoning overlay to point-max.
Inert when no reasoning region is active or content already started."
  (when (overlayp quoth--reasoning-overlay)
    (move-overlay quoth--reasoning-overlay
                  (overlay-start quoth--reasoning-overlay)
                  (point-max))))

(defun quoth--reasoning-stop ()
  "Freeze the reasoning region, marking where the answer begins.
Sets `quoth--reasoning-end' at point-max (before the content delta
is appended), stops moving the overlay, and inserts a separator
before the answer so the content is visually separated from the
reasoning.  Inert when no reasoning is active or it already ended.
The separator is inserted at point-max, never at an arbitrary point,
so it cannot land inside a just-inserted tool block.

The overlay end is set *after* ensuring the reasoning text ends
with a newline.  This guarantees `:extend t' on `quoth-reasoning-face'
paints the last line's background to the end of the screen line, and
gives the fold's `before-string' marker a clean line-end boundary so
it starts on its own line."
  (when (and (overlayp quoth--reasoning-overlay)
             (not (markerp quoth--reasoning-end)))
    (goto-char (point-max))
    ;; Ensure the reasoning text ends with a newline so the overlay
    ;; covers a complete last line: `:extend t' needs a newline to
    ;; extend past, and the fold before-string must start on its own
    ;; line (after the overlay's trailing newline).
    (unless (eq (char-before) ?\n)
      (insert "\n"))
    (setq-local quoth--reasoning-end (copy-marker (point-max) nil))
    (move-overlay quoth--reasoning-overlay
                  (overlay-start quoth--reasoning-overlay)
                  (marker-position quoth--reasoning-end))
    ;; Insert a blank-line separator before the content delta.
    (insert "\n")))

(defvar quoth--reasoning-fold-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'quoth-reasoning-toggle)
    (define-key map (kbd "RET") #'quoth-reasoning-toggle)
    (define-key map [mouse-1] #'quoth-reasoning-toggle)
    map)
  "Keymap on the reasoning fold body overlay.
TAB / RET (and mouse-1 on GUIs, ignored harmlessly in TUI) toggle
`quoth-reasoning-toggle'.")

(defun quoth--reasoning-fold-marker (start end)
  "Return a display-only string for the fold marker.
START and END are the body overlay boundaries.  The marker shows
the hidden line and char count.  Carries the toggle keymap and the
`quoth-reasoning-face' so the marker line has the same background
color as the reasoning text.  The leading newline pushes the
marker onto its own visual line when used as an `after-string' on
the last visible position of the preview overlay."
  (let* ((lines (count-lines start end))
         (chars (- end start))
         (text (format "\n... reasoning (%d lines, %d chars)" lines chars)))
    (propertize text
                'face 'quoth-reasoning-face
                'keymap quoth--reasoning-fold-keymap)))

(defun quoth--reasoning-install-fold (region)
  "Install the reasoning fold on REGION (START . END) of current buffer.
Creates two overlays: a preview overlay (first N lines, always
visible) and a body overlay (the rest, hidden with a display-only
`before-string' marker).  No buffer text is inserted.  When the
reasoning is `quoth-reasoning-preview-lines' lines or fewer, the
original reasoning overlay stays as-is with no fold.  Returns the
body overlay, or nil."
  (let* ((start (car region))
         (end (cdr region))
         (start-m (copy-marker start))
         (end-m (copy-marker end t))
         (ov (car (cl-remove-if-not
                   (lambda (o) (overlay-get o 'quoth-overlay))
                   (overlays-in start end))))
         (preview-lines (or quoth-reasoning-preview-lines 10)))
    (when (and (overlayp ov) (> end start))
      (save-excursion
        (goto-char start-m)
        (beginning-of-line)
        (set-marker start-m (point)))
      (let ((total-lines (count-lines start-m end-m)))
        (if (<= total-lines preview-lines)
            (progn
              (overlay-put ov 'quoth-reasoning nil)
              (set-marker start-m nil)
              (set-marker end-m nil)
              nil)
          (let ((preview-end nil))
            (save-excursion
              (goto-char start-m)
              (forward-line (1- preview-lines))
              (end-of-line)
              ;; Cross the newline so preview-end is at the beginning of
              ;; the next line.  This ensures: (1) the preview overlay
              ;; includes the trailing newline so `:extend t' paints the
              ;; last preview line's background to EOL, and (2) the body
              ;; overlay (and its before-string marker) starts on its
              ;; own line instead of mid-line after the last preview text.
              (unless (eobp)
                (forward-char))
              (setq preview-end (point)))
            (let ((preview-ov (make-overlay start-m preview-end nil nil nil)))
              (overlay-put preview-ov 'quoth-overlay t)
              (overlay-put preview-ov 'quoth-reasoning-preview t)
              (overlay-put preview-ov 'face 'quoth-reasoning-face)
              (overlay-put preview-ov 'keymap quoth--reasoning-fold-keymap)
              (move-overlay ov preview-end end-m)
              (overlay-put ov 'quoth-fold-state 'collapsed)
              (overlay-put ov 'invisible 'quoth-reasoning-fold)
              (overlay-put ov 'intangible t)
              (overlay-put ov 'keymap quoth--reasoning-fold-keymap)
              (overlay-put ov 'quoth-reasoning nil)
              (overlay-put ov 'quoth-reasoning-origin
                           (marker-position start-m))
              ;; Create a separate zero-width marker overlay at the last
              ;; visible position before the body (the trailing newline of
              ;; the preview).  This overlay carries the fold marker as an
              ;; `after-string' instead of putting it on the invisible body
              ;; overlay as a `before-string'.  The key difference: the
              ;; marker overlay is at a VISIBLE position, so its
              ;; `after-string' text is tangible and `line-move-visual' can
              ;; navigate through it.  A `before-string' on the invisible
              ;; body overlay creates a visual line at an invisible+intangible
              ;; position, trapping vertical navigation with
              ;; `beginning-of-buffer' errors.
              (let ((marker-pos (1- preview-end)))
                (when (< marker-pos start-m)
                  (setq marker-pos start-m))
                (let ((marker-ov (make-overlay marker-pos marker-pos nil nil t)))
                  (overlay-put marker-ov 'quoth-overlay t)
                  (overlay-put marker-ov 'quoth-reasoning-marker t)
                  (overlay-put marker-ov 'after-string
                               (quoth--reasoning-fold-marker
                                preview-end end-m))
                  (overlay-put marker-ov 'keymap
                               quoth--reasoning-fold-keymap)))
              (set-marker start-m nil)
              (set-marker end-m nil)
              ov)))))))

(defun quoth--reasoning-marker-overlay-for (body-ov)
  "Return the marker overlay associated with BODY-OV, or nil.
The marker overlay is the zero-width overlay carrying the fold
marker as an `after-string', positioned just before the body overlay."
  (let ((body-start (overlay-start body-ov)))
    (cl-find-if
     (lambda (o)
       (and (overlay-get o 'quoth-reasoning-marker)
            (= (overlay-start o) (1- body-start))))
     (overlays-in (max (point-min) (- body-start 2))
                  (min (point-max) (+ body-start 1))))))

(defun quoth-reasoning-toggle ()
  "Toggle the reasoning fold at point.
Finds an overlay with `quoth-fold-state' at point.  If point is on
the marker overlay or the preview overlay, finds the adjacent body
overlay.  If collapsed, expands it (clear `invisible' and
`intangible').  If expanded, collapses it (re-set `invisible' and
`intangible').  If no fold overlay is at point, signals a message."
  (interactive)
  (let* ((ov (cl-find-if
              (lambda (o) (overlay-get o 'quoth-fold-state))
              (overlays-at (point))))
         (marker-ov (when (not ov)
                      (cl-find-if
                       (lambda (o) (overlay-get o 'quoth-reasoning-marker))
                       (overlays-at (point)))))
         (preview-ov (when (not ov)
                       (cl-find-if
                        (lambda (o) (overlay-get o 'quoth-reasoning-preview))
                        (overlays-at (point))))))
    (when (and marker-ov (not ov))
      (setq ov (cl-find-if
                (lambda (o)
                  (and (overlay-get o 'quoth-fold-state)
                       (= (overlay-start o) (1+ (overlay-start marker-ov)))))
                (overlays-in (point-min) (point-max)))))
    (when (and preview-ov (not ov))
      (setq ov (cl-find-if
                (lambda (o)
                  (and (overlay-get o 'quoth-fold-state)
                       (= (overlay-start o) (overlay-end preview-ov))))
                (overlays-in (point-min) (point-max)))))
    (if (not (overlayp ov))
        (message "No reasoning fold at point")
      (if (eq (overlay-get ov 'quoth-fold-state) 'collapsed)
          (quoth--reasoning-expand ov)
        (quoth--reasoning-collapse ov)))))

(defun quoth--reasoning-expand (body-ov)
  "Expand the reasoning body overlay BODY-OV.
Clears `invisible' and `intangible' so the full reasoning text is
visible.  Also hides the marker overlay's `after-string'.  No buffer
text is inserted or deleted."
  (overlay-put body-ov 'quoth-fold-state 'expanded)
  (overlay-put body-ov 'invisible nil)
  (overlay-put body-ov 'intangible nil)
  ;; Hide the marker overlay's after-string.
  (let ((marker-ov (quoth--reasoning-marker-overlay-for body-ov)))
    (when marker-ov
      (overlay-put marker-ov 'after-string nil)))
  (message "Reasoning expanded"))

(defun quoth--reasoning-collapse (body-ov)
  "Collapse the reasoning body overlay BODY-OV.
Re-sets `invisible' and `intangible' so the body is hidden.  Also
re-shows the marker overlay's `after-string'.  No buffer text is
inserted or deleted."
  (overlay-put body-ov 'quoth-fold-state 'collapsed)
  (overlay-put body-ov 'invisible 'quoth-reasoning-fold)
  (overlay-put body-ov 'intangible t)
  ;; Re-show the marker overlay's after-string.
  (let ((marker-ov (quoth--reasoning-marker-overlay-for body-ov)))
    (when marker-ov
      (overlay-put marker-ov 'after-string
                   (quoth--reasoning-fold-marker
                    (overlay-start body-ov) (overlay-end body-ov)))))
  (message "Reasoning collapsed"))

(defun quoth--reasoning-tab ()
  "Handle TAB in quoth chat buffers.
Toggles the reasoning fold when point is inside a fold body overlay,
the marker overlay, or the preview overlay; otherwise falls back to
the major mode's or global TAB binding."
  (interactive)
  (if (cl-find-if
       (lambda (o)
         (or (overlay-get o 'quoth-fold-state)
             (overlay-get o 'quoth-reasoning-marker)
             (overlay-get o 'quoth-reasoning-preview)))
       (overlays-at (point)))
      (quoth-reasoning-toggle)
    (let ((fallback (or (lookup-key (current-local-map) (kbd "TAB"))
                        (lookup-key (current-global-map) (kbd "TAB")))))
      (when (commandp fallback)
        (call-interactively fallback)))))

(defun quoth--reasoning-regions ()
  "Return the list of reasoning regions, or nil.
The active reasoning region runs from `quoth--reasoning-start' to the
answer boundary: `quoth--reasoning-end' (where a content delta froze
the CoT) when set, else the first tool block at or after the start
\(the model went straight from reasoning to a tool call), else
`point-max'.  Each tool-loop round gets its own region tracked by its
own markers; the boundary is computed relative to the start, never the
response head, so reasoning that follows an earlier round's tool
blocks is still found after `quoth--reasoning-reset'."
  (when (markerp quoth--reasoning-start)
    (let* ((pos (marker-position quoth--reasoning-start))
           (end (if (markerp quoth--reasoning-end)
                    (marker-position quoth--reasoning-end)
                  (or (cl-loop for (bs . _be) in (quoth--tool-block-bounds)
                               when (>= bs pos) return bs)
                      (point-max)))))
      (when (< pos end)
        (list (cons pos end))))))

(defun quoth--tool-block-bounds ()
  "Return the list of (START . END) tool blocks in the current buffer.
A tool block is a span tagged `quoth-region-type' `tool' (starting at
its text after the trailing newline).  Blocks run from `response-start'
to `(point-max)'; search from `(point-min)'."
  (let ((pos (point-min))
        (list nil))
    (while (setq pos (text-property-any pos (point-max)
                                        'quoth-region-type 'tool))
      (let ((end (or (next-single-property-change pos 'quoth-region-type
                                                  nil (point-max))
                     (point-max))))
        (when (> end pos)
          (setq list (cons (cons pos end) list))
          (setq pos end))))
    (nreverse list)))

(defun quoth--reasoning-reset ()
  "Reset per-prompt reasoning state after finalize or interrupt.
The overlay itself is left in place; `quoth-clear-buffer' removes
it.  Markers are invalidated."
  (when (markerp quoth--reasoning-start)
    (set-marker quoth--reasoning-start nil))
  (when (markerp quoth--reasoning-end)
    (set-marker quoth--reasoning-end nil))
  (setq-local quoth--reasoning-start nil)
  (setq-local quoth--reasoning-end nil)
  (setq-local quoth--reasoning-overlay nil))

(defun quoth--tag-response-region (response-start response-end prompt-id)
  "Tag the response and reasoning regions from RESPONSE-START to RESPONSE-END.
PROMPT-ID is applied to both regions.  Applies `quoth-prompt-id',
`quoth-response-to' and `quoth-region-type' (`response', with the
reasoning sub-span retagged `reasoning').  Shared by
`quoth--finalize-response' and `quoth-interrupt'.  Tool regions within
the response are tagged `tool' (and their nested raw-result span
`tool-output') and carry the `quoth-tool-call' property for wire
resume."
  (when (and response-start (> response-end response-start))
    ;; Tag the response span, but never overwrite existing `tool',
    ;; `tool-output', or `reasoning' regions: the tool loop tags its
    ;; blocks (and their nested raw-result spans) before this runs,
    ;; and the reasoning overlay retags its CoT span separately.
    ;; Overwriting reasoning to `response' would make history replay
    ;; send the CoT as plain assistant content and, worse, cause a
    ;; bare `tool' message (tool_call_id unknown) to be emitted for
    ;; the reasoning text.  User input inside the response range
    ;; (typed text before the stream started) is overwritten to
    ;; `response': the region spans from `quoth--response-start'
    ;; onward, past the typed input.
    (let ((pos response-start))
      (while (< pos response-end)
        (let ((type (get-text-property pos 'quoth-region-type))
              (run-end (or (next-single-property-change pos 'quoth-region-type
                                                        nil response-end)
                           response-end)))
          (if (memq type '(tool tool-output reasoning))
              (setq pos run-end)
            (put-text-property pos run-end
                               'quoth-prompt-id prompt-id)
            (put-text-property pos run-end
                               'quoth-response-to prompt-id)
            (put-text-property pos run-end
                               'quoth-region-type 'response)
            (setq pos run-end)))))
    (dolist (region (quoth--reasoning-regions))
      (let ((rs (car region))
            (re (cdr region)))
        (when (and (>= rs response-start) (<= re response-end))
          (put-text-property rs re
                             'quoth-prompt-id prompt-id)
          (put-text-property rs re
                             'quoth-response-to prompt-id)
          (put-text-property rs re
                             'quoth-region-type 'reasoning))))))

(defun quoth--close-response (response-start prompt-id)
  "Close the response started at RESPONSE-START with PROMPT-ID.
Tags the response text (including any reasoning sub-span), auto-collapses
the reasoning fold, resets reasoning state, and inserts a fresh prompt.
Runs in the quoth buffer, which owns all response text."
  (save-excursion
    (goto-char (point-max))
    (newline)
    ;; Remember where response ends (before new prompt)
    (let ((response-end (point)))
      ;; Tag the full response text with the prompt ID it answers and
      ;; region type.  Deltas were inserted with modification hooks
      ;; suppressed, so this is the only tagging the response gets.
      (quoth--tag-response-region response-start response-end prompt-id)
      ;; Auto-collapse every reasoning overlay in the response
      ;; (there may be multiple across tool-call rounds).
      ;; Use (point-min) instead of response-start because
      ;; quoth--response-start is relocated after tool blocks
      ;; in quoth--tool-loop, so the first round's
      ;; reasoning overlay would be outside the range.
      (dolist (ov (overlays-in (point-min) response-end))
        (when (and (overlay-get ov 'quoth-reasoning)
                   (not (overlay-get ov 'quoth-fold-state)))
          (quoth--reasoning-install-fold
           (cons (overlay-start ov) (overlay-end ov)))))
      (quoth--reasoning-reset))
    ;; Generate new prompt ID BEFORE inserting marker
    (setq-local quoth--prompt-id (quoth--generate-id))
    (quoth--insert-input-separator))
  ;; If the window was following the stream, advance cursor to the
  ;; new input separator so the user lands at the editable prompt.
  (when quoth--follow-p
    (let ((win (get-buffer-window (current-buffer) 'visible)))
      (goto-char (point-max))
      (when win
        (set-window-point win (point-max)))
      (setq-local quoth--last-follow-point (point-max))))
  (setq-local quoth--response-start nil)
  (setq-local quoth--tool-loop-count 0)
  (quoth--input-ring-write)
  (quoth--update-header-line)
  (setq-local buffer-undo-list nil))

(defvar-local quoth--usage-acc nil
  "Accumulated usage plist for the current session, or nil.
Shape: (:input-tokens :output-tokens :cached-tokens :cost-unit
:cost-value), each summed across all prompts and tool-loop rounds
when the provider is per-request.  Caching applies to input tokens
only, so :cached-tokens never exceeds :input-tokens.  Reset only on
`quoth-clear-buffer'.")

(defun quoth--merge-usage (acc usage)
  "Merge one round's USAGE plist into ACC, summing numeric fields.
Sums :input-tokens, :output-tokens, :cached-tokens, and :cost-value.
Preserves the :cost-unit from the first round (providers don't switch
currency mid-prompt)."
  (let ((or0 (lambda (v) (if (numberp v) v 0))))
    (list :input-tokens  (+ (funcall or0 (plist-get usage :input-tokens))
                            (or (plist-get acc :input-tokens) 0))
          :output-tokens (+ (funcall or0 (plist-get usage :output-tokens))
                            (or (plist-get acc :output-tokens) 0))
          :cached-tokens (+ (funcall or0 (plist-get usage :cached-tokens))
                            (or (plist-get acc :cached-tokens) 0))
          :cost-unit      (or (plist-get acc :cost-unit)
                              (plist-get usage :cost-unit))
          :cost-value     (+ (funcall or0 (plist-get usage :cost-value))
                             (or (plist-get acc :cost-value) 0)))))

(defun quoth--accumulate-usage ()
  "Read one round's usage from the active transport and merge into accumulator.
Accumulation is session-wide: totals sum across all prompts and tool-loop
rounds, resetting only on `quoth-clear-buffer'.  When the provider's
:accumulated is non-nil (it returns a running total), take the values
verbatim; otherwise sum into the accumulator."
  (when (and quoth-active-provider (quoth-provider-p quoth-active-provider))
    (let ((u (quoth-provider--usage
              quoth-active-provider
              (quoth-provider-transport-process quoth-active-provider))))
      (when u
        (if (plist-get u :accumulated)
            (setq-local quoth--usage-acc
                        (list :input-tokens  (plist-get u :input-tokens)
                              :output-tokens (plist-get u :output-tokens)
                              :cached-tokens (plist-get u :cached-tokens)
                              :cost-unit      (plist-get u :cost-unit)
                              :cost-value     (plist-get u :cost-value)))
          (setq-local quoth--usage-acc
                      (quoth--merge-usage quoth--usage-acc u)))))))

(defun quoth--group-number-compact (n)
  "Format integer N compactly with a k/M suffix and one decimal.
Returns `0' for nil/non-numbers.  Values below 1000 render verbatim;
1000-999999 as e.g. `9.0k'; 1000000+ as e.g. `1.0M'."
  (if (and (numberp n) (> n 0))
      (cond ((>= n 1000000) (format "%.1fM" (/ (float n) 1000000.0)))
            ((>= n 1000)    (format "%.1fk" (/ (float n) 1000.0)))
            (t              (number-to-string n)))
    "0"))

(defun quoth--usage-header-segment ()
  "Return the compact session usage string for the header, or nil.
The segment is label-free: input and output tokens (k/M, prefixed
with \u2191 and \u2193 arrows), accumulated cost (unit prefixed), and
cache percentage, joined by single spaces.  The cache percentage
divides cached by INPUT tokens only -- caching applies to the prompt
side, never to completions.  Usage is session-scoped (accumulated in
`quoth--usage-acc'), so it belongs to the buffer cluster, not the
model."
  (when quoth--usage-acc
    (let* ((input  (or (plist-get quoth--usage-acc :input-tokens) 0))
           (output (or (plist-get quoth--usage-acc :output-tokens) 0))
           (cached (plist-get quoth--usage-acc :cached-tokens))
           (unit   (plist-get quoth--usage-acc :cost-unit))
           (value  (or (plist-get quoth--usage-acc :cost-value) 0))
           (parts nil))
      (push (format "\u2191%s" (quoth--group-number-compact input)) parts)
      (push (format "\u2193%s" (quoth--group-number-compact output)) parts)
      (when unit
        (push (format "%s%s" unit
                      (if (string= unit "$")
                          (format "%.4f" value)
                        (format "%.3f" value)))
              parts))
      (when cached
        (let ((pct (if (> input 0) (round (* 100.0 (/ (float cached) (float input)))) 0)))
          (push (format "%d%%%%" pct) parts)))
      (mapconcat #'identity (nreverse parts) " "))))

(defun quoth--finalize-response ()
  "Finalize the current response.
Check for pending tool invocation from the SSE stream; when present,
drive the tool loop (execute, insert blocks, send follow-up).
Otherwise close the response and insert a fresh prompt.  The
provider's completion action invokes this."
  (quoth--accumulate-usage)
  (if (and quoth-tools-enabled
           quoth-active-provider
           (let ((tcs (quoth-provider--tool-calls
                       quoth-active-provider
                       (quoth-provider-transport-process quoth-active-provider))))
             (and (vectorp tcs) (> (length tcs) 0))))
      (quoth--tool-loop)
    (quoth--stream-transition 'done 1)
    (let ((response-start (when (markerp quoth--response-start)
                            (marker-position quoth--response-start)))
          (prompt-id quoth--prompt-id))
      (quoth--close-response response-start prompt-id))))

(defvar-local quoth--tool-loop-count 0
  "Number of tool-loop rounds executed for the current prompt.")

(defun quoth--tool-loop ()
  "Execute pending tool invocations and send a follow-up request.
Extracts tool invocations from the transport's SSE state, executes them
via `quoth-provider--tool-results', inserts tool blocks into the
buffer, then reconstructs the follow-up continuation from the buffer's
tagged regions via `quoth--tool-rounds' (no in-memory cache).  Loop up
to `quoth-tool-loop-max' rounds; when the cap is hit or no invocation
come back, finalize via `quoth--close-response'."
  (if (>= quoth--tool-loop-count quoth-tool-loop-max)
      (progn
        (setq-local quoth--tool-loop-count 0)
        (quoth--stream-transition 'done 1)
        (let ((response-start (when (markerp quoth--response-start)
                                (marker-position quoth--response-start)))
              (prompt-id quoth--prompt-id))
          (quoth--close-response response-start prompt-id)))
    (let* ((tool-calls (quoth-provider--tool-calls
                        quoth-active-provider
                        (quoth-provider-transport-process quoth-active-provider)))
           (result (quoth-provider--tool-results
                    quoth-active-provider tool-calls))
           (blocks (nth 2 result))
           (prompt-id quoth--prompt-id)
           (buf (current-buffer)))
      (setq-local quoth--tool-loop-count (1+ quoth--tool-loop-count))
      ;; Insert tool blocks before the response-start marker so they
      ;; appear as part of the current response.
      (dolist (block blocks)
        (quoth--tool-block-insert block prompt-id))
      ;; Tag the response so far (streamed content + the just-inserted
      ;; tool blocks), so `quoth--tool-rounds' can rebuild the wire
      ;; continuation from the buffer alone.
      (let ((response-start (when (markerp quoth--response-start)
                              (marker-position quoth--response-start))))
        (quoth--tag-response-region response-start (point-max) prompt-id))
      (quoth--reasoning-reset)
      ;; Reconstruct the continuation: the current prompt's user message
      ;; followed by every assistant(tool_calls)/tool exchange so far,
      ;; walking the whole response region for this prompt so prior rounds
      ;; are included.
      (let* ((user-msg (let ((text (quoth--user-turn-text prompt-id)))
                         (and text
                              (> (length text) 0)
                              (list (cons 'role "user")
                                    (cons 'content text)))))
             (continuation (append (and user-msg (list user-msg))
                                   (quoth--tool-rounds prompt-id))))
        ;; Clear the old transport and set up for the follow-up.
        (setf (quoth-provider-transport-process quoth-active-provider) nil)
        (setq-local quoth--response-start (point-marker))
        (quoth--stream-transition 'active 2)
        (let ((real-proc (quoth-provider-send-prompt
                          quoth-active-provider ""
                          :session-id quoth--session
                          :session-uuid quoth--session-uuid
                          :continue-p quoth--continue
                          :completion (lambda ()
                                        (when (buffer-live-p buf)
                                          (with-current-buffer buf
                                            (quoth--finalize-response))))
                          :on-delta (lambda (delta kind)
                                      (when (buffer-live-p buf)
                                        (with-current-buffer buf
                                          (quoth--append-delta delta kind))))
                          :on-error (lambda (message)
                                      (when (buffer-live-p buf)
                                        (with-current-buffer buf
                                          (quoth--record-error message))))
                          :buffer buf
                          :stderr (get-buffer-create "*quoth-errors*")
                          :continuation continuation)))
          (when (and real-proc (processp real-proc))
            (set-marker (process-mark real-proc) (point-max))))))))

;;; Major mode commands

(defun quoth--append-delta (delta kind)
  "Append streamed DELTA of KIND (`content' or `reasoning') to the buffer.
Insert streamed deltas at
point-max, the growing response area, and drives the reasoning overlay:
the first reasoning delta opens the region, later ones extend it, the
first content delta stops it.  `quoth--response-start' is never touched;
it stays at the response start for finalization.

Uses `quoth--insert-at-eof' for insertion, which only advances the cursor
if it was already at point-max, allowing users to scroll back while the
response streams in.  Runs in the quoth buffer (the `:on-delta'
closure enters it)."
  (save-excursion
    (goto-char (point-max))
    (pcase kind
      ('reasoning
       (quoth--reasoning-start-region)
       (quoth--reasoning-extend-overlay))
      ('content
       (quoth--reasoning-stop))))
  (quoth--insert-at-eof delta)
  (when (eq kind 'reasoning)
    (save-excursion
      (goto-char (point-max))
      (quoth--reasoning-extend-overlay))))

(defun quoth--send-prompt (prompt)
  "Send PROMPT via the active provider.
Injects completion/delta/error callbacks as the provider's completion
action so providers signal stream events without touching buffers.  Runs in
the quoth buffer, which owns all streamed output."
  (let ((buf (current-buffer)))
    (quoth--stream-transition 'active 2)
    (let ((real-proc (quoth-provider-send-prompt
                      quoth-active-provider prompt
                      :session-id quoth--session
                      :session-uuid quoth--session-uuid
                      :continue-p quoth--continue
                      :completion (lambda ()
                                    (when (buffer-live-p buf)
                                      (with-current-buffer buf
                                        (quoth--finalize-response))))
                      :on-delta (lambda (delta kind)
                                  (when (buffer-live-p buf)
                                    (with-current-buffer buf
                                      (quoth--append-delta delta kind))))
                      :on-error (lambda (message)
                                  (when (buffer-live-p buf)
                                    (with-current-buffer buf
                                      (quoth--record-error message))))
                      :buffer buf
                      :stderr (get-buffer-create "*quoth-errors*"))))
      (when (and real-proc (processp real-proc))
        (set-marker (process-mark real-proc) (point-max)))
      (setq-local quoth--continue t)
      (setq-local quoth--response-start (point-marker)))))

(defun quoth--fence-str (text)
  "Return a markdown fence string long enough to enclose TEXT.
Scan TEXT for the longest run of consecutive backtick (`` ` ``)
characters and return one more backtick than that, with a minimum
of 3 (the standard markdown fenced-code-block delimiter)."
  (let ((max-run 0)
        (run 0))
    (dotimes (i (length text))
      (if (eq (aref text i) ?\`)
          (setq run (1+ run))
        (setq max-run (max max-run run))
        (setq run 0)))
    (setq max-run (max max-run run))
    (make-string (max 3 (1+ max-run)) ?\`)))

(defconst quoth--fence-lang "text"
  "Language tag for tool-output fenced blocks.
Always `text' so tool output renders as a plain code block regardless
of what the raw result contains.")

(defun quoth--shell-language (shell-path)
  "Return the markdown fence language for SHELL-PATH.
SHELL-PATH is a shell binary path or name (nil means
`shell-file-name').  The language is derived from the shell type so the
`exec_command' `ran:' fence highlights correctly: `bash', `zsh', `sh',
`cmd', `powershell', or `shell' for an unknown POSIX-style shell."
  (let ((shell-path (or shell-path shell-file-name)))
    (pcase (quoth-process--shell-type shell-path)
      ('bash "bash")
      ('zsh "zsh")
      ('sh "sh")
      ('cmd "cmd")
      ('powershell "powershell")
      ('sh-like "shell"))))

;;; Tool-block display decoration

(defconst quoth--tool-icons
  '(("exec_command" . "🔧")
    ("write_stdin" . "⌨️")
    ("web_search" . "🔍"))
  "Alist mapping tool names to the emoji icon for their buffer header.")

(defun quoth--yield-ms->human (ms)
  "Render a millisecond duration MS as a short human string.
7500 → \"7.5s\", 60000 → \"1m\", 300 → \"300ms\".  Non-numbers pass
through unchanged."
  (if (not (numberp ms))
      ms
    (cond
     ((<= ms 0) "0ms")
     ((zerop (% ms 60000))
      (format "%dm" (/ ms 60000)))
     ((zerop (% ms 1000))
      (format "%ds" (/ ms 1000)))
     ((>= ms 1000)
      (format "%ss" (replace-regexp-in-string
                     "\\.0+\\'" ""
                     (number-to-string (/ ms 1000.0)))))
     (t (format "%dms" ms)))))

(defun quoth--tool-fenced-block (text &optional lang)
  "Return TEXT as a markdown fenced code block string.
The fence length is chosen by `quoth--fence-str' so nested backtick
runs never break the block.  TEXT is used verbatim; a trailing newline
is added when missing so the closing fence sits on its own line.  LANG
is the language identifier for the opening fence; it defaults to
`quoth--fence-lang'.  The returned string does not end in a newline:
callers own the blank-line separator, so joined sections keep exactly
one blank line."
  (let* ((fence (quoth--fence-str text))
         (lang (or lang quoth--fence-lang))
         (body (if (string-suffix-p "\n" text) text (concat text "\n"))))
    (concat fence lang "\n" body fence)))

(defun quoth--tool-login-requested-p (args)
  "Return non-nil when ARGS requests a login shell.
A pure display predicate: unlike `quoth-exec--login', it never signals
when login is disallowed by config, so the header can render
`login yes|no' without erroring on a rejected request."
  (let ((requested (plist-get args :login)))
    (and requested (not (eq requested :json-false)) t)))

(defun quoth--tool-clauses (tool args)
  "Return the display clauses for TOOL and its ARGS plist.
Return a plist `(:inline CLAUSES :blocks BLOCKS)' where CLAUSES is the
ordered list of inline scalar clauses for the header line (yield,
shell, login, session, max, categories, engines) and BLOCKS is the
ordered list of `(:label LABEL :value VALUE :fence FENCE)' plists for
argument values rendered below the header (ran, in, wrote, query).
A non-nil `:fence' forces the value into a fenced code block even when
it is single-line.  Every parameter renders, with execution-side
defaults filled in when the model omitted them, so the display shows
what the tool actually ran."
  (let ((inline nil)
        (blocks nil))
    (cond
     ((string= tool "exec_command")
      (when (stringp (plist-get args :cmd))
        (push (list :label "ran" :value (plist-get args :cmd) :fence t
                    :lang (quoth--shell-language (plist-get args :shell)))
              blocks))
      (push (list :label "in"
                  :value (or (plist-get args :workdir) default-directory))
            blocks)
      (push (format "yield %s"
                    (quoth--yield-ms->human
                     (quoth-exec--yield-ms args quoth-process-yield-ms)))
            inline)
      (push (format "shell %s" (or (plist-get args :shell) shell-file-name))
            inline)
      (push (format "login %s"
                    (if (quoth--tool-login-requested-p args) "yes" "no"))
            inline))
     ((string= tool "write_stdin")
      (when (integerp (plist-get args :session_id))
        (push (format "session %d" (plist-get args :session_id)) inline))
      (push (list :label "wrote" :value (or (plist-get args :input) ""))
            blocks)
      (push (format "yield %s"
                    (quoth--yield-ms->human
                     (quoth-exec--yield-ms args quoth-process-write-yield-ms)))
            inline))
     ((string= tool "web_search")
      (when (stringp (plist-get args :query))
        (push (list :label "query" :value (plist-get args :query)) blocks))
      (when (stringp (plist-get args :categories))
        (push (format "categories %s" (plist-get args :categories)) inline))
      (when (stringp (plist-get args :engines))
        (push (format "engines %s" (plist-get args :engines)) inline))
      (push (format "max %d" (or (plist-get args :max_results)
                                 quoth-searxng-max-results))
            inline)))
    (list :inline (nreverse inline)
          :blocks (nreverse blocks))))

(defun quoth--tool-header-line (tool args)
  "Return the single markdown header line for TOOL and its ARGS plist.
The line is bold icon + tool name, then a plain-text summary of the
scalar clauses (no inline emphasis, comma-separated), e.g.
\"**🔧 exec_command** — yield 10s, shell /bin/bash, login no\".
Free-text argument values (cmd, workdir, input, query) are rendered
below the header as `LABEL: VALUE' lines, or as fenced code blocks when
they span multiple lines, so multiline values stay valid markdown.  The
tool-call id is deliberately not shown: it is display noise, and wire
resume reads it from the `quoth-tool-call' text property."
  (let* ((icon (or (cdr (assoc tool quoth--tool-icons)) "🛠️"))
         (name (if (string= tool "write_stdin") "write_stdin" tool))
         (clauses (plist-get (quoth--tool-clauses tool args) :inline))
         (summary (when clauses
                    (format " — %s" (mapconcat #'identity clauses ", ")))))
    (format "**%s %s**%s" icon name (or summary ""))))

(defun quoth--tool-arg-blocks (tool args)
  "Return the below-header argument lines for TOOL and its ARGS plist.
Each argument value renders as a `LABEL: VALUE' line when the value is
single-line (no embedded newline), and as a `LABEL:' line followed by a
fenced code block when it spans multiple lines or carries a non-nil
`:fence' flag.  Rendered lines are separated by blank lines.  Returns
nil when there are no argument blocks."
  (let ((blocks (plist-get (quoth--tool-clauses tool args) :blocks)))
    (when blocks
      (mapconcat
       (lambda (block)
         (let ((label (plist-get block :label))
               (value (plist-get block :value))
               (fence-p (plist-get block :fence))
               (lang (plist-get block :lang)))
           (if (or fence-p (string-match-p "\n" value))
               (format "%s:\n\n%s" label
                       (quoth--tool-fenced-block value lang))
             (format "%s: %s" label value))))
       blocks
       "\n\n"))))

(defun quoth--ensure-blank-line ()
  "Ensure the text before point is separated from what follows by one blank line.
At point, count trailing newlines and insert the minimum number needed to
leave exactly two newlines (one blank line) before the next insertion.
Existing whitespace is never removed, and a point at `point-min' is left
untouched."
  (unless (bobp)
    (let ((newlines 0))
      (save-excursion
        (while (and (> (point) (point-min))
                    (eq (char-before) ?\n))
          (backward-char)
          (setq newlines (1+ newlines))))
      (when (< newlines 2)
        (insert (make-string (- 2 newlines) ?\n))))))

(defun quoth--tool-block-insert (tool-calls prompt-id)
  "Insert a tool-call block for TOOL-CALLS into the buffer.
TOOL-CALLS is a plist of :name :id :args-json :result :exit.
PROMPT-ID is the current prompt's ID.  The block is
tagged `quoth-region-type' `tool' with `quoth-prompt-id' /
`quoth-response-to', and carries the `quoth-tool-call' property
for wire resume.  Returns the end position of the inserted block."
  ;; When reasoning was streamed but no content delta ever arrived
  ;; (the model went straight to tool calls), the reasoning text
  ;; is still active and lacks a trailing newline.  Stop reasoning
  ;; now so the tool block is visually separated from the reasoning
  ;; and the reasoning region boundaries are correct.
  ;; Wrap in `save-excursion' so `quoth--reasoning-stop`'s internal
  ;; `goto-char (point-max)` does not yank the user's cursor.
  (save-excursion (quoth--reasoning-stop))
  (let* ((name (plist-get tool-calls :name))
         (id (plist-get tool-calls :id))
         (args (or (and (stringp (plist-get tool-calls :args-json))
                        (quoth-openai-parse-tool-args
                         (plist-get tool-calls :args-json)))
                   (list)))
         (result (plist-get tool-calls :result))
         ;; A model often ends its trailing sentence with no newline
         ;; before emitting a tool call; make sure the header starts on
         ;; its own line with one blank line of separation so the block
         ;; stays valid markdown (buffer, HTML, and PDF alike).
         (prefix (unless (bobp)
                   (let ((n 0))
                     (save-excursion
                       (goto-char (point-max))
                       (while (and (> (point) (point-min))
                                   (eq (char-before) ?\n))
                         (backward-char)
                         (setq n (1+ n))))
                     (when (< n 2)
                       (make-string (- 2 n) ?\n)))))
         (header (quoth--tool-header-line name args))
         (arg-blocks (quoth--tool-arg-blocks name args))
         (raw (when result
                (concat result (unless (string-suffix-p "\n" result) "\n"))))
         (output-fence (when result (quoth--fence-str result)))
         (output-block (when result
                         (concat output-fence quoth--fence-lang "\n"
                                 raw output-fence)))
         ;; Assemble the block: prefix, header line, then argument
         ;; blocks (if any), then the output fence (if any).  Each
         ;; section is separated by a blank line.  Track the offset of
         ;; the output block within the body so the raw-result region
         ;; can be tagged without fragile per-field length arithmetic.
         (segments (delq nil
                         (list (when arg-blocks arg-blocks)
                               (when output-block output-block))))
         (output-offset
          (when output-block
            (let ((offset (length header)))
              (setq offset (+ offset 2)) ; header + "\n\n"
              (when arg-blocks
                (setq offset (+ offset (length arg-blocks) 2))) ; + "\n\n"
              offset)))
         (body (if segments
                   (concat header "\n\n"
                           (mapconcat #'identity segments "\n\n")
                           "\n\n")
                 (concat header "\n\n")))
         (block (concat prefix body))
         (start (point-max)))
    (quoth--insert-at-eof block)
    (let* ((end (point-max))
           ;; The raw tool result (wire `role: "tool"' content) sits
           ;; between the output fence's opening line and the closing
           ;; fence.  Its offset is prefix + output-offset + the
           ;; opening fence line length.
           (raw-start
            (when output-block
              (+ start (length prefix) output-offset
                 (length output-fence) (length quoth--fence-lang) 1)))
           (raw-end (when raw-start (+ raw-start (length raw)))))
      (put-text-property start end 'quoth-region-type 'tool)
      (put-text-property start end 'quoth-prompt-id prompt-id)
      (put-text-property start end 'quoth-response-to prompt-id)
      ;; Tag the whole block (including the closing fence) so the
      ;; wire-reconstruction walk in `quoth--tool-rounds' treats it as
      ;; one call span.  A trailing fence char left without the call
      ;; property is itself `tool'-typed and, having no metadata, makes
      ;; the walker fall into the legacy branch, whose raw-result bound
      ;; (the next `quoth-tool-call' change) extends to the end of the
      ;; response and swallows every following turn as a bare `tool'
      ;; message with `tool_call_id: unknown'.
      (put-text-property start end 'quoth-tool-call
                         (list :id id
                               :name name
                               :args-json (plist-get tool-calls :args-json)))
      ;; Nested region: the raw tool result (the wire `role: "tool"`
      ;; content) sits between the output label's opening fence and the
      ;; closing fence.  Tag it separately so history extraction can
      ;; send the raw result without the display decoration.  Carries
      ;; the same prompt/response tags so it survives re-tagging and
      ;; persistence.
      (when raw-start
        (put-text-property raw-start raw-end 'quoth-region-type 'tool-output)
        (put-text-property raw-start raw-end 'quoth-prompt-id prompt-id)
        (put-text-property raw-start raw-end 'quoth-response-to prompt-id))
      end)))

(defun quoth-send-input ()
  "Send the current prompt to the provider."
  (interactive)
  (when (and quoth-active-provider
             (quoth-provider-p quoth-active-provider)
             (quoth-provider-active-p quoth-active-provider))
    (user-error "Quoth is still running; interrupt with C-c c i"))
  (let* ((input-start (or (when (and quoth--input-start-marker
                                     (markerp quoth--input-start-marker))
                            (marker-position quoth--input-start-marker))
                          (point-min)))
         (input (buffer-substring-no-properties
                 input-start (point-max)))
         (prompt (string-trim input)))
    (when (string-empty-p prompt)
      (user-error "No prompt to send"))
    (quoth--input-ring-add prompt)
    ;; Explicitly tag the user input region as `user' so history
    ;; extraction (quoth--user-turn-text) can find it.  There is no
    ;; after-change hook; tagging happens here, at send time, so yank,
    ;; undo, and other non-interactive paths are all covered.
    (put-text-property input-start (point-max)
                       'quoth-region-type 'user)
    (put-text-property input-start (point-max)
                       'quoth-prompt-id quoth--prompt-id)
    (goto-char (point-max))
    (newline)
    ;; Draw a horizontal divider after the user turn so the response is
    ;; visually decoupled from the prompt text; the response region and
    ;; reasoning overlay begin after it.
    (quoth--insert-user-separator)
    (setq-local quoth--response-start (point-marker))
    (setq-local quoth--input-ring-index 0)
    (setq-local quoth--tool-loop-count 0)
    (setq-local quoth--follow-p t)
    (setq-local quoth--last-follow-point (point-max))
    (quoth--send-prompt prompt)))

(defun quoth-interrupt ()
  "Interrupt the active provider's in-flight request.
Dispatches through `quoth-provider-interrupt' so the provider owns its
transport process.  The partial response is tagged and a fresh
input divider inserted, mirroring normal finalization."
  (interactive)
  (let ((active (and quoth-active-provider
                     (quoth-provider-p quoth-active-provider)
                     (quoth-provider-active-p quoth-active-provider))))
    (if (not active)
        (message "No quoth process running")
      (quoth-provider-interrupt quoth-active-provider)
      (save-excursion
        (goto-char (point-max))
        (newline)
        ;; Tag the partial response (including any streamed reasoning)
        ;; up to the interrupt point, and auto-collapse the reasoning.
        (let ((response-start (when (markerp quoth--response-start)
                                (marker-position quoth--response-start))))
          (quoth--tag-response-region response-start (point) quoth--prompt-id)
          (dolist (ov (overlays-in (or response-start (point-min)) (point)))
            (when (and (overlay-get ov 'quoth-reasoning)
                       (not (overlay-get ov 'quoth-fold-state)))
              (quoth--reasoning-install-fold
               (cons (overlay-start ov) (overlay-end ov)))))
          (quoth--reasoning-reset))
        ;; Generate a fresh pending ID before the new marker, exactly
        ;; like `quoth--close-response'.
        (setq-local quoth--prompt-id (quoth--generate-id))
        (quoth--insert-input-separator))
      (when quoth--follow-p
        (let ((win (get-buffer-window (current-buffer) 'visible)))
          (goto-char (point-max))
          (when win
            (set-window-point win (point-max)))
          (setq-local quoth--last-follow-point (point-max))))
      (setq-local quoth--response-start nil)
      (setq-local quoth--tool-loop-count 0)
      (quoth--stream-transition 'done 1)
      (setq-local buffer-undo-list nil)
      (message "Quoth process interrupted"))))

(defun quoth-clear-buffer ()
  "Clear the Quoth buffer output and start a fresh session.
Also rotates the buffer's session UUID, so the next prompt gets a
cold hyperscale cache (new x-session-id / x-session-affinity)."
  (interactive)
  (setq-local quoth--continue nil)
  (setq-local quoth--follow-p nil)
  (setq-local quoth--last-follow-point 0)
  (setq-local quoth-openai--cached-system-prompt nil)
  (setq-local quoth-openai--cache-key nil)
  (quoth--init-session-uuid)
  (quoth--stream-clear)
  ;; Kill any in-flight provider transport before clearing.
  (when (and quoth-active-provider
             (quoth-provider-p quoth-active-provider))
    (quoth-provider-cleanup quoth-active-provider))
  ;; Kill any live process sessions this buffer owns.
  (quoth-process--cleanup-buffer (current-buffer))
  ;; Delete all quoth-overlay tagged overlays
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'quoth-overlay)
      (delete-overlay ov)))
  (quoth--reasoning-reset)
  (setq-local quoth--usage-acc nil)
  (erase-buffer)
  (quoth--insert-input-separator)
  (setq-local buffer-undo-list nil))

(defun quoth-select-model ()
  "Select a model from the Hyper gateway's catalog.
Fetches the live model catalog from `quoth-hyper-base-url'/provider
\(sync) and prompts for a choice; picking a model sets the global
`quoth-model' and the current buffer's provider model slot, so the
header line updates immediately and future buffers use the choice.
Choosing the `default' entry clears the selection back to
`quoth-openai-default-model'.  When the catalog fetch fails, offers a
small fallback list so selection still works offline."
  (interactive)
  (let* ((base-url (or (getenv "HYPER_URL")
                       (and (quoth-hyper-provider-p quoth-active-provider)
                            (quoth-hyper-provider-base-url quoth-active-provider))
                       quoth-hyper-base-url))
         (fetched (quoth-hyper--fetch-models base-url
                                             quoth-hyper-token))
         (catalog (car fetched))
         (choices (if catalog
                      (quoth-hyper--model-choices catalog)
                    (list (cons quoth-openai-default-model
                                (format "%s (default)" quoth-openai-default-model))
                          (cons "qwen3.7-plus" "qwen3.7-plus")
                          (cons "deepseek-v4-flash" "deepseek-v4-flash"))))
         (choice (completing-read
                  "Model: "
                  (cons (cons "default" "default (provider default)")
                        choices)
                  nil t nil)))
    (if (string= choice "default")
        (progn
          (setq quoth-model nil)
          (when (quoth-hyper-provider-p quoth-active-provider)
            (setf (quoth-hyper-provider-model quoth-active-provider) nil)))
      (setq quoth-model choice)
      (when (quoth-hyper-provider-p quoth-active-provider)
        (setf (quoth-hyper-provider-model quoth-active-provider) choice)))
    (quoth--update-header-line)
    (message "Model: %s"
             (or (and (not (string= choice "default")) choice)
                 quoth-openai-default-model))))

;;; Minor mode commands

(defun quoth-insert-selection (beg end)
  "Insert the current buffer selection into the Quoth buffer.
BEG and END are the bounds of the selection."
  (interactive "r")
  (let* ((file (buffer-file-name))
         (relative (quoth--relative-file file))
         (formatted (quoth--format-selection file relative beg end))
         (buf (quoth--current-quoth-buffer)))
    (with-current-buffer buf
      (quoth--append-as-user-input buf formatted)
      (quoth--update-header-line))
    (switch-to-buffer-other-window buf)))

(defun quoth-insert-buffer ()
  "Insert the entire current buffer into the Quoth buffer as context."
  (interactive)
  (quoth-insert-selection (point-min) (point-max)))

(defun quoth-insert-filepath ()
  "Insert the current buffer's file path into the Quoth buffer as context."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Current buffer has no file"))
    (let* ((relative-file (quoth--relative-file file))
           (formatted (if relative-file
                          (format "[%s](%s)" relative-file relative-file)
                        ""))
           (buf (quoth--current-quoth-buffer)))
      (with-current-buffer buf
        (quoth--append-as-user-input buf formatted)
        (quoth--update-header-line))
      (switch-to-buffer-other-window buf))))

;;; Entry point

;;;###autoload
(defun quoth ()
  "Start an interactive Quoth session.
Creates a buffer if none exists, switches to it, and prepares it for input."
  (interactive)
  (let ((buf (quoth--current-quoth-buffer)))
    (switch-to-buffer-other-window buf)))

;;; Minor mode

(defvar quoth-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-s") #'quoth-insert-selection)
    (define-key map (kbd "C-c C-b") #'quoth-insert-buffer)
    (define-key map (kbd "C-c C-p") #'quoth-insert-filepath)
    (define-key map (kbd "C-c C-c") #'quoth)
    map)
  "Keymap for `quoth-minor-mode'.")

;;;###autoload
(define-minor-mode quoth-minor-mode
  "Minor mode for sending buffer content to the quoth provider.

When enabled, provides keybindings under the `C-c C-' prefix for
sending selections, whole buffers, and file paths to the Quoth
interaction buffer.

\\{quoth-minor-mode-map}"
  :lighter " Quoth"
  :group 'quoth
  :keymap quoth-minor-mode-map)

(provide 'quoth)
;;; quoth.el ends here
