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
;;; Tool-call machinery tests: process execution via real shell commands,
;;; the tool registry, result formatting, and the tool-call struct.  The
;;; `exec_command' and `write_stdin' tools target `crush-process.el'
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
  (dolist (dep '("crush" "crush-openai" "crush-process" "crush-tools"))
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

(declare-function crush-test--fresh-buffer "crush-test" ())
(declare-function crush-test--cleanup "crush-test" ())
(defvar crush-test--root)

(defun crush-test--tool-call (name &optional args-json)
  "Return a `crush-tool-call' for NAME with ARGS-JSON (or nil)."
  (let ((call (crush-make-openai-tool-call :id "call_test" :name name)))
    (when args-json
      (setf (crush-openai-tool-call-args call)
            (crush-openai-parse-tool-args args-json)))
    call))

;;; 1. Tool registry and dispatch

(ert-deftest crush-test/tool-registry-has-exec-command ()
  "The registry should map \"exec_command\" to `crush-exec-command--exec'."
  (should (equal (cdr (assoc "exec_command" crush-openai-tool-registry))
                 #'crush-exec-command--exec)))

(ert-deftest crush-test/tool-registry-has-write-stdin ()
  "The registry should map \"write_stdin\" to `crush-write-stdin--exec'."
  (should (equal (cdr (assoc "write_stdin" crush-openai-tool-registry))
                 #'crush-write-stdin--exec)))

(ert-deftest crush-test/tool-unknown-name-errors-without-process ()
  "An unknown tool name should yield an error result and spawn nothing."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (crush-test--tool-call "nope" "{}"))
             (result (crush-openai-execute-tool call)))
        (should-not spawned)
        (should (string-match-p "Process exited with code -1" (car result)))
        (should (= (cdr result) -1))))))

(ert-deftest crush-test/tool-execute-returns-result-and-exit ()
  "`crush-openai-execute-tool' returns a result and exit code.
It returns (RESULT-TEXT . EXIT-CODE) and fills the call's slots."
  (let* ((call (crush-test--tool-call "exec_command" "{\"cmd\":\"echo hi\"}"))
         (result (crush-openai-execute-tool call)))
    (should (stringp (car result)))
    (should (integerp (cdr result)))
    (should (string= (crush-openai-tool-call-result call) (car result)))
    (should (= (crush-openai-tool-call-exit call) (cdr result)))))

(ert-deftest crush-test/tool-dispatch-logs-call ()
  "The dispatch boundary logs every tool call under the `tool' category.
Executors return (RESULT . EXIT); `crush-openai-execute-tool' owns the
debug log, so a tool is never expected to log
itself."
  (unwind-protect
      (let ((crush-debug-mode t))
        (should-not (get-buffer "*crush-debug*"))
        (let* ((call (crush-test--tool-call "exec_command" "{\"cmd\":\"echo hi\"}"))
               (result (crush-openai-execute-tool call)))
          (should (integerp (cdr result)))
          (with-current-buffer "*crush-debug*"
            (goto-char (point-min))
            (should (search-forward "tool: exec_command" nil t))
            (should (search-forward "echo hi" nil t)))))
    (crush-test--cleanup)))

;;; 2. Argument parsing

(ert-deftest crush-test/tool-parse-args-valid ()
  "A valid args JSON should parse into a plist with keyword values."
  (should (equal (crush-openai-parse-tool-args
                  "{\"cmd\":\"git status\",\"workdir\":null}")
                 '(:cmd "git status" :workdir nil))))

(ert-deftest crush-test/tool-parse-args-malformed ()
  "Malformed args JSON should parse to nil."
  (should (null (crush-openai-parse-tool-args "not json")))
  (should (null (crush-openai-parse-tool-args "")))
  (should (null (crush-openai-parse-tool-args nil))))

(ert-deftest crush-test/tool-parse-args-non-object ()
  "A non-object payload (array/string) should parse to nil."
  (should (null (crush-openai-parse-tool-args "[1,2]")))
  (should (null (crush-openai-parse-tool-args "\"hi\""))))

;;; 3. exec_command execution

(ert-deftest crush-test/exec-command-captures-output ()
  "`crush-exec-command--exec' should capture combined stdout and exit 0."
  (let* ((call (crush-test--tool-call "exec_command" "{\"cmd\":\"echo hello\"}"))
         (result (crush-exec-command--exec call)))
    (should (string-match-p "hello" (car result)))
    (should (string-match-p "Process exited with code 0" (car result)))
    (should (string-match-p "Output:" (car result)))
    (should (= (cdr result) 0))))

(ert-deftest crush-test/exec-command-nonzero-exit ()
  "A command that exits non-zero should report its exit code in prose."
  (let* ((call (crush-test--tool-call "exec_command" "{\"cmd\":\"exit 3\"}"))
         (result (crush-exec-command--exec call)))
    (should (string-match-p "Process exited with code 3" (car result)))
    (should (= (cdr result) 3))))

(ert-deftest crush-test/exec-command-missing-cmd-errors ()
  "A missing or empty `cmd' should error without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (dolist (json '("{}" "{\"cmd\":\"\"}" "{\"cmd\":\"  \"}"))
        (let* ((call (crush-test--tool-call "exec_command" json))
               (result (crush-exec-command--exec call)))
          (should (string-match-p "Process exited with code -1" (car result)))
          (should (= (cdr result) -1))))
      (should-not spawned))))

