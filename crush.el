;;; crush.el --- Chat with AI providers from GNU Emacs  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/crush.el
;;; Version: 0.1.0
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience
;;; Prefix: crush-

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

;; crush.el is a GNU Emacs package for direct provider interaction: a
;; dedicated interactive buffer that sends structured prompts to AI
;; models over HTTP and receives streamed responses.  The backend talks
;; to the Charm Hyper gateway (https://hyper.charm.land) via streaming
;; chat completions.
;;
;; In addition to the dedicated chat buffer, any buffer selection can
;; be used as context.  The selection is formatted as a markdown fenced
;; code block with the file path and line numbers, then inserted
;; into the crush buffer where the user can add additional context
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

(defgroup crush nil
  "Chat with AI providers from GNU Emacs."
  :group 'tools
  :prefix "crush-")

(defface crush-prompt-face
  '((t :inherit font-lock-keyword-face))
  "Face for the crush> prompt marker."
  :group 'crush)

(defface crush-reasoning-face
  '((t :inherit region :extend t))
  "Face for streamed chain-of-thought reasoning text.
Applied via an overlay (not a text property) so markdown-mode
refontification cannot strip it.  Inherits the theme's `region'
background, a neutral dark tint that leaves markdown's text colors
visible on top.  `:extend t' paints the background across the full
window width on every line the reasoning covers."
  :group 'crush)

(defcustom crush-model nil
  "Model to use for Crush requests.
When nil, the backend falls back to `crush-openai-default-model'.  The
facade passes this into the backend's model slot at buffer
initialization.  Should be a model name like
`claude-sonnet-4-20250514' or `gpt-4o'."
  :type '(choice (const nil) string)
  :group 'crush)

;;; Buffer-local state

;;; `crush--continue', `crush--session-uuid', `crush--session-id',
;;; `crush--response-start', `crush--pending-context', and
;;; `crush-process' are the shared buffer-local state owned by the
;;; facade (defined below); backends must not touch them.

(defcustom crush-reasoning-preview-lines 10
  "Number of reasoning lines to show in the collapsed preview.
When a reasoning region contains more than this many lines, the first
N lines are shown as a preview and the rest are hidden behind a `…'
ellipsis toggle.  Set to 0 to always collapse with no preview.
Must be a non-negative integer."
  :type 'integer
  :group 'crush)

(defcustom crush-hyper-history-limit 200
  "Maximum number of prior prompts sent as history by the hyper backend.
0 disables history entirely (each prompt is a single request).  Only
the last LIMIT complete exchanges are sent; the current turn is always
sent in full."
  :type 'integer
  :group 'crush)

(defcustom crush--continue nil
  "Whether the next prompt continues the conversation session.
When non-nil, the next prompt continues the active session.
Set to nil by `crush-clear-buffer' so the next prompt starts a fresh
session.
Buffer-local."
  :type 'boolean
  :group 'crush)

(defcustom crush-working-directory nil
  "Working directory for the crush provider.
When nil, uses the project root if `project-current' is non-nil,
otherwise `default-directory'."
  :type '(choice (const nil) directory)
  :group 'crush)

(defcustom crush-input-ring-size 32
  "Maximum number of prompts stored in the input ring."
  :type 'integer
  :group 'crush)

(defcustom crush-debug-mode t
  "When non-nil, log commands, input, and output to a *crush-debug* buffer."
  :type 'boolean
  :group 'crush)

(defcustom crush--session nil
  "Session ID to pass to the provider.
When non-nil, continues a specific session by ID.
Takes precedence over `crush--continue'.
Buffer-local."
  :type '(choice (const nil) string)
  :group 'crush)

(defvar-local crush--session-uuid nil
  "Opaque UUID identifying this crush buffer's session.
Generated in `crush--init-buffer' and rotated by `crush-clear-buffer'.
The hyper backend hashes it (XXH3-64) for the x-session-id /
x-session-affinity cache-affinity headers; the raw UUID is never sent
to the network.  Persistence (as a file-local) is Phase 2 roadmap work.
Buffer-local.")

(defvar-local crush--session-id nil
  "The 16-hex XXH3-64 of `crush--session-uuid'.
Computed lazily by the hyper backend on request; kept here so the hash
is stable for the session's life, and to trace as `SESS' in the debug
log.  Buffer-local.")

(defvar crush--response-start nil
  "Marker for where response text starts.
Set when prompt is sent, used by sentinel to tag response text.
Buffer-local.")

(defvar crush--pending-context nil
  "Context text stashed for stdin delivery.
Buffer-local.")

(defvar crush-process nil
  "The currently running Crush process, if any.
Buffer-local.")

(defvar-local crush--tool-continuation nil
  "Continuation messages for an in-flight tool loop, or nil.
A list of structured message alists (assistant with `tool_calls'
followed by `role: \"tool\"' messages) appended to the request
history when the tool loop sends a follow-up.  Reset to nil when
the tool loop finishes or the buffer is cleared.")

;;; The facade stream protocol (state, progress, error pane) lives in
;;; `crush-stream.el'; crush.el requires and transitions it.

(defvar crush--prompt-id nil
  "Unique ID for the current pending prompt.
Generated when prompt marker is created, used when prompt is sent.
Buffer-local.")

(defvar crush--initialized nil
  "Non-nil once a crush buffer has been initialized.
Used to make `crush--init-buffer' idempotent regardless of the active
parent mode (which may be `markdown-mode' or `text-mode').
Buffer-local.")

(defvar crush--attachments nil
  "List of attachments for current pending prompt.
Each attachment is a plist: (:id <uuid> :prompt-id <uuid> :content <string>).
Buffer-local.")

(defvar crush--prompt-start-marker nil
  "Marker at the start of the `crush> ' prompt text.
Buffer-local.")

(defvar crush--reasoning-start nil
  "Marker at the start of the current reasoning region, or nil.
Set by the hyper backend on the first reasoning delta streamed for
the current prompt.  Buffer-local.")

(defvar crush--reasoning-end nil
  "Marker at the end of the reasoning region, or nil.
Set on the first content delta (reasoning stops where the answer
begins).  Buffer-local.")

(defvar crush--reasoning-overlay nil
  "Overlay highlighting the current reasoning region, or nil.
Carries `crush-reasoning-face' and the `crush-overlay' property so
`crush-clear-buffer' removes it.  Buffer-local.")

(defvar crush--input-start-marker nil
  "Marker at the start of user input area (after prompt text).
Buffer-local.")

(defvar crush--project-root nil
  "Canonical project root (or `default-directory') this buffer serves.
Set at initialization; determines the buffer name and the working
directory for the crush provider.  Buffer-local.")

(defvar crush--input-ring nil
  "Ring of previously entered prompts.
Buffer-local.")

(defvar crush--input-ring-index 0
  "Position in `crush--input-ring' for previously-entered inputs.
Navigated with `crush--input-previous' / `crush--input-next'.
Buffer-local.")

(defvar crush--input-ring-file-name
  (expand-file-name "crush-history" user-emacs-directory)
  "File where input history is persisted.")

;;; Backend abstraction

;;; The `crush-provider' base struct and the `crush-provider-*' protocol
;;; live in `crush-provider.el'; the reusable OpenAI client in
;;; `crush-openai.el'; the concrete provider in `crush-hyper-provider.el'
;;; (direct HTTP to the Charm Hyper gateway).
;;; The dependency files sit next to this file but are not guaranteed to
;;; be on `load-path': package.el adds the package dir, while direct
;;; `load' or flycheck's batch byte-compile do not.  Try `require'
;;; first, then fall back to loading from this file's own directory so
;;; both setups work.
(eval-and-compile
  (dolist (dep '("crush-provider" "crush-openai" "crush-xxh3" "crush-stream"
                 "crush-hyper-provider" "crush-tools"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              ;; In a flycheck byte-compile child the source path lives in
              ;; `buffer-file-name'; under `load' it is `load-file-name'.
              ;; `default-directory' is a last resort for eval-buffer.
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defvar crush-active-provider nil
  "The active crush backend for this buffer (facade-owned).
Set during buffer initialization; the facade's `crush-facade--send'
and `crush-interrupt' dispatch through it.  Buffer-local.")
(declare-function markdown-mode "markdown-mode" ())
(declare-function crush-xxh3-hash64 "crush-xxh3" (input))
(declare-function crush-provider--tool-calls "crush-provider" (backend process))
(declare-function crush-provider--tool-results "crush-provider" (backend tool-calls))

;;; Buffer naming

(defvar crush--root-buffer-alist nil
  "Alist mapping canonical project root directories to crush buffer names.
Each entry is (ROOT . NAME) where ROOT is an absolute directory path
with a trailing slash.  Entries survive buffer kills so that re-opening
a root keeps its original buffer name, including any collision suffix.")

(defun crush--canonical-root (root)
  "Return ROOT as a canonical absolute directory path with trailing slash."
  (file-name-as-directory (expand-file-name root)))

(defun crush--buffer-name-for-root (root)
  "Return a stable, unique crush buffer name for project/directory ROOT.
The name is based on the basename of ROOT, e.g. \"*crush:foo*\".  When
another distinct root already resolved to that name, an incrementing
suffix is appended: \"*crush:foo(2)*\", \"*crush:foo(3)*\", and so on.
The mapping is recorded in `crush--root-buffer-alist' so the same ROOT
always resolves to the same name."
  (let* ((canonical (crush--canonical-root root))
         (existing (cdr (assoc canonical crush--root-buffer-alist))))
    (if existing
        existing
      (let* ((base (file-name-nondirectory
                    (directory-file-name canonical)))
             (base (if (string-empty-p base) "root" base))
             (name (format "*crush:%s*" base))
             (counter 2))
        (while (member name (mapcar #'cdr crush--root-buffer-alist))
          (setq name (format "*crush:%s(%d)*" base counter))
          (setq counter (1+ counter)))
        (push (cons canonical name) crush--root-buffer-alist)
        name))))

(defun crush--current-root ()
  "Return the canonical project root for the current buffer, if any.
Returns the `project-root' when the current buffer is inside a project,
otherwise `default-directory'.  Both as canonical directory paths."
  (let ((proj (project-current)))
    (crush--canonical-root
     (or (when proj (project-root proj))
         default-directory))))

(defun crush--current-crush-buffer ()
  "Return the crush buffer associated with the current context.
The root is the project root when in a project, otherwise
`default-directory'.  Creates and initializes the buffer if needed."
  (let* ((root (crush--current-root))
         (name (crush--buffer-name-for-root root))
         (buf (get-buffer-create name)))
    (crush--init-buffer buf)
    buf))

;;; Major mode

(defvar crush--parent-mode
  (if (require 'markdown-mode nil t)
      'markdown-mode
    'text-mode)
  "Parent mode for the crush buffer.
Uses `markdown-mode' if available, otherwise `text-mode'.")

;;; Chat minor mode

(defvar crush-chat-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'crush-send-input)
    (define-key map (kbd "i") #'crush-interrupt)
    (define-key map (kbd "k") #'crush-clear-buffer)
    (define-key map (kbd "a") #'crush-insert-selection)
    (define-key map (kbd "r") #'crush-reasoning-toggle)
    map)
  "Keymap under `C-c c' for crush chat-buffer commands.")

(defvar crush-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'crush-send-input)
    (define-key map (kbd "TAB") #'crush--reasoning-tab)
    (define-key map (kbd "C-c c") crush-chat-command-map)
    (define-key map (kbd "M-p") #'crush--input-previous)
    (define-key map (kbd "M-n") #'crush--input-next)
    map)
  "Keymap for `crush-chat-mode'.")

(define-minor-mode crush-chat-mode
  "Minor mode for interactive Crush chat in a buffer.

When enabled, provides keybindings for sending prompts,
interrupting, clearing, and session management.

\\{crush-chat-mode-map}"
  :lighter " Chat"
  :group 'crush
  :keymap crush-chat-mode-map
  (if crush-chat-mode
      (progn
        (add-hook 'after-change-functions #'crush--after-change nil t)
        (add-hook 'post-command-hook #'crush--update-header-line nil t)
        (add-hook 'post-command-hook #'crush--reassert-read-only-boundaries nil t))
    (remove-hook 'after-change-functions #'crush--after-change t)
    (remove-hook 'post-command-hook #'crush--update-header-line t)
    (remove-hook 'post-command-hook #'crush--reassert-read-only-boundaries t)))

;;; Internal helpers

(defun crush--debug-log (category message)
  "Log MESSAGE with CATEGORY to *crush-debug* buffer.
Only logs when `crush-debug-mode' is non-nil."
  (when crush-debug-mode
    (with-current-buffer (get-buffer-create "*crush-debug*")
      (goto-char (point-max))
      (let ((inhibit-read-only t))
        (insert (format "[%s] %s: %s\n"
                        (format-time-string "%H:%M:%S")
                        category message))))))

(defun crush--generate-id ()
  "Generate a unique ID for prompt and attachment IDs."
  (format "%s-%s"
          (format-time-string "%Y%m%d-%H%M%S")
          (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))

(defun crush--input-ring-read ()
  "Read input history from `crush--input-ring-file-name'."
  (setq crush--input-ring (make-ring crush-input-ring-size))
  (when (file-readable-p crush--input-ring-file-name)
    (let ((lines nil))
      (with-temp-buffer
        (insert-file-contents crush--input-ring-file-name)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p line)
              (push line lines))
            (forward-line 1))))
      (dolist (line (nreverse lines))
        (ring-insert crush--input-ring line)))))

(defun crush--input-ring-write ()
  "Write input history to `crush--input-ring-file-name'."
  (when (and crush--input-ring (ring-p crush--input-ring))
    (let ((ring crush--input-ring)
          (file crush--input-ring-file-name))
      (with-temp-buffer
        (dotimes (i (ring-length ring))
          (insert (ring-ref ring i) "\n"))
        (write-region (point-min) (point-max) file nil 'quiet)))))

(defun crush--input-ring-add (input)
  "Add INPUT to the input ring, skipping duplicates."
  (when (and crush--input-ring (ring-p crush--input-ring)
             (not (string-empty-p input)))
    (unless (and (> (ring-length crush--input-ring) 0)
                 (string= input (ring-ref crush--input-ring 0)))
      (ring-insert crush--input-ring input))))

(defun crush--input-previous ()
  "Insert the previous input from the input ring."
  (interactive)
  (when (and crush--input-ring (ring-p crush--input-ring)
             (> (ring-length crush--input-ring) 0))
    (let ((input-start (marker-position crush--input-start-marker)))
      (when input-start
        (delete-region input-start (line-end-position))
        (goto-char input-start)
        (insert (ring-ref crush--input-ring crush--input-ring-index))
        (setq-local crush--input-ring-index
                    (min (1+ crush--input-ring-index)
                         (1- (ring-length crush--input-ring))))))))

(defun crush--input-next ()
  "Insert the next input from the input ring."
  (interactive)
  (when (and crush--input-ring (ring-p crush--input-ring)
             (> (ring-length crush--input-ring) 0))
    (let ((input-start (marker-position crush--input-start-marker)))
      (when input-start
        (delete-region input-start (line-end-position))
        (goto-char input-start)
        (if (<= crush--input-ring-index 0)
            (setq-local crush--input-ring-index 0)
          (setq-local crush--input-ring-index (1- crush--input-ring-index))
          (insert (ring-ref crush--input-ring crush--input-ring-index)))))))

(defun crush--header-model ()
  "Return the effective model name for the header line, or nil.
Reads the backend's model slot (derived from `crush-model' at buffer
init); falls back to `crush-openai-default-model' for hyper backends."
  (let ((model (and (crush-hyper-provider-p crush-active-provider)
                    (crush-hyper-provider-model crush-active-provider))))
    (or model
        (and (crush-hyper-provider-p crush-active-provider)
             crush-openai-default-model))))

(defun crush--region-label-at-point ()
  "Return a human label for the `crush-region-type' at point.
Any region type symbol maps to its name, so new region types (e.g. the
nested `tool-output' span) label themselves without a static list.
When no region type is set, falls back to `prompt' on prompt/input
text and `plain' elsewhere."
  (let ((type (get-text-property (point) 'crush-region-type)))
    (if (and type (symbolp type))
        (symbol-name type)
      (if (crush-get-prompt-at-point) "prompt" "plain"))))

(defun crush--update-header-line ()
  "Update header line with the current model and region type at point."
  (let* ((model (crush--header-model))
         (region (crush--region-label-at-point))
         (model-str (if model (format "model: %s" model) "model: -"))
         (region-str (format "region: %s" region)))
    (setq header-line-format
          (list (propertize (format "%s   %s" model-str region-str)
                            'face 'bold)))))

(defun crush--after-change (beg end _len)
  "Tag inserted text with prompt ID if at or after the prompt marker.
BEG and END are standard after-change hook arguments."
  (when (and crush--prompt-start-marker
             (markerp crush--prompt-start-marker)
             (>= beg (marker-position crush--prompt-start-marker)))
    (put-text-property beg end 'crush-prompt-id crush--prompt-id))
  (crush--update-header-line))

(defun crush--lang-from-extension (filename)
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

(defun crush--freeze-region (start end)
  "Make the region from START to END read-only via text properties.
The `read-only' property blocks both insertion into and deletion of the
covered text.  `front-sticky' and `rear-nonsticky' keep the freeze from
leaking: text typed just before the region stays read-only, and text typed
just after it stays editable.  `rear-nonsticky' must stay on the last
read-only char, otherwise inserting right after it fails with
\"Text is read-only\" because the new text inherits `read-only'.
`crush--install-font-lock-guard' keeps `rear-nonsticky' intact across
font-lock refontification.
Modification hooks are suppressed while applying so other buffer
metadata (like prompt IDs) is not re-tagged by `crush--after-change'."
  (when (> end start)
    (let ((inhibit-modification-hooks t))
      (add-text-properties
       start end
       '(read-only t
                   front-sticky (read-only)
                   rear-nonsticky (read-only))))))

(defun crush--reassert-read-only-boundaries (&rest _)
  "Re-assert `rear-nonsticky' on all read-only text.
font-lock (e.g. markdown-mode) includes `rear-nonsticky' in its managed
properties and strips it whenever it writes `font-lock-face' over a
region.  Without `rear-nonsticky', text typed just after a read-only char
inherits `read-only' and Emacs refuses the insertion (\"Text is
read-only\").  This restores the boundary on every read-only position.
Runs in `post-command-hook' so any `rear-nonsticky' stripped by a
completed command (including font-lock refontification) is restored
before the next user input.
Accepts optional hook arguments so it can also be used as a change hook."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (pos (point-min)))
    (while (< pos (point-max))
      (when (get-text-property pos 'read-only)
        (add-text-properties
         pos (1+ pos)
         '(rear-nonsticky (read-only font-lock-face))))
      (setq pos (or (next-single-property-change pos 'read-only nil (point-max))
                    (point-max))))))

(defun crush--insert-prompt ()
  "Insert the `crush> ' prompt marker with crush-specific properties.
Read-only is enforced via text properties.  The prompt itself and all
previous content are frozen read-only; new text after the prompt stays
editable."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (start (point)))
    (insert "crush> ")
    (put-text-property start (point) 'crush-prompt-id crush--prompt-id)
    (add-text-properties
     start (point)
     '(read-only t
                 front-sticky (read-only)
                 rear-nonsticky (read-only font-lock-face)
                 font-lock-face crush-prompt-face))
    (crush--freeze-region (point-min) start)
    (setq-local crush--prompt-start-marker (copy-marker start))
    (set-marker-insertion-type crush--prompt-start-marker t)
    (setq-local crush--input-start-marker (point-marker))
    (set-marker-insertion-type crush--input-start-marker nil)))

(defun crush-get-prompt-at-point ()
  "Return the prompt ID at or before point, or nil if not found."
  (or (get-text-property (point) 'crush-prompt-id)
      (get-text-property (point) 'crush-response-to)
      (when (> (point) (point-min))
        (get-text-property (1- (point)) 'crush-prompt-id))))

(defun crush-get-attachments-for-prompt (prompt-id)
  "Return list of attachment regions for PROMPT-ID.
Each element is (START END ATTACHMENT-ID)."
  (let ((pos (point-min))
        attachments)
    (while (setq pos (text-property-any pos (point-max) 'crush-prompt-id prompt-id))
      (let ((attach-id (get-text-property pos 'crush-attachment-id)))
        (if attach-id
            (let ((end (or (next-single-property-change pos 'crush-attachment-id nil (point-max))
                           (point-max))))
              (push (list pos end attach-id) attachments)
              (setq pos end))
          ;; No attachment at this position, move to next property change
          (setq pos (or (next-single-property-change pos 'crush-prompt-id nil (point-max))
                        (point-max))))))
    (nreverse attachments)))

(defun crush-get-all-prompts ()
  "Return list of all unique prompt IDs in buffer."
  (let ((pos (point-min))
        prompts)
    (while (< pos (point-max))
      (let ((prompt-id (get-text-property pos 'crush-prompt-id)))
        (when (and prompt-id (not (member prompt-id prompts)))
          (push prompt-id prompts))
        (setq pos (or (next-single-property-change pos 'crush-prompt-id nil (point-max))
                      (point-max)))))
    (nreverse prompts)))

(defun crush-get-response-text (prompt-id)
  "Return the assistant answer text for PROMPT-ID, or nil.
The text tagged `crush-response-to' equal to PROMPT-ID, excluding the
streamed reasoning (CoT) span, the reasoning-fold marker line, and any
tool blocks (display decoration around tool results).  Reasoning
streams before the answer, and tool blocks may interrupt it, so the
answer is the concatenation of the non-reasoning, non-tool runs.
Returns nil when no such region exists."
  (let ((pos (text-property-any (point-min) (point-max)
                                'crush-response-to prompt-id)))
    (when pos
      (let* ((end (or (next-single-property-change pos 'crush-response-to
                                                   nil (point-max))
                      (point-max)))
             (chunks nil)
             (p pos))
        ;; Walk the response, skipping reasoning and tool spans.
        (while (< p end)
          (let ((type (get-text-property p 'crush-region-type))
                (run-end (or (next-single-property-change p 'crush-region-type
                                                          nil end)
                             end)))
            (unless (memq type '(reasoning tool tool-output))
              (push (buffer-substring-no-properties p run-end) chunks))
            (setq p run-end)))
        (let ((text (string-join (nreverse chunks) "")))
          (string-trim text))))))

(defun crush-get-reasoning-text (prompt-id)
  "Return the streamed reasoning (CoT) text for PROMPT-ID, or nil.
The span tagged `crush-region-type' `reasoning' within the response
region for PROMPT-ID, trimmed.  Returns nil when the model produced
no chain-of-thought."
  (let ((pos (text-property-any (point-min) (point-max)
                                'crush-response-to prompt-id)))
    (when pos
      (let ((end (or (next-single-property-change pos 'crush-response-to
                                                  nil (point-max))
                     (point-max))))
        (let ((rs (text-property-any pos end 'crush-region-type 'reasoning)))
          (when rs
            (let ((re (or (next-single-property-change rs 'crush-region-type
                                                       nil end)
                          end)))
              (let ((text (string-trim
                           (buffer-substring-no-properties rs re))))
                (when (> (length text) 0)
                  text)))))))))

(defun crush--user-turn-text (prompt-id)
  "Return the user-side text for PROMPT-ID: typed input + attachments.
The text is the buffer content tagged with `crush-prompt-id' PROMPT-ID
in buffer order, including attachment regions (that context traveled
inside the user message when sent), excluding the `crush> ' marker
line, the response, and reasoning regions (which share the
`crush-prompt-id' tag but belong to the assistant).  Returns nil when
nothing remains."
  (let ((pos (text-property-any (point-min) (point-max)
                                'crush-prompt-id prompt-id))
        (chunks nil))
    (while pos
      ;; Chunk ends either where `crush-prompt-id' changes (the next
      ;; prompt) or where `crush-region-type' changes (a response or
      ;; reasoning region nested inside this prompt's text).
      (let* ((prompt-end (or (next-single-property-change pos 'crush-prompt-id
                                                          nil (point-max))
                             (point-max)))
             (type-end (or (next-single-property-change pos 'crush-region-type
                                                        nil prompt-end)
                           prompt-end))
             (end type-end)
             (chunk-start (if (string= (buffer-substring-no-properties
                                        pos (min (point-max) (+ pos 7)))
                                       "crush> ")
                              (+ pos 7)
                            pos)))
        (when (and (< chunk-start end)
                   (memq (get-text-property pos 'crush-region-type)
                         '(nil attachment)))
          (push (buffer-substring-no-properties chunk-start end) chunks))
        (setq pos (and (< end (point-max))
                       (text-property-any end (point-max)
                                          'crush-prompt-id prompt-id)))))
    (let ((text (string-join (nreverse chunks) "")))
      (when (> (length (string-trim text)) 0)
        (string-trim text)))))

(defun crush--history-turns (prompt-id)
  "Return the conversation history up to (but excluding) PROMPT-ID.
Iterate the buffer's prompts in buffer order, stopping at PROMPT-ID;
the pending prompt is being sent and therefore never part of history.
For each prior prompt emit (ROLE . TEXT) conses: `user'
with the typed input and attachments, `assistant' with the streamed
answer (reasoning excluded), `tool' with the tool-call exchange text,
and, when `crush-hyper-history-include-reasoning' is enabled, a
`reasoning' record carrying the CoT text.  Returns nil when PROMPT-ID
is the first prompt in the buffer."
  (if (and (boundp 'crush-hyper-history-limit)
           (= crush-hyper-history-limit 0))
      nil
    (let* ((prompts (crush-get-all-prompts))
           (reached-current nil)
           (turns nil))
      (dolist (id prompts)
        (if (string= id prompt-id)
            (setq reached-current t)
          (unless reached-current
            (let ((user-text (crush--user-turn-text id)))
              (when user-text
                (push (cons 'user user-text) turns)))
            (let ((tool-turn (crush--tool-turn id)))
              (if tool-turn
                  (push tool-turn turns)
                ;; No tool turn: emit the assistant text as a plain
                ;; message.  When a tool turn exists, the
                ;; crush-openai-history-messages function emits the
                ;; proper assistant(tool_calls) + tool pair instead.
                (let ((resp-text (crush-get-response-text id)))
                  (when resp-text
                    (push (cons 'assistant resp-text) turns)))))
            (when (and (boundp 'crush-hyper-history-include-reasoning)
                       crush-hyper-history-include-reasoning)
              (let ((reasoning-text (crush-get-reasoning-text id)))
                (when reasoning-text
                  (push (cons 'reasoning reasoning-text) turns)))))))
      (let* ((limited (nreverse turns))
             (exchanges (cl-count-if (lambda (turn) (eq (car turn) 'user))
                                     limited)))
        (if (and (boundp 'crush-hyper-history-limit)
                 (> crush-hyper-history-limit 0)
                 (> exchanges crush-hyper-history-limit))
            (let ((to-cut (- exchanges crush-hyper-history-limit))
                  (cut 0)
                  (i 0))
              (while (and (< i (length limited))
                          (if (eq (car (nth i limited)) 'user)
                              (< cut to-cut)
                            t))
                (when (eq (car (nth i limited)) 'user)
                  (setq cut (1+ cut)))
                (setq i (1+ i)))
              (seq-subseq limited i))
          limited)))))

(defun crush--history-for (buffer)
  "Return BUFFER's history without its pending prompt.
The pending prompt is the one about to be sent (its ID lives in
BUFFER's `crush--prompt-id'); the transcript stops at the last
completed exchange.  Entering BUFFER is this function's job, which
keeps the backend buffer-free."
  (with-current-buffer buffer
    (crush--history-turns crush--prompt-id)))

(defun crush--tool-turn-text (prompt-id)
  "Return the tool-call exchange text for PROMPT-ID, or nil.
The raw tool result (the nested `crush-region-type' `tool-output'
span) within the response region for PROMPT-ID, falling back to the
decorated `tool' span for buffers created before the nested region
existed.  Returns nil when no tool calls were made."
  (let ((pos (text-property-any (point-min) (point-max)
                                'crush-response-to prompt-id)))
    (when pos
      (let* ((end (or (next-single-property-change pos 'crush-response-to
                                                   nil (point-max))
                      (point-max)))
             (raw-pos (text-property-any pos end
                                         'crush-region-type 'tool-output)))
        (if raw-pos
            ;; Raw result (the wire `role: "tool"' content).
            (let ((raw-end (or (next-single-property-change raw-pos 'crush-region-type
                                                            nil end)
                               end)))
              (let ((text (string-trim
                           (buffer-substring-no-properties raw-pos raw-end))))
                (when (> (length text) 0)
                  text)))
          ;; Fallback: pre-nested-region buffers carry only the
          ;; decorated `tool' span.
          (when (text-property-any pos end 'crush-region-type 'tool)
            (let ((ts (text-property-any pos end 'crush-region-type 'tool)))
              (let ((te (or (next-single-property-change ts 'crush-region-type
                                                         nil end)
                            end)))
                (let ((text (string-trim
                             (buffer-substring-no-properties ts te))))
                  (when (> (length text) 0)
                    text))))))))))

(defun crush--tool-call-meta (prompt-id)
  "Return (ID NAME ARGS) for PROMPT-ID's first tool call, or nil.
Reads the block's `crush-tool-call' text property (a plist of :id
:name :args-json) within the response region for PROMPT-ID.  Returns
nil when the block predates the property or no call exists."
  (let ((pos (text-property-any (point-min) (point-max)
                                'crush-response-to prompt-id)))
    (when pos
      (let ((end (or (next-single-property-change pos 'crush-response-to
                                                  nil (point-max))
                     (point-max))))
        (let ((ts (text-property-any pos end
                                     'crush-region-type 'tool)))
          (when ts
            (let ((plist (get-text-property ts 'crush-tool-call)))
              (when plist
                (list (plist-get plist :id)
                      (plist-get plist :name)
                      (plist-get plist :args-json))))))))))

(defun crush--tool-turn (prompt-id)
  "Return the tool turn for PROMPT-ID as a cons, or nil.
When the call metadata (id/name/args) is available the turn is a
plist-style cons `(tool ID NAME ARGS . TEXT)' carrying the raw result
TEXT; without metadata it falls back to the legacy bare `(tool .
TEXT)' cons.  TEXT is the raw `<command>/<output>/<exit_code>' result,
or the decorated block for pre-nested-region buffers."
  (let ((text (crush--tool-turn-text prompt-id)))
    (when text
      (let ((meta (crush--tool-call-meta prompt-id)))
        (if meta
            (cons 'tool (append meta (list text)))
          (cons 'tool text))))))

(defun crush--install-font-lock-guard (&optional enable)
  "Protect read-only boundaries from font-lock in the current buffer.
markdown-mode (and other modes) include `rear-nonsticky' in
`font-lock-extra-managed-props', so font-lock strips it from read-only
prompts and frozen responses during refontification.  Without
`rear-nonsticky', text typed just after a read-only char inherits
`read-only' and Emacs refuses the insertion (\"Text is read-only\"),
making the input area uneditable.
ENABLE non-nil (or omitted) installs a buffer-local
`font-lock-unfontify-region-function' that skips `rear-nonsticky' when
unfontifying.  ENABLE nil restores the default."
  (if (called-interactively-p 'any)
      (setq enable (not (local-variable-p 'font-lock-unfontify-region-function))))
  (if enable
      (progn
        ;; Keep the reasoning fold marker's keymap and fold mark through
        ;; refontification: font-lock otherwise strips arbitrary text
        ;; properties (same failure mode as `rear-nonsticky').  Both are
        ;; removed from the strip list so unfontify preserves them.
        (setq-local font-lock-unfontify-region-function
                    (lambda (beg end)
                      (let ((props (remove 'rear-nonsticky
                                           (remove 'keymap
                                                   (remove 'crush-fold-mark
                                                           (append font-lock-extra-managed-props
                                                                   '(face font-lock-multiline)))))))
                        (remove-list-of-text-properties beg end props)))))
    (kill-local-variable 'font-lock-unfontify-region-function)))

(defun crush--init-session-uuid ()
  "Generate a fresh session UUID and its cached XXH3-64 hash.
Sets `crush--session-uuid' to an opaque random string and
`crush--session-id' to the 16-hex XXH3-64 of it.  The UUID is
buffer-local and never leaves via the network; only the hash is sent."
  (setq-local crush--session-uuid
              (format "crs-%s-%s-%s"
                      (format-time-string "%Y%m%d%H%M%S")
                      (substring (md5 (format "%s%s" (random) (current-time))) 0 8)
                      (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))
  (setq-local crush--session-id (crush-xxh3-hash64 crush--session-uuid)))

(defun crush--init-buffer (buf)
  "Initialize BUF as a crush buffer if not already initialized."
  (with-current-buffer buf
    (unless crush--initialized
      ;; Establish the buffer's major mode directly (markdown-mode or
      ;; text-mode). There is no separate crush-mode major mode.
      (funcall (symbol-function
                (if (and (memq crush--parent-mode '(markdown-mode text-mode))
                         (fboundp crush--parent-mode))
                    crush--parent-mode
                  'text-mode)))
      ;; Initialize crush state AFTER mode setup, since the mode may have
      ;; run kill-all-local-variables.
      ;; Generate prompt ID BEFORE inserting the marker.
      (setq-local crush--prompt-id (crush--generate-id))
      (setq-local crush-process nil)
      (setq-local crush--continue nil)
      (crush--init-session-uuid)
      (setq-local crush--attachments nil)
      (setq-local crush--response-start nil)
      (setq-local crush--pending-context nil)
      (setq-local crush-active-provider nil)
      (setq-local crush--prompt-start-marker nil)
      (setq-local crush--input-start-marker nil)
      (setq-local crush--input-ring nil)
      (setq-local crush--input-ring-index 0)
      (setq-local crush--tool-continuation nil)
      (setq-local crush--tool-loop-count 0)
      (crush-chat-mode 1)
      (crush--install-font-lock-guard t)
      (crush--update-header-line)
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t))
        (erase-buffer)
        (crush--insert-prompt))
      (setq-local buffer-undo-list nil)
      (crush--input-ring-read)
      (setq-local default-directory
                  (file-name-as-directory
                   (or crush-working-directory
                       (when-let ((proj (project-current)))
                         (project-root proj))
                       default-directory)))
      (setq-local crush--project-root
                  (crush--canonical-root default-directory))
      (setq-local crush-active-provider
                  (crush-make-hyper-provider
                   :buffer buf
                   :working-directory default-directory
                   :base-url crush-hyper-base-url
                   :token crush-hyper-token
                   :model crush-model))
      ;; Mark initialized only after mode setup so the flag is not wiped
      ;; by the parent mode (which calls kill-all-local-variables).
      (setq-local crush--initialized t))))

(defun crush--insert-before-prompt (buf formatted &optional attachment-id prompt-id filename lines)
  "Insert FORMATTED content into BUF before the `crush> ' prompt line.
Uses `crush--prompt-start-marker' to find the prompt position.
If ATTACHMENT-ID and PROMPT-ID are provided, apply text properties.
When FILENAME is provided, tag the region with `crush-filename';
when LINES is provided, tag it with `crush-lines' (a line range string)."
  (with-current-buffer buf
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (if (and crush--prompt-start-marker
               (markerp crush--prompt-start-marker))
          (let ((prompt-pos (marker-position crush--prompt-start-marker))
                (start nil))
            (save-excursion
              (goto-char prompt-pos)
              (beginning-of-line)
              (setq start (point))
              (insert formatted "\n\n")
              (when (and attachment-id prompt-id)
                (put-text-property start (point) 'crush-attachment-id attachment-id)
                (put-text-property start (point) 'crush-prompt-id prompt-id))
              (put-text-property start (point) 'crush-region-type 'attachment)
              (when filename
                (put-text-property start (point) 'crush-filename filename))
              (when lines
                (put-text-property start (point) 'crush-lines lines))))
        (let ((start nil))
          (save-excursion
            (goto-char (point-max))
            (setq start (point))
            (insert formatted "\n\n")
            (when (and attachment-id prompt-id)
              (put-text-property start (point) 'crush-attachment-id attachment-id)
              (put-text-property start (point) 'crush-prompt-id prompt-id))
            (put-text-property start (point) 'crush-region-type 'attachment)
            (when filename
              (put-text-property start (point) 'crush-filename filename))
            (when lines
              (put-text-property start (point) 'crush-lines lines))))))))

(defun crush--relative-file (file)
  "Return FILE relative to the project root or the default directory.
Resolves against `project-root' when in a project, otherwise
`default-directory'.  Returns nil when FILE is nil."
  (when file
    (file-relative-name
     file
     (or (when-let ((proj (project-current)))
           (project-root proj))
         default-directory))))

(defun crush--format-selection (file start end)
  "Format the selection as a markdown fenced code block.
FILE is the file path, START and END are the line numbers."
  (let* ((start-line (save-excursion
                       (goto-char start)
                       (line-number-at-pos)))
         (end-line (save-excursion
                     (goto-char end)
                     (line-number-at-pos)))
         (selected-text (buffer-substring-no-properties start end))
         (relative-file (or (crush--relative-file file) "(no file)"))
         (lang (crush--lang-from-extension (file-name-nondirectory relative-file))))
    (format "**Attachment: %s (lines %d-%d)**\n\n```%s\n%s\n```"
            relative-file start-line end-line lang selected-text)))

(defun crush--reasoning-start-region ()
  "Start a reasoning region at point-max if none is active.
Creates the reasoning overlay and the start marker on the first
reasoning delta streamed for the current prompt.  Returns the
overlay.  Inert once content has started or when an active
overlay is already open."
  (unless (or crush--reasoning-overlay
              (markerp crush--reasoning-end))
    (let ((pos (point)))
      (setq-local crush--reasoning-start (copy-marker pos nil))
      (setq-local crush--reasoning-overlay
                  (make-overlay pos pos nil nil nil))
      (overlay-put crush--reasoning-overlay 'crush-overlay t)
      (overlay-put crush--reasoning-overlay 'crush-reasoning t)
      (overlay-put crush--reasoning-overlay 'face 'crush-reasoning-face)
      crush--reasoning-overlay)))

(defun crush--reasoning-extend-overlay ()
  "Extend the reasoning overlay to point-max.
Inert when no reasoning region is active or content already started."
  (when (overlayp crush--reasoning-overlay)
    (move-overlay crush--reasoning-overlay
                  (overlay-start crush--reasoning-overlay)
                  (point-max))))

(defun crush--reasoning-stop ()
  "Freeze the reasoning region, marking where the answer begins.
Sets `crush--reasoning-end' at point-max (before the content delta
is appended), stops moving the overlay, and inserts two newlines
before the answer so the content is visually separated from the
reasoning.  Inert when no reasoning is active or it already ended."
  (when (and (overlayp crush--reasoning-overlay)
             (not (markerp crush--reasoning-end)))
    (setq-local crush--reasoning-end (copy-marker (point) nil))
    (move-overlay crush--reasoning-overlay
                  (overlay-start crush--reasoning-overlay)
                  (marker-position crush--reasoning-end))
    (insert "\n\n")))

(defvar crush--reasoning-fold-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'crush-reasoning-toggle)
    (define-key map (kbd "RET") #'crush-reasoning-toggle)
    (define-key map [mouse-1] #'crush-reasoning-toggle)
    map)
  "Keymap on the reasoning collapse marker.
TAB / RET (and mouse-1 on GUIs, ignored harmlessly in TUI) toggle
`crush-reasoning-toggle'.")

(defun crush--reasoning-install-fold (region)
  "Install the reasoning fold on REGION (START . END) of current buffer.
When the reasoning is `crush-reasoning-preview-lines' lines or fewer,
the overlay stays visible with no fold.  When it exceeds that, the
first N lines are shown via a preview overlay, a `…' (U+2026) ellipsis
is inserted as real text carrying the toggle keymap and
`crush-fold-mark', and the remaining lines are hidden by an
`invisible' body overlay.  Returns the body overlay, or nil."
  (let* ((start (car region))
         (end (cdr region))
         (start-m (copy-marker start))
         (end-m (copy-marker end t))
         (ov (car (cl-remove-if-not
                   (lambda (o) (overlay-get o 'crush-overlay))
                   (overlays-in start end))))
         (preview-lines (or crush-reasoning-preview-lines 10)))
    (when (and (overlayp ov) (> end start))
      (save-excursion
        (goto-char start-m)
        (beginning-of-line)
        (set-marker start-m (point)))
      (let ((total-lines (count-lines start-m end-m)))
        (if (<= total-lines preview-lines)
            (progn
              (overlay-put ov 'crush-reasoning nil)
              (set-marker start-m nil)
              (set-marker end-m nil)
              nil)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t)
                (preview-end nil)
                (ellipsis-end nil))
            (save-excursion
              (goto-char start-m)
              (forward-line (1- preview-lines))
              (end-of-line)
              (setq preview-end (point)))
            (save-excursion
              (goto-char preview-end)
              (insert "\n" (propertize "…"
                                       'keymap crush--reasoning-fold-keymap
                                       'crush-fold-mark t))
              (setq ellipsis-end (point)))
            (let ((preview-ov (make-overlay start-m preview-end
                                            nil nil nil)))
              (overlay-put preview-ov 'crush-overlay t)
              (overlay-put preview-ov 'crush-reasoning-preview t)
              (overlay-put preview-ov 'face 'crush-reasoning-face)
              (crush--freeze-region (marker-position start-m)
                                    ellipsis-end)
              (move-overlay ov ellipsis-end end-m)
              (overlay-put ov 'crush-fold-state 'collapsed)
              (overlay-put ov 'invisible t)
              (overlay-put ov 'crush-reasoning nil)
              (overlay-put ov 'crush-reasoning-origin
                           (marker-position start-m))
              (set-marker start-m nil)
              (set-marker end-m nil)
              ov)))))))

(defun crush-reasoning-toggle ()
  "Toggle the reasoning fold at point.
When point is on the `…' ellipsis or inside a collapsed (hidden)
reasoning body, expand it.  When inside an expanded reasoning
region, collapse it (re-install the preview).  Otherwise signal
a message.  Triggered by TAB / RET on the ellipsis (real text
keymap), by `C-c c r', or directly."
  (interactive)
  (if (get-text-property (point) 'crush-fold-mark)
      (crush--reasoning-expand)
    (let ((ov (cl-find-if
               (lambda (o) (overlay-get o 'crush-fold-state))
               (overlays-at (point)))))
      (if (not (overlayp ov))
          (message "No reasoning fold at point")
        (if (eq (overlay-get ov 'crush-fold-state) 'collapsed)
            (crush--reasoning-expand)
          (crush--reasoning-collapse ov))))))

(defun crush--reasoning-expand ()
  "Expand the reasoning fold closest to point.
Searches backward from point for the `…' ellipsis, then the adjacent
body and preview overlays.  Deletes the ellipsis and preview overlay,
extends the body overlay to cover the full reasoning region, and makes
it visible."
  (let* ((ellipsis-pos (save-excursion
                         (when (search-backward "…" nil t)
                           (point)))))
    (unless ellipsis-pos
      (setq ellipsis-pos (save-excursion
                           (goto-char (point-min))
                           (when (search-forward "…" nil t)
                             (1- (point))))))
    (let ((body-ov (when ellipsis-pos
                     (car (cl-remove-if-not
                           (lambda (o)
                             (and (overlay-get o 'crush-fold-state)
                                  (= (overlay-start o)
                                     (1+ ellipsis-pos))))
                           (overlays-in (point-min) (point-max))))))
          (preview-ov (when ellipsis-pos
                        (car (cl-remove-if-not
                              (lambda (o)
                                (and (overlay-get o 'crush-reasoning-preview)
                                     (= (overlay-end o)
                                        (1- ellipsis-pos))))
                              (overlays-in (point-min) (point-max)))))))
      (when (and (overlayp body-ov) (overlayp preview-ov) ellipsis-pos)
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t)
              (preview-start (overlay-start preview-ov))
              (full-end (overlay-end body-ov)))
          (overlay-put body-ov 'crush-reasoning-origin preview-start)
          (goto-char ellipsis-pos)
          (delete-region ellipsis-pos (1+ (point)))
          (delete-overlay preview-ov)
          (move-overlay body-ov preview-start full-end)
          (overlay-put body-ov 'crush-fold-state 'expanded)
          (overlay-put body-ov 'invisible nil)
          (message "Reasoning expanded"))))))

(defun crush--reasoning-collapse (body-ov)
  "Collapse the reasoning body overlay BODY-OV.
Re-installs the preview overlay and `…' ellipsis, hiding the body
beyond `crush-reasoning-preview-lines' lines."
  (let* ((origin (overlay-get body-ov 'crush-reasoning-origin))
         (full-end (overlay-end body-ov))
         (preview-lines (or crush-reasoning-preview-lines 10))
         (start-m (copy-marker (or origin (overlay-start body-ov))))
         (end-m (copy-marker full-end t)))
    (save-excursion
      (goto-char start-m)
      (beginning-of-line)
      (set-marker start-m (point)))
    (let ((total-lines (count-lines start-m end-m)))
      (when (> total-lines preview-lines)
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t)
              (preview-end nil)
              (ellipsis-end nil))
          (save-excursion
            (goto-char start-m)
            (forward-line (1- preview-lines))
            (end-of-line)
            (setq preview-end (point)))
          (save-excursion
            (goto-char preview-end)
            (insert "\n" (propertize "…"
                                     'keymap crush--reasoning-fold-keymap
                                     'crush-fold-mark t))
            (setq ellipsis-end (point)))
          (let ((preview-ov (make-overlay start-m preview-end
                                          nil nil nil)))
            (overlay-put preview-ov 'crush-overlay t)
            (overlay-put preview-ov 'crush-reasoning-preview t)
            (overlay-put preview-ov 'face 'crush-reasoning-face)
            (crush--freeze-region (marker-position start-m)
                                  ellipsis-end)
            (move-overlay body-ov ellipsis-end end-m)
            (overlay-put body-ov 'crush-fold-state 'collapsed)
            (overlay-put body-ov 'invisible t)
            (message "Reasoning collapsed")))))
    (set-marker start-m nil)
    (set-marker end-m nil)))

(defun crush--reasoning-tab ()
  "Handle TAB in crush chat buffers.
Toggles the reasoning fold when point is on a fold marker (or the
fold's overlay); otherwise falls back to the major mode's or global
TAB binding."
  (interactive)
  (if (or (get-text-property (point) 'crush-fold-mark)
          (cl-find-if
           (lambda (o) (overlay-get o 'crush-fold-state))
           (overlays-at (point))))
      (crush-reasoning-toggle)
    (let ((fallback (or (lookup-key (current-local-map) (kbd "TAB"))
                        (lookup-key (current-global-map) (kbd "TAB")))))
      (when (commandp fallback)
        (call-interactively fallback)))))

(defun crush--reasoning-regions ()
  "Return the list of reasoning regions, or nil.
When content never began, the reasoning region is the span from
`crush--reasoning-start' to `crush--reasoning-end' (or point-max).
When at least one content delta arrived (or a tool block re-tagged),
the full-response span is scanned: reasoning covers the runs between
the response start and each tool block or the content start, tool
blocks stay `tool', and the trailing content stays `response'."
  (if (not (markerp crush--reasoning-start))
      nil
    (let ((end (if (markerp crush--reasoning-end)
                   (marker-position crush--reasoning-end)
                 (point-max))))
      (if (and (markerp crush--reasoning-end)
               (< end (point-max)))
          ;; Content already began: the reasoning span runs from the
          ;; response start up to the first tool block or the content
          ;; start, whichever comes first.  Everything after it stays
          ;; `response'; tool blocks stay `tool'.
          (let ((limit (or (when-let ((first (car (crush--tool-block-bounds))))
                             (car first))
                           end))
                (pos (marker-position crush--reasoning-start)))
            (when (< pos limit)
              (list (cons pos limit))))
        ;; No content yet: reasoning runs from start to the answer
        ;; boundary (tool block or point-max).
        (let ((list nil)
              (pos (marker-position crush--reasoning-start)))
          (dolist (tb (crush--tool-block-bounds))
            (when (and (>= (car tb) pos) (< (cdr tb) (point-max)))
              (when (< pos (car tb))
                (setq list (cons (cons pos (car tb)) list)))
              (setq pos (cdr tb))))
          (when (< pos (point-max))
            (setq list (cons (cons pos (point-max)) list)))
          (nreverse list))))))

(defun crush--tool-block-bounds ()
  "Return the list of (START . END) tool blocks in the current buffer.
A tool block is a span tagged `crush-region-type' `tool' (starting at
its text after the trailing newline).  Blocks run from `response-start'
to `(point-max)'; search from `(point-min)'."
  (let ((pos (point-min))
        (list nil))
    (while (setq pos (text-property-any pos (point-max)
                                        'crush-region-type 'tool))
      (let ((end (or (next-single-property-change pos 'crush-region-type
                                                  nil (point-max))
                     (point-max))))
        (when (> end pos)
          (setq list (cons (cons pos end) list))
          (setq pos end))))
    (nreverse list)))

(defun crush--reasoning-reset ()
  "Reset per-prompt reasoning state after finalize or interrupt.
The overlay itself is left in place; `crush-clear-buffer' removes
it.  Markers are invalidated."
  (when (markerp crush--reasoning-start)
    (set-marker crush--reasoning-start nil))
  (when (markerp crush--reasoning-end)
    (set-marker crush--reasoning-end nil))
  (setq-local crush--reasoning-start nil)
  (setq-local crush--reasoning-end nil)
  (setq-local crush--reasoning-overlay nil))

(defun crush--tag-response-region (response-start response-end prompt-id)
  "Tag the response and reasoning regions from RESPONSE-START to RESPONSE-END.
PROMPT-ID is applied to both regions.  Applies `crush-prompt-id',
`crush-response-to' and `crush-region-type' (`response', with the
reasoning sub-span retagged `reasoning').  Shared by
`crush-facade--finalize' and `crush-interrupt'.  Tool regions within
the response are tagged `tool' (and their nested raw-result span
`tool-output') and carry the `crush-tool-call' property for wire
resume."
  (when (and response-start (> response-end response-start))
    (let ((inhibit-read-only t))
      ;; Tag the response span, but never overwrite existing `tool' or
      ;; `tool-output' regions: the tool loop tags its blocks before
      ;; this runs, and the nested `tool-output' raw result is the wire
      ;; `role: "tool"' content that must survive re-tagging.
      (let ((pos response-start))
        (while (< pos response-end)
          (let ((type (get-text-property pos 'crush-region-type))
                (run-end (or (next-single-property-change pos 'crush-region-type
                                                          nil response-end)
                             response-end)))
            (if (memq type '(tool tool-output))
                (setq pos run-end)
              (put-text-property pos run-end
                                 'crush-prompt-id prompt-id)
              (put-text-property pos run-end
                                 'crush-response-to prompt-id)
              (put-text-property pos run-end
                                 'crush-region-type 'response)
              (setq pos run-end)))))
      (dolist (region (crush--reasoning-regions))
        (let ((rs (car region))
              (re (cdr region)))
          (when (and (>= rs response-start) (<= re response-end))
            (put-text-property rs re
                               'crush-prompt-id prompt-id)
            (put-text-property rs re
                               'crush-response-to prompt-id)
            (put-text-property rs re
                               'crush-region-type 'reasoning)))))))

(defun crush-facade--close-response (response-start prompt-id)
  "Close the response started at RESPONSE-START with PROMPT-ID.
Tags the response text (including any reasoning sub-span), auto-collapses
the reasoning fold, resets reasoning state, and inserts a fresh prompt.
Runs in the crush buffer, which owns all response text."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (newline)
      ;; Remember where response ends (before new prompt)
      (let ((response-end (point)))
        ;; Tag the full response text with the prompt ID it answers and
        ;; region type.  Deltas were inserted with modification hooks
        ;; suppressed, so this is the only tagging the response gets.
        (crush--tag-response-region response-start response-end prompt-id)
        ;; Auto-collapse every reasoning overlay in the response
        ;; (there may be multiple across tool-call rounds).
        ;; Use (point-min) instead of response-start because
        ;; crush--response-start is relocated after tool blocks
        ;; in crush-facade--tool-loop, so the first round's
        ;; reasoning overlay would be outside the range.
        (dolist (ov (overlays-in (point-min) response-end))
          (when (and (overlay-get ov 'crush-reasoning)
                     (not (overlay-get ov 'crush-fold-state)))
            (crush--reasoning-install-fold
             (cons (overlay-start ov) (overlay-end ov)))))
        (crush--reasoning-reset))
      ;; Generate new prompt ID BEFORE inserting marker
      (setq-local crush--prompt-id (crush--generate-id))
      (crush--insert-prompt))
    (setq-local crush-process nil)
    (setq-local crush--response-start nil)
    (setq-local crush--attachments nil)
    (setq-local crush--tool-continuation nil)
    (setq-local crush--tool-loop-count 0)
    (crush--input-ring-write)
    (crush--update-header-line)
    (setq-local buffer-undo-list nil)
    (goto-char (point-max))))

(defun crush-facade--finalize ()
  "Finalize the current response via the facade.
Checks for pending tool calls from the SSE stream; when present,
drives the tool loop (execute, insert blocks, send follow-up).
Otherwise closes the response and inserts a fresh prompt.  The
backend's completion action invokes this."
  (if (and crush-tools-enabled
           crush-active-provider
           crush-process
           (let ((tcs (crush-provider--tool-calls
                       crush-active-provider crush-process)))
             (and (vectorp tcs) (> (length tcs) 0))))
      (crush-facade--tool-loop)
    (crush-facade--stream-transition 'done 1)
    (let ((response-start (when (markerp crush--response-start)
                            (marker-position crush--response-start)))
          (prompt-id crush--prompt-id))
      (crush-facade--close-response response-start prompt-id))))

(defvar-local crush--tool-loop-count 0
  "Number of tool-loop rounds executed for the current prompt.")

(defun crush-facade--tool-loop ()
  "Execute pending tool calls and send a follow-up request.
Extracts tool calls from the transport's SSE state, executes them
via `crush-provider--tool-results', inserts tool blocks into the
buffer, and sends a follow-up request with the continuation
messages.  Loops up to `crush-tool-loop-max' rounds; when the cap
is hit or no tool calls come back, finalizes via
`crush-facade--close-response'."
  (if (>= crush--tool-loop-count crush-tool-loop-max)
      (progn
        (setq-local crush--tool-loop-count 0)
        (setq-local crush--tool-continuation nil)
        (crush-facade--stream-transition 'done 1)
        (let ((response-start (when (markerp crush--response-start)
                                (marker-position crush--response-start)))
              (prompt-id crush--prompt-id))
          (crush-facade--close-response response-start prompt-id)))
    (let* ((tool-calls (crush-provider--tool-calls
                        crush-active-provider crush-process))
           (result (crush-provider--tool-results
                    crush-active-provider tool-calls))
           (assistant-msg (nth 0 result))
           (tool-msgs (nth 1 result))
           (blocks (nth 2 result))
           (prompt-id crush--prompt-id)
           (buf (current-buffer)))
      (setq-local crush--tool-loop-count (1+ crush--tool-loop-count))
      ;; Insert tool blocks before the response-start marker so they
      ;; appear as part of the current response.
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t))
        (dolist (block blocks)
          (crush--tool-block-insert block prompt-id)))
      ;; Build the continuation messages: user + assistant(tool_calls) +
      ;; tool results.  The user message is extracted from the buffer
      ;; (the current prompt's typed input), and the assistant + tool
      ;; messages come from `crush-provider--tool-results'.
      (let ((user-text (crush--user-turn-text prompt-id)))
        (setq-local crush--tool-continuation
                    (append (when (and user-text (> (length user-text) 0))
                              (list (list (cons 'role "user")
                                          (cons 'content user-text))))
                            (list assistant-msg)
                            tool-msgs)))
      ;; Tag the response so far, then reset reasoning state before
      ;; the follow-up stream starts a new response region.
      (let ((response-start (when (markerp crush--response-start)
                              (marker-position crush--response-start))))
        (crush--tag-response-region response-start (point) prompt-id))
      (crush--reasoning-reset)
      ;; Clear the old process and set up for the follow-up.
      (setq-local crush-process nil)
      (setq-local crush--response-start (point-marker))
      (crush-facade--stream-transition 'active 2)
      (let ((real-proc (crush-provider-send-prompt
                        crush-active-provider ""
                        :context nil
                        :session-id crush--session
                        :session-uuid crush--session-uuid
                        :continue-p crush--continue
                        :completion (lambda ()
                                      (when (buffer-live-p buf)
                                        (with-current-buffer buf
                                          (crush-facade--finalize))))
                        :on-delta (lambda (delta kind)
                                    (when (buffer-live-p buf)
                                      (with-current-buffer buf
                                        (crush-facade--append-delta delta kind))))
                        :on-error (lambda (message)
                                    (when (buffer-live-p buf)
                                      (with-current-buffer buf
                                        (crush-facade--record-error message))))
                        :buffer buf
                        :stderr (get-buffer-create "*crush-errors*")
                        :continuation crush--tool-continuation)))
        (when (and real-proc (processp real-proc))
          (set-marker (process-mark real-proc) (point-max))
          (setq-local crush-process real-proc))))))

;;; Major mode commands

(defun crush-facade--append-delta (delta kind)
  "Append streamed DELTA of KIND (`content' or `reasoning') to the buffer.
The facade's buffer-aware consumer for streaming backends inserts at
point-max, the growing response area, and drives the reasoning overlay:
the first reasoning delta opens the region, later ones extend it, the
first content delta freezes it, and the cursor moves along reasoning
insertions while point stays put for content.  `crush--response-start'
is never touched; it stays at the response start for finalization.
Runs in the crush buffer (the facade's `:on-delta' closure enters it)."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t))
    (save-excursion
      (goto-char (point-max))
      (pcase kind
        ('reasoning
         (crush--reasoning-start-region)
         (crush--reasoning-extend-overlay))
        ('content
         (crush--reasoning-stop)))
      (insert delta)
      (pcase kind
        ('reasoning
         (crush--reasoning-extend-overlay))))
    (when (eq kind 'reasoning)
      (goto-char (point-max)))))

(defun crush-facade--send (prompt context has-context)
  "Send PROMPT (with optional CONTEXT when HAS-CONTEXT) via the active backend.
Injects the facade's continuation as the backend's completion action so
backends signal stream completion without touching buffers.  Runs in the
crush buffer, which owns all streamed output."
  (let ((buf (current-buffer)))
    (crush-facade--stream-transition 'active 2)
    (let ((real-proc (crush-provider-send-prompt
                      crush-active-provider prompt
                      :context (when has-context context)
                      :session-id crush--session
                      :session-uuid crush--session-uuid
                      :continue-p crush--continue
                      :completion (lambda ()
                                    (when (buffer-live-p buf)
                                      (with-current-buffer buf
                                        (crush-facade--finalize))))
                      :on-delta (lambda (delta kind)
                                  (when (buffer-live-p buf)
                                    (with-current-buffer buf
                                      (crush-facade--append-delta delta kind))))
                      :on-error (lambda (message)
                                  (when (buffer-live-p buf)
                                    (with-current-buffer buf
                                      (crush-facade--record-error message))))
                      :buffer buf
                      :stderr (get-buffer-create "*crush-errors*"))))
      (when (and real-proc (processp real-proc))
        (set-marker (process-mark real-proc) (point-max))
        (setq-local crush-process real-proc)
        (setq-local crush--continue t)
        (setq-local crush--response-start (point-marker))))))

(defun crush--fence-str (text)
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

(defun crush--tool-block-insert (tool-calls prompt-id)
  "Insert a tool-call block for TOOL-CALLS into the buffer.
TOOL-CALLS is a plist of :name :id :args-json :result :exit.
PROMPT-ID is the current prompt's ID.  The block is read-only,
tagged `crush-region-type' `tool' with `crush-prompt-id' /
`crush-response-to', and carries the `crush-tool-call' property
for wire resume.  Returns the end position of the inserted block."
  ;; When reasoning was streamed but no content delta ever arrived
  ;; (the model went straight to tool calls), the reasoning text
  ;; is still active and lacks a trailing newline.  Stop reasoning
  ;; now so the tool block is visually separated from the reasoning
  ;; and the reasoning region boundaries are correct.
  (crush--reasoning-stop)
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (start (point-max))
        (raw-start nil)
        (raw-end nil))
    (save-excursion
      (goto-char start)
      (insert (format "**🔧 tool: %s**\n\n" (plist-get tool-calls :name)))
      (insert (format "**command:** `%s`\n" (or (plist-get tool-calls :args-json) "")))
      (let ((exit (plist-get tool-calls :exit)))
        (when exit
          (insert (format "**exit:** `%s`\n" exit))))
      (let ((result (plist-get tool-calls :result)))
        (when result
          (let ((fence (crush--fence-str result)))
            (insert "**output:**\n")
            (insert fence "\n")
            (setq raw-start (point))
            (insert result)
            (unless (string-suffix-p "\n" result)
              (insert "\n"))
            (setq raw-end (point))
            (insert fence "\n"))))
      (insert "\n"))
    (let ((end (point-max)))
      (put-text-property start end 'crush-region-type 'tool)
      (put-text-property start end 'crush-prompt-id prompt-id)
      (put-text-property start end 'crush-response-to prompt-id)
      (put-text-property start (1- end) 'crush-tool-call
                         (list :id (plist-get tool-calls :id)
                               :name (plist-get tool-calls :name)
                               :args-json (plist-get tool-calls :args-json)))
      ;; Nested region: the raw tool result (the wire `role: "tool"`
      ;; content) sits between the output label's opening fence and the
      ;; closing fence.  Tag it separately so history extraction can
      ;; send the raw `<command>/<output>/<exit_code>' without the
      ;; display decoration.  Carries the same prompt/response tags so
      ;; it survives re-tagging and persistence.
      (when raw-start
        (put-text-property raw-start raw-end 'crush-region-type 'tool-output)
        (put-text-property raw-start raw-end 'crush-prompt-id prompt-id)
        (put-text-property raw-start raw-end 'crush-response-to prompt-id))
      (crush--freeze-region start end)
      end)))

(defun crush-send-input ()
  "Send the current prompt to the provider."
  (interactive)
  (when (and crush-process (process-live-p crush-process))
    (user-error "Crush is still running; interrupt with C-c c i"))
  (let* ((input-start (or (when (and crush--input-start-marker
                                     (markerp crush--input-start-marker))
                            (marker-position crush--input-start-marker))
                          (point-min)))
         (input (buffer-substring-no-properties
                 input-start (line-end-position)))
         (prompt (string-trim input))
         (context (string-trim
                   (mapconcat
                    (lambda (region)
                      (buffer-substring-no-properties
                       (car region) (cadr region)))
                    (crush-get-attachments-for-prompt crush--prompt-id)
                    "\n\n")))
         (has-context (not (string-empty-p context))))
    (when (string-empty-p prompt)
      (user-error "No prompt to send"))
    (crush--input-ring-add prompt)
    (goto-char (line-end-position))
    (newline)
    (setq-local crush--response-start (point-marker))
    (setq-local crush--input-ring-index 0)
    (setq-local crush--tool-loop-count 0)
    (crush-facade--send prompt context has-context)
    (setq-local crush--attachments nil)
    (goto-char (point-max))))

(defun crush-interrupt ()
  "Interrupt the currently running Crush process."
  (interactive)
  (let ((interrupted nil))
    (cond
     (crush-process
      (interrupt-process crush-process)
      (setq-local crush-process nil)
      (setq interrupted t))
     (t
      (message "No crush process running")))
    (when interrupted
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (newline)
          ;; Tag the partial response (including any streamed reasoning)
          ;; up to the interrupt point, and auto-collapse the reasoning.
          (let ((response-start (when (markerp crush--response-start)
                                  (marker-position crush--response-start))))
            (crush--tag-response-region response-start (point) crush--prompt-id)
            (dolist (ov (overlays-in response-start (point)))
              (when (and (overlay-get ov 'crush-reasoning)
                         (not (overlay-get ov 'crush-fold-state)))
                (crush--reasoning-install-fold
                 (cons (overlay-start ov) (overlay-end ov)))))
            (crush--reasoning-reset))
          (crush--insert-prompt)))
      (setq-local crush--tool-continuation nil)
      (setq-local crush--tool-loop-count 0)
      (setq-local buffer-undo-list nil)
      (goto-char (point-max))
      (message "Crush process interrupted"))))

(defun crush-clear-buffer ()
  "Clear the Crush buffer output and start a fresh session.
Also rotates the buffer's session UUID, so the next prompt gets a
cold hyperscale cache (new x-session-id / x-session-affinity)."
  (interactive)
  (setq-local crush--continue nil)
  (crush--init-session-uuid)
  (crush-facade--stream-clear)
  ;; Delete all crush-overlay tagged overlays
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'crush-overlay)
      (delete-overlay ov)))
  (crush--reasoning-reset)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (crush--insert-prompt))
  (setq-local buffer-undo-list nil))

;;; Minor mode commands

(defun crush-insert-selection (beg end)
  "Insert the current buffer selection into the Crush buffer.
BEG and END are the bounds of the selection."
  (interactive "r")
  (let* ((file (buffer-file-name))
         (formatted (crush--format-selection file beg end))
         (relative (crush--relative-file file))
         (lines (format "%d-%d"
                        (save-excursion (goto-char beg) (line-number-at-pos))
                        (save-excursion (goto-char end) (line-number-at-pos))))
         (buf (crush--current-crush-buffer)))
    (with-current-buffer buf
      (let ((attachment-id (crush--generate-id)))
        ;; Insert with text properties
        (crush--insert-before-prompt buf formatted attachment-id crush--prompt-id
                                     relative lines)
        ;; Update header line to show attachment count
        (crush--update-header-line)))
    (switch-to-buffer-other-window buf)))

(defun crush-insert-buffer ()
  "Insert the entire current buffer into the Crush buffer as context."
  (interactive)
  (crush-insert-selection (point-min) (point-max)))

(defun crush-insert-filepath ()
  "Insert the current buffer's file path into the Crush buffer as context."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Current buffer has no file"))
    (let* ((relative-file (crush--relative-file file))
           (formatted (if relative-file
                          (format "[%s](%s)" relative-file relative-file)
                        ""))
           (buf (crush--current-crush-buffer)))
      (with-current-buffer buf
        (let ((attachment-id (crush--generate-id)))
          (crush--insert-before-prompt buf formatted attachment-id crush--prompt-id
                                       relative-file nil)
          (crush--update-header-line)))
      (switch-to-buffer-other-window buf))))

;;; Entry point

;;;###autoload
(defun crush ()
  "Start an interactive Crush session.
Creates a buffer if none exists, switches to it, and prepares it for input."
  (interactive)
  (let ((buf (crush--current-crush-buffer)))
    (switch-to-buffer-other-window buf)))

;;; Minor mode

(defvar crush-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-s") #'crush-insert-selection)
    (define-key map (kbd "C-c C-b") #'crush-insert-buffer)
    (define-key map (kbd "C-c C-p") #'crush-insert-filepath)
    (define-key map (kbd "C-c C-c") #'crush)
    map)
  "Keymap for `crush-minor-mode'.")

;;;###autoload
(define-minor-mode crush-minor-mode
  "Minor mode for sending buffer content to the crush provider.

When enabled, provides keybindings under the `C-c C-' prefix for
sending selections, whole buffers, and file paths to the Crush
interaction buffer.

\\{crush-minor-mode-map}"
  :lighter " Crush"
  :group 'crush
  :keymap crush-minor-mode-map)

(provide 'crush)
;;; crush.el ends here
