;;; quoth-test-tools.el --- Tool-call tests for quoth  -*- lexical-binding: t; -*-
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
;;; Tool-call machinery tests: process execution via real shell commands,
;;; the tool registry, result formatting, and the tool-call struct.  The
;;; `exec_command' and `write_stdin' tools target `quoth-process.el'
;;; these tests exercise the full exec path through
;;; that layer with real subprocesses.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth" "quoth-openai" "quoth-process" "quoth-tools"))
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

(declare-function quoth-test--fresh-buffer "quoth-test" ())
(declare-function quoth-test--cleanup "quoth-test" ())
(defvar quoth-test--root)

(defun quoth-test--tool-call (name &optional args-json)
  "Return a `quoth-tool-call' for NAME with ARGS-JSON (or nil)."
  (let ((call (quoth-make-openai-tool-call :id "call_test" :name name)))
    (when args-json
      (setf (quoth-openai-tool-call-args call)
            (quoth-openai-parse-tool-args args-json)))
    call))

(defun quoth-test--ran-fence-lang (&optional shell)
  "Return the expected `ran:' fence language for SHELL (default `shell-file-name')."
  (let ((shell-path (or shell shell-file-name)))
    (format "```%s" (quoth--shell-language shell-path))))

;;; 1. Tool registry and dispatch

(ert-deftest quoth-test/tool-registry-has-exec-command ()
  "The registry should map \"exec_command\" to `quoth-exec-command--exec'."
  (should (equal (cdr (assoc "exec_command" quoth-openai-tool-registry))
                 #'quoth-exec-command--exec)))

(ert-deftest quoth-test/tool-registry-has-write-stdin ()
  "The registry should map \"write_stdin\" to `quoth-write-stdin--exec'."
  (should (equal (cdr (assoc "write_stdin" quoth-openai-tool-registry))
                 #'quoth-write-stdin--exec)))

(ert-deftest quoth-test/tool-unknown-name-errors-without-process ()
  "An unknown tool name should yield an error result and spawn nothing."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (quoth-test--tool-call "nope" "{}"))
             (result (quoth-openai-execute-tool call)))
        (should-not spawned)
        (should (string-match-p "Process exited with code -1" (car result)))
        (should (= (cdr result) -1))))))

(ert-deftest quoth-test/tool-execute-returns-result-and-exit ()
  "`quoth-openai-execute-tool' returns a result and exit code.
It returns (RESULT-TEXT . EXIT-CODE) and fills the call's slots."
  (let* ((call (quoth-test--tool-call "exec_command" "{\"cmd\":\"echo hi\"}"))
         (result (quoth-openai-execute-tool call)))
    (should (stringp (car result)))
    (should (integerp (cdr result)))
    (should (string= (quoth-openai-tool-call-result call) (car result)))
    (should (= (quoth-openai-tool-call-exit call) (cdr result)))))

(ert-deftest quoth-test/tool-dispatch-logs-call ()
  "The dispatch boundary logs every tool call under the `tool' category.
Executors return (RESULT . EXIT); `quoth-openai-execute-tool' owns the
debug log, so a tool is never expected to log
itself."
  (unwind-protect
      (let ((quoth-debug-mode t))
        (should-not (get-buffer "*quoth-debug*"))
        (let* ((call (quoth-test--tool-call "exec_command" "{\"cmd\":\"echo hi\"}"))
               (result (quoth-openai-execute-tool call)))
          (should (integerp (cdr result)))
          (with-current-buffer "*quoth-debug*"
            (goto-char (point-min))
            (should (search-forward "tool: exec_command" nil t))
            (should (search-forward "echo hi" nil t)))))
    (quoth-test--cleanup)))

;;; 2. Argument parsing

(ert-deftest quoth-test/tool-parse-args-valid ()
  "A valid args JSON should parse into a plist with keyword values."
  (should (equal (quoth-openai-parse-tool-args
                  "{\"cmd\":\"git status\",\"workdir\":null}")
                 '(:cmd "git status" :workdir nil))))

(ert-deftest quoth-test/tool-parse-args-malformed ()
  "Malformed args JSON should parse to nil."
  (should (null (quoth-openai-parse-tool-args "not json")))
  (should (null (quoth-openai-parse-tool-args "")))
  (should (null (quoth-openai-parse-tool-args nil))))

(ert-deftest quoth-test/tool-parse-args-non-object ()
  "A non-object payload (array/string) should parse to nil."
  (should (null (quoth-openai-parse-tool-args "[1,2]")))
  (should (null (quoth-openai-parse-tool-args "\"hi\""))))

;;; 3. exec_command execution

(ert-deftest quoth-test/exec-command-captures-output ()
  "`quoth-exec-command--exec' should capture combined stdout and exit 0."
  (let* ((call (quoth-test--tool-call "exec_command" "{\"cmd\":\"echo hello\"}"))
         (result (quoth-exec-command--exec call)))
    (should (string-match-p "hello" (car result)))
    (should (string-match-p "Process exited with code 0" (car result)))
    (should (string-match-p "Output:" (car result)))
    (should (= (cdr result) 0))))

(ert-deftest quoth-test/exec-command-nonzero-exit ()
  "A command that exits non-zero should report its exit code in prose."
  (let* ((call (quoth-test--tool-call "exec_command" "{\"cmd\":\"exit 3\"}"))
         (result (quoth-exec-command--exec call)))
    (should (string-match-p "Process exited with code 3" (car result)))
    (should (= (cdr result) 3))))

(ert-deftest quoth-test/exec-command-missing-cmd-errors ()
  "A missing or empty `cmd' should error without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (dolist (json '("{}" "{\"cmd\":\"\"}" "{\"cmd\":\"  \"}"))
        (let* ((call (quoth-test--tool-call "exec_command" json))
               (result (quoth-exec-command--exec call)))
          (should (string-match-p "Process exited with code -1" (car result)))
          (should (= (cdr result) -1))))
      (should-not spawned))))