(ert-deftest crush-test/exec-command-malformed-args-errors ()
  "Malformed args JSON should error without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (crush-test--tool-call "exec_command" "not json"))
             (result (crush-exec-command--exec call)))
        (should (string-match-p "Process exited with code -1" (car result)))
        (should (= (cdr result) -1)))
      (should-not spawned))))

(ert-deftest crush-test/exec-command-login-rejected-by-default ()
  "A `login' request is rejected when not allowed by config."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (crush-test--tool-call
                    "exec_command"
                    "{\"cmd\":\"echo hi\",\"login\":true}"))
             (result (crush-exec-command--exec call)))
        (should (string-match-p "login shell is disabled" (car result)))
        (should (= (cdr result) -1)))
      (should-not spawned))))

(ert-deftest crush-test/exec-command-login-allowed-when-enabled ()
  "A `login' request is honored when `crush-tool-allow-login-shell' is t."
  (let ((crush-tool-allow-login-shell t))
    (let* ((call (crush-test--tool-call
                  "exec_command"
                  "{\"cmd\":\"echo hi\",\"login\":true}"))
           (result (crush-exec-command--exec call)))
      (should (string-match-p "hi" (car result)))
      (should (= (cdr result) 0)))))

(ert-deftest crush-test/exec-command-shell-parameter ()
  "A requested shell binary is used to run the command."
  (let* ((call (crush-test--tool-call
                "exec_command"
                "{\"cmd\":\"echo fromsh\",\"shell\":\"/bin/sh\"}"))
         (result (crush-exec-command--exec call)))
    (should (string-match-p "fromsh" (car result)))
    (should (= (cdr result) 0))))

(ert-deftest crush-test/exec-command-uses-workdir ()
  "The command runs with the resolved working directory."
  (let ((wd (make-temp-file "crush-wd" t)))
    (unwind-protect
        (let* ((call (crush-test--tool-call
                      "exec_command"
                      (format "{\"cmd\":\"pwd\",\"workdir\":%S}"
                              wd)))
               (result (crush-exec-command--exec call)))
          (should (string-match-p (regexp-quote wd) (car result))))
      (ignore-errors (delete-directory wd t)))))

(ert-deftest crush-test/exec-command-short-yield-reports-session ()
  "A still-running command yields a session id and no exit code."
  (let ((call (crush-test--tool-call
               "exec_command"
               "{\"cmd\":\"sleep 5\",\"yield_time_ms\":200}"))
        session-id)
    (let ((result (crush-exec-command--exec call)))
      (should (stringp (car result)))
      (should (string-match "Process running with session ID \\([0-9]+\\)"
                            (car result)))
      (setq session-id (string-to-number
                        (match-string 1 (car result))))
      (should (null (cdr result))))
    (should (gethash session-id crush-process--sessions))
    (crush-process--kill (crush-process--find session-id))))

;;; 4. write_stdin execution

(ert-deftest crush-test/write-stdin-round-trip ()
  "Test that \"exec_command\" and \"write_stdin\" drive the process to completion."
  (let* ((start (crush-test--tool-call
                 "exec_command"
                 "{\"cmd\":\"read line; echo got:$line\",\"yield_time_ms\":200}"))
         (start-result (crush-exec-command--exec start))
         session-id)
    (should (string-match "Process running with session ID \\([0-9]+\\)"
                          (car start-result)))
    (setq session-id (string-to-number (match-string 1 (car start-result))))
    (let* ((write (crush-test--tool-call
                   "write_stdin"
                   (format "{\"session_id\":%d,\"input\":\"hello\\n\"}"
                           session-id)))
           (write-result (crush-write-stdin--exec write)))
      (should (string-match-p "got:hello" (car write-result)))
      (should (string-match-p "Process exited with code 0" (car write-result)))
      (should (= (cdr write-result) 0)))
    (should-not (gethash session-id crush-process--sessions))))

