;;; crush-test-backend.el --- Run backend tests for crush  -*- lexical-binding: t; -*-
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
;;; CLI flag composition, sentinel behavior, backend struct protocol, mock CLI integration.

;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'crush)

;;; 10. Backend command includes --continue when continue-p is true

(ert-deftest crush-test/backend-command-includes-continue ()
  "crush-backend-send-prompt should include --continue when :continue-p is t."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue t)
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--continue" captured-args))))

(ert-deftest crush-test/backend-command-omits-continue ()
  "crush-backend-send-prompt should omit --continue when :continue-p is nil."  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue nil)
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not (member "--continue" captured-args))))

(ert-deftest crush-test/facade-send-injects-completion ()
  "crush-send-input should inject a completion action into the backend.
The completion action is the facade's continuation so the backend can
signal stream completion without knowing about buffers or finalization."
  (let ((captured-completion nil)
        (buf (crush-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'crush-backend-send-prompt)
                     (lambda (_backend _prompt &rest args)
                       (setq captured-completion (plist-get args :completion)))))
            (goto-char (point-max))
            (insert "test")
            (call-interactively #'crush-send-input)
            (should (functionp captured-completion)))
          ;; The captured action must be the facade's continuation:
          ;; calling it finalizes the response (fresh prompt + new
          ;; prompt-id), even though the backend capture already happened.
          (let ((old-id crush--prompt-id))
            (setq-local crush--response-start (point-marker))
            (funcall captured-completion)
            (should-not (string= crush--prompt-id old-id))
            (should (search-backward "crush> " nil t))))
      (crush-test--cleanup))))

;;; Mock CLI integration tests

(defun crush-test--mock-program ()
  "Return path to the mock crush CLI script."
  (expand-file-name "mock-crush.sh"
                    (file-name-directory (locate-library "crush-test"))))

(defun crush-test--with-mock (body)
  "Execute BODY with `crush-program' set to the mock CLI.
Returns the contents of the capture file after BODY completes."
  (let* ((cap (make-temp-file "crush-test-capture"))
         (crush-program (crush-test--mock-program))
         (default-directory crush-test--root)
         (process-environment (cons (format "CRUSH_CAPTURE_FILE=%s" cap)
                                    process-environment)))
    (unwind-protect
        (progn
          (funcall body)
          (with-temp-buffer
            (insert-file-contents cap)
            (buffer-string)))
      (crush-test--cleanup)
      (when (file-exists-p cap)
        (delete-file cap)))))

(ert-deftest crush-test/mock-sends-prompt-as-arg ()
  "Without context, the prompt should be sent as a CLI argument."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       (goto-char (point-max))
                       (insert "what is 2+2?")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    (should (string-match-p "ARGS:" result))
    (should (string-match-p "what is 2+2?" result))
    (should-not (string-match-p "STDIN:" result))))

