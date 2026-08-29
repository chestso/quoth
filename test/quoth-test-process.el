;;; quoth-test-process.el --- Process-handler tests for quoth  -*- lexical-binding: t; -*-
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
;;; Tests for `quoth-process.el': the session registry, PTY process
;;; spawning, output collection, yield, stdin writes, and cleanup.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth" "quoth-process"))
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

(defun quoth-test-process--owner ()
  "Return a throwaway buffer to use as a session owner."
  (generate-new-buffer " *quoth-process-owner*"))

(defun quoth-test-process--cleanup-owner (owner)
  "Kill OWNER and any sessions it owns."
  (quoth-process--cleanup-buffer owner)
  (when (buffer-live-p owner)
    (kill-buffer owner)))

;;; 1. Session registry

(ert-deftest quoth-test-process/registry-starts-empty ()
  "The session registry is empty at load time."
  (should (boundp 'quoth-process--sessions))
  (should (hash-table-p quoth-process--sessions))
  (should (integerp quoth-process--counter)))

(ert-deftest quoth-test-process/sessions-get-monotonic-ids ()
  "Session ids come from a monotonic counter and are unique."
  (let ((owner (quoth-test-process--owner))
        (a nil)
        (b nil))
    (unwind-protect
        (progn
          (setq a (quoth-process--start "true" nil owner)
                b (quoth-process--start "true" nil owner))
          (quoth-process--collect a)
          (quoth-process--collect b)
          (should (integerp (quoth-process-session-id a)))
          (should (integerp (quoth-process-session-id b)))
          (should-not (= (quoth-process-session-id a)
                         (quoth-process-session-id b))))
      (quoth-process--kill a)
      (quoth-process--kill b)
      (quoth-test-process--cleanup-owner owner))))

;;; 2. Shell selection

(ert-deftest quoth-test-process/shell-type-detects-common-shells ()
  "`quoth-process--shell-type' maps binary names to their shell type."
  (should (eq (quoth-process--shell-type "bash") 'bash))
  (should (eq (quoth-process--shell-type "/bin/bash") 'bash))
  (should (eq (quoth-process--shell-type "zsh") 'zsh))
  (should (eq (quoth-process--shell-type "sh") 'sh))
  (should (eq (quoth-process--shell-type "cmd") 'cmd))
  (should (eq (quoth-process--shell-type "cmd.exe") 'cmd))
  (should (eq (quoth-process--shell-type "powershell") 'powershell))
  (should (eq (quoth-process--shell-type "pwsh") 'powershell))
  (should (eq (quoth-process--shell-type "dash") 'sh-like)))

(ert-deftest quoth-test-process/shell-args-posix-and-login ()
  "POSIX-style shells use `-c', or `-lc' with a login request."
  (should (equal (quoth-process--shell-args "/bin/bash" "echo hi" nil)
                 '("/bin/bash" "-c" "echo hi")))
  (should (equal (quoth-process--shell-args "/bin/bash" "echo hi" t)
                 '("/bin/bash" "-lc" "echo hi")))
  (should (equal (quoth-process--shell-args "zsh" "echo hi" nil)
                 '("zsh" "-c" "echo hi"))))

(ert-deftest quoth-test-process/shell-args-powershell-and-cmd ()
  "PowerShell uses `-Command'; cmd uses `/c'."
  (should (equal (quoth-process--shell-args "powershell" "Get-Location" nil)
                 '("powershell" "-NoProfile" "-Command" "Get-Location")))
  (should (equal (quoth-process--shell-args "cmd" "dir" nil)
                 '("cmd" "/c" "dir"))))

;;; 3. Output collection and yield

(ert-deftest quoth-test-process/collect-returns-output-and-exit ()
  "Collect returns output produced since the last report and the exit code."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start
                         "printf \"line1\nline2\""
                         nil owner))
          (let ((result (quoth-process--yield session 1000)))
            (should (consp result))
            (should (string-match-p "line1" (car result)))
            (should (string-match-p "line2" (car result)))
            (should (= (cdr result) 0))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/yield-reports-session-for-running ()
  "A still-running process yields a chunk with a nil exit code."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "sleep 10" nil owner))
          (let ((result (quoth-process--yield session 200)))
            (should (consp result))
            (should (stringp (car result)))
            (should (null (cdr result)))
            (should (process-live-p (quoth-process-session-process session)))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/collect-advances-last-report ()
  "Yield only reports output produced since the previous yield."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start
                         "echo one; sleep 1; echo two"
                         nil owner))
          (let ((first (quoth-process--yield session 300)))
            (should (consp first))
            (should (null (cdr first)))
            (should (string-match-p "one" (car first)))
            (should-not (string-match-p "two" (car first)))
            (let ((second (quoth-process--yield session 1500)))
              (should (consp second))
              (should (= (cdr second) 0))
              (should-not (string-match-p "one" (car second)))
              (should (string-match-p "two" (car second))))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/spawn-env-reaches-child ()
  "The sanitized environment (pagers off, TERM=dumb) reaches the child.
Regression: `quoth-process--spawn' once bound `process-environment' and
`make-process' in the same `let', so the pager vars were bound only
after the child had already inherited the unsanitized environment."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start
                         "echo PAGER=[$PAGER] GIT_PAGER=[$GIT_PAGER] TERM=[$TERM]"
                         nil owner))
          (let ((output (car (quoth-process--yield session 2000))))
            (should (string-search "PAGER=[" output))
            (should-not (string-search "PAGER=[]" output))
            (should (string-search "GIT_PAGER=[cat]" output))
            (should (string-search "TERM=[dumb]" output))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))

;;; 4. Stdin writes

(ert-deftest quoth-test-process/write-stdin-round-trip ()
  "Writing stdin to a reading process returns its reply."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "read line; echo got:$line"
                                              nil owner))
          (let ((result (quoth-process--write-stdin session "hello\n" 1000)))
            (should (string-match-p "got:hello" (car result)))
            (should (= (cdr result) 0))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))

;;; 5. Cleanup

(ert-deftest quoth-test-process/cleanup-buffer-kills-owned-sessions ()
  "Cleanup kills every session owned by a buffer."
  (let ((owner (quoth-test-process--owner))
        (other (quoth-test-process--owner))
        (a nil)
        (b nil)
        (c nil))
    (unwind-protect
        (progn
          (setq a (quoth-process--start "sleep 30" nil owner)
                b (quoth-process--start "sleep 30" nil owner)
                c (quoth-process--start "sleep 30" nil other))
          (let ((id-a (quoth-process-session-id a))
                (id-b (quoth-process-session-id b))
                (id-c (quoth-process-session-id c)))
            (quoth-process--cleanup-buffer owner)
            (should-not (gethash id-a quoth-process--sessions))
            (should-not (gethash id-b quoth-process--sessions))
            (should (gethash id-c quoth-process--sessions))))
      (when c (quoth-process--kill c))
      (quoth-test-process--cleanup-owner owner)
      (quoth-test-process--cleanup-owner other))))

(ert-deftest quoth-test-process/kill-unregisters-session ()
  "Kill removes the session from the registry and stops the process."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "sleep 30" nil owner))
          (let ((id (quoth-process-session-id session)))
            (quoth-process--kill session)
            (should-not (gethash id quoth-process--sessions))
            (should-not (process-live-p (quoth-process-session-process session)))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))

(provide 'quoth-test-process)
;;; quoth-test-process.el ends here
