;;; crush-debug-tools.el --- Debugging utilities for crush buffers -*- lexical-binding: t; -*-
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

;; On-demand debugging helpers for the crush chat buffer.  The crush
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
;;   M-x load-file RET <repo>/crush-debug-tools.el RET
;;
;; or, from Lisp:
;;
;;   (load "/path/to/crush.el/crush-debug-tools.el")
;;
;; It does not change any crush behavior; it only adds the commands
;; below.  crush.el itself must be loaded for the history command to
;; work (the region dump works standalone).
;;
;; Commands (run them with point in the crush buffer):
;;
;;   M-x crush-dump-buffer
;;     Dump every region in the buffer: its span, `crush-region-type',
;;     `crush-prompt-id', `crush-response-to', `crush-tool-call',
;;     read-only flag, and a 40-character text sample, plus the buffer's
;;     prompt id and response-start.  Output goes to *crush-dump*.
;;     Use this first when debugging history or tagging problems.
;;
;;   M-x crush-dump-region-type-at-point
;;     Show just the tags at point.  Quick inspection while navigating.
;;
;;   M-x crush-dump-history-for-prompt
;;     Show what the next request would carry: the reconstructed wire
;;     messages (user/assistant/tool alists) for the pending prompt,
;;     pretty-printed into *crush-dump*.  This is exactly what
;;     `crush--history-turns' would send on the next prompt.
;;
;; All output goes to a single *crush-dump* buffer, one dump per call.

;;; Code:

(require 'cl-lib)
(declare-function crush--history-turns "crush" (prompt-id))

(defun crush-dump-buffer ()
  "Dump the current crush buffer's regions and text properties.
Writes a region-by-region listing (type, prompt id, response-to,
tool-call, read-only, and a text sample) plus key buffer-local state
into the *crush-dump* buffer.  For debugging region tagging and
history replay."
  (interactive)
  (let* ((buf (current-buffer))
         (s (with-current-buffer buf
              (with-output-to-string
                (princ (format "buffer=%s mode=%s prompt-id=%S response-start=%S continue=%S\n"
                               (buffer-name buf)
                               major-mode
                               (and (boundp 'crush--prompt-id) crush--prompt-id)
                               (and (boundp 'crush--response-start)
                                    (markerp crush--response-start)
                                    (marker-position crush--response-start))
                               (and (boundp 'crush--continue) crush--continue)))
                (let ((pos (point-min))
                      (count 0))
                  (while (and (< pos (point-max)) (< count 5000))
                    (let* ((type (get-text-property pos 'crush-region-type))
                           (pid (get-text-property pos 'crush-prompt-id))
                           (rt (get-text-property pos 'crush-response-to))
                           (cc (get-text-property pos 'crush-tool-call))
                           (ro (get-text-property pos 'read-only))
                           (end (or (next-single-property-change pos 'crush-region-type
                                                                 nil (point-max))
                                    (point-max)))
                           (txt (buffer-substring-no-properties
                                 pos (min end (+ pos 40)))))
                      (princ (format "[%d..%d) type=%S pid=%S rt=%S cc=%S ro=%S txt=%S\n"
                                     pos end type pid rt cc ro txt))
                      (setq pos (if (> end pos) end (1+ pos)))
                      (setq count (1+ count)))))))))
    (with-current-buffer (get-buffer-create "*crush-dump*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert s)))
    (display-buffer "*crush-dump*")
    (message "Crush buffer dumped to *crush-dump*")))

(defun crush-dump-region-type-at-point ()
  "Show the crush region type and related tags at point.
Useful for quick inspection while navigating a crush buffer."
  (interactive)
  (let ((p (point)))
    (message "type=%S pid=%S rt=%S cc=%S at %d"
             (get-text-property p 'crush-region-type)
             (get-text-property p 'crush-prompt-id)
             (get-text-property p 'crush-response-to)
             (get-text-property p 'crush-tool-call)
             p)))

(defun crush-dump-history-for-prompt (&optional prompt-id)
  "Show the reconstructed wire messages for PROMPT-ID.
Defaults to the current buffer's pending prompt, showing the history
that the next request would carry.  Displays the message alists as
pretty-printed Lisp in the *crush-dump* buffer.  Requires crush.el to
be loaded."
  (interactive)
  (if (not (fboundp 'crush--history-turns))
      (message "crush.el not loaded; cannot reconstruct history")
    (let* ((id (or prompt-id (and (boundp 'crush--prompt-id) crush--prompt-id)))
           (s (when id
                (with-output-to-string
                  (princ (format "history for %S:\n" id))
                  (pp (crush--history-turns id))))))
      (when s
        (with-current-buffer (get-buffer-create "*crush-dump*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert s)))
        (display-buffer "*crush-dump*")
        (message "History shown in *crush-dump*")))))

(provide 'crush-debug-tools)
;;; crush-debug-tools.el ends here