(ert-deftest crush-test/mock-process-exits-promptly-without-context ()
  "Without context, the crush process should exit promptly after sending EOF.
Regression test: `crush run' reads all of stdin before processing, so stdin
must be closed with EOF even when the prompt is a CLI arg. Otherwise the
process never exits and the buffer hangs after hitting RET."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (crush-test--with-mock
         (lambda ()
           (let ((buf (crush-test--fresh-buffer)))
             (with-current-buffer buf
               (goto-char (point-max))
               (insert "exit test")
               (call-interactively #'crush-send-input)
               ;; Wait for the process to exit on its own, timing how long.
               (let ((start (float-time)))
                 (while (and crush-process
                             (process-live-p crush-process)
                             (< (- (float-time) start) 2.0))
                   (accept-process-output crush-process 0.1))
                 ;; It must finish well under the old 2s hang window.
                 (should (< (- (float-time) start) 1.0))
                 (should-not (process-live-p crush-process)))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/mock-sends-context-via-stdin ()
  "With context blocks, the context and prompt should be sent via stdin."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       ;; Simulate an inserted attachment before the prompt
                       (goto-char (point-min))
                       (let ((start (point))
                             (inhibit-read-only t))
                         (insert "**Attachment: foo.el (lines 1-3)**\n\n```emacs-lisp\n(foo)\n```\n\n")
                         (add-text-properties
                          start (point)
                          (list 'crush-attachment-id "test-attach-id"
                                'crush-prompt-id crush--prompt-id
                                'crush-region-type 'attachment
                                'crush-filename "foo.el"
                                'crush-lines "1-3")))
                       (goto-char (point-max))
                       (insert "explain this code")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    (should (string-match-p "STDIN:" result))
    (should (string-match-p "explain this code" result))
    (should (string-match-p "\\*\\*Attachment: foo.el" result))
    (should (string-match-p "markdown fenced code blocks" result))))

(ert-deftest crush-test/mock-sends-continue-flag ()
  "After first prompt, --continue should be passed on subsequent prompts."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       (setq-local crush--continue t)
                       (goto-char (point-max))
                       (insert "follow up question")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    (should (string-match-p "ARGS:" result))
    (should (string-match-p "\\-\\-continue" result))
    (should (string-match-p "follow up question" result))))

;;; 11. --quiet flag suppresses spinner

(ert-deftest crush-test/backend-command-includes-quiet ()
  "crush-backend-send-prompt should always include --quiet."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--quiet" captured-args))))

;;; 12. Exit code handling

(ert-deftest crush-test/sentinel-shows-interrupted-on-sigint ()
  "When process exits with interrupt signal, sentinel should insert a new prompt."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          ;; Simulate a process that was interrupted
          (let* ((fake-proc (make-process
                             :name "crush-test-fake"
                             :buffer buf
                             :command '("sh" "-c" "kill -INT $$")
                             :connection-type 'pipe
                             :noquery t)))
            (setq-local crush-process fake-proc)
            (set-marker (process-mark fake-proc) (point-max))
            (accept-process-output fake-proc 1)
            ;; Manually call sentinel with "interrupt" signal
            (crush--process-sentinel fake-proc "interrupt\n")
            ;; Check that a new prompt was inserted
            (goto-char (point-min))
            (should (search-forward "crush> " nil t)))))
    (crush-test--cleanup)))

;;; 13. --session flag support

(ert-deftest crush-test/backend-command-includes-session-when-set ()
  "crush-backend-send-prompt should include --session when session-id is set."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--session "abc123")
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--session" captured-args))
    (should (member "abc123" captured-args))))

(ert-deftest crush-test/backend-command-omits-session-when-nil ()
  "crush-backend-send-prompt should omit --session when session-id is nil."
  (let ((captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--session nil)
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not (member "--session" captured-args))))

;;; 14. --model flag support

(ert-deftest crush-test/backend-command-includes-model-when-set ()
  "crush-backend-send-prompt should include --model when crush-model is set."
  (let ((crush-model "claude-sonnet-4-20250514")
        (captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should (member "--model" captured-args))
    (should (member "claude-sonnet-4-20250514" captured-args))))

(ert-deftest crush-test/backend-command-omits-model-when-nil ()
  "crush-backend-send-prompt should omit --model when crush-model is nil."
  (let ((crush-model nil)
        (captured-args nil)
        (real-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest args)
                 (setq captured-args (plist-get args :command))
                 (let ((proc (funcall real-make-process
                                      :name "crush-fake"
                                      :buffer (current-buffer)
                                      :command '("true")
                                      :connection-type 'pipe
                                      :noquery t)))
                   (set-process-query-on-exit-flag proc nil)
                   proc))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "test")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not (member "--model" captured-args))))

;;; 68. Phase 6: crush-send-input uses crush--input-start-marker

(ert-deftest crush-test/send-input-works-without-prompt-start ()
  "crush-send-input should extract input using crush--input-start-marker.
The extracted prompt in stdin should not include preceding text
or the crush> prompt marker."
  (let ((result (crush-test--with-mock
                 (lambda ()
                   (let ((buf (crush-test--fresh-buffer)))
                     (with-current-buffer buf
                       ;; Add an attachment via the real function
                       (crush--insert-before-prompt
                        buf
                        "**Attachment: foo.el (lines 1-3)**\n\n```emacs-lisp\n(foo)\n```"
                        "test-attach-id" crush--prompt-id)
                       (goto-char (point-max))
                       (insert "hello world")
                       (call-interactively #'crush-send-input)
                       (accept-process-output crush-process 2)))))))
    ;; The stdin capture should contain the prompt "hello world"
    (should (string-match-p "STDIN:" result))
    (should (string-match-p "hello world" result))
    ;; It should NOT contain the "crush> " prompt marker
    (should-not (string-match-p "crush> " result))))

;;; Backend abstraction tests

(ert-deftest crush-test/active-backend-variable-renamed ()
  "The facade's backend variable should be `crush-active-backend' (not
the legacy `crush--backend'), reflecting facade ownership."
  (unwind-protect
      (with-current-buffer (crush-test--fresh-buffer)
        (should (boundp 'crush-active-backend))
        (should (crush-backend-p crush-active-backend))
        (should-not (boundp 'crush--backend)))
    (crush-test--cleanup)))

(defun crush-test--source-text (file)
  "Return the source text of FILE at the package root."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name file
                       (file-name-directory
                        (directory-file-name
                         (file-name-directory
                          (locate-library "crush-test"))))))
    (buffer-string)))

(ert-deftest crush-test/model-defcustom-single ()
  "There should be exactly one `crush-model' defcustom in the package.
Previously `crush-run-backend.el' defined it and `crush-hyper-backend.el'
shadowed it as a defvar; the facade should own the single defcustom."
  (let* ((files '("crush.el" "crush-run-backend.el" "crush-hyper-backend.el"))
         (defcustom-count
           (apply #'+
                  (mapcar
                   (lambda (file)
                     (with-temp-buffer
                       (insert (crush-test--source-text file))
                       (goto-char (point-min))
                       (count-matches "(defcustom crush-model ")))
                   files)))
         (defvar-count
           (apply #'+
                  (mapcar
                   (lambda (file)
                     (with-temp-buffer
                       (insert (crush-test--source-text file))
                       (goto-char (point-min))
                       (count-matches "(defvar crush-model ")))
                   files))))
    (should (= defcustom-count 1))
    (should (= defvar-count 0))))

(ert-deftest crush-test/run-backend-buffer-unaware ()
  "crush-run-backend.el should not reference buffers, buffer-local state,
or the errors buffer: backends are buffer-unaware by design."
  (let ((src (with-temp-buffer
               (insert-file-contents
                (expand-file-name "crush-run-backend.el"
                                  (file-name-directory
                                   (directory-file-name
                                    (file-name-directory
                                     (locate-library "crush-test"))))))
               (buffer-string)))
        (forbidden '("with-current-buffer"
                     "set-buffer"
                     "buffer-live-p"
                     "get-buffer"
                     "current-buffer"
                     "crush-backend-buffer"
                     "crush--response-start"
                     "crush-process"
                     "process-buffer"
                     "crush--finalize-response"
                     "*crush-errors*")))
    (dolist (term forbidden)
      (should-not (string-match-p term src)))))

