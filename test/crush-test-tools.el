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
  (dolist (dep '("crush" "crush-openai" "crush-tools"))
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
  (let ((call (crush-make-openai-tool-call :id "call_test" :name name)))
    (when args-json
      (setf (crush-openai-tool-call-args call)
            (crush-openai-parse-tool-args args-json)))
    call))

;;; 1. Tool registry and dispatch

(ert-deftest crush-test/tool-registry-has-bash ()
  "The registry should map `bash' to `crush-bash--exec'."
  (should (equal (cdr (assoc "bash" crush-openai-tool-registry))
                 #'crush-bash--exec)))

(ert-deftest crush-test/tool-unknown-name-errors-without-process ()
  "An unknown tool name should yield an error result and spawn nothing."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (crush-test--tool-call "nope" "{}"))
             (result (crush-openai-execute-tool call)))
        (should-not spawned)
        (should (string-prefix-p "<output>" (car result)))
        (should (= (cdr result) -1))))))

(ert-deftest crush-test/tool-execute-returns-result-and-exit ()
  "`crush-openai-execute-tool' returns a result and exit code.
It returns (RESULT-TEXT . EXIT-CODE) and fills the call's slots."
  (let* ((call (crush-test--tool-call "bash" "{\"command\":\"echo hi\"}"))
         (result (crush-openai-execute-tool call)))
    (should (stringp (car result)))
    (should (integerp (cdr result)))
    (should (string= (crush-openai-tool-call-result call) (car result)))
    (should (= (crush-openai-tool-call-exit call) (cdr result)))))

;;; 2. Argument parsing

(ert-deftest crush-test/tool-parse-args-valid ()
  "A valid args JSON should parse into a plist with keyword values."
  (should (equal (crush-openai-parse-tool-args
                  "{\"command\":\"git status\",\"working_dir\":null}")
                 '(:command "git status" :working_dir nil))))

(ert-deftest crush-test/tool-parse-args-malformed ()
  "Malformed args JSON should parse to nil."
  (should (null (crush-openai-parse-tool-args "not json")))
  (should (null (crush-openai-parse-tool-args "")))
  (should (null (crush-openai-parse-tool-args nil))))

(ert-deftest crush-test/tool-parse-args-non-object ()
  "A non-object payload (array/string) should parse to nil."
  (should (null (crush-openai-parse-tool-args "[1,2]")))
  (should (null (crush-openai-parse-tool-args "\"hi\""))))

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
    (should (string-match-p "<cwd>/tmp</cwd>" (car result)))
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

;;; 4. Tool-block buffer formatting

(ert-deftest crush-test/tool-block-renders-as-markdown ()
  "`crush--tool-block-insert' should render a tool block as valid markdown.
The tool name is bold, command/exit are inline code, and output is a
fenced code block."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}"
                 :result "<output>AGENTS.md\ncrush.el</output>"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*🔧 tool: bash\\*\\*" content))
            (should (string-match-p "\\*\\*command:\\*\\* `" content))
            (should (string-match-p "\\*\\*exit:\\*\\* `0`" content))
            (should (string-match-p "\\*\\*output:\\*\\*\n```" content))
            (should (string-match-p "```\n$" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-read-only-and-tagged ()
  "Tool blocks should be read-only and tagged `crush-region-type' tool."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}"
                 :result "<output>files</output>"
                 :exit 0)
           crush--prompt-id)
          (goto-char (point-min))
          (search-forward "tool: bash")
          (goto-char (match-beginning 0))
          (should (eq (get-text-property (point) 'crush-region-type) 'tool))
          (should (get-text-property (point) 'read-only))
          (should-error (insert "x") :type 'text-read-only))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-no-result-no-output-section ()
  "Tool blocks without a result should omit the output section."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "output" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-no-exit-no-exit-line ()
  "Tool blocks without an exit code should omit the exit line."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}")
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "exit" content))))
      (crush-test--cleanup))))

;;; 5. Fence escaping: protect against nested fences in tool output

(ert-deftest crush-test/fence-str-empty-output ()
  "Empty output uses the default 3-backtick fence."
  (should (string= (crush--fence-str "") "```")))

(ert-deftest crush-test/fence-str-no-backticks ()
  "Output without backticks uses the default 3-backtick fence."
  (should (string= (crush--fence-str "hello\nworld") "```")))

(ert-deftest crush-test/fence-str-single-backtick ()
  "Output with a single backtick uses 3-backtick fence (minimum)."
  (should (string= (crush--fence-str "`code`") "```")))

(ert-deftest crush-test/fence-str-three-backticks ()
  "Output with 3 backticks in a row uses 4-backtick fence."
  (should (string= (crush--fence-str "```code```") "````")))

(ert-deftest crush-test/fence-str-longest-run ()
  "The fence is one more than the longest backtick run."
  (should (string= (crush--fence-str "`a` ```b``` 'c'") "````")))

(ert-deftest crush-test/fence-str-many-backticks ()
  "A long backtick run produces a longer fence."
  (should (string= (crush--fence-str "`````") "``````")))

(ert-deftest crush-test/tool-block-escapes-nested-fences ()
  "Tool output containing fences should use a longer fence to not break."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}"
                 :result "regular output with ```nested``` fence"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*output:\\*\\*\n````" content))
            (should (string-match-p "````\n$" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-safe-with-triple-backtick ()
  "Default 3-backtick fence is safe when output has no backticks."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "bash" :id "call_1"
                 :args-json "{\"command\":\"ls\"}"
                 :result "plain output"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*output:\\*\\*\n```\n" content))
            (should (string-match-p "\n```\n$" content))))
      (crush-test--cleanup))))

(provide 'crush-test-tools)
;;; crush-test-tools.el ends here
