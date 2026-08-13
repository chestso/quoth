;;; crush-test-tools.el --- Tool-call tests for crush  -*- lexical-binding: t; -*-
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
;;; Tool-call machinery tests: bash execution via real shell commands,
;;; the tool registry, result formatting, and the tool-call struct.
;;; Tests that need to assert "no process was spawned" use cl-letf on
;;; make-process; tests that exercise the full exec path use real
;;; subprocesses (sh -c).

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("crush" "crush-tool"))
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


(defun crush-test--tool-call (name &optional args-json)
  "Return a `crush-tool-call' for NAME with ARGS-JSON (or nil)."
  (let ((call (crush-make-tool-call :id "call_test" :name name)))
    (when args-json
      (setf (crush-tool-call-args call)
            (crush--tool-parse-args args-json)))
    call))

;;; 1. Tool registry and dispatch

(ert-deftest crush-test/tool-registry-has-bash ()
  "The registry should map `bash' to `crush-bash--exec'."
  (should (equal (cdr (assoc "bash" crush-tool--registry))
                 #'crush-bash--exec)))

(ert-deftest crush-test/tool-unknown-name-errors-without-process ()
  "An unknown tool name should yield an error result and spawn nothing."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (crush-test--tool-call "nope" "{}"))
             (result (crush-tool-execute call)))
        (should-not spawned)
        (should (string-prefix-p "<output>" (car result)))
        (should (= (cdr result) -1))))))

(ert-deftest crush-test/tool-execute-returns-result-and-exit ()
  "`crush-tool-execute' returns a result and exit code.
It returns (RESULT-TEXT . EXIT-CODE) and fills the call's slots."
  (let* ((call (crush-test--tool-call "bash" "{\"command\":\"echo hi\"}"))
         (result (crush-tool-execute call)))
    (should (stringp (car result)))
    (should (integerp (cdr result)))
    (should (string= (crush-tool-call-result call) (car result)))
    (should (= (crush-tool-call-exit call) (cdr result)))))

;;; 2. Argument parsing

(ert-deftest crush-test/tool-parse-args-valid ()
  "A valid args JSON should parse into a plist with keyword values."
  (should (equal (crush--tool-parse-args
                  "{\"command\":\"git status\",\"working_dir\":null}")
                 '(:command "git status" :working_dir nil))))

(ert-deftest crush-test/tool-parse-args-malformed ()
  "Malformed args JSON should parse to nil."
  (should (null (crush--tool-parse-args "not json")))
  (should (null (crush--tool-parse-args "")))
  (should (null (crush--tool-parse-args nil))))

(ert-deftest crush-test/tool-parse-args-non-object ()
  "A non-object payload (array/string) should parse to nil."
  (should (null (crush--tool-parse-args "[1,2]")))
  (should (null (crush--tool-parse-args "\"hi\""))))

;;; 3. Bash execution

(ert-deftest crush-test/bash-exec-captures-output ()
  "`crush-bash--exec' should capture combined stdout and exit 0."
  (let* ((call (crush-test--tool-call "bash" "{\"command\":\"echo hello\"}"))
         (result (crush-bash--exec call)))
    (should (string-match-p "hello" (car result)))
    (should (= (cdr result) 0))))

(ert-deftest crush-test/bash-exec-nonzero-exit ()
  "A command that exits non-zero should fold the exit code into the result."
  (let* ((call (crush-test--tool-call "bash" "{\"command\":\"exit 3\"}"))
         (result (crush-bash--exec call)))
    (should (string-match-p "<exit_code>3</exit_code>" (car result)))
    (should (= (cdr result) 3))))

(ert-deftest crush-test/bash-exec-missing-command-errors ()
  "A missing or empty `command' should error without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (dolist (json '("{}" "{\"command\":\"\"}" "{\"command\":\"  \"}"))
        (let* ((call (crush-test--tool-call "bash" json))
               (result (crush-bash--exec call)))
          (should (string-match-p "missing command" (car result)))
          (should (= (cdr result) -1))))
      (should-not spawned))))

(ert-deftest crush-test/bash-exec-malformed-args-errors ()
  "Malformed args JSON should error without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (crush-test--tool-call "bash" "not json"))
             (result (crush-bash--exec call)))
        (should (string-match-p "missing command" (car result)))
        (should (= (cdr result) -1)))
      (should-not spawned))))

