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
;; be used as context.  The selection is formatted as an org-mode
;; source block with the file path and line numbers, then inserted
;; into the crush buffer where the user can add additional context
;; about what to do with it.
;;
;; IMPORTANT: This package uses `crush run' mode, which auto-approves
;; all permissions.  Tools like `edit', `write', and `bash' execute
;; immediately without prompting for user confirmation.  This is
;; functionally equivalent to running `crush --yolo'.  See CRUSH-SPEC.md
;; for details on permission behavior and alternative client/server mode.
;;
;; See TODO.md for the full project goal and roadmap.

;;; Code:

(require 'comint)
(require 'subr-x)
(require 'project)
(require 'seq)

;;; Configuration

(defgroup crush nil
  "Interact with Crush CLI from GNU Emacs."
  :group 'tools
  :prefix "crush-")

(defcustom crush-program "crush"
  "Path to the Crush CLI executable."
  :type 'file
  :group 'crush)

(defcustom crush-args nil
  "Additional command-line arguments passed to the Crush CLI."
  :type '(repeat string)
  :group 'crush)

(defcustom crush-buffer-name "*crush*"
  "Name of the dedicated Crush interaction buffer."
  :type 'string
  :group 'crush)

(defcustom crush-working-directory nil
  "Working directory for the Crush CLI.
When nil, uses the project root if `project-current' is non-nil,
otherwise `default-directory'."
  :type '(choice (const nil) directory)
  :group 'crush)

(defcustom crush-model nil
  "Model to use for the Crush CLI.
When nil, uses the default model configured in Crush.
Should be a model name like `claude-sonnet-4-20250514' or `gpt-4o'."
  :type '(choice (const nil) string)
  :group 'crush)

;;; Buffer-local state

(defvar crush--continue nil
  "Whether to pass --continue to the Crush CLI.
When non-nil, the next prompt continues the active session in the folder.
Set to nil by `crush-new-session' and `crush-clear-buffer' so the next
prompt starts a fresh session.
Buffer-local.")

(defvar crush--session nil
  "Session ID to pass to the Crush CLI via --session.
When non-nil, continues a specific session by ID.
Takes precedence over `crush--continue'.
Buffer-local.")

(defvar crush--prompt-id nil
  "Unique ID for the current pending prompt.
Generated when prompt marker is created, used when prompt is sent.
Buffer-local.")

(defvar crush--attachments nil
  "List of attachments for current pending prompt.
Each attachment is a plist: (:id <uuid> :prompt-id <uuid> :content <string>).
Buffer-local.")

(defvar crush--response-start nil
  "Marker for where response text starts.
Set when prompt is sent, used by sentinel to tag response text.
Buffer-local.")

(defvar crush-prompt-start nil
  "Marker for the start of the current prompt.
Buffer-local.")

(defvar crush-process nil
  "The currently running Crush process, if any.
Buffer-local.")

;;; Major mode

(defvar crush-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'crush-send-input)
    (define-key map (kbd "C-c C-c") #'crush-interrupt)
    (define-key map (kbd "C-c C-k") #'crush-clear-buffer)
    (define-key map (kbd "C-c C-s") #'crush-new-session)
    (define-key map (kbd "C-c C-i") #'crush-insert-selection)
    map)
  "Keymap for `crush-mode'.")

(define-derived-mode crush-mode comint-mode "Crush"
  "Major mode for interacting with the Crush CLI.

A dedicated buffer that sends structured prompts to the Crush CLI
and receives streamed responses.  Use `crush' to start a session.

\\{crush-mode-map}"
  :group 'crush
  (setq-local comint-prompt-read-only t)
  (setq-local comint-use-prompt-regexp t)
  (setq-local comint-prompt-regexp "^crush> ")
  (setq-local crush-prompt-start (crush--make-prompt-marker))
  (setq-local crush-process nil)
  (setq-local crush--continue nil)
  (setq-local crush--session nil)
  (setq-local crush--prompt-id (crush--generate-id))
  (setq-local crush--attachments nil)
  (setq-local crush--response-start nil)
  (crush--update-header-line)
  (add-hook 'after-change-functions #'crush--after-change nil t)
  (add-hook 'post-command-hook #'crush--update-header-line nil t))

;;; Internal helpers

(defun crush--generate-id ()
  "Generate a unique ID for prompt and attachment IDs."
  (format "%s-%s"
          (format-time-string "%Y%m%d-%H%M%S")
          (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))

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
  "Tag inserted text with prompt ID if at or after prompt marker.
BEG and END are standard after-change hook arguments."
  (when (and crush-prompt-start
             (markerp crush-prompt-start)
             (>= beg (marker-position crush-prompt-start)))
    (put-text-property beg end 'crush-prompt-id crush--prompt-id))
  (crush--update-header-line))

(defun crush--make-prompt-marker ()
  "Create a marker at point-max for `crush-prompt-start'."
  (let ((m (make-marker)))
    (set-marker m (point-max))
    m))

(defun crush--build-command ()
  "Build the Crush CLI command list."
  (let ((base (append (list crush-program "run" "--quiet")
                      (when crush-args crush-args)
                      (when crush-model
                        (list "--model" crush-model)))))
    (append base
            (when crush--session
              (list "--session" crush--session))
            (when (and crush--continue (not crush--session))
              (list "--continue")))))

(defun crush--insert-prompt-marker ()
  "Insert the `crush> ' prompt marker with crush-prompt-id text property."
  (let ((start (point)))
    (insert "crush> ")
    (put-text-property start (point) 'crush-prompt-id crush--prompt-id)))

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

(defun crush--init-buffer (buf)
  "Initialize BUF as a crush buffer if not already initialized."
  (with-current-buffer buf
    (unless (eq major-mode 'crush-mode)
      ;; Generate prompt ID BEFORE inserting marker
      (setq-local crush--prompt-id (crush--generate-id))
      (crush-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (crush--insert-prompt-marker))
      (setq-local crush-prompt-start (crush--make-prompt-marker))
      (setq-local crush--attachments nil)
      (setq-local default-directory
                  (file-name-as-directory
                   (or crush-working-directory
                       (when-let ((proj (project-current)))
                         (project-root proj))
                       default-directory))))))

(defun crush--insert-before-prompt (buf formatted &optional attachment-id prompt-id)
  "Insert FORMATTED content into BUF before the `crush> ' prompt line.
The `crush-prompt-start' marker shifts automatically to stay correct.
If ATTACHMENT-ID and PROMPT-ID are provided, apply text properties."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (if (markerp crush-prompt-start)
          (let ((prompt-pos (marker-position crush-prompt-start))
                (start nil))
            (save-excursion
              (goto-char prompt-pos)
              (beginning-of-line)
              (setq start (point))
              (insert formatted "\n\n")
              (when (and attachment-id prompt-id)
                (put-text-property start (point) 'crush-attachment-id attachment-id)
                (put-text-property start (point) 'crush-prompt-id prompt-id))))
        (let ((start nil))
          (save-excursion
            (goto-char (point-max))
            (setq start (point))
            (insert formatted "\n\n")
            (when (and attachment-id prompt-id)
              (put-text-property start (point) 'crush-attachment-id attachment-id)
              (put-text-property start (point) 'crush-prompt-id prompt-id))))))))

(defun crush--format-selection (file start end)
  "Format selection as an `org-mode' source block.
FILE is the file path, START and END are the line numbers."
  (let* ((start-line (save-excursion
                       (goto-char start)
                       (line-number-at-pos)))
         (end-line (save-excursion
                     (goto-char end)
                     (line-number-at-pos)))
         (selected-text (buffer-substring-no-properties start end))
         (relative-file (if file
                            (file-relative-name
                             file
                             (or (when-let ((proj (project-current)))
                                   (project-root proj))
                                 default-directory))
                          "(no file)")))
    (format "#+begin_src text :file %s :lines %d-%d\n%s\n#+end_src"
            relative-file start-line end-line selected-text)))

(defun crush--process-filter (process output)
  "Filter function for Crush PROCESS.
Insert OUTPUT into the buffer."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((inhibit-read-only t)
            (moving (= (point) (process-mark process))))
        (save-excursion
          (goto-char (process-mark process))
          (insert output)
          (set-marker (process-mark process) (point)))
        (when moving
          (goto-char (process-mark process)))
        (force-mode-line-update)))))

(defun crush--process-sentinel (process event)
  "Sentinel for PROCESS that handles completion and interruption for EVENT."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let* ((inhibit-read-only t)
             (event-str (if (stringp event) event (format "%s" event)))
             (interrupted (string-match-p "interrupt\\|signal" event-str))
             (response-start (when (markerp crush--response-start)
                               (marker-position crush--response-start)))
             (prompt-id crush--prompt-id))
        (save-excursion
          (goto-char (process-mark process))
          (newline)
          (if interrupted
              (insert "---------- Interrupted ----------\n")
            (insert "------------------------------------\n"))
          ;; Tag response text with prompt ID it answers
          (when (and response-start (> (point) response-start))
            (put-text-property response-start (point) 'crush-response-to prompt-id))
          ;; Make everything before new prompt read-only
          (put-text-property (point-min) (point) 'read-only t)
          ;; Generate new prompt ID BEFORE inserting marker
          (setq-local crush--prompt-id (crush--generate-id))
          (crush--insert-prompt-marker))
        (setq-local crush-process nil)
        (setq-local crush--response-start nil)
        (setq-local crush-prompt-start (crush--make-prompt-marker))
        (setq-local crush--attachments nil)
        (crush--update-header-line)
        (goto-char (point-max))))))

;;; Major mode commands

(defun crush-send-input ()
  "Send the current prompt to the Crush CLI."
  (interactive)
  (when crush-process
    (user-error "Crush is still running; interrupt with C-c C-c"))
  (let* ((prompt-pos (if (markerp crush-prompt-start)
                         (marker-position crush-prompt-start)
                       (point-min)))
         (prompt-line-start (save-excursion
                              (goto-char prompt-pos)
                              (beginning-of-line)
                              (point)))
         (context (string-trim
                   (buffer-substring-no-properties (point-min) prompt-line-start)))
         (input (buffer-substring-no-properties
                 prompt-pos (line-end-position)))
         (prompt (string-trim input))
         (has-context (not (string-empty-p context)))
         (stdin-text (if has-context
                         (concat
                          "The following org-mode source blocks contain code context"
                          " from the user's editor. Each block has a :file header"
                          " indicating the source file and optional :lines for the"
                          " line range. Use this context to answer the prompt.\n\n"
                          context "\n\n" prompt "\n")
                       nil)))
    (when (string-empty-p prompt)
      (user-error "No prompt to send"))
    (goto-char (point-max))
    (newline)
    (let ((inhibit-read-only t))
      (insert "---------- Crush Response ----------\n"))
    (setq-local crush-prompt-start nil)
    (setq-local crush--attachments nil)
    ;; Mark where response will start for tagging
    (setq-local crush--response-start (point-marker))
    (let* ((args (if has-context
                     (crush--build-command)
                   (append (crush--build-command) (list prompt))))
           (process
            (make-process
             :name "crush"
             :buffer (current-buffer)
             :command args
             :connection-type 'pipe
             :filter #'crush--process-filter
             :sentinel #'crush--process-sentinel
             :stderr (get-buffer-create "*crush-errors*")
             :noquery t)))
      (setq-local crush-process process)
      (setq-local crush--continue t)
      (when (process-live-p process)
        (when has-context
          (process-send-string process stdin-text))
        (process-send-eof process))
      (goto-char (point-max))
      (set-marker (process-mark process) (point)))))

(defun crush-interrupt ()
  "Interrupt the currently running Crush process."
  (interactive)
  (when crush-process
    (interrupt-process crush-process)
    (setq-local crush-process nil)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (newline)
        (insert "------------------------------------\n")
        (insert "crush> ")))
    (setq-local crush-prompt-start (crush--make-prompt-marker))
    (goto-char (point-max))
    (message "Crush process interrupted"))
  (unless crush-process
    (message "No crush process running")))

(defun crush-clear-buffer ()
  "Clear the Crush buffer output and start a fresh session."
  (interactive)
  (setq-local crush--continue nil)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "crush> "))
  (setq-local crush-prompt-start (crush--make-prompt-marker)))

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
         (buf (get-buffer-create crush-buffer-name)))
    (crush--init-buffer buf)
    (with-current-buffer buf
      (let ((attachment-id (crush--generate-id)))
        ;; Insert with text properties
        (crush--insert-before-prompt buf formatted attachment-id crush--prompt-id)
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
    (let* ((relative-file (file-relative-name
                           file
                           (or (when-let ((proj (project-current)))
                                 (project-root proj))
                               default-directory)))
           (formatted (format "#+begin_src text :file %s\n#+end_src"
                              relative-file))
           (buf (get-buffer-create crush-buffer-name)))
      (crush--init-buffer buf)
      (with-current-buffer buf
        (let ((attachment-id (crush--generate-id)))
          (crush--insert-before-prompt buf formatted attachment-id crush--prompt-id)
          (crush--update-header-line)))
      (switch-to-buffer-other-window buf))))

;;; Entry point

;;;###autoload
(defun crush ()
  "Start an interactive Crush session.
Creates a buffer if none exists, switches to it, and prepares it for input."
  (interactive)
  (let ((buf (get-buffer-create crush-buffer-name)))
    (crush--init-buffer buf)
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