(ert-deftest quoth-test/exec-command-malformed-args-errors ()
  "Malformed args JSON should error without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (quoth-test--tool-call "exec_command" "not json"))
             (result (quoth-exec-command--exec call)))
        (should (string-match-p "Process exited with code -1" (car result)))
        (should (= (cdr result) -1)))
      (should-not spawned))))

(ert-deftest quoth-test/exec-command-login-rejected-by-default ()
  "A `login' request is rejected when not allowed by config."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (quoth-test--tool-call
                    "exec_command"
                    "{\"cmd\":\"echo hi\",\"login\":true}"))
             (result (quoth-exec-command--exec call)))
        (should (string-match-p "login shell is disabled" (car result)))
        (should (= (cdr result) -1)))
      (should-not spawned))))

(ert-deftest quoth-test/exec-command-login-allowed-when-enabled ()
  "A `login' request is honored when `quoth-tool-allow-login-shell' is t."
  (let ((quoth-tool-allow-login-shell t))
    (let* ((call (quoth-test--tool-call
                  "exec_command"
                  "{\"cmd\":\"echo hi\",\"login\":true}"))
           (result (quoth-exec-command--exec call)))
      (should (string-match-p "hi" (car result)))
      (should (= (cdr result) 0)))))

(ert-deftest quoth-test/exec-command-shell-parameter ()
  "A requested shell binary is used to run the command."
  (let* ((call (quoth-test--tool-call
                "exec_command"
                "{\"cmd\":\"echo fromsh\",\"shell\":\"/bin/sh\"}"))
         (result (quoth-exec-command--exec call)))
    (should (string-match-p "fromsh" (car result)))
    (should (= (cdr result) 0))))

