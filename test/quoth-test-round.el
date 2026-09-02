;;; quoth-test-round.el --- Tool-round orchestrator tests for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience

;;; This file is not part of GNU Emacs.

;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;; of this software and associated documentation files (the "Software"), to deal
;;; in the Software without restriction, including without limitation the
;;; rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
;;; sell copies of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:

;;; The above copyright notice and this permission notice shall be included in all
;;; copies or substantial portions of the Software.

;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
;;; THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

;;; Commentary:

;; The round orchestrator (quoth--round-dispatch and friends): the
;; event chain from a tool_calls stream to the follow-up request.
;; Placeholder blocks, completion fills, the exactly-once and
;; round-liveness guards, the follow-up composition, and interrupt
;; mid-round.  All tests mock the provider's tool-calls vector and the
;; registry, and flatten the 0-timer hop, so the chain runs
;; deterministically with no subprocesses.

;;; Code:

(require 'ert)
(require 'cl-lib)

(declare-function quoth-test--fresh-buffer "quoth-test" ())
(declare-function quoth-test--cleanup "quoth-test" ())
(declare-function quoth-test--with-immediate-schedule "quoth-test" (&rest body))

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

(defvar quoth-test--round-sends nil
  "Registry of `quoth-provider-send-prompt' calls made by the round tests.
Each entry is the arguments plist, appended per call.")

(defun quoth-test--with-round (tool-calls entries thunk)
  "Run THUNK in a fresh chat buffer wired for a tool round.
TOOL-CALLS is the vector the transport's SSE state reports (the shape
`quoth-provider--tool-calls' returns); ENTRIES is the
`quoth-openai-tool-registry' value the dispatch uses.  The follow-up
send is captured into `quoth-test--round-sends' instead of hitting a
provider, and the 0-timer hop is flattened so the chain is
synchronous.  THUNK runs in the chat buffer."
  (let ((quoth-test--round-sends nil)
        (quoth-tools-enabled t))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (setq-local quoth--response-start (point-marker))
          (let ((fake-proc (make-pipe-process :name "quoth-round-test"
                                              :noquery t
                                              :coding 'binary)))
            (process-put fake-proc :quoth-sse
                         (list :tool-calls tool-calls))
            (setf (quoth-provider-transport-process quoth-active-provider)
                  fake-proc)
            (unwind-protect
                (quoth-test--with-immediate-schedule
                 (let ((quoth-openai-tool-registry entries))
                   (cl-letf
                       (((symbol-function 'quoth-provider-send-prompt)
                         (lambda (_provider prompt &rest args)
                           (push (cons prompt args) quoth-test--round-sends)
                           nil)))
                     (funcall thunk))))

              (when (process-live-p fake-proc) (delete-process fake-proc)))))
      (quoth-test--cleanup))))

(defun quoth-test--call-entry (id name &optional args-json)
  "Return one SSE tool-call vector entry with id ID, name NAME."
  (list (cons 'id id)
        (cons 'type "function")
        (cons 'function
              (list (cons 'name name)
                    (cons 'arguments (or args-json "{}"))))))

(defun quoth-test--stub-entry (name handler)
  "Return a registry entry NAME running HANDLER (call on-done) -> cancel.
HANDLER's return value is the cancel thunk (or nil)."
  (cons name (lambda (call on-done)
               (push (cons (quoth-openai-tool-call-id call)
                           (quoth-openai-tool-call-args call))
                     quoth-test--round--entries-run)
               (funcall handler call on-done))))

(defvar quoth-test--round--entries-run nil
  "Registry of entries dispatched by the live round test, newest first.")

(defmacro quoth-test--with-dispatch (tool-calls entries &rest body)
  "Run BODY with the round dispatched in a fresh wired buffer.
Phase `tools' and a non-zero tool-loop count are preset (the state
finalize leaves behind); BODY runs after dispatch."
  (declare (indent 2))
  `(quoth-test--with-round
    ,tool-calls ,entries
    (lambda ()
      (setq-local quoth--tool-loop-count 1)
      (quoth--phase-set 'tools :round 1)
      (quoth--round-dispatch)
      ,@body)))

(defconst quoth-test--round-status-text "⏳ running…"
  "The placeholder status line (must match `quoth--tool-status-running').")

;;; 1. Placeholder blocks

(ert-deftest quoth-test/round-placeholder-tagged-tool-region ()
  "Dispatch inserts a placeholder block tagged as the tool region.
The block carries the wire metadata (id/name/args-json) and the
prompt id; the status span shows the running status."
  (let ((entries (list (quoth-test--stub-entry
                        "exec_command"
                        (lambda (_call _on-done) nil)))))
    (quoth-test--with-dispatch
     (vector (quoth-test--call-entry "call_1" "exec_command"
                                     "{\"cmd\":\"echo hi\"}"))
     entries
     (should (eq (plist-get quoth--phase :phase) 'tools))
     (let ((pos (text-property-any (point-min) (point-max)
                                   'quoth-region-type 'tool)))
       (should pos)
       (should (string-match-p (regexp-quote quoth-test--round-status-text)
                               (buffer-substring-no-properties
                                pos (point-max))))
       (should (equal (get-text-property pos 'quoth-tool-call)
                      (list :id "call_1"
                            :name "exec_command"
                            :args-json "{\"cmd\":\"echo hi\"}")))
       (should (string= (get-text-property pos 'quoth-prompt-id)
                        quoth--prompt-id)))
     ;; The round state is armed with one pending call.
     (should (= (plist-get quoth--round :pending) 1))
     (should (= (length (plist-get quoth--round :calls)) 1)))))

(ert-deftest quoth-test/round-placeholder-preserves-declared-order ()
  "Parallel calls get placeholder blocks in the SSE vector's order."
  (let ((entries (list (quoth-test--stub-entry
                        "exec_command"
                        (lambda (_call _on-done) nil)))))
    (quoth-test--with-dispatch
     (vector (quoth-test--call-entry "call_a" "exec_command"
                                     "{\"cmd\":\"echo a\"}")
             (quoth-test--call-entry "call_b" "exec_command"
                                     "{\"cmd\":\"echo b\"}"))
     entries
     (let ((ids nil)
           (pos (point-min)))
       (while pos
         (let ((call (get-text-property pos 'quoth-tool-call)))
           (when call
             (push (plist-get call :id) ids))
           (setq pos (and (< pos (point-max))
                          (next-single-property-change
                           pos 'quoth-tool-call nil (point-max))))))
       (should (equal (nreverse ids) '("call_a" "call_b"))))
     (should (= (plist-get quoth--round :pending) 2)))))

;;; 2. Completion fills

(ert-deftest quoth-test/round-fill-tags-tool-output-span ()
  "A completed call's fill replaces the status with the fenced result.
The raw result span is tagged `tool-output' (the wire tool content),
nested inside the contiguous `tool' span carrying the call metadata."
  (let ((entries (list (quoth-test--stub-entry
                        "exec_command"
                        (lambda (_call on-done)
                          (funcall on-done
                                   (cons "Process exited with code 0\nOutput:\nhi"
                                         0))
                          nil)))))
    (quoth-test--with-dispatch
     (vector (quoth-test--call-entry "call_1" "exec_command"
                                     "{\"cmd\":\"echo hi\"}"))
     entries
     ;; The stub delivered inline; the hop is flattened, so the fill
     ;; and the follow-up already ran.
     (should (null quoth--round))
     (let* ((pos (text-property-any (point-min) (point-max)
                                    'quoth-region-type 'tool))
            (block (buffer-substring-no-properties pos (point-max))))
       (should (string-match-p "Process exited with code 0" block))
       (should-not (string-match-p
                    (regexp-quote quoth-test--round-status-text) block)))
     (let ((raw-pos (text-property-any (point-min) (point-max)
                                       'quoth-region-type 'tool-output)))
       (should raw-pos)
       (should (string-match-p
                "Process exited with code 0"
                (buffer-substring-no-properties
                 raw-pos
                 (or (next-single-property-change raw-pos
                                                  'quoth-region-type)
                     (point-max)))))))))

(ert-deftest quoth-test/round-completion-fires-one-followup ()
  "The last completion fires exactly one follow-up request.
The continuation is composed from the buffer: the user message, then
the assistant tool_calls + tool result pair."
  (let ((entries (list (quoth-test--stub-entry
                        "exec_command"
                        (lambda (_call on-done)
                          (funcall on-done
                                   (cons "Process exited with code 0\nOutput:\nhi"
                                         0))
                          nil)))))
    (quoth-test--with-round
     (vector (quoth-test--call-entry "call_1" "exec_command"
                                     "{\"cmd\":\"echo hi\"}"))
     entries
     (lambda ()
       ;; A tagged user turn seeds the buffer (the source of truth).
       (goto-char (point-max))
       (insert "run it")
       (put-text-property (marker-position quoth--input-start-marker)
                          (point-max)
                          'quoth-region-type 'user)
       (put-text-property (marker-position quoth--input-start-marker)
                          (point-max)
                          'quoth-prompt-id quoth--prompt-id)
       ;; The response region starts after the user turn (as it does
       ;; on a real send); otherwise dispatch's region tagging
       ;; would retag the user text as response.
       (setq-local quoth--response-start (point-marker))
       (setq-local quoth--tool-loop-count 1)
       (quoth--phase-set 'tools :round 1)
       (quoth--round-dispatch)
       (should (= (length quoth-test--round-sends) 1))
       (let* ((send (car quoth-test--round-sends))
              (continuation (plist-get (cdr send) :continuation)))
         (should (string= (car send) ""))
         ;; user + assistant(tool_calls) + tool result.
         (should (= (length continuation) 3))
         ;; user
         (should (string= (cdr (assq 'role (nth 0 continuation))) "user"))
         ;; assistant with tool_calls
         (should (string= (cdr (assq 'role (nth 1 continuation)))
                          "assistant"))
         (let ((tcs (cdr (assq 'tool_calls (nth 1 continuation)))))
           (should (vectorp tcs))
           (should (string= (cdr (assq 'id (aref tcs 0))) "call_1")))
         ;; tool result
         (should (string= (cdr (assq 'role (nth 2 continuation))) "tool"))
         (should (string= (cdr (assq 'tool_call_id (nth 2 continuation)))
                          "call_1"))
         (should (string-match-p "Process exited with code 0"
                                 (cdr (assq 'content
                                            (nth 2 continuation))))))
       ;; The phase returned to streaming for the follow-up round.
       (should (eq (plist-get quoth--phase :phase) 'streaming))))))

(ert-deftest quoth-test/round-followup-waits-for-all-calls ()
  "The follow-up fires only after every parallel call completed.
Two calls: completing the first leaves the round pending (no send);
completing the second fires the one follow-up."
  (let ((first-on-done nil)
        (second-on-done nil))
    (let ((entries
           (list (quoth-test--stub-entry
                  "exec_command"
                  (lambda (_call on-done)
                    (unless first-on-done (setq first-on-done on-done))
                    (lambda () nil)))
                 (quoth-test--stub-entry
                  "write_file"
                  (lambda (_call on-done)
                    (unless second-on-done (setq second-on-done on-done))
                    (lambda () nil))))))
      (quoth-test--with-dispatch
       (vector (quoth-test--call-entry "call_a" "exec_command"
                                       "{\"cmd\":\"echo a\"}")
               (quoth-test--call-entry "call_b" "write_file"
                                       "{\"path\":\"/x\",\"content\":\"y\"}"))
       entries
       ;; Neither entry delivered yet: no follow-up.
       (should (null quoth-test--round-sends))
       (should (= (plist-get quoth--round :pending) 2))
       (funcall first-on-done (cons "Process exited with code 0\nOutput:\na" 0))
       (should (null quoth-test--round-sends))
       (should (= (plist-get quoth--round :pending) 1))
       (funcall second-on-done (cons "Process exited with code 0\nOutput:\nWrote /x" 0))
       (should (= (length quoth-test--round-sends) 1))))))

(ert-deftest quoth-test/round-on-done-delivery-is-exactly-once ()
  "A duplicate on-done delivery fills the block and follows up once.
A racing window/sentinel pair delivering the same call's result twice
reports once: the second delivery observes the done flag."
  (let ((deliver nil))
    (let ((entries
           (list (quoth-test--stub-entry
                  "exec_command"
                  (lambda (_call on-done)
                    (setq deliver on-done)
                    (lambda () nil))))))
      (quoth-test--with-dispatch
       (vector (quoth-test--call-entry "call_1" "exec_command"
                                       "{\"cmd\":\"echo hi\"}"))
       entries
       (should (functionp deliver))
       (funcall deliver (cons "Process exited with code 0\nOutput:\nhi" 0))
       (should (= (length quoth-test--round-sends) 1))
       (should (null quoth--round))
       ;; The late duplicate delivery no-ops.
       (funcall deliver (cons "Process exited with code 0\nOutput:\ndup" 0))
       (should (= (length quoth-test--round-sends) 1))
       (should-not (search-forward "dup" nil t))))))

(ert-deftest quoth-test/round-late-delivery-after-abandon-noops ()
  "A delivery arriving after the round was abandoned changes nothing.
Interrupt closes the turn and fills the pending block; a late
completion (a window timer that raced the interrupt) observes the
cleared round and no-ops."
  (let ((deliver nil)
        (cancel-called 0))
    (let ((entries
           (list (quoth-test--stub-entry
                  "exec_command"
                  (lambda (_call on-done)
                    (setq deliver on-done)
                    (lambda () (cl-incf cancel-called)))))))
      (quoth-test--with-dispatch
       (vector (quoth-test--call-entry "call_1" "exec_command"
                                       "{\"cmd\":\"sleep 5\"}"))
       entries
       (cl-letf (((symbol-function 'quoth-provider-interrupt) #'ignore))
         (quoth-interrupt))
       (should (= cancel-called 1))
       (should (null quoth--round))
       (should (eq (plist-get quoth--phase :phase) 'idle))
       ;; The pending block holds the interrupted result text.
       (goto-char (point-min))
       (should (search-forward "interrupted by user" nil t))
       (search-backward "interrupted by user")
       (should (eq (get-text-property (match-beginning 0)
                                      'quoth-region-type)
                   'tool-output))
       ;; The late delivery no-ops: no fill, no follow-up.
       (funcall deliver (cons "Process exited with code 0\nOutput:\nlate" 0))
       (should (null quoth-test--round-sends))
       (goto-char (point-min))
       (should-not (search-forward "late" nil t))))))

;;; 3. Interrupt mid-round

(ert-deftest quoth-test/round-interrupt-fills-pending-blocks ()
  "Interrupt cancels every pending call and fills its block.
Each cancel thunk runs once; each pending block carries the
interrupted result as valid wire tool content; the phase returns to
idle and the turn is closed."
  (let ((cancel-called 0))
    (let ((entries
           (list (quoth-test--stub-entry
                  "exec_command"
                  (lambda (_call _on-done)
                    (lambda () (cl-incf cancel-called)))))))
      (quoth-test--with-dispatch
       (vector (quoth-test--call-entry "call_a" "exec_command"
                                       "{\"cmd\":\"sleep 5\"}")
               (quoth-test--call-entry "call_b" "exec_command"
                                       "{\"cmd\":\"sleep 5\"}"))
       entries
       (cl-letf (((symbol-function 'quoth-provider-interrupt) #'ignore))
         (quoth-interrupt))
       (should (= cancel-called 2))
       (should (null quoth--round))
       (should (eq (plist-get quoth--phase :phase) 'idle))
       ;; Both blocks hold the interrupted result; both are complete
       ;; tool blocks (no status spans remain).
       (goto-char (point-min))
       (let ((count 0))
         (while (search-forward "interrupted by user" nil t)
           (cl-incf count))
         (should (= count 2)))
       (should-not (search-backward
                    (regexp-quote quoth-test--round-status-text)
                    nil t))))))

;;; 4. Deleted-block fallback

(ert-deftest quoth-test/round-fill-falls-back-on-deleted-block ()
  "A fill whose markers were destroyed appends the block at point-max.
The user deleted the pending block; the completed block is still
rendered (never dropped), and the follow-up composes from the buffer."
  (let ((deliver nil))
    (let ((entries
           (list (quoth-test--stub-entry
                  "exec_command"
                  (lambda (_call on-done)
                    (setq deliver on-done)
                    (lambda () nil))))))
      (quoth-test--with-round
       (vector (quoth-test--call-entry "call_1" "exec_command"
                                       "{\"cmd\":\"echo hi\"}"))
       entries
       (lambda ()
         (setq-local quoth--tool-loop-count 1)
         (quoth--phase-set 'tools :round 1)
         (quoth--round-dispatch)
         ;; The user deletes the pending block's whole span, collapsing
         ;; the status markers.
         (let ((state (car (plist-get quoth--round :calls))))
           (delete-region (plist-get state :status-start)
                          (plist-get state :status-end))
           (funcall deliver
                    (cons "Process exited with code 0\nOutput:\nhi" 0)))
         (should (null quoth--round))
         (should (= (length quoth-test--round-sends) 1))
         ;; The fallback appended a complete block at point-max.
         (goto-char (point-max))
         (should (search-backward "Process exited with code 0" nil t))
         (should (eq (get-text-property (match-beginning 0)
                                        'quoth-region-type)
                     'tool-output))
         ;; The follow-up carries the completed pair from the buffer.
         (let ((continuation (plist-get (cdr (car quoth-test--round-sends))
                                        :continuation)))
           (should (string-match-p
                    "Process exited with code 0"
                    (cdr (assq 'content (car (last continuation))))))))))))

;;; 5. Cap and malformed calls

(ert-deftest quoth-test/round-cap-closes-without-dispatch ()
  "At the round cap, finalize closes the turn without dispatching."
  (let ((entries (list (quoth-test--stub-entry
                        "exec_command"
                        (lambda (_call _on-done) nil)))))
    (let ((quoth-tool-loop-max 2))
      (quoth-test--with-round
       (vector (quoth-test--call-entry "call_1" "exec_command"
                                       "{\"cmd\":\"echo hi\"}"))
       entries
       (lambda ()
         ;; Two rounds already ran.
         (setq-local quoth--tool-loop-count 2)
         (quoth--phase-set 'streaming)
         (quoth--finalize-response)
         (should (eq (plist-get quoth--phase :phase) 'idle))
         (should (null quoth--round))
         (should (null quoth-test--round-sends))
         ;; A fresh input separator was inserted (the turn closed).
         (goto-char (point-max))
         (should (search-backward "---" nil t)))))))

(ert-deftest quoth-test/round-malformed-calls-close-the-turn ()
  "Dispatch with no usable call closes the turn.
Entries missing an id or a function name cannot run; the turn closes
through the unified finalizer instead of hanging in `tools'."
  (let ((entries (list (quoth-test--stub-entry
                        "exec_command"
                        (lambda (_call _on-done) nil)))))
    (quoth-test--with-round
     (vector (list (cons 'type "function"))
             (list (cons 'id "no-fn")))
     entries
     (lambda ()
       (setq-local quoth--tool-loop-count 1)
       (quoth--phase-set 'tools :round 1)
       (quoth--round-dispatch)
       (should (eq (plist-get quoth--phase :phase) 'idle))
       (should (null quoth--round))
       (should (null quoth-test--round-sends))))))

;;; 6. Unknown tool errors complete the round

(ert-deftest quoth-test/round-unknown-tool-delivers-error-and-proceeds ()
  "An unknown tool name delivers an error result and the round proceeds.
The block fills with the error text; the follow-up still fires."
  (let ((entries nil))
    (quoth-test--with-dispatch
     (vector (quoth-test--call-entry "call_1" "no_such_tool"
                                     "{\"x\":1}"))
     entries
     (should (null quoth--round))
     (should (= (length quoth-test--round-sends) 1))
     (goto-char (point-min))
     (should (search-forward "unknown tool" nil t)))))

;;; 7. Phase transitions across the round

(ert-deftest quoth-test/round-phase-transitions ()
  "The phase moves streaming → tools → streaming across a round.
Finalize with pending calls sets `tools' and schedules dispatch; the
dispatch runs the calls; the follow-up returns the phase to
`streaming' with the round counter advanced."
  (let ((entries (list (quoth-test--stub-entry
                        "exec_command"
                        (lambda (_call on-done)
                          (funcall on-done
                                   (cons "Process exited with code 0\nOutput:\nhi"
                                         0))
                          nil)))))
    (quoth-test--with-round
     (vector (quoth-test--call-entry "call_1" "exec_command"
                                     "{\"cmd\":\"echo hi\"}"))
     entries
     (lambda ()
       (setq-local quoth--tool-loop-count 0)
       (quoth--phase-set 'streaming)
       (quoth--finalize-response)
       ;; With the hop flattened, finalize ran the whole chain inline:
       ;; dispatch, the inline completion, and the follow-up send.
       (should (eq (plist-get quoth--phase :phase) 'streaming))
       (should (= quoth--tool-loop-count 1))
       (should (= (plist-get quoth--phase :round) 1))
       (should (= (length quoth-test--round-sends) 1))))))

(provide 'quoth-test-round)
;;; quoth-test-round.el ends here
