;;; quoth-stream.el --- Facade stream protocol for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/quoth
;;; Version: 0.1.0
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

;; The facade stream protocol for quoth.el: buffer-local stream state
;; (idle/active/done/error), the progress query that exposes the
;; application count, and the clickable read-only error pane rendered on
;; stream failure.  The facade (quoth.el) owns the state transitions;
;; this file just provides the protocol and the pane rendering, keeping
;; the core file free of stream bookkeeping.

;;; Code:

(require 'cl-lib)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the sibling from this file's
;;; own directory so both flycheck and package-installed loads work.
(eval-and-compile
  (dolist (dep '("quoth-provider"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defvar quoth-active-provider nil
  "The active quoth provider for this buffer; defined in `quoth.el'.
Declared here so the compiler accepts the free reference in
`quoth-facade--stream-progress'.")

(defvar quoth--stream-state nil
  "Facade stream state plist: (:status STATUS :error ERR :count N).
STATUS is `idle', `active', `done', or `error'.  ERR is the error
message when STATUS is `error', and COUNT is the application count,
meaning the runnable pipeline, inflight, and blocked applications.
Buffer-local.")

(defun quoth-facade--stream-transition (status &optional count error)
  "Move the facade stream state to STATUS with optional COUNT and ERROR.
Records the transition in `quoth--stream-state'."
  (setq-local quoth--stream-state
              (list :status status
                    :error error
                    :count (or count
                               (plist-get quoth--stream-state :count)
                               1))))

(defun quoth-facade--stream-progress ()
  "Return the facade stream state plist (status, error, applications).
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

(defun quoth-facade--stream-clear ()
  "Reset the facade stream state to a fresh `idle' state."
  (setq-local quoth--stream-state
              (list :status 'idle :error nil :count 1)))

(defun quoth-facade--record-error (message)
  "Record an error MESSAGE on the facade stream and render the error pane.
Marks the stream `error' and inserts a clickable, read-only error pane
overlay at point-max carrying `quoth-error-action' (so
`quoth-clear-buffer' sweeps it)."
  (quoth-facade--stream-transition 'error nil message)
  (let ((inhibit-read-only t)
        (pos (point-max)))
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
                                    map)))
        (add-text-properties start (point) '(read-only t))))))

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
      (quoth-facade--stream-clear)
      (message "Error dismissed"))))

(provide 'quoth-stream)
;;; quoth-stream.el ends here
