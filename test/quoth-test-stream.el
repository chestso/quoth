;;; quoth-test-stream.el --- Stream protocol tests for quoth  -*- lexical-binding: t; -*-
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

;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

;;; Commentary:
;;; Stream state (idle/active/done/error), application count, and
;;; the clickable error pane.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth"))
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

(declare-function quoth-test--fresh-buffer "quoth-test")
(declare-function quoth-test--cleanup "quoth-test")
(declare-function quoth-test--buffer-name "quoth-test")

(defun quoth-test--send-capturing-completion ()
  "Send a prompt in a fresh buffer with `quoth-provider-send-prompt' mocked.
Returns the completion action the send loop injected, with the
0-timer hop flattened so calling it runs the finalizer inline.
The mock simulates the staged handoff: the phase moves to streaming
when the (cache-hit) prompt delivers."
  (let ((captured-completion nil))
    (quoth-test--with-immediate-schedule
     (cl-letf (((symbol-function 'quoth-provider-send-prompt)
                (lambda (_provider _prompt &rest args)
                  (setq captured-completion (plist-get args :completion))
                  (when (quoth--busy-p)
                    (quoth--phase-set 'streaming))
                  (list :stage-process nil :curl nil :done-p nil))))
       (with-current-buffer (quoth-test--fresh-buffer)
         (goto-char (point-max))
         (insert "test")
         (call-interactively #'quoth-send-input))))
    captured-completion))

(ert-deftest quoth-test/stream-progress-idle-before-send ()
  "The phase is idle before any prompt is sent."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (let ((state (quoth--stream-progress)))
          (should (eq (plist-get state :status) 'idle))
          (should (= (plist-get state :round) 0))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/stream-progress-active-after-send ()
  "Sending a prompt marks the stream active with two applications."
  (unwind-protect
      (let ((completion (quoth-test--send-capturing-completion)))
        (should (functionp completion))
        (let ((buf (quoth-test--buffer-name)))
          (with-current-buffer buf
            (let ((state (quoth--stream-progress)))
              (should (eq (plist-get state :status) 'streaming))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/stream-progress-done-after-finalize ()
  "The completion action finalizes and returns the phase to idle.
The completion hops through `quoth--schedule'; with the hop flattened,
calling the captured completion runs the finalizer inline."
  (unwind-protect
      (let ((completion (quoth-test--send-capturing-completion)))
        (let ((buf (quoth-test--buffer-name)))
          (with-current-buffer buf
            (quoth-test--with-immediate-schedule
             (funcall completion))
            (let ((state (quoth--stream-progress)))
              (should (eq (plist-get state :status) 'idle))
              (should (null (plist-get state :error)))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/stream-record-error-tags-system-pane ()
  "Recording an error marks the stream errored and renders a system pane.
The pane is a blockquote tagged `system' (never `response'), carrying a
`help-echo' and a `quoth-system-detail' plist with `:kind' `error'."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'streaming)
        (quoth--record-error "Boom")
        (let ((state (quoth--stream-progress)))
          (should (string= (plist-get state :error) "Boom")))
        (save-excursion
          (goto-char (point-min))
          (should (re-search-forward "> \\*\\*Error:\\*\\*" nil t)))
        (let ((ov (cl-find-if
                   (lambda (o) (overlay-get o 'quoth-overlay))
                   (overlays-in (point-min) (point-max)))))
          (should (overlayp ov))
          (should (eq (overlay-get ov 'face) 'error))
          (should (overlay-get ov 'help-echo))
          (let ((detail (overlay-get ov 'quoth-system-detail)))
            (should (consp detail))
            (should (eq (plist-get detail :kind) 'error)))
          (let ((type (get-text-property (overlay-start ov)
                                         'quoth-region-type)))
            (should (eq type 'system)))
          (should-not
           (text-property-any (overlay-start ov) (overlay-end ov)
                              'quoth-region-type 'response)))
        ;; The pane is inert: no dismiss keymap.
        (should-not
         (cl-some (lambda (o) (overlay-get o 'quoth-error-action))
                  (overlays-in (point-min) (point-max)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/clear-buffer-removes-error-pane ()
  "Quoth-clear-buffer should remove the error pane overlay.
Clear sweeps any `quoth-overlay'-tagged overlay, including the system
pane; the text beneath is deleted by clear-buffer's full wipe."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--phase-set 'streaming)
        (quoth--record-error "Boom")
        (should (cl-some (lambda (o) (overlay-get o 'quoth-overlay))
                         (overlays-in (point-min) (point-max))))
        (quoth-clear-buffer)
        (should-not (cl-some (lambda (o) (overlay-get o 'quoth-overlay))
                             (overlays-in (point-min) (point-max)))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/interrupt-tags-system-note ()
  "`quoth-interrupt' leaves a `system' note and stamps the partial.
The note reads `> **Interrupted.**' tagged `system' (never `response'),
with a `user'-kind detail; the partial is tagged `response' with
`quoth-interrupted' = `user'."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer)))
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "partial answer")
          (let ((old-id quoth--prompt-id))
            (setq-local quoth--response-start
                        (copy-marker (progn (goto-char (point-min))
                                            (forward-char 5) (point))))
            (setf (quoth-provider-request quoth-active-provider)
                  (make-pipe-process :name "quoth-test-int-note"
                                     :noquery t :coding 'binary
                                     :filter #'ignore :sentinel #'ignore))
            (quoth--phase-set 'streaming)
            (cl-letf (((symbol-function 'quoth-openai-abort) #'ignore))
              (quoth-interrupt))
            ;; The note is a `system' region reading `> **Interrupted.**'.
            (let ((note-start (text-property-any
                               (point-min) (point-max)
                               'quoth-region-type 'system)))
              (should note-start)
              (let ((note-end (or (next-single-property-change
                                   note-start 'quoth-region-type)
                                  (point-max))))
                (should (string-match-p
                         "> \\*\\*Interrupted\\.\\*\\*"
                         (buffer-substring-no-properties
                          note-start note-end)))
                ;; The note is never tagged `response'.
                (should-not
                 (text-property-any note-start note-end
                                    'quoth-region-type 'response)))
              ;; The note carries a user-kind detail.
              (let ((ov (cl-find-if
                         (lambda (o) (overlay-get o 'quoth-system-detail))
                         (overlays-in (point-min) (point-max)))))
                (should (overlayp ov))
                (let ((detail (overlay-get ov 'quoth-system-detail)))
                  (should (eq (plist-get detail :kind) 'user)))
                (should-not (eq (overlay-get ov 'face) 'error))))
            ;; The partial response carries the interruption marker.
            (let ((resp-start (text-property-any
                               (point-min) (point-max)
                               'quoth-response-to old-id)))
              (should resp-start)
              (should (eq (get-text-property resp-start 'quoth-region-type)
                          'response))
              (should (eq (get-text-property resp-start 'quoth-interrupted)
                          'user))))))
    (quoth-test--cleanup)))
(ert-deftest quoth-test/system-note-inserts-tagged-buffer-text ()
  "`quoth--insert-system-note' inserts blockquote text tagged `system'."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--insert-system-note "> **Error:** boom" :kind 'error)
        (let ((note-start (text-property-any
                           (point-min) (point-max)
                           'quoth-region-type 'system)))
          (should note-start)
          (let ((note-end (or (next-single-property-change
                               note-start 'quoth-region-type)
                              (point-max))))
            (should (string-match-p
                     "boom"
                     (buffer-substring-no-properties note-start note-end)))
            ;; Text is present (save-able), not display-only.
            (should (string-search "boom"
                                   (buffer-substring-no-properties
                                    (point-min) (point-max)))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/system-note-visible-on-save ()
  "The `system' pane is real buffer text included in buffer-substring."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        (quoth--insert-system-note "> **Error:** boom" :kind 'error)
        (let ((saved (buffer-substring-no-properties
                      (point-min) (point-max))))
          (should (string-match-p "> \\*\\*Error:\\*\\* boom" saved))))
    (quoth-test--cleanup)))


(ert-deftest quoth-test/error-finalization-stamps-interrupted-markers ()
  "A server failure finalizes the turn immediately with the error marker.
`quoth--record-error' sets `quoth--pending-interrupt' = `error'; the
unified finalizer then tags the partial `response' with
`quoth-interrupted' = `error', keeps the `system' pane, and inserts a
fresh input separator — no separate continue step."
  (unwind-protect
      (with-current-buffer (quoth-test--fresh-buffer)
        ;; Simulate an in-flight turn: user prompt then streamed partial.
        (let* ((prompt-id quoth--prompt-id)
               (user-start (point-max)))
          (insert "hi")
          (put-text-property user-start (point) 'quoth-region-type 'user)
          (put-text-property user-start (point) 'quoth-prompt-id prompt-id)
          (goto-char (point-max)) (newline)
          (let ((resp-start (point)))
            (insert "partial answer")
            (setq-local quoth--response-start (copy-marker resp-start)))
          ;; Failure surfaces: pane + pending-interrupt = error.
          (quoth--phase-set 'streaming)
          (quoth--record-error "stream closed before [DONE]")
          (should (eq quoth--pending-interrupt 'error))
          ;; The unified finalizer closes the partial.
          (quoth--finalize-response)
          (should (null quoth--pending-interrupt))
          ;; The partial is tagged response with the error marker.
          (let ((resp-start (text-property-any
                             (point-min) (point-max)
                             'quoth-region-type 'response)))
            (should resp-start)
            (should (eq (get-text-property resp-start 'quoth-interrupted)
                        'error)))
          ;; The system pane remains and the fresh separator follows it.
          (let ((pane-start (text-property-any
                             (point-min) (point-max)
                             'quoth-region-type 'system)))
            (should pane-start)
            (should (string-match-p "stream closed before"
                                    (buffer-substring-no-properties
                                     pane-start (point-max))))
            (should (text-property-any (or (next-single-property-change
                                            pane-start 'quoth-region-type)
                                           (point-max))
                                       (point-max)
                                       'quoth-region-type 'separator)))))
    (quoth-test--cleanup)))

;;; Test harness

;;; A fake process that never actually runs a subprocess: `quoth--send-prompt'
;;; calls the real provider transport against a dummy pipe process, so all the
;;; buffer plumbing (process mark, response-start marker, stream state) runs
;;; without spawning anything.

(defun quoth-test--fake-pipe-proc ()
  "Return a disconnected pipe process usable as a fake transport process.
Uses inert filter/sentinel so ending the response never triggers
transport callbacks."
  (let ((proc (make-pipe-process :name "quoth-test-fake"
                                 :noquery t
                                 :coding 'binary
                                 :filter #'ignore
                                 :sentinel #'ignore)))
    proc))

(defun quoth-test--with-stream (thunk)
  "Run THUNK with the provider transport mocked to a fake process.
THUNK receives (PROC COMPLETION) in the fresh quoth buffer, where PROC
is the fake transport process and COMPLETION the injected continuation.
Mocks `make-process' so the hyper provider's curl transport creates the
fake instead of spawning curl."
  (let ((fake (quoth-test--fake-pipe-proc)))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let ((completion nil))
            ;; Give the fake process a live buffer so the process mark
            ;; plumbing works.
            (set-process-buffer fake (current-buffer))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _args) fake)))
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'quoth-send-input)
              ;; Capture the injected completion from the provider slot
              ;; (the provider stores it there on send).
              (setq completion (quoth-provider-completion-action
                                quoth-active-provider))
              (quoth-test--with-immediate-schedule
               (funcall thunk fake completion)))))
      (when (process-live-p fake)
        (delete-process fake))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/stream-harness-active-then-complete ()
  "Test harness should expose a live process that completes.
After send, the session is live (the fake process); running the
injected completion finalizes the response and the stream transitions
to done."
  (unwind-protect
      (quoth-test--with-stream
       (lambda (_fake completion)
         ;; The completion is the injected continuation.
         (should (functionp completion))
         ;; Complete the stream through the injected continuation.
         (funcall completion)
         (let ((state (quoth--stream-progress)))
           (should (eq (plist-get state :status) 'idle)))
         ;; A fresh prompt was inserted.
         (goto-char (point-max))
         (should (search-backward "---" nil t))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/stream-send-keeps-usage-acc ()
  "Sending a new prompt does not clear the accumulated usage.
The previous prompt's total stays visible in the header while the next
request is in flight; it is reset lazily on the new prompt's first usage."
  (unwind-protect
      (quoth-test--with-stream
       (lambda (_fake _completion)
         ;; Seed an accumulated total for the previous prompt.
         (setq-local quoth--usage-acc
                     (list :input-tokens 8923
                           :output-tokens 68
                           :cached-tokens 8320
                           :cost-unit "hc"
                           :cost-value 0.0432696))
         (setq-local quoth--usage-prompt-id "prev")
         ;; A fresh send (new prompt) must not blank the accumulator.
         ;; Use a fresh fake process (the harness's is consumed by the
         ;; initial send).
         (let ((fake2 (quoth-test--fake-pipe-proc)))
           (set-process-buffer fake2 (current-buffer))
           (unwind-protect
               (cl-letf (((symbol-function 'make-process)
                          (lambda (&rest _args) fake2)))
                 (quoth--send-prompt "another")
                 (should (= (plist-get quoth--usage-acc :input-tokens) 8923))
                 (should (= (plist-get quoth--usage-acc :output-tokens) 68))
                 (should (= (plist-get quoth--usage-acc :cached-tokens) 8320)))
             (when (process-live-p fake2)
               (delete-process fake2))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/stream-harness-moves-process-mark ()
  "Test that the send loop sets the process mark at point-max after send.
Streamed deltas append at point-max (not via the mark)."
  (unwind-protect
      (quoth-test--with-stream
       (lambda (fake _completion)
         (should (= (marker-position (process-mark fake)) (point-max)))
         ;; Deltas streamed land at point-max.
         (quoth--append-delta "chunk" 'content)
         (goto-char (point-max))
         (should (search-backward "chunk" nil t))
         ;; Appends at point-max; the process mark stays at the
         ;; pre-delta send position, not at the append cursor.
         (should (< (marker-position (process-mark fake)) (point-max)))))
    (quoth-test--cleanup)))

(provide 'quoth-test-stream)
;;; quoth-test-stream.el ends here