(ert-deftest crush-test/write-stdin-unknown-session-errors ()
  "An unknown session id yields an error result without spawning."
  (let ((spawned nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _args) (setq spawned t) nil)))
      (let* ((call (crush-test--tool-call "write_stdin" "{\"session_id\":9999}"))
             (result (crush-write-stdin--exec call)))
        (should (string-match-p "Process exited with code -1" (car result)))
        (should (= (cdr result) -1)))
      (should-not spawned))))

;;; 5. Result prose formatting

(ert-deftest crush-test/result-format-exit ()
  "A finished run should carry prose status and exit code."
  (let* ((result (crush-exec--format-result "hi" 0)))
    (should (string-match-p "Process exited with code 0" result))
    (should (string-match-p "Output:" result))))

(ert-deftest crush-test/result-format-session ()
  "A running command should carry a session id and no exit code."
  (let* ((result (crush-exec--format-running "ticks" 7)))
    (should (string-match-p "Process running with session ID 7" result))
    (should (string-match-p "Output:" result))
    (should-not (string-match-p "exited" result))))

;;; 6. Output truncation

(ert-deftest crush-test/truncate-output ()
  "Long output should be capped with a head/tail split and an omission marker."
  (let* ((body (make-string 2000 ?x))
         (truncated (crush-exec--truncate-output body)))
    (should (string= truncated body)))
  (let* ((crush-tool-max-output 50)
         (body (concat (make-string 40 ?a) (make-string 40 ?b)))
         (truncated (crush-exec--truncate-output body)))
    (should (string-match-p "omitted" truncated))
    (should (string-prefix-p (make-string 35 ?a) truncated)))
  (should (string= (crush-exec--truncate-output "") "no output")))

(ert-deftest crush-test/truncate-output-preserves-leading-whitespace ()
  "Leading whitespace (indentation) is preserved in command output."
  (should (string= (crush-exec--truncate-output "  indented\nnext")
                   "  indented\nnext"))
  (should (string= (crush-exec--truncate-output "\t\ttabbed")
                   "\t\ttabbed"))
  (should (string= (crush-exec--truncate-output "  \n") "no output")))

;;; 7. Tool-block buffer formatting

(ert-deftest crush-test/tool-block-renders-as-markdown ()
  "`crush--tool-block-insert' should render a tool block as valid markdown.
The header carries the tool name, an icon, and a human summary; the
output is a fenced code block tagged `text`."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nAGENTS.md"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*🔧 exec_command\\*\\*" content))
            (should (string-match-p "ran: ls\n" content))
            (should (string-match-p "```text\n" content))
            (should (string-match-p "```\n$" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-adds-blank-line-after-bare-content ()
  "Test that a tool block after bare content gains a blank line.
The blank line appears before the header so the block stays valid markdown."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert "what it does"))
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nAGENTS.md"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "what it does\n\n\\*\\*🔧 exec_command\\*\\*"
                                    content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-reuses-existing-blank-line ()
  "Test that a tool block reuses an existing blank line.
The tool block does not add extra blank lines after content already
ending in a blank line."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert "what it does\n\n"))
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nAGENTS.md"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "\n\n\n\n\\*\\*🔧" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-exec-command-summary-fields ()
  "The exec_command summary renders every metadata field, present or default."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\",\"workdir\":\"/tmp\",\"yield_time_ms\":7500,\"shell\":\"/bin/zsh\",\"login\":true}"
                 :result "out"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "ran: ls\n" content))
            (should (string-match-p "in: /tmp\n" content))
            (should (string-match-p "yield 7.5s" content))
            (should (string-match-p "shell /bin/zsh" content))
            (should (string-match-p "login yes" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-exec-command-shows-defaults ()
  "Test that a bare exec_command renders all defaults.
The defaults are the real cwd, configured yield, `shell-file-name', and
login no."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "out"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "ran: ls\n" content))
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
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-escapes-backticks-in-cmd ()
  "Backtick runs inside the displayed cmd are fenced, keeping valid markdown.
The cmd is rendered as a fenced code block below the header, so
backticks in the command text never break inline code spans."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"echo `pwd`\"}"
                 :result "out"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            ;; The cmd is a single line; backticks are literal text.
            (should (string-match-p "ran: echo `pwd`\n"
                                    content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-write-stdin-summary ()
  "The write_stdin summary renders session id, input, and yield."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "write_stdin" :id "call_2"
                 :args-json "{\"session_id\":7,\"input\":\"hello\"}"
                 :result "out"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "\\*\\*⌨️ write_stdin\\*\\*" content))
            (should (string-match-p "session 7" content))
            (should (string-match-p "wrote: hello\n" content))
            (should (string-match-p "yield 1s" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-read-only-and-tagged ()
  "Tool blocks should be read-only and tagged `crush-region-type' tool."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nfiles"
                 :exit 0)
           crush--prompt-id)
          (goto-char (point-min))
          (search-forward "🔧 exec_command")
          (goto-char (match-beginning 0))
          (should (eq (get-text-property (point) 'crush-region-type) 'tool))
          (should (get-text-property (point) 'read-only))
          (should-error (insert "x") :type 'text-read-only))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-minimal-write-stdin ()
  "Test that a minimal write_stdin block renders session, input, and yield.
A block with only a session id renders the session, empty input
(as a fenced block), yield, and no output fence."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "write_stdin" :id "call_2"
                 :args-json "{\"session_id\":7}")
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "session 7" content))
            (should (string-match-p "wrote: \n" content))
            (should (string-match-p "yield 1s" content))
            ;; No output fence (no result), but arg blocks use fences.
            (should-not (string-match-p "```text\nProcess" content))))
      (crush-test--cleanup))))


