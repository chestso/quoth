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

;;; Buffer-local state

(defvar crush--continue nil
  "Whether to pass --continue to the Crush CLI.
When non-nil, the next prompt continues the active session in the folder.
Set to nil by `crush-new-session' and `crush-clear-buffer' so the next
prompt starts a fresh session.
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
  (setq-local crush--continue nil))

;;; Internal helpers

(defun crush--make-prompt-marker ()
  "Create a marker at point-max for `crush-prompt-start'."
  (let ((m (make-marker)))
    (set-marker m (point-max))
    m))

(defun crush--build-command ()
  "Build the Crush CLI command list."
  (let ((base (append (list crush-program "run")
                      (when crush-args crush-args))))
    (append base
            (when crush--continue
              (list "--continue")))))

(defun crush--init-buffer (buf)
  "Initialize BUF as a crush buffer if not already initialized."
  (unless (buffer-base-buffer buf)
    (with-current-buffer buf
      (crush-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "crush> "))
      (setq-local crush-prompt-start (crush--make-prompt-marker))
      (setq-local default-directory
                  (file-name-as-directory
                   (or crush-working-directory
                       (when-let ((proj (project-current)))
                         (project-root proj))
                       default-directory))))))

(defun crush--insert-before-prompt (buf formatted)
  "Insert FORMATTED content into BUF before the `crush> ' prompt line.
The `crush-prompt-start' marker shifts automatically to stay correct."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (if (markerp crush-prompt-start)
          (let ((prompt-pos (marker-position crush-prompt-start)))
            (save-excursion
              (goto-char prompt-pos)
              (beginning-of-line)
              (insert formatted "\n\n")))
        (save-excursion
          (goto-char (point-max))
          (insert formatted "\n\n"))))))

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

(defun crush--process-sentinel (process _event)
  "Sentinel for Crush PROCESS.
Handles process completion."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (process-mark process))
          (newline)
          (insert "------------------------------------\n")
          (insert "crush> "))
        (setq-local crush-process nil)
        (setq-local crush-prompt-start (crush--make-prompt-marker))
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
    (crush--insert-before-prompt buf formatted)
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
      (crush--insert-before-prompt buf formatted)
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