(ert-deftest quoth-test/exec-command-uses-workdir ()
  "The command runs with the resolved working directory."
  (let ((wd (make-temp-file "quoth-wd" t)))
    (unwind-protect
        (let* ((call (quoth-test--tool-call
                      "exec_command"
                      (format "{\"cmd\":\"pwd\",\"workdir\":%S}"
                              wd)))
               (result (quoth-exec-command--exec call)))
          (should (string-match-p (regexp-quote wd) (car result))))
      (ignore-errors (delete-directory wd t)))))

(ert-deftest quoth-test/exec-command-short-yield-reports-session ()
  "A still-running command yields a session id and no exit code."
  (let ((call (quoth-test--tool-call
               "exec_command"
               "{\"cmd\":\"sleep 5\",\"yield_time_ms\":200}"))
        session-id)
    (let ((result (quoth-exec-command--exec call)))
      (should (stringp (car result)))
      (should (string-match "Process running with session ID \\([0-9]+\\)"
                            (car result)))
      (setq session-id (string-to-number
                        (match-string 1 (car result))))
      (should (null (cdr result))))
    (should (gethash session-id quoth-process--sessions))
    (quoth-process--kill (quoth-process--find session-id))))

;;; 4. write_stdin execution

(ert-deftest quoth-test/write-stdin-round-trip ()
  "Test that \"exec_command\" and \"write_stdin\" drive the process to completion."
  (let* ((start (quoth-test--tool-call
                 "exec_command"
                 "{\"cmd\":\"read line; echo got:$line\",\"yield_time_ms\":200}"))
         (start-result (quoth-exec-command--exec start))
         session-id)
    (should (string-match "Process running with session ID \\([0-9]+\\)"
                          (car start-result)))
    (setq session-id (string-to-number (match-string 1 (car start-result))))
    (let* ((write (quoth-test--tool-call
                   "write_stdin"
                   (format "{\"session_id\":%d,\"input\":\"hello\\n\"}"
                           session-id)))
           (write-result (quoth-write-stdin--exec write)))
      (should (string-match-p "got:hello" (car write-result)))
      (should (string-match-p "Process exited with code 0" (car write-result)))
      (should (= (cdr write-result) 0)))
    (should-not (gethash session-id quoth-process--sessions))))

(ert-deftest quoth-test/write-stdin-unknown-session-errors ()
  "An unknown session id yields an error result without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (quoth-test--tool-call "write_stdin" "{\"session_id\":9999}"))
             (result (quoth-write-stdin--exec call)))
        (should (string-match-p "Process exited with code -1" (car result)))
        (should (= (cdr result) -1)))
      (should-not spawned))))

;;; 5. Result prose formatting

(ert-deftest quoth-test/result-format-exit ()
  "A finished run should carry prose status and exit code."
  (let* ((result (quoth-exec--format-result "hi" 0)))
    (should (string-match-p "Process exited with code 0" result))
    (should (string-match-p "Output:" result))))

(ert-deftest quoth-test/result-format-session ()
  "A running command should carry a session id and no exit code."
  (let* ((result (quoth-exec--format-running "ticks" 7)))
    (should (string-match-p "Process running with session ID 7" result))
    (should (string-match-p "Output:" result))
    (should-not (string-match-p "exited" result))))

;;; 6. Output truncation

(ert-deftest quoth-test/truncate-output ()
  "Long output should be capped with a head/tail split and an omission marker."
  (let* ((body (make-string 2000 ?x))
         (truncated (quoth-exec--truncate-output body)))
    (should (string= truncated body)))
  (let* ((quoth-tool-max-output 50)
         (body (concat (make-string 40 ?a) (make-string 40 ?b)))
         (truncated (quoth-exec--truncate-output body)))
    (should (string-match-p "omitted" truncated))
    (should (string-prefix-p (make-string 35 ?a) truncated)))
  (should (string= (quoth-exec--truncate-output "") "no output")))

