;;; crush.el --- Interact with Crush CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Thomas Christensen

;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;; URL: https://github.com/thomasc1971/crush.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, ai, convenience
;; Prefix: crush-

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; crush.el is a GNU Emacs package for direct provider interaction: a
;; dedicated interactive buffer that sends structured prompts to AI
;; models over HTTP and receives streamed responses.  The primary
;; backend (default) talks to the Charm Hyper gateway
;; (https://hyper.charm.land) via streaming chat completions; a
;; compatibility backend drives the Crush CLI (https://github.com/
;; charmbracelet/crush) `crush run' instead.
;;
;; In addition to the dedicated chat buffer, any buffer selection can
;; be used as context.  The selection is formatted as a markdown fenced
;; code block with the file path and line numbers, then inserted
;; into the crush buffer where the user can add additional context
;; about what to do with it.
;;
;; IMPORTANT: the optional `run' backend auto-approves all tool
;; permissions (functionally `crush --yolo'); the default `hyper'
;; backend executes no local tools.  See CRUSH-SPEC.md for details on
;; the CLI's permission behavior.
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
  "Interact with Crush CLI from GNU Emacs."
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
  "Model to use for Crush requests (both backends).
When nil, the backends fall back to their defaults: the Crush CLI's
configured model, or `crush-hyper-default-model' for hyper.  The facade
passes this into the backend's model slot at buffer initialization.
Should be a model name like `claude-sonnet-4-20250514' or `gpt-4o'."
  :type '(choice (const nil) string)
  :group 'crush)

;;; Buffer-local state

;;; `crush--continue', `crush--session', `crush--response-start',
;;; `crush--pending-context', and `crush-process' are the shared
;;; buffer-local state owned by the facade (defined below); backends
;;; must not touch them.

(defcustom crush-hyper-history-limit 200
  "Maximum number of prior prompts sent as history by the hyper backend.
0 disables history entirely (each prompt is a single request).  Only
the last LIMIT complete exchanges are sent; the current turn is always
sent in full."
  :type 'integer
  :group 'crush)

(defcustom crush--continue nil
  "Whether to pass --continue to the Crush CLI.
When non-nil, the next prompt continues the active session in the folder.
Set to nil by `crush-new-session' and `crush-clear-buffer' so the next
prompt starts a fresh session.
Buffer-local."
  :type 'boolean
  :group 'crush)

(defcustom crush--session nil
  "Session ID to pass to the Crush CLI via --session.
When non-nil, continues a specific session by ID.
Takes precedence over `crush--continue'.
Buffer-local."
  :type '(choice (const nil) string)
  :group 'crush)

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
directory for the Crush CLI.  Buffer-local.")

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

;;; The `crush-backend' base struct and the `crush-backend-*' protocol
;;; live in `crush-backend.el'; the concrete backends in
;;; `crush-run-backend.el' (the `crush run' CLI) and
;;; `crush-hyper-backend.el' (direct HTTP to the Charm Hyper gateway).

(require 'crush-backend)
(require 'crush-run-backend)
(require 'crush-hyper-backend)
(require 'crush-stream)

(defvar crush-active-backend nil
  "The active crush backend for this buffer (facade-owned).
Set during buffer initialization; the facade's `crush-facade--send'
and `crush-interrupt' dispatch through it.  Buffer-local.")

(declare-function markdown-mode "markdown-mode" ())

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
    (define-key map (kbd "n") #'crush-new-session)
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

(defun crush--count-attachments-for-prompt (prompt-id)
  "Count attachments for PROMPT-ID in current buffer."
  (length (crush-get-attachments-for-prompt prompt-id)))

(defun crush--update-header-line ()
  "Update header line with current prompt ID and attachment count."
  (let* ((prompt-id (or (crush-get-prompt-at-point) crush--prompt-id))
         (attach-count (crush--count-attachments-for-prompt prompt-id))
         (attach-str (if (> attach-count 0)
                         (format " (%d attach)" attach-count)
                       "")))
    (setq header-line-format
          (list (propertize (format "Prompt: %s%s" prompt-id attach-str)
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
streamed reasoning (CoT) span and the reasoning-fold marker line.
Reasoning streams before the answer, so the answer is everything after
the reasoning region.  Returns nil when no such region exists."
  (let ((pos (text-property-any (point-min) (point-max)
                                'crush-response-to prompt-id)))
    (when pos
      (let* ((end (or (next-single-property-change pos 'crush-response-to
                                                   nil (point-max))
                      (point-max)))
             (reasoning-start (text-property-any pos end
                                                 'crush-region-type 'reasoning))
             (answer-start (or (and reasoning-start
                                    (next-single-property-change
                                     reasoning-start 'crush-region-type nil end))
                               pos)))
        (string-trim
         (buffer-substring-no-properties answer-start end))))))

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
Iterates the buffer's prompts in buffer order, stopping at PROMPT-ID
(the pending prompt, which is being sent and therefore never part of
history).  For each prior prompt emits (ROLE . TEXT) conses: `user'
with the typed input and attachments, `assistant' with the streamed
answer (reasoning excluded), and, when
`crush-hyper-history-include-reasoning' is enabled, a `reasoning'
record carrying the CoT text.  Returns nil when PROMPT-ID is the
first prompt in the buffer."
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
            (let ((resp-text (crush-get-response-text id)))
              (when resp-text
                (push (cons 'assistant resp-text) turns)))
            (when (and (boundp 'crush-hyper-history-include-reasoning)
                       crush-hyper-history-include-reasoning)
              (let ((reasoning-text (crush-get-reasoning-text id)))
                (when reasoning-text
                  (push (cons 'reasoning reasoning-text) turns)))))))
      ;; `crush-hyper-history-limit' caps the EXCHANGE count; the tail
      ;; (most recent) always survives.  Drop the surplus oldest user
      ;; turns from the front.
      (let* ((limited (nreverse turns))
             (exchanges (cl-count-if (lambda (turn) (eq (car turn) 'user))
                                     limited)))
        (if (and (boundp 'crush-hyper-history-limit)
                 (> crush-hyper-history-limit 0)
                 (> exchanges crush-hyper-history-limit))
            ;; Skip whole exchanges from the front until exactly
            ;; `crush-hyper-history-limit' user turns remain.  Stop AT
            ;; the first user turn that must be kept.
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
  "Return the history turns for BUFFER, excluding its pending prompt.
The pending prompt is the one about to be sent (its ID lives in
BUFFER's `crush--prompt-id'); the transcript stops at the last
completed exchange.  Entering BUFFER is this function's job, keeping
the backend buffer-free."
  (with-current-buffer buffer
    (crush--history-turns crush--prompt-id)))

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
      (setq-local crush--session nil)
      (setq-local crush--attachments nil)
      (setq-local crush--response-start nil)
      (setq-local crush--pending-context nil)
      (setq-local crush-active-backend nil)
      (setq-local crush--prompt-start-marker nil)
      (setq-local crush--input-start-marker nil)
      (setq-local crush--input-ring nil)
      (setq-local crush--input-ring-index 0)
      (crush-chat-mode 1)
      (crush--install-font-lock-guard t)
      (crush--update-header-line)
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t))
        (erase-buffer)
        (crush--insert-prompt))
      (crush--input-ring-read)
      (setq-local default-directory
                  (file-name-as-directory
                   (or crush-working-directory
                       (when-let ((proj (project-current)))
                         (project-root proj))
                       default-directory)))
      (setq-local crush--project-root
                  (crush--canonical-root default-directory))
      (setq-local crush-active-backend
                  (pcase crush-backend-type
                    (`hyper (crush-make-hyper-backend
                             :buffer buf
                             :working-directory default-directory
                             :base-url crush-hyper-base-url
                             :token crush-hyper-token
                             :model crush-model))
                    (_ (crush-make-run-backend
                        :buffer buf
                        :working-directory default-directory
                        :program crush-program
                        :args crush-args
                        :model crush-model))))
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

(defun crush--output-filter (proc string)
  "Insert STRING from PROC into the crush buffer at the process mark."
  (crush--debug-log 'output (format "%S" string))
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)
            (mark (process-mark proc)))
        (save-excursion
          (goto-char mark)
          (insert string)
          (set-marker mark (point)))))))

(defun crush--reasoning-start-region ()
  "Start a reasoning region at point-max if none is active.
Creates the reasoning overlay and the start marker on the first
reasoning delta streamed for the current prompt.  Returns the
overlay.  Inert (returns nil) once content has started."
  (unless (or crush--reasoning-overlay
              (markerp crush--reasoning-end))
    (let ((pos (point)))
      (setq-local crush--reasoning-start (copy-marker pos nil))
      (setq-local crush--reasoning-overlay
                  (make-overlay pos pos nil t))
      (overlay-put crush--reasoning-overlay 'crush-overlay t)
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

(defun crush--reasoning-build-marker (start end)
  "Return the propertized reasoning fold marker for region START..END.
The marker is `... reasoning (N lines, M chars)' carrying the toggle
keymap and `crush-fold-mark'."
  (propertize
   (format "... reasoning (%d lines, %d chars)"
           (count-lines start end) (- end start))
   'keymap crush--reasoning-fold-keymap
   'crush-fold-mark t))

(defun crush--reasoning-install-fold (region)
  "Install the reasoning fold on REGION (START . END) of current buffer.
Snaps the reasoning region to whole lines and auto-collapses it: a
marker line `... reasoning (N lines, M chars)' becomes real buffer
text carrying the toggle keymap and `crush-fold-mark', and the
reasoning body below it is hidden by an `invisible' overlay.  A
marker overlay paints the marker line with `crush-reasoning-face'
so the collapsed state keeps the reasoning background (font-lock
strips text-property faces, so the face must live on an overlay).
Markers keep the region shift-immune when the marker line is
inserted.  Real marker text makes the cursor land on it and lets
TAB work through native key dispatch.  Returns the body overlay."
  (let* ((start (car region))
         (end (cdr region))
         (start-m (copy-marker start))
         (end-m (copy-marker end t))
         (ov (car (cl-remove-if-not
                   (lambda (o) (overlay-get o 'crush-overlay))
                   (overlays-in start end)))))
    (when (and (overlayp ov) (> end start))
      ;; Snap to whole lines so collapsing leaves a clean single
      ;; blank separation instead of dangling partial lines.
      (save-excursion
        (goto-char start-m)
        (beginning-of-line)
        (set-marker start-m (point))
        (goto-char end-m)
        (end-of-line)
        (set-marker end-m (point)))
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t)
            body-start)
        (save-excursion
          (goto-char start-m)
          (insert (crush--reasoning-build-marker
                   (marker-position start-m) (marker-position end-m)))
          (setq body-start (point)))
        ;; Paint the marker line with the reasoning face via an
        ;; overlay (font-lock would strip a text-property face).
        (let ((mark-ov (make-overlay start-m body-start nil t)))
          (overlay-put mark-ov 'crush-overlay t)
          (overlay-put mark-ov 'face 'crush-reasoning-face))
        ;; Freeze the marker text so it is read-only like the rest of
        ;; the frozen response.
        (crush--freeze-region (marker-position start-m) body-start)
        (move-overlay ov body-start end-m)
        (overlay-put ov 'crush-fold-state 'collapsed)
        (overlay-put ov 'invisible t))
      (set-marker start-m nil)
      (set-marker end-m nil)
      ov)))

(defun crush-reasoning-toggle ()
  "Toggle the reasoning fold at point.
When point is on a reasoning fold marker (real text), expand it;
when inside an expanded reasoning region, collapse it; when inside
a collapsed (hidden) region, expand it.  Otherwise signal a
message.  Triggered by TAB / RET on the marker (real text keymap),
by `C-c c r', or directly."
  (interactive)
  (if (get-text-property (point) 'crush-fold-mark)
      ;; On the marker text: the body overlay starts right after it.
      (let ((ov (car (cl-remove-if-not
                      (lambda (o) (overlay-get o 'crush-fold-state))
                      (overlays-in (point) (1+ (line-end-position)))))))
        (when (overlayp ov)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t))
            (delete-region (line-beginning-position) (overlay-start ov)))
          ;; Remove the marker-line face overlay.
          (dolist (mo (overlays-in (line-beginning-position) (point)))
            (when (overlay-get mo 'crush-overlay)
              (delete-overlay mo)))
          (overlay-put ov 'crush-fold-state 'expanded)
          (overlay-put ov 'invisible nil)
          (message "Reasoning expanded")))
    (let ((ov (cl-find-if
               (lambda (o) (overlay-get o 'crush-fold-state))
               (overlays-at (point)))))
      (if (not (overlayp ov))
          (message "No reasoning fold at point")
        (if (eq (overlay-get ov 'crush-fold-state) 'collapsed)
            ;; Point inside the hidden body: expand.
            (progn
              (overlay-put ov 'crush-fold-state 'expanded)
              (overlay-put ov 'invisible nil)
              (message "Reasoning expanded"))
          ;; Collapse: hide the body behind a marker line.
          (crush--reasoning-install-fold
           (cons (overlay-start ov) (overlay-end ov)))
          (message "Reasoning collapsed"))))))

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

(defun crush--reasoning-region ()
  "Return (START . END) of the reasoning region, or nil.
Uses `crush--reasoning-end' when content began, else falls back to
the end of the response (point-max) for reasoning-only streams."
  (when (markerp crush--reasoning-start)
    (let ((start (marker-position crush--reasoning-start))
          (end (if (markerp crush--reasoning-end)
                   (marker-position crush--reasoning-end)
                 (point-max))))
      (when (> end start)
        (cons start end)))))

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
`crush-facade--finalize' and `crush-interrupt'."
  (when (and response-start (> response-end response-start))
    (put-text-property response-start response-end
                       'crush-prompt-id prompt-id)
    (put-text-property response-start response-end
                       'crush-response-to prompt-id)
    (put-text-property response-start response-end
                       'crush-region-type 'response)
    ;; Reasoning is a sub-region of the response: tag it over the
    ;; response tags so lookup by region type sees `reasoning'
    ;; first for the CoT span.
    (let ((reasoning-region (crush--reasoning-region)))
      (when reasoning-region
        (let ((rs (car reasoning-region))
              (re (cdr reasoning-region)))
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
        ;; Auto-collapse streamed reasoning behind its fold marker
        ;; while the markers are still live.
        (when-let* ((region (crush--reasoning-region)))
          (crush--reasoning-install-fold region))
        (crush--reasoning-reset))
      ;; Generate new prompt ID BEFORE inserting marker
      (setq-local crush--prompt-id (crush--generate-id))
      (crush--insert-prompt))
    (setq-local crush-process nil)
    (setq-local crush--response-start nil)
    (setq-local crush--attachments nil)
    ;; The facade owns process lifecycle: clear the backend's process
    ;; slot so `crush-backend-active-p' reads nil after completion.
    (when (and crush-active-backend
               (crush-run-backend-p crush-active-backend))
      (setf (crush-run-backend-process crush-active-backend) nil))
    (crush--input-ring-write)
    (crush--update-header-line)
    (goto-char (point-max))))

(defun crush-facade--finalize ()
  "Finalize the current response via the facade.
Calls `crush-facade--close-response' with the response-start marker and
current prompt ID; the backend's completion action invokes this."
  (crush-facade--stream-transition 'done 1)
  (let ((response-start (when (markerp crush--response-start)
                          (marker-position crush--response-start)))
        (prompt-id crush--prompt-id))
    (crush-facade--close-response response-start prompt-id)))
(defun crush--process-sentinel (process event)
  "Sentinel for PROCESS that handles completion and interruption for EVENT.
Invokes the backend's stored completion action (the facade's
continuation) when injected; otherwise falls back to
`crush-facade--finalize' (the run backend's legacy path)."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let* ((event-str (if (stringp event) event (format "%s" event))))
        (crush--debug-log 'sentinel (format "%s" event-str))
        (let ((completion-action
               (and crush-active-backend
                    (crush-backend-completion-action crush-active-backend))))
          (if (functionp completion-action)
              (funcall completion-action)
            (crush-facade--finalize)))))))

;;; Major mode commands

(defun crush-facade--append-delta (delta kind)
  "Append streamed DELTA of KIND (`content' or `reasoning') to the buffer.
The facade's buffer-aware consumer for streaming backends: inserts at
point-max (the growing response area), drives the reasoning overlay
(the first reasoning delta opens the region, later ones extend it, the
first content delta freezes it), and moves the cursor along reasoning
insertions while leaving point alone for content.  `crush--response-start'
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
    (let ((real-proc (crush-backend-send-prompt
                      crush-active-backend prompt
                      :context (when has-context context)
                      :session-id crush--session
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
      ;; The facade owns the per-prompt buffer plumbing that backends
      ;; must not know about: the process mark, session/process state,
      ;; and the response-start marker.  Runs only when the backend
      ;; returned a process (mocked transports may return nil).
      (when (and real-proc (processp real-proc))
        (set-marker (process-mark real-proc) (point-max))
        (setq-local crush-process real-proc)
        (setq-local crush--continue t)
        (setq-local crush--response-start (point-marker))))))

(defun crush-send-input ()
  "Send the current prompt to the Crush CLI."
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
    (crush-facade--send prompt context has-context)
    (setq-local crush--attachments nil)
    (goto-char (point-max))))

(defun crush-interrupt ()
  "Interrupt the currently running Crush process."
  (interactive)
  (let ((interrupted nil))
    (cond
     ((and crush-active-backend (crush-backend-active-p crush-active-backend))
      (crush-backend-interrupt crush-active-backend)
      (setq-local crush-process nil)
      (setq interrupted t))
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
            (when-let* ((region (crush--reasoning-region)))
              (crush--reasoning-install-fold region))
            (crush--reasoning-reset))
          (crush--insert-prompt)))
      (goto-char (point-max))
      (message "Crush process interrupted"))))

(defun crush-clear-buffer ()
  "Clear the Crush buffer output and start a fresh session."
  (interactive)
  (setq-local crush--continue nil)
  (crush-facade--stream-clear)
  ;; Delete all crush-overlay tagged overlays
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'crush-overlay)
      (delete-overlay ov)))
  (crush--reasoning-reset)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (crush--insert-prompt)))

(defun crush-new-session ()
  "Start a new Crush session.
The next prompt will omit --continue, starting a fresh session.
Subsequent prompts will continue the new active session."
  (interactive)
  (setq-local crush--continue nil)
  (message "New Crush session will start on next prompt"))

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
  "Minor mode for sending buffer content to the Crush CLI.

When enabled, provides keybindings under the `C-c C-' prefix for
sending selections, whole buffers, and file paths to the Crush
interaction buffer.

\\{crush-minor-mode-map}"
  :lighter " Crush"
  :group 'crush
  :keymap crush-minor-mode-map)

(provide 'crush)
;;; crush.el ends here
