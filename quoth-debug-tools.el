;;; quoth-debug-tools.el --- Debugging utilities for quoth buffers -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/quoth
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

;; On-demand debugging helpers for the quoth chat buffer.  The quoth
;; buffer stores all conversation state (prompts, responses, reasoning,
;; tool blocks, attachments) as text properties on the buffer content;
;; that tagged state is the single source of truth for history replay,
;; request reconstruction, and persistence.  When something goes wrong
;; on the wire (a dropped turn, a mis-tagged region, a "stray command"
;; the model misread), the fastest way to see what the buffer actually
;; holds is to dump its regions.
;;
;; This file is intentionally NOT part of the package's normal load
;; path: it is a debug tool, loaded on demand.  To use it, load the
;; file once from any buffer:
;;
;;   M-x load-file RET <repo>/quoth-debug-tools.el RET
;;
;; or, from Lisp:
;;
;;   (load "/path/to/quoth.el/quoth-debug-tools.el")
;;
;; It does not change any quoth behavior; it only adds the commands
;; below.  quoth.el itself must be loaded for the history command to
;; work (the region dump works standalone).
;;
;; Commands (run them with point in the quoth buffer):
;;
;;   M-x quoth-dump-buffer
;;     Dump every region in the buffer: its span, `quoth-region-type',
;;     `quoth-prompt-id', `quoth-response-to', `quoth-tool-call',
;;     and a 40-character text sample, plus the buffer's
;;     prompt id and response-start.  Output goes to *quoth-dump*.
;;     Use this first when debugging history or tagging problems.
;;
;;   M-x quoth-dump-region-type-at-point
;;     Show just the tags at point.  Quick inspection while navigating.
;;
;;   M-x quoth-dump-history-for-prompt
;;     Show what the next request would carry: the reconstructed wire
;;     messages (user/assistant/tool alists) for the pending prompt,
;;     pretty-printed into *quoth-dump*.  This is exactly what
;;     `quoth--history-turns' would send on the next prompt.
;;
;; All output goes to a single *quoth-dump* buffer, one dump per call.

;;; Code:

(require 'cl-lib)
(declare-function quoth--history-turns "quoth" (prompt-id))

(defun quoth-dump-buffer ()
  "Dump the current quoth buffer's regions and text properties.
Writes a region-by-region listing (type, prompt id, response-to,
tool-call, and a text sample) plus key buffer-local state
into the *quoth-dump* buffer.  For debugging region tagging and
history replay."
  (interactive)
  (let* ((buf (current-buffer))
         (s (with-current-buffer buf
              (with-output-to-string
                (princ (format "buffer=%s mode=%s prompt-id=%S response-start=%S continue=%S\n"
                               (buffer-name buf)
                               major-mode
                               (and (boundp 'quoth--prompt-id) quoth--prompt-id)
                               (and (boundp 'quoth--response-start)
                                    (markerp quoth--response-start)
                                    (marker-position quoth--response-start))
                               (and (boundp 'quoth--continue) quoth--continue)))
                (let ((pos (point-min))
                      (count 0))
                  (while (and (< pos (point-max)) (< count 5000))
                    (let* ((type (get-text-property pos 'quoth-region-type))
                           (pid (get-text-property pos 'quoth-prompt-id))
                           (rt (get-text-property pos 'quoth-response-to))
                           (cc (get-text-property pos 'quoth-tool-call))
                           (end (or (next-single-property-change pos 'quoth-region-type
                                                                 nil (point-max))
                                    (point-max)))
                           (txt (buffer-substring-no-properties
                                 pos (min end (+ pos 40)))))
                      (princ (format "[%d..%d) type=%S pid=%S rt=%S cc=%S txt=%S\n"
                                     pos end type pid rt cc txt))
                      (setq pos (if (> end pos) end (1+ pos)))
                      (setq count (1+ count)))))))))
    (with-current-buffer (get-buffer-create "*quoth-dump*")
      (erase-buffer)
      (insert s))
    (display-buffer "*quoth-dump*")
    (message "Quoth buffer dumped to *quoth-dump*")))

(defun quoth-dump-region-type-at-point ()
  "Show the quoth region type and related tags at point.
Useful for quick inspection while navigating a quoth buffer."
  (interactive)
  (let ((p (point)))
    (message "type=%S pid=%S rt=%S cc=%S at %d"
             (get-text-property p 'quoth-region-type)
             (get-text-property p 'quoth-prompt-id)
             (get-text-property p 'quoth-response-to)
             (get-text-property p 'quoth-tool-call)
             p)))

(defun quoth-dump-history-for-prompt (&optional prompt-id)
  "Show the reconstructed wire messages for PROMPT-ID.
Defaults to the current buffer's pending prompt, showing the history
that the next request would carry.  Displays the message alists as
pretty-printed Lisp in the *quoth-dump* buffer.  Requires quoth.el to
be loaded."
  (interactive)
  (if (not (fboundp 'quoth--history-turns))
      (message "quoth.el not loaded; cannot reconstruct history")
    (let* ((id (or prompt-id (and (boundp 'quoth--prompt-id) quoth--prompt-id)))
           (s (when id
                (with-output-to-string
                  (princ (format "history for %S:\n" id))
                  (pp (quoth--history-turns id))))))
      (when s
        (with-current-buffer (get-buffer-create "*quoth-dump*")
          (erase-buffer)
          (insert s))
        (display-buffer "*quoth-dump*")
        (message "History shown in *quoth-dump*")))))

(provide 'quoth-debug-tools)
;;; quoth-debug-tools.el ends here