(ert-deftest crush-test/tool-block-multiline-cmd-is-fenced ()
  "A multiline cmd renders as a fenced block, not a broken inline span.
CommonMark inline code is single-line; a multiline cmd must be fenced
so the header stays valid markdown."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"for i in 1 2 3; do\\necho $i\\ndone\"}"
                 :result "out"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     "ran:\n\n```text\nfor i in 1 2 3; do\necho $i\ndone\n```"
                     content))
            ;; The header line must not contain the cmd inline.
            (should-not (string-match-p "ran `for" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-multiline-cmd-backticks-escaped ()
  "A multiline cmd containing triple backticks uses a 4-backtick fence.
The `crush--fence-str' mechanism extends the fence to outmatch any
backtick run in the argument value."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"echo ```markdown\\n# heading\\n```\"}"
                 :result "out"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            ;; The arg fence is 4 backticks (one more than the 3-run).
            (should (string-match-p "ran:\n\n````text\n" content))
            (should (string-match-p "````\n" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-multiline-write-stdin-input ()
  "A multiline write_stdin input renders as a fenced block."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "write_stdin" :id "call_2"
                 :args-json "{\"session_id\":3,\"input\":\"line1\\nline2\"}"
                 :result "ok"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     "wrote:\n\n```text\nline1\nline2\n```" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-multiline-query ()
  "A multiline web_search query renders as a fenced block."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "web_search" :id "call_3"
                 :args-json "{\"query\":\"foo\\nbar\"}"
                 :result "results"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p
                     "query:\n\n```text\nfoo\nbar\n```" content))))
      (crush-test--cleanup))))

(ert-deftest crush-test/tool-block-arg-blocks-not-tool-output ()
  "Argument fenced blocks are `tool' region, not `tool-output'.
Only the output fence interior is tagged `tool-output' for history
extraction; argument blocks are display decoration."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush--tool-block-insert
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "Process exited with code 0\nOutput:\nfiles"
                 :exit 0)
           crush--prompt-id)
          (goto-char (point-min))
          (search-forward "ran:")
          (should (eq (get-text-property (point) 'crush-region-type) 'tool))
          (should-not (eq (get-text-property (point) 'crush-region-type)
                          'tool-output))
          ;; The output fence interior IS tool-output.
          (search-forward "Process exited")
          (should (eq (get-text-property (point) 'crush-region-type)
                      'tool-output)))
      (crush-test--cleanup))))

;;; 8. Fence escaping: protect against nested fences in tool output

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
           (list :name "exec_command" :id "call_1"
                 :args-json "{\"cmd\":\"ls\"}"
                 :result "regular output with ```nested``` fence"
                 :exit 0)
           crush--prompt-id)
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "````text\n" content))
            (should (string-match-p "````\n$" content))))
      (crush-test--cleanup))))

(provide 'crush-test-tools)
;;; crush-test-tools.el ends here