(ert-deftest crush-test/bash-exec-uses-working-dir ()
  "The command runs with the resolved working directory.
That directory becomes `default-directory' for the call."
  (let ((wd (make-temp-file "crush-wd" t)))
    (unwind-protect
        (let* ((call (crush-test--tool-call
                      "bash"
                      (format "{\"command\":\"pwd\",\"working_dir\":%S}"
                              wd)))
               (result (crush-bash--exec call)))
          (should (string-match-p (regexp-quote wd) (car result))))
      (ignore-errors (delete-directory wd t)))))

(ert-deftest crush-test/bash-exec-default-dir ()
  "Without `working_dir', the command should run in `default-directory'."
  (let ((dir (make-temp-file "crush-dir" t)))
    (unwind-protect
        (let ((default-directory (file-name-as-directory dir)))
          (let* ((call (crush-test--tool-call "bash" "{\"command\":\"pwd\"}"))
                 (result (crush-bash--exec call)))
            (should (string-match-p (regexp-quote dir) (car result)))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest crush-test/bash-exec-empty-output-no-output ()
  "Empty output should render as the literal string `no output'."
  (let* ((call (crush-test--tool-call "bash" "{\"command\":\"true\"}"))
         (result (crush-bash--exec call)))
    (should (string-match-p "no output" (car result)))
    (should (= (cdr result) 0))))

(ert-deftest crush-test/bash-truncate-output ()
  "Long output should be capped with a head/tail split and ellipsis."
  (let* ((body (make-string 2000 ?x))
         (truncated (crush-bash--truncate-output body)))
    (should (string= truncated body)))
  (let* ((crush-tool-max-output 50)
         (body (concat (make-string 40 ?a) (make-string 40 ?b)))
         (truncated (crush-bash--truncate-output body)))
    (should (string-match-p "truncated" truncated))
    (should (string-prefix-p (make-string 35 ?a) truncated)))
  (should (string= (crush-bash--truncate-output "") "no output")))

(ert-deftest crush-test/bash-result-format-success ()
  "A successful run should carry `<cwd>' markup and exit code 0."
  (let* ((result (crush-bash--format-result "echo hi" "/tmp" "hi" 0)))
    (should (string-match-p "<command>echo hi</command>" (car result)))
    (should (string-match-p "<exit_code>0</exit_code>" (car result)))
    (should (= (cdr result) 0))))

(ert-deftest crush-test/bash-result-format-error-exit ()
  "A non-zero exit should fold into the result text."
  (let* ((result (crush-bash--format-result "false" "/tmp" "" 1)))
    (should (string-match-p "<exit_code>1</exit_code>" (car result)))
    (should (= (cdr result) 1))))

(ert-deftest crush-test/bash-result-format-timeout ()
  "A killed (timeout) run should report `exit: killed'."
  (let* ((result (crush-bash--format-result "sleep" "/tmp" "" 124)))
    (should (string-match-p "<exit_code>killed</exit_code>" (car result)))
    (should (= (cdr result) 124))))

(ert-deftest crush-test/bash-exec-timeout-kills ()
  "A command exceeding `crush-tool-timeout' is killed.\nThe result reports the timeout."
  (let ((crush-tool-timeout 1))
    (let* ((call (crush-test--tool-call "bash" "{\"command\":\"sleep 10\"}"))
           (result (crush-bash--exec call)))
      (should (string-match-p "killed" (car result)))
      (should (= (cdr result) 124)))))

(ert-deftest crush-test/bash-exec-logs-to-debug ()
  "Each bash round should log a `tool' line to *crush-debug*."
  (let ((call (crush-test--tool-call "bash" "{\"command\":\"echo hi\"}")))
    (crush-bash--exec call))
  (let ((debug (get-buffer "*crush-debug*")))
    (should (buffer-live-p debug))
    (with-current-buffer debug
      (goto-char (point-min))
      (should (search-forward "tool: bash" nil t))
      (should (search-forward "echo hi" nil t)))))

(provide 'crush-test-tools)
;;; crush-test-tools.el ends here