(ert-deftest quoth-test/truncate-output-preserves-leading-whitespace ()
  "Leading whitespace (indentation) is preserved in command output."
  (should (string= (quoth-exec--truncate-output "  indented\nnext")
                   "  indented\nnext"))
  (should (string= (quoth-exec--truncate-output "\t\ttabbed")
                   "\t\ttabbed"))
  (should (string= (quoth-exec--truncate-output "  \n") "no output")))

;;; 7. Tool-block buffer formatting

(ert-deftest quoth-test/tool-block-renders-as-markdown ()
  "`quoth--tool-block-insert' should render a tool block as valid markdown.
The header carries the tool name, an icon, and a human summary; the
output is a fenced code block tagged `text`."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nAGENTS.md"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*🔧 exec_command\\*\\*" content))
            (should (string-match-p (concat "ran:\n\n" (quoth-test--ran-fence-lang)
                                            "\nls\n```") content))
            (should (string-match-p "```text\n" content))
            (should (string-match-p "```\n$" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-output-fence-single-blank-after ()
  "The output fence is followed by exactly one blank line.
The assembler inserts the fence's trailing newline and the blank-line
separator once, so exactly one blank line follows the closing fence."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nfiles"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            ;; Closing fence, newline, one blank line, then whatever
            ;; follows the block.
            (should (string-match-p "```\n\n" content))
            (should-not (string-match-p "```\n\n\n" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-adds-blank-line-after-bare-content ()
  "Test that a tool block after bare content gains a blank line.
The blank line appears before the header so the block stays valid markdown."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (goto-char (point-max))
          (insert "what it does")
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nAGENTS.md"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "what it does\n\n\\*\\*🔧 exec_command\\*\\*"
                                    content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-reuses-existing-blank-line ()
  "Test that a tool block reuses an existing blank line.
The tool block does not add extra blank lines after content already
ending in a blank line."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (goto-char (point-max))
          (insert "what it does\n\n")
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nAGENTS.md"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "\n\n\n\n\\*\\*🔧" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-exec-command-summary-fields ()
  "The exec_command summary renders every metadata field, present or default."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\",\"workdir\":\"/tmp\",\"yield_time_ms\":7500,\"shell\":\"/bin/zsh\",\"login\":true}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "ran:\n\n```zsh\nls\n```" content))
            (should (string-match-p "in: /tmp\n" content))
            (should (string-match-p "yield 7.5s" content))
            (should (string-match-p "shell /bin/zsh" content))
            (should (string-match-p "login yes" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-exec-command-shows-defaults ()
  "Test that a bare exec_command renders all defaults.
The defaults are the real cwd, configured yield, `shell-file-name', and
login no."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p (concat "ran:\n\n" (quoth-test--ran-fence-lang)
                                            "\nls\n```") content))
            (should (string-match-p (concat "in: "
                                            (regexp-quote
                                             (file-name-as-directory
                                              (expand-file-name default-directory)))
                                            "\n")
                                    content))
            (should (string-match-p "yield 10s" content))
            (should (string-match-p (concat "shell " (regexp-quote shell-file-name))
                                    content))
            (should (string-match-p "login no" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-cmd-fence-uses-shell-language ()
  "The exec_command `ran:' fence uses the shell-derived language.
An explicit `shell' parameter (zsh) must make the cmd fence ````zsh`,
not the output ````text` default."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\",\"shell\":\"/bin/zsh\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "ran:\n\n```zsh\nls\n```" content))
            ;; Output stays a plain text block.
            (should (string-match-p "```text\nout\n```" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-cmd-fence-powershell ()
  "A powershell exec_command renders the cmd fence as `powershell'."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"Get-ChildItem\",\"shell\":\"pwsh\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "ran:\n\n```powershell\nGet-ChildItem\n```"
                                    content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-cmd-fence-unknown-shell-is-shell ()
  "An unknown POSIX-style shell renders the cmd fence language as `shell'."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\",\"shell\":\"/bin/fish\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "ran:\n\n```shell\nls\n```" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-escapes-backticks-in-cmd ()
  "Single-line cmd with backticks renders as a fenced block.
The cmd is always fenced (single- or multi-line), so backticks in the
command text are literal text inside the fence, never inline code."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"echo `pwd`\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            ;; The cmd is always fenced; backticks are literal text
            ;; inside the fence.
            (should (string-match-p (concat "ran:\n\n" (quoth-test--ran-fence-lang)
                                            "\necho `pwd`\n```")
                                    content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-single-line-cmd-triple-backticks-escaped ()
  "A single-line cmd containing triple backticks uses a 4-backtick fence.
The `quoth--fence-str' mechanism extends the fence to outmatch any
backtick run in the command text, even when the cmd is a single line."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"echo ```markdown\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            ;; The arg fence is 4 backticks (one more than the 3-run).
            (should (string-match-p (concat "ran:\n\n````"
                                            (quoth--shell-language shell-file-name)
                                            "\n")
                                    content))
            (should (string-match-p "````\n" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-write-stdin-summary ()
  "The write_stdin summary renders session id, input, and yield."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "write_stdin" :id "call_2"
                 :args-json "{\"session_id\":7,\"input\":\"hello\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*⌨️ write_stdin\\*\\*" content))
            (should (string-match-p "session 7" content))
            (should (string-match-p "wrote: hello\n" content))
            (should (string-match-p "yield 1s" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-tagged ()
  "Tool blocks should be tagged `quoth-region-type' tool."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nfiles"
                 :exit 0)
           quoth--prompt-id)
          (goto-char (point-min))
          (search-forward "🔧 exec_command")
          (goto-char (match-beginning 0))
          (should (eq (get-text-property (point) 'quoth-region-type) 'tool)))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-minimal-write-stdin ()
  "Test that a minimal write_stdin block renders session, input, and yield.
A block with only a session id renders the session, empty input
(as a fenced block), yield, and no output fence."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "write_stdin" :id "call_2"
                 :args-json "{\"session_id\":7}")
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "session 7" content))
            (should (string-match-p "wrote: \n" content))
            (should (string-match-p "yield 1s" content))
            ;; No output fence (no result), but arg blocks use fences.
            (should-not (string-match-p "```text\nProcess" content))))
      (quoth-test--cleanup))))


(ert-deftest quoth-test/tool-block-multiline-cmd-is-fenced ()
  "A multiline cmd renders as a fenced block, not a broken inline span.
CommonMark inline code is single-line; a multiline cmd must be fenced
so the header stays valid markdown."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"for i in 1 2 3; do\\necho $i\\ndone\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     (concat "ran:\n\n" (quoth-test--ran-fence-lang)
                             "\nfor i in 1 2 3; do\necho $i\ndone\n```")
                     content))
            ;; The header line must not contain the cmd inline.
            (should-not (string-match-p "ran `for" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-multiline-cmd-backticks-escaped ()
  "A multiline cmd containing triple backticks uses a 4-backtick fence.
The `quoth--fence-str' mechanism extends the fence to outmatch any
backtick run in the argument value."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"echo ```markdown\\n# heading\\n```\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            ;; The arg fence is 4 backticks (one more than the 3-run).
            (should (string-match-p (concat "ran:\n\n````"
                                            (quoth--shell-language shell-file-name)
                                            "\n")
                                    content))
            (should (string-match-p "````\n" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-multiline-write-stdin-input ()
  "A multiline write_stdin input renders as a fenced block."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "write_stdin" :id "call_2"
                 :args-json "{\"session_id\":3,\"input\":\"line1\\nline2\"}"
                 :result "ok"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     "wrote:\n\n```text\nline1\nline2\n```" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-multiline-query ()
  "A multiline web_search query renders as a fenced block."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "web_search" :id "call_3"
                 :args-json "{\"query\":\"foo\\nbar\"}"
                 :result "results"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     "query:\n\n```text\nfoo\nbar\n```" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/tool-block-arg-blocks-not-tool-output ()
  "Argument fenced blocks are `tool' region, not `tool-output'.
Only the output fence interior is tagged `tool-output' for history
extraction; argument blocks are display decoration."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nfiles"
                 :exit 0)
           quoth--prompt-id)
          (goto-char (point-min))
          (search-forward "ran:")
          (should (eq (get-text-property (point) 'quoth-region-type) 'tool))
          (should-not (eq (get-text-property (point) 'quoth-region-type)
                          'tool-output))
          ;; The output fence interior IS tool-output.
          (search-forward "Process exited")
          (should (eq (get-text-property (point) 'quoth-region-type)
                      'tool-output)))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/write-file-tool-block-renders-path ()
  "A `write_file' tool block renders its path and content in the buffer."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "write_file" :id "call_1"
                 :args-json "{\"path\":\"/tmp/out.txt\",\"content\":\"hi\"}"
                 :result "ok"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*✍️ write_file\\*\\*" content))
            (should (string-match-p "path: /tmp/out.txt" content))
            (should (string-match-p "content:" content))))
      (quoth-test--cleanup))))

(ert-deftest quoth-test/read-file-tool-block-renders-path ()
  "A `read_file' tool block renders its path in the buffer."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "read_file" :id "call_2"
                 :args-json "{\"path\":\"/tmp/in.txt\"}"
                 :result "out"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*📖 read_file\\*\\*" content))
            (should (string-match-p "path: /tmp/in.txt" content))))
      (quoth-test--cleanup))))


