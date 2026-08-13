;;; crush-test-stream.el --- Stream protocol tests for crush  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/crush.el
;;; Version: 0.1.0
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience

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
;;; Facade stream state (idle/active/done/error), application count, and
;;; the clickable error pane.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("crush"))
    (unless (require (intern dep) nil t)
      (let* ((base (file-name-directory
                    (or buffer-file-name load-file-name default-directory)))
             (dirs (list base (expand-file-name ".." base)))
             (loaded nil))
        (dolist (dir dirs)
          (unless loaded
            (let ((file (expand-file-name (concat dep ".el") dir)))
              (when (file-exists-p file)
                (load file nil t)
                (setq loaded t)))))))))

(defun crush-test--send-capturing-completion ()
  "Send a prompt in a fresh buffer with `crush-backend-send-prompt' mocked.
Returns the completion action the facade injected."
  (let ((captured-completion nil))
    (cl-letf (((symbol-function 'crush-backend-send-prompt)
               (lambda (_backend _prompt &rest args)
                 (setq captured-completion (plist-get args :completion)))))
      (with-current-buffer (crush-test--fresh-buffer)
        (goto-char (point-max))
        (insert "test")
        (call-interactively #'crush-send-input)))
    captured-completion))

(ert-deftest crush-test/stream-progress-idle-before-send ()
  "Stream state is idle before any prompt is sent, with one application."
  (unwind-protect
      (with-current-buffer (crush-test--fresh-buffer)
        (let ((state (crush-facade--stream-progress)))
          (should (eq (plist-get state :status) 'idle))
          (should (= (plist-get state :applications) 1))))
    (crush-test--cleanup)))

(ert-deftest crush-test/stream-progress-active-after-send ()
  "Sending a prompt marks the stream active with two applications."
  (unwind-protect
      (let ((completion (crush-test--send-capturing-completion)))
        (should (functionp completion))
        (let ((buf (crush-test--buffer-name)))
          (with-current-buffer buf
            (let ((state (crush-facade--stream-progress)))
              (should (eq (plist-get state :status) 'active))
              (should (= (plist-get state :applications) 2))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/stream-progress-done-after-finalize ()
  "The completion action marks the stream done with one application."
  (unwind-protect
      (let ((completion (crush-test--send-capturing-completion)))
        (let ((buf (crush-test--buffer-name)))
          (with-current-buffer buf
            (funcall completion)
            (let ((state (crush-facade--stream-progress)))
              (should (eq (plist-get state :status) 'done))
              (should (= (plist-get state :applications) 1))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/stream-record-error-renders-clickable-pane ()
  "Recording an error marks the stream errored and renders a clickable pane."
  (unwind-protect
      (with-current-buffer (crush-test--fresh-buffer)
        (crush-facade--record-error "Boom")
        (let ((state (crush-facade--stream-progress)))
          (should (eq (plist-get state :status) 'error))
          (should (string= (plist-get state :error) "Boom")))
        (let ((ov (cl-find-if
                   (lambda (o) (overlay-get o 'crush-error-action))
                   (overlays-in (point-min) (point-max)))))
          (should (overlayp ov))
          (should (string-match-p
                   "boom"
                   (buffer-substring-no-properties
                    (overlay-start ov) (overlay-end ov))))
          (should (eq (overlay-get ov 'crush-overlay) t))
          (should (keymapp (overlay-get ov 'keymap)))
          ;; The pane is read-only like the rest of the frozen history.
          (should (get-text-property (overlay-start ov) 'read-only))))
    (crush-test--cleanup)))

(ert-deftest crush-test/clear-buffer-removes-error-pane ()
  "Crush-clear-buffer should remove the error pane overlay."
  (unwind-protect
      (with-current-buffer (crush-test--fresh-buffer)
        (crush-facade--record-error "Boom")
        (should (cl-some (lambda (o) (overlay-get o 'crush-error-action))
                         (overlays-in (point-min) (point-max))))
        (crush-clear-buffer)
        (should-not (cl-some (lambda (o) (overlay-get o 'crush-error-action))
                             (overlays-in (point-min) (point-max)))))
    (crush-test--cleanup)))

;;; Physics-free facade harness

;;; A fake process that never actually runs a subprocess: `crush-facade--send'
;;; calls the real backend transport against a dummy pipe process, so all the
;;; buffer plumbing (process mark, response-start marker, stream state) runs
;;; without spawning anything.

(defun crush-test--fake-pipe-proc ()
  "Return a disconnected pipe process usable as a fake transport process.
Uses inert filter/sentinel so the facade's `crush--process-mark' plumbing
and `delete-process' never trigger transport callbacks."
  (let ((proc (make-pipe-process :name "crush-test-facade-fake"
                                 :noquery t
                                 :coding 'binary
                                 :filter #'ignore
                                 :sentinel #'ignore)))
    proc))

(defun crush-test--with-facade (thunk)
  "Run THUNK with `crush-backend-send-prompt' mocked to a fake process.
THUNK receives (PROC COMPLETION) in the fresh crush buffer, where PROC
is the fake transport process and COMPLETION the injected continuation."
  (let ((fake (crush-test--fake-pipe-proc)))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((completion nil))
            ;; Give the fake process a live buffer so `crush--output-filter'
            ;; and the process mark work; store it on the backend's process
            ;; slot exactly as the real run backend would.
            (set-process-buffer fake (current-buffer))
            (cl-letf (((symbol-function 'crush-backend-send-prompt)
                       (lambda (backend _prompt &rest args)
                         (setq completion (plist-get args :completion))
                         (setf (crush-run-backend-process backend) fake)
                         fake)))
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)
              (funcall thunk fake completion))))
      (when (process-live-p fake)
        (delete-process fake))
      (crush-test--cleanup))))

(ert-deftest crush-test/facade-harness-active-then-complete ()
  "The facade harness should expose a live process that completes.
After send, `crush-backend-active-p' is non-nil (the fake process is
live); running the injected completion finalizes the response and the
stream transitions to done."
  (unwind-protect
      (crush-test--with-facade
       (lambda (_fake completion)
         ;; The backend's process slot holds the fake process.
         (should (crush-backend-active-p crush-active-backend))
         (should (functionp completion))
         ;; Complete the stream through the injected continuation.
         (funcall completion)
         (should-not (crush-backend-active-p crush-active-backend))
         (let ((state (crush-facade--stream-progress)))
           (should (eq (plist-get state :status) 'done))
           (should (= (plist-get state :applications) 1)))
         ;; A fresh prompt was inserted.
         (goto-char (point-max))
         (should (search-backward "crush> " nil t))))
    (crush-test--cleanup)))

(ert-deftest crush-test/facade-harness-moves-process-mark ()
  "The facade should set the process mark at point-max after send.
This is what `crush--output-filter' uses to append streamed output."
  (unwind-protect
      (crush-test--with-facade
       (lambda (fake _completion)
         (should (= (marker-position (process-mark fake)) (point-max)))
         ;; Inserting through the filter lands at the mark.
         (crush--output-filter fake "chunk")
         (goto-char (point-max))
         (should (search-backward "chunk" nil t))
         (should (= (marker-position (process-mark fake)) (point-max)))))
    (crush-test--cleanup)))

(defun crush-test--stream-source (library)
  "Return the uncompiled source of LIBRARY (strip any .elc)."
  (let ((lib (locate-library library)))
    (when (and lib (string-suffix-p ".elc" lib))
      (setq lib (replace-regexp-in-string "\\.elc\\'" ".el" lib)))
    (when lib
      (with-temp-buffer
        (insert-file-contents lib)
        (buffer-string)))))

(ert-deftest crush-test/stream-file-provides-protocol ()
  "The stream protocol lives in its own file, not the core.
State, progress, and the error pane live in `crush-stream.el'; the
facade delegates to a dedicated stream module."
  (let ((stream-src (crush-test--stream-source "crush-stream")))
    (should stream-src)
    (should (string-match-p "defun crush-facade--stream-progress" stream-src))
    (should (string-match-p "defun crush-facade--record-error" stream-src))
    (should (string-match-p "crush--stream-state" stream-src)))
  ;; crush.el should load it and no longer define the protocol itself.
  (let ((core (crush-test--stream-source "crush")))
    (should (string-match-p "\"crush-stream\"" core))
    (should-not (string-match-p "defun crush-facade--stream-progress" core))))

(provide 'crush-test-stream)
;;; crush-test-stream.el ends here
