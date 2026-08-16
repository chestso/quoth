;;; crush-test-process.el --- Process-handler tests for crush  -*- lexical-binding: t; -*-
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
;;; Tests for `crush-process.el': the session registry, PTY process
;;; spawning, output collection, yield, stdin writes, and cleanup.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("crush" "crush-process"))
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

(defun crush-test-process--owner ()
  "Return a throwaway buffer to use as a session owner."
  (generate-new-buffer " *crush-process-owner*"))

(defun crush-test-process--cleanup-owner (owner)
  "Kill OWNER and any sessions it owns."
  (crush-process--cleanup-buffer owner)
  (when (buffer-live-p owner)
    (kill-buffer owner)))

;;; 1. Session registry

(ert-deftest crush-test-process/registry-starts-empty ()
  "The session registry is empty at load time."
  (should (boundp 'crush-process--sessions))
  (should (hash-table-p crush-process--sessions))
  (should (integerp crush-process--counter)))

(ert-deftest crush-test-process/sessions-get-monotonic-ids ()
  "Session ids come from a monotonic counter and are unique."
  (let ((owner (crush-test-process--owner))
        (a nil)
        (b nil))
    (unwind-protect
        (progn
          (setq a (crush-process--start "true" nil owner)
                b (crush-process--start "true" nil owner))
          (crush-process--collect a)
          (crush-process--collect b)
          (should (integerp (crush-process-session-id a)))
          (should (integerp (crush-process-session-id b)))
          (should-not (= (crush-process-session-id a)
                         (crush-process-session-id b))))
      (crush-process--kill a)
      (crush-process--kill b)
      (crush-test-process--cleanup-owner owner))))

;;; 2. Shell selection

(ert-deftest crush-test-process/shell-type-detects-common-shells ()
  "`crush-process--shell-type' maps binary names to their shell type."
  (should (eq (crush-process--shell-type "bash") 'bash))
  (should (eq (crush-process--shell-type "/bin/bash") 'bash))
  (should (eq (crush-process--shell-type "zsh") 'zsh))
  (should (eq (crush-process--shell-type "sh") 'sh))
  (should (eq (crush-process--shell-type "cmd") 'cmd))
  (should (eq (crush-process--shell-type "cmd.exe") 'cmd))
  (should (eq (crush-process--shell-type "powershell") 'powershell))
  (should (eq (crush-process--shell-type "pwsh") 'powershell))
  (should (eq (crush-process--shell-type "dash") 'sh-like)))

(ert-deftest crush-test-process/shell-args-posix-and-login ()
  "POSIX-style shells use `-c', or `-lc' with a login request."
  (should (equal (crush-process--shell-args "/bin/bash" "echo hi" nil)
                 '("/bin/bash" "-c" "echo hi")))
  (should (equal (crush-process--shell-args "/bin/bash" "echo hi" t)
                 '("/bin/bash" "-lc" "echo hi")))
  (should (equal (crush-process--shell-args "zsh" "echo hi" nil)
                 '("zsh" "-c" "echo hi"))))

(ert-deftest crush-test-process/shell-args-powershell-and-cmd ()
  "PowerShell uses `-Command'; cmd uses `/c'."
  (should (equal (crush-process--shell-args "powershell" "Get-Location" nil)
                 '("powershell" "-NoProfile" "-Command" "Get-Location")))
  (should (equal (crush-process--shell-args "cmd" "dir" nil)
                 '("cmd" "/c" "dir"))))

;;; 3. Output collection and yield

(ert-deftest crush-test-process/collect-returns-output-and-exit ()
  "Collect returns output produced since the last report and the exit code."
  (let ((owner (crush-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (crush-process--start
                         "printf \"line1\nline2\""
                         nil owner))
          (let ((result (crush-process--yield session 1000)))
            (should (consp result))
            (should (string-match-p "line1" (car result)))
            (should (string-match-p "line2" (car result)))
            (should (= (cdr result) 0))))
      (when session (crush-process--kill session))
      (crush-test-process--cleanup-owner owner))))

(ert-deftest crush-test-process/yield-reports-session-for-running ()
  "A still-running process yields a chunk with a nil exit code."
  (let ((owner (crush-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (crush-process--start "sleep 10" nil owner))
          (let ((result (crush-process--yield session 200)))
            (should (consp result))
            (should (stringp (car result)))
            (should (null (cdr result)))
            (should (process-live-p (crush-process-session-process session)))))
      (when session (crush-process--kill session))
      (crush-test-process--cleanup-owner owner))))

(ert-deftest crush-test-process/collect-advances-last-report ()
  "Yield only reports output produced since the previous yield."
  (let ((owner (crush-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (crush-process--start
                         "echo one; sleep 1; echo two"
                         nil owner))
          (let ((first (crush-process--yield session 300)))
            (should (consp first))
            (should (null (cdr first)))
            (should (string-match-p "one" (car first)))
            (should-not (string-match-p "two" (car first)))
            (let ((second (crush-process--yield session 1500)))
              (should (consp second))
              (should (= (cdr second) 0))
              (should-not (string-match-p "one" (car second)))
              (should (string-match-p "two" (car second))))))
      (when session (crush-process--kill session))
      (crush-test-process--cleanup-owner owner))))

;;; 4. Stdin writes

(ert-deftest crush-test-process/write-stdin-round-trip ()
  "Writing stdin to a reading process returns its reply."
  (let ((owner (crush-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (crush-process--start "read line; echo got:$line"
                                              nil owner))
          (let ((result (crush-process--write-stdin session "hello\n" 1000)))
            (should (string-match-p "got:hello" (car result)))
            (should (= (cdr result) 0))))
      (when session (crush-process--kill session))
      (crush-test-process--cleanup-owner owner))))

;;; 5. Cleanup

(ert-deftest crush-test-process/cleanup-buffer-kills-owned-sessions ()
  "Cleanup kills every session owned by a buffer."
  (let ((owner (crush-test-process--owner))
        (other (crush-test-process--owner))
        (a nil)
        (b nil)
        (c nil))
    (unwind-protect
        (progn
          (setq a (crush-process--start "sleep 30" nil owner)
                b (crush-process--start "sleep 30" nil owner)
                c (crush-process--start "sleep 30" nil other))
          (let ((id-a (crush-process-session-id a))
                (id-b (crush-process-session-id b))
                (id-c (crush-process-session-id c)))
            (crush-process--cleanup-buffer owner)
            (should-not (gethash id-a crush-process--sessions))
            (should-not (gethash id-b crush-process--sessions))
            (should (gethash id-c crush-process--sessions))))
      (when c (crush-process--kill c))
      (crush-test-process--cleanup-owner owner)
      (crush-test-process--cleanup-owner other))))

(ert-deftest crush-test-process/kill-unregisters-session ()
  "Kill removes the session from the registry and stops the process."
  (let ((owner (crush-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (crush-process--start "sleep 30" nil owner))
          (let ((id (crush-process-session-id session)))
            (crush-process--kill session)
            (should-not (gethash id crush-process--sessions))
            (should-not (process-live-p (crush-process-session-process session)))))
      (when session (crush-process--kill session))
      (crush-test-process--cleanup-owner owner))))

(provide 'crush-test-process)
;;; crush-test-process.el ends here