;;; 8. Fence escaping: protect against nested fences in tool output

(ert-deftest quoth-test/fence-str-empty-output ()
  "Empty output uses the default 3-backtick fence."
  (should (string= (quoth--fence-str "") "```")))

(ert-deftest quoth-test/fence-str-no-backticks ()
  "Output without backticks uses the default 3-backtick fence."
  (should (string= (quoth--fence-str "hello\nworld") "```")))

(ert-deftest quoth-test/fence-str-single-backtick ()
  "Output with a single backtick uses 3-backtick fence (minimum)."
  (should (string= (quoth--fence-str "`code`") "```")))

(ert-deftest quoth-test/fence-str-three-backticks ()
  "Output with 3 backticks in a row uses 4-backtick fence."
  (should (string= (quoth--fence-str "```code```") "````")))

(ert-deftest quoth-test/fence-str-longest-run ()
  "The fence is one more than the longest backtick run."
  (should (string= (quoth--fence-str "`a` ```b``` 'c'") "````")))

(ert-deftest quoth-test/fence-str-many-backticks ()
  "A long backtick run produces a longer fence."
  (should (string= (quoth--fence-str "`````") "``````")))

(ert-deftest quoth-test/tool-block-escapes-nested-fences ()
  "Tool output containing fences should use a longer fence to not break."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "regular output with ```nested``` fence"
                 :exit 0)
           quoth--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "````text\n" content))
            (should (string-match-p "````\n$" content))))
      (quoth-test--cleanup))))