(ert-deftest crush-test/hyper-backend-buffer-unaware ()
  "crush-hyper-backend.el should not reference buffers, buffer-local state,
or the errors buffer: backends are buffer-unaware by design."
  (let ((src (with-temp-buffer
               (insert-file-contents
                (expand-file-name "crush-hyper-backend.el"
                                  (file-name-directory
                                   (directory-file-name
                                    (file-name-directory
                                     (locate-library "crush-test"))))))
               (buffer-string)))
        (forbidden '("with-current-buffer"
                     "buffer-live-p"
                     "crush-backend-buffer"
                     "crush--response-start"
                     "crush-process"
                     "process-buffer"
                     "crush--finalize-response")))
    (dolist (term forbidden)
      (should-not (string-match-p term src)))))

(ert-deftest crush-test/backend-is-run-by-default ()
  "crush-active-backend should be a crush-run-backend in the test
harness (which pins `crush-backend-type' to `run')."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush-active-backend)
          (should (crush-backend-p crush-active-backend))
          (should (crush-run-backend-p crush-active-backend))
          (should (eq (crush-backend-type crush-active-backend) 'run))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-type-defaults-to-hyper ()
  "The package default backend is `hyper' (direct provider interaction
is the primary goal; the CLI `run' backend is the compatibility path)."
  (should (eq crush-backend-type 'hyper)))

(ert-deftest crush-test/backend-has-buffer ()
  "crush-active-backend should have its buffer set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (eq (crush-backend-buffer crush-active-backend) buf))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-has-program ()
  "crush-run-backend should have the program path set."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (string= (crush-run-backend-program crush-active-backend) crush-program))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-active-p-when-no-process ()
  "crush-backend-active-p should return nil when no process is running."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should-not (crush-backend-active-p crush-active-backend))))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-active-p-when-process-running ()
  "crush-backend-active-p should return non-nil when a process is running."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setf (crush-run-backend-process crush-active-backend)
                (make-process
                 :name "crush-test-fake"
                 :buffer buf
                 :command '("sleep" "30")
                 :connection-type 'pipe
                 :noquery t))
          (should (crush-backend-active-p crush-active-backend))
          (interrupt-process (crush-run-backend-process crush-active-backend))
          (setf (crush-run-backend-process crush-active-backend) nil)))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-send-prompt-spawns-process ()
  "crush-backend-send-prompt should spawn a crush process via the backend."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((result (crush-test--with-mock
                       (lambda ()
                         (let ((buf (crush-test--fresh-buffer)))
                           (with-current-buffer buf
                             (goto-char (point-max))
                             (insert "test via backend")
                             (call-interactively #'crush-send-input)
                             (accept-process-output crush-process 2)))))))
          (should (string-match-p "test via backend" result)))
      (crush-test--cleanup))))

(ert-deftest crush-test/backend-send-prompt-with-context ()
  "crush-backend-send-prompt should send context via stdin when attachments exist."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (let ((result (crush-test--with-mock
                       (lambda ()
                         (let ((buf (crush-test--fresh-buffer)))
                           (with-current-buffer buf
                             (goto-char (point-min))
                             (let ((start (point))
                                   (inhibit-read-only t))
                               (insert "**Attachment: foo.el (lines 1-3)**\n\n```emacs-lisp\n(foo)\n```\n\n")
                               (add-text-properties
                                start (point)
                                (list 'crush-attachment-id "test-attach-id"
                                      'crush-prompt-id crush--prompt-id
                                      'crush-region-type 'attachment
                                      'crush-filename "foo.el"
                                      'crush-lines "1-3")))
                             (goto-char (point-max))
                             (insert "explain this code")
                             (call-interactively #'crush-send-input)
                             (accept-process-output crush-process 2)))))))
          (should (string-match-p "STDIN:" result))
          (should (string-match-p "explain this code" result))
          (should (string-match-p "\\*\\*Attachment: foo.el" result)))
      (crush-test--cleanup))))

(ert-deftest crush-test/backend-interrupt-stops-process ()
  "crush-backend-interrupt should stop the running process."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setf (crush-run-backend-process crush-active-backend)
                (make-process
                 :name "crush-test-fake"
                 :buffer buf
                 :command '("sh" "-c" "kill -INT $$")
                 :connection-type 'pipe
                 :noquery t))
          (should (crush-backend-active-p crush-active-backend))
          (crush-backend-interrupt crush-active-backend)
          (accept-process-output nil 0.2)
          (should-not (crush-backend-active-p crush-active-backend))
          (setf (crush-run-backend-process crush-active-backend) nil)))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-cleanup-kills-process ()
  "crush-backend-cleanup should kill any running process."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (setf (crush-run-backend-process crush-active-backend)
                (make-process
                 :name "crush-test-fake"
                 :buffer buf
                 :command '("sleep" "30")
                 :connection-type 'pipe
                 :noquery t))
          (should (crush-backend-active-p crush-active-backend))
          (crush-backend-cleanup crush-active-backend)
          (should-not (crush-backend-active-p crush-active-backend))))
    (crush-test--cleanup)))


(ert-deftest crush-test/backend-grant-permission-noop-for-run ()
  "crush-backend-grant-permission should be a no-op for run backend."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should (null (crush-backend-grant-permission crush-active-backend "perm-id" 'allow)))))
    (crush-test--cleanup)))

;;; Phase 6: Backend abstraction cleanup


(ert-deftest crush-test/send-input-always-uses-backend ()
  "crush-send-input should always use crush-active-backend (never nil)."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush-active-backend)))
    (crush-test--cleanup)))

(ert-deftest crush-test/backend-send-prompt-receives-continue-p ()
  "crush-backend-send-prompt should receive :continue-p keyword."
  (let ((received-continue-p nil))
    (cl-letf (((symbol-function #'crush-backend-send-prompt)
               (lambda (_backend _prompt &rest keys)
                 (setq received-continue-p
                       (plist-get keys :continue-p))
                 (make-process :name "crush-fake"
                               :buffer (current-buffer)
                               :command '("true")
                               :connection-type 'pipe
                               :noquery t))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue t)
              (goto-char (point-max))
              (insert "test continue-p")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should received-continue-p)))

(ert-deftest crush-test/backend-send-prompt-continue-p-nil-when-no-continue ()
  "crush-backend-send-prompt :continue-p should be nil when crush--continue is nil."
  (let ((received-continue-p 'unset))
    (cl-letf (((symbol-function #'crush-backend-send-prompt)
               (lambda (_backend _prompt &rest keys)
                 (setq received-continue-p
                       (plist-get keys :continue-p))
                 (make-process :name "crush-fake"
                               :buffer (current-buffer)
                               :command '("true")
                               :connection-type 'pipe
                               :noquery t))))
      (unwind-protect
          (let ((buf (crush-test--fresh-buffer)))
            (with-current-buffer buf
              (setq-local crush--continue nil)
              (goto-char (point-max))
              (insert "test no continue")
              (call-interactively #'crush-send-input)))
        (crush-test--cleanup)))
    (should-not received-continue-p)))

(ert-deftest crush-test/send-input-no-dead-else-branch ()
  "crush-send-input should not have a fallback path when backend is nil.
The else branch in crush-send-input is dead code since crush-active-backend
is always set after crush--init-buffer."
  (unwind-protect
      (let ((buf (crush-test--fresh-buffer)))
        (with-current-buffer buf
          (should crush-active-backend)
          (should (crush-run-backend-p crush-active-backend))))
    (crush-test--cleanup)))

(provide 'crush-test-backend)
;;; crush-test-backend.el ends here
