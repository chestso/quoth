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

;; crush.el is a GNU Emacs package for interacting with the Crush CLI
;; (https://github.com/charmbracelet/crush).  It provides a dedicated
;; interactive buffer that sends structured prompts to the Crush CLI
;; and receives streamed responses.
;;
;; In addition to the dedicated chat buffer, any buffer selection can
;; be used as context.  The selection is formatted as a markdown fenced
;; code block with the file path and line numbers, then inserted
;; into the crush buffer where the user can add additional context
;; about what to do with it.
;;
;; IMPORTANT: This package uses `crush run' mode, which auto-approves
;; all permissions.  Tools like `edit', `write', and `bash' execute
;; immediately without prompting for user confirmation.  This is
;; functionally equivalent to running `crush --yolo'.  See CRUSH-SPEC.md
;; for details on permission behavior.
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

;;; Buffer-local state

;;; `crush--continue', `crush--session', `crush--response-start',
;;; `crush--pending-context', `crush-process', and `crush--backend' are
;;; defined in `crush-run-backend.el' (they are shared with the hyper
;;; backend).

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

(defvar crush--backend nil
  "The active crush backend for this buffer.
Defined in `crush-run-backend.el' as a buffer-local variable; shadowed
here so the compiler knows the free references in `crush-send-input'
and `crush-interrupt' are buffer-local variables.")

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
    map)
  "Keymap under `C-c c' for crush chat-buffer commands.")

(defvar crush-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'crush-send-input)
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
      (setq-local font-lock-unfontify-region-function
                  (lambda (beg end)
                    (let ((props (remove 'rear-nonsticky
                                         (append font-lock-extra-managed-props
                                                 '(face font-lock-multiline)))))
                      (remove-list-of-text-properties beg end props))))
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
      (setq-local crush--backend nil)
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
      (setq-local crush--backend
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

(defun crush--finalize-response ()
  "Finalize the current response in the current crush buffer.
Tags the response text, inserts a fresh prompt, and resets per-prompt
state.  Shared by the run-backend sentinel and the hyper backend's
stream-completion callback."
  (let* ((inhibit-read-only t)
         (response-start (when (markerp crush--response-start)
			   (marker-position crush--response-start)))
         (prompt-id crush--prompt-id))
    (save-excursion
      (goto-char (point-max))
      (newline)
      ;; Remember where response ends (before new prompt)
      (let ((response-end (point)))
        ;; Tag the full response text with the prompt ID it answers and
        ;; region type.  Deltas were inserted with modification hooks
        ;; suppressed, so this is the only tagging the response gets.
        (when (and response-start (> response-end response-start))
          (put-text-property response-start response-end
                             'crush-prompt-id prompt-id)
          (put-text-property response-start response-end
                             'crush-response-to prompt-id)
          (put-text-property response-start response-end
                             'crush-region-type 'response)))
      ;; Generate new prompt ID BEFORE inserting marker
      (setq-local crush--prompt-id (crush--generate-id))
      (crush--insert-prompt))
    (setq-local crush-process nil)
    (setq-local crush--response-start nil)
    (setq-local crush--attachments nil)
    (crush--input-ring-write)
    (crush--update-header-line)
    (goto-char (point-max))))

(defun crush--process-sentinel (process event)
  "Sentinel for PROCESS that handles completion and interruption for EVENT."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let* ((event-str (if (stringp event) event (format "%s" event))))
        (crush--debug-log 'sentinel (format "%s" event-str))
        (crush--finalize-response)))))

;;; Major mode commands

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
    (crush-backend-send-prompt crush--backend prompt
                               :context (when has-context context)
                               :session-id crush--session
                               :continue-p crush--continue)
    (setq-local crush--attachments nil)
    (goto-char (point-max))))

(defun crush-interrupt ()
  "Interrupt the currently running Crush process."
  (interactive)
  (if (and crush--backend (crush-backend-active-p crush--backend))
      (progn
        (crush-backend-interrupt crush--backend)
        (setq-local crush-process nil)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (newline)
            (crush--insert-prompt)))
        (goto-char (point-max))
        (message "Crush process interrupted"))
    (when crush-process
      (interrupt-process crush-process)
      (setq-local crush-process nil)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (newline)
          (crush--insert-prompt)))
      (goto-char (point-max))
      (message "Crush process interrupted"))
    (unless crush-process
      (message "No crush process running"))))

(defun crush-clear-buffer ()
  "Clear the Crush buffer output and start a fresh session."
  (interactive)
  (setq-local crush--continue nil)
  ;; Delete all crush-overlay tagged overlays
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'crush-overlay)
      (delete-overlay ov)))
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