;;; 9. read_file / write_file execution

(defun quoth-test--tmpdir ()
  "Return a fresh temp dir for a filesystem-tool test."
  (make-temp-file "quoth-fs" t))

(defun quoth-test--args-json (&rest args)
  "Return an args-json string from keyword ARGS.
Uses `quoth-json-write' so string values containing newlines/CR are
escaped correctly (JSON, unlike `format %S', escapes control chars)."
  (quoth-json-write args))

(ert-deftest quoth-test/tool-registry-has-read-file ()
  "The registry should map \"read_file\" to `quoth-read-file--exec'."
  (should (equal (cdr (assoc "read_file" quoth-openai-tool-registry))
                 #'quoth-read-file--exec)))

(ert-deftest quoth-test/tool-registry-has-write-file ()
  "The registry should map \"write_file\" to `quoth-write-file--exec'."
  (should (equal (cdr (assoc "write_file" quoth-openai-tool-registry))
                 #'quoth-write-file--exec)))

(ert-deftest quoth-test/write-file-creates-file-with-exact-content ()
  "`quoth-write-file--exec' writes the exact content and reports exit 0."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "out.txt" dir))
               (call (quoth-test--tool-call
                      "write_file"
                      (quoth-test--args-json
                       :path target :content "hello\nworld\n")))
               (result (quoth-write-file--exec call)))
          (should (string-match-p "Process exited with code 0" (car result)))
          (should (= (cdr result) 0))
          (should (file-exists-p target))
          (with-temp-buffer
            (insert-file-contents target)
            (should (string= (buffer-substring-no-properties (point-min)
                                                             (point-max))
                             "hello\nworld\n"))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/write-file-preserves-crlf ()
  "A content with CRLF stays CRLF on disk (byte-exact, no newline munging)."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "crlf.txt" dir))
               (content "line1\r\nline2\r\n")
               (call (quoth-test--tool-call
                      "write_file"
                      (quoth-test--args-json
                       :path target :content content)))
               (result (quoth-write-file--exec call)))
          (should (= (cdr result) 0))
          (with-temp-buffer
            ;; Force no newline translation on insert so we read raw bytes.
            (let ((coding-system-for-read 'binary))
              (insert-file-contents target))
            (should (string= (buffer-substring-no-properties (point-min)
                                                             (point-max))
                             "line1\r\nline2\r\n"))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/write-file-relative-path-uses-workdir ()
  "A relative `path' resolves against `workdir'."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((call (quoth-test--tool-call
                      "write_file"
                      (quoth-test--args-json
                       :path "rel.txt" :content "x" :workdir dir)))
               (result (quoth-write-file--exec call)))
          (should (= (cdr result) 0))
          (should (file-exists-p (expand-file-name "rel.txt" dir))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/write-file-creates-parent-directories ()
  "`write_file' creates missing parent directories for the target path."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "a/b/c.txt" dir))
               (call (quoth-test--tool-call
                      "write_file"
                      (quoth-test--args-json
                       :path target :content "nested")))
               (result (quoth-write-file--exec call)))
          (should (= (cdr result) 0))
          (should (file-exists-p target)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/write-file-overwrite-false-refuses-existing ()
  "`overwrite: false' fails on an existing file without touching it."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "keep.txt" dir))
               (_ (write-region "original" nil target))
               (call (quoth-test--tool-call
                      "write_file"
                      (quoth-test--args-json
                       :path target :content "new" :overwrite :json-false)))
               (result (quoth-write-file--exec call)))
          (should (string-match-p "Process exited with code -1" (car result)))
          (should (= (cdr result) -1))
          ;; Existing content is untouched.
          (with-temp-buffer
            (insert-file-contents target)
            (should (string= (buffer-substring-no-properties (point-min)
                                                             (point-max))
                             "original"))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/write-file-overwrite-default-clobbers ()
  "By default `write_file' overwrites an existing file."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "clob.txt" dir))
               (_ (write-region "old" nil target))
               (call (quoth-test--tool-call
                      "write_file"
                      (quoth-test--args-json
                       :path target :content "new")))
               (result (quoth-write-file--exec call)))
          (should (= (cdr result) 0))
          (with-temp-buffer
            (insert-file-contents target)
            (should (string= (buffer-substring-no-properties (point-min)
                                                             (point-max))
                             "new"))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/write-file-no-temp-file-left-behind ()
  "`write_file' is atomic: no temp file remains in the target directory."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "atomic.txt" dir))
               (call (quoth-test--tool-call
                      "write_file"
                      (quoth-test--args-json
                       :path target :content "data")))
               (result (quoth-write-file--exec call)))
          (should (= (cdr result) 0))
          ;; No leftover atomic-write temp file remains.
          (should-not (directory-files dir nil "\\.tmp\\'"))
          ;; Exactly the one target file (besides `.`/`..`).
          (should (equal (directory-files dir nil "\\`[^.]")
                         (list (file-name-nondirectory target)))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/write-file-missing-path-errors ()
  "A missing or empty `path' yields an error result."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (dolist (json (list (quoth-test--args-json :content "x" :workdir dir)
                            (quoth-test--args-json :path "" :content "x")))
          (let* ((call (quoth-test--tool-call "write_file" json))
                 (result (quoth-write-file--exec call)))
            (should (string-match-p "Process exited with code -1" (car result)))
            (should (= (cdr result) -1))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/read-file-round-trip ()
  "`quoth-read-file--exec' returns the file's exact content with exit 0."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "read.txt" dir))
               (_ (write-region "some\ncontent\n" nil target))
               (call (quoth-test--tool-call
                      "read_file"
                      (quoth-test--args-json :path target)))
               (result (quoth-read-file--exec call)))
          (should (string-match-p "Process exited with code 0" (car result)))
          (should (= (cdr result) 0))
          (should (string-match-p "some\ncontent\n" (car result))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/read-file-preserves-crlf ()
  "`read_file' returns CRLF content byte-exact (no re-cooking)."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "readcrlf.txt" dir))
               (_ (write-region "a\r\nb\r\n" nil target))
               (call (quoth-test--tool-call
                      "read_file"
                      (quoth-test--args-json :path target)))
               (result (quoth-read-file--exec call)))
          (should (= (cdr result) 0))
          (should (string-match-p "a\r\nb\r\n" (car result))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/read-file-decodes-utf8 ()
  "`read_file' reads and decodes a file with multi-byte UTF-8 content.
A regression test: bytes >= #x80 are read as raw byte values (a unibyte
string) so the UTF-8 validator sees `0xE2` rather than Emacs's eight-bit
character form, and the decoded codepoints (including any >= #x100) land
in a proper multibyte result string."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "utf8.txt" dir))
               (_ (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert "caf\303\251 \342\200\224 ok\n")
                    (write-region (point-min) (point-max) target nil 'silent)))
               (call (quoth-test--tool-call
                      "read_file"
                      (quoth-test--args-json :path target)))
               (result (quoth-read-file--exec call)))
          (should (= (cdr result) 0))
          ;; The multi-byte sequences on disk (C3 A9 for é, E2 80 94 for
          ;; the em dash) decode to the single chars U+00E9 and U+2014.
          (should (string-match-p "caf\u00e9 \u2014 ok" (car result))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/read-file-relative-path-uses-workdir ()
  "A relative `path' resolves against `workdir'."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "rel.txt" dir))
               (_ (write-region "hi" nil target))
               (call (quoth-test--tool-call
                      "read_file"
                      (quoth-test--args-json :path "rel.txt" :workdir dir)))
               (result (quoth-read-file--exec call)))
          (should (= (cdr result) 0))
          (should (string-match-p "hi" (car result))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/read-file-missing-file-errors ()
  "A missing file yields an error result."
  (let ((dir (quoth-test--tmpdir)))
    (unwind-protect
        (let* ((target (expand-file-name "nope.txt" dir))
               (call (quoth-test--tool-call
                      "read_file"
                      (quoth-test--args-json :path target)))
               (result (quoth-read-file--exec call)))
          (should (string-match-p "Process exited with code -1" (car result)))
          (should (= (cdr result) -1)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest quoth-test/read-file-truncates-large-content ()
  "`read_file' caps output at `quoth-tool-max-output'."
  (let ((dir (quoth-test--tmpdir))
        (quoth-tool-max-output 100))
    (unwind-protect
        (let* ((target (expand-file-name "big.txt" dir))
               (body (make-string 500 ?x))
               (_ (write-region body nil target))
               (call (quoth-test--tool-call
                      "read_file"
                      (quoth-test--args-json :path target)))
               (result (quoth-read-file--exec call)))
          (should (= (cdr result) 0))
          (should (string-match-p "omitted" (car result))))
      (ignore-errors (delete-directory dir t)))))

(provide 'quoth-test-tools)
;;; quoth-test-tools.el ends here
