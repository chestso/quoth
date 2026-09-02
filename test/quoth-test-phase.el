;;; quoth-test-phase.el --- Phase machine tests for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
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

;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT ANY KIND, EXPRESS OR IMPLIED,
;;; INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
;;; THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
;;; IN THE SOFTWARE.

;;; Commentary:

;; The buffer-local phase machine (quoth--phase): the single source of
;; truth for what the current turn is doing, the quoth-phase-change-hook
;; it fires, and the quoth--busy-p guard that send/interrupt key on.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth"))
    (unless (require (intern dep) nil t)
      (let* ((base (file-name-directory
                    (or buffer-file-name load-file-name default-directory)))
             (dirs (list base (expand-file-name ".." base)))
             (loaded nil))
        (dolist (dir dirs)
          (unless loaded
            (let ((file (expand-file-name
                         (concat dep ".el") dir)))
              (when (file-exists-p file)
                (load file nil t)
                (setq loaded t)))))))))

(declare-function quoth-test--fresh-buffer "quoth-test")
(declare-function quoth-test--cleanup "quoth-test")

(ert-deftest quoth-test/phase-idle-in-fresh-buffer ()
  "A fresh quoth buffer is in the idle phase."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (should (eq (plist-get quoth--phase :phase) 'idle)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-set-writes-and-runs-hook ()
  "`quoth--phase-set' is the single writer and fires the change hook.
The hook runs with the chat buffer current, receiving the new phase."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (let* ((hook-buffer nil)
               (hook-phase nil)
               (runs 0))
          (let ((quoth-phase-change-hook
                 (list (lambda (phase)
                         (setq runs (1+ runs)
                               hook-buffer (current-buffer)
                               hook-phase phase)))))
            (quoth--phase-set 'streaming :round 1)
            (should (eq (plist-get quoth--phase :phase) 'streaming))
            (should (= (plist-get quoth--phase :round) 1))
            (should (= runs 1))
            (should (eq hook-buffer (current-buffer)))
            (should (eq hook-phase 'streaming)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-set-keeps-error-and-round-unless-given ()
  "`quoth--phase-set' preserves :error and :round from the prior state."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'streaming :error "boom")
        (quoth--phase-set 'tools :round 3)
        (should (string= (plist-get quoth--phase :error) "boom"))
        (should (= (plist-get quoth--phase :round) 3)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-set-idle-resets-round-and-error ()
  "`quoth--phase-set' to idle clears the round counter and error message."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'tools :round 3 :error "boom")
        (quoth--phase-set 'idle)
        (should (eq (plist-get quoth--phase :phase) 'idle))
        (should (eq (plist-get quoth--phase :round) 0))
        (should (null (plist-get quoth--phase :error))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-busy-p-follows-phase ()
  "`quoth--busy-p' is non-nil in every phase but idle."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'idle)
        (should-not (quoth--busy-p))
        (dolist (phase '(preparing streaming tools))
          (quoth--phase-set phase)
          (should (quoth--busy-p))
          ;; `quoth--busy-p' does not mutate state.
          (should (eq (plist-get quoth--phase :phase) phase))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-send-guards-on-busy ()
  "`quoth-send-input' rejects a send while the phase is busy.
The message is the existing user-error text."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (goto-char (point-max))
        (insert "hello")
        (quoth--phase-set 'tools :round 2)
        (should-error (call-interactively #'quoth-send-input)
                      :type 'user-error)
        ;; A non-busy buffer still accepts the input (send proceeds to
        ;; the provider; the mock below intercepts it).
        (quoth--phase-set 'idle)
        (cl-letf (((symbol-function 'quoth-provider-send-prompt)
                   (lambda (&rest _args) nil)))
          (should-not (condition-case nil
                          (progn (call-interactively #'quoth-send-input) nil)
                        (user-error t)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-send-sets-preparing-then-streaming ()
  "A send moves the phase from idle to streaming once the transport fires.
With the staged prompt a cache hit today (no async stage in Phase A),
`quoth--send-prompt' transitions directly to streaming."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (goto-char (point-max))
        (insert "hello")
        (cl-letf (((symbol-function 'quoth-provider-send-prompt)
                   (lambda (&rest _args) nil)))
          (call-interactively #'quoth-send-input))
        (should (eq (plist-get quoth--phase :phase) 'streaming)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-finalize-returns-to-idle ()
  "Finalizing a completed response returns the phase to idle."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (goto-char (point-max))
        (insert "hi")
        (cl-letf (((symbol-function 'quoth-provider-send-prompt)
                   (lambda (&rest _args) nil)))
          (call-interactively #'quoth-send-input))
        (should (eq (plist-get quoth--phase :phase) 'streaming))
        (quoth--finalize-response)
        (should (eq (plist-get quoth--phase :phase) 'idle)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-interrupt-returns-to-idle ()
  "`quoth-interrupt' returns the phase to idle from any busy phase."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        ;; Simulate an in-flight turn.
        (goto-char (point-max))
        (insert "partial")
        (setq-local quoth--response-start (copy-marker (point-min)))
        (setf (quoth-provider-transport-process quoth-active-provider)
              (make-pipe-process :name "quoth-test-phase-int"
                                 :noquery t :coding 'binary
                                 :filter #'ignore :sentinel #'ignore))
        (cl-letf (((symbol-function 'quoth-openai-abort) #'ignore))
          (quoth-interrupt))
        (should (eq (plist-get quoth--phase :phase) 'idle))
        (should-not (quoth--busy-p)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-clear-resets-to-idle ()
  "`quoth-clear-buffer' resets the phase to a fresh idle state."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'tools :round 5 :error "boom")
        (quoth-clear-buffer)
        (should (eq (plist-get quoth--phase :phase) 'idle))
        (should (= (plist-get quoth--phase :round) 0))
        (should (null (plist-get quoth--phase :error))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-progress-shape ()
  "`quoth--stream-progress' reads the phase machine.
Returns the current phase as :status, the last error as :error, and
the round counter as :round."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'streaming :error "late failure")
        (let ((state (quoth--stream-progress)))
          (should (eq (plist-get state :status) 'streaming))
          (should (string= (plist-get state :error) "late failure"))
          (should (= (plist-get state :round) 0))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-record-error-keeps-message ()
  "`quoth--record-error' records the message on the phase and flags
the pending interruption; the phase stays busy until finalization."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'streaming)
        (quoth--record-error "Boom")
        (should (string= (plist-get quoth--phase :error) "Boom"))
        (should (eq quoth--pending-interrupt 'error))
        (should (quoth--busy-p)))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/phase-change-hook-default-subscriber ()
  "The default hook wiring refreshes the header line on a phase change."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (let ((header nil))
          (setq header-line-format nil)
          (quoth--phase-set 'streaming)
          (should header-line-format)))
    (quoth-test--cleanup)))

;;; The 0-timer hop and buffer-kill cleanup (same Phase A unit).

(ert-deftest quoth-test/schedule-runs-function-on-timer ()
  "`quoth--schedule' defers FN to the next event turn; firing runs it."
  (let ((ran nil))
    (let ((timer (quoth--schedule (lambda () (setq ran t)))))
      (should-not ran)
      (should (timerp timer))
      ;; Drain: run the pending zero-timeout timer.
      (sleep-for 0 5)
      (should ran))))

(ert-deftest quoth-test/kill-buffer-cleans-up-sessions ()
  "Killing a chat buffer kills its owned PTY sessions.
A session owned by the buffer is gone from the registry after kill."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer))
            (session nil))
        (with-current-buffer buf
          (setq session (quoth-process--start "sleep 30"
                                              default-directory
                                              (current-buffer)))
          (should (quoth-process-session-p session)))
        (kill-buffer buf)
        (should-not (quoth-process-session-p
                     (and session (quoth-process--find
                                   (quoth-process-session-id session))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/kill-buffer-cancels-round-timers ()
  "Killing a chat buffer cancels its armed round timers."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (let ((timer (run-at-time 1000 nil #'ignore)))
          (setq-local quoth--round-timers (list timer))
          (kill-buffer (current-buffer))
          (should-not (memq timer timer-list))))
    (quoth-test--cleanup)))

(provide 'quoth-test-phase)
;;; quoth-test-phase.el ends here
