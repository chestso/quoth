;;; crush-test-openai.el --- OpenAI client tests for crush  -*- lexical-binding: t; -*-
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
;;; The reusable OpenAI chat-completions client (crush-openai.el): request
;;; composition, history building, SSE parsing, and the wire helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("crush-openai"))
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

(defvar crush-tools-enabled t)

;;; 1. Request composition

(ert-deftest crush-test/openai-compose-no-context ()
  "Without context, messages should be system + user with just the prompt."
  (let ((crush-git-context nil))
    (let* ((req (crush-openai-compose-request "Hello" nil "m"))
           (msgs (alist-get 'messages req)))
      (should (string= (alist-get 'model req) "m"))
      (should (eq (alist-get 'stream req) t))
      (should (= (length msgs) 2))
      (should (string= (crush--openai-alist-get "role" (nth 0 msgs)) "system"))
      (should (string= (crush--openai-alist-get "role" (nth 1 msgs)) "user"))
      (should (string= (crush--openai-alist-get "content" (nth 1 msgs)) "Hello")))))

(ert-deftest crush-test/openai-compose-with-context-merges-preamble ()
  "With context, the user message should carry preamble + context + prompt."
  (let* ((req (crush-openai-compose-request "Do the thing" "**Attachment: foo**" "m"))
         (user-content (crush--openai-alist-get
                        "content"
                        (nth 1 (alist-get 'messages req)))))
    (should (string-match-p "The following markdown fenced code blocks" user-content))
    (should (string-match-p "\\*\\*Attachment: foo\\*\\*" user-content))
    (should (string-match-p "Do the thing$" user-content))))

(ert-deftest crush-test/openai-compose-respects-options ()
  "Optional max-tokens, temperature, thinking, and effort land in the body."
  (let ((crush-openai-max-tokens 1234)
        (crush-openai-temperature 0.5)
        (crush-openai-thinking t)
        (crush-openai-reasoning-effort "high"))
    (let ((req (crush-openai-compose-request "P" nil "my-model")))
      (should (= (alist-get 'max_tokens req) 1234))
      (should (= (alist-get 'temperature req) 0.5))
      (should (eq (alist-get 'thinking req) t))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest crush-test/openai-compose-tools-by-default ()
  "With `crush-tools-enabled' t the body announces exec_command.
The default is non-nil, so `tool_choice' is `auto'."
  (let ((req (crush-openai-compose-request "P" nil "m")))
    (should (assq 'tools req))
    (should (equal (alist-get 'tool_choice req) "auto"))
    (let ((tools (alist-get 'tools req)))
      (should (vectorp tools))
      (should (= (length tools) 2))
      (should (equal (cdr (assq 'name (cdr (assq 'function (aref tools 0)))))
                     "exec_command"))
      (should (equal (cdr (assq 'name (cdr (assq 'function (aref tools 1)))))
                     "write_stdin")))))

(ert-deftest crush-test/openai-compose-no-tools-when-disabled ()
  "With `crush-tools-enabled' nil the body has no `tools' or `tool_choice'."
  (let ((crush-tools-enabled nil))
    (let ((req (crush-openai-compose-request "P" nil "m")))
      (should-not (assq 'tools req))
      (should-not (assq 'tool_choice req)))))

(ert-deftest crush-test/openai-compose-continuation-replaces-user ()
  "A non-nil CONTINUATION replaces the user message with follow-up msgs."
  (let ((msgs (alist-get 'messages
                         (crush-openai-compose-request
                          "P" nil "m" nil
                          '(((role . "assistant") (content . nil)
                             (tool_calls . [(id . "c1")]))
                            ((role . "tool") (tool_call_id . "c1")
                             (content . "ok")))))))
    (should (= (length msgs) 3))  ; system + assistant + tool
    (should (string= (cdr (assoc 'role (nth 1 msgs))) "assistant"))
    (should (string= (cdr (assoc 'tool_call_id (nth 2 msgs))) "c1"))))

;;; 1b. Git context injection

(ert-deftest crush-test/openai-compose-injects-git-summary ()
  "When `crush-git-context' is t and the project is a git repo,
the user message should include git branch, status, and commits."
  (let* ((default-directory (make-temp-file "crush-git-test" t))
         (crush-git-context t))
    (unwind-protect
        (progn
          (call-process "git" nil nil nil "init" default-directory)
          (call-process "git" nil nil nil "-C" default-directory
                        "config" "user.email" "test@crush.el")
          (call-process "git" nil nil nil "-C" default-directory
                        "config" "user.name" "Crush Test")
          (let ((f (expand-file-name "README" default-directory)))
            (write-region "hello" nil f)
            (call-process "git" nil nil nil "-C" default-directory
                          "add" "README")
            (call-process "git" nil nil nil "-C" default-directory
                          "commit" "-m" "initial commit"))
          (let* ((req (crush-openai-compose-request "Hello" nil "m"))
                 (user-content (crush--openai-alist-get
                                "content"
                                (nth 1 (alist-get 'messages req)))))
            (should (string-match-p "<git_state>" user-content))
            (should (string-match-p "master" user-content))
            (should (string-match-p "Status: clean" user-content))
            (should (string-match-p "initial commit" user-content))
            (should (string-match-p "</git_state>" user-content))))
      (delete-directory default-directory t))))

(ert-deftest crush-test/openai-compose-omits-git-summary-when-disabled ()
  "When `crush-git-context' is nil, no git state is injected."
  (let* ((default-directory (make-temp-file "crush-git-test" t))
         (crush-git-context nil))
    (unwind-protect
        (progn
          (call-process "git" nil nil nil "init" default-directory)
          (call-process "git" nil nil nil "-C" default-directory
                        "config" "user.email" "test@crush.el")
          (call-process "git" nil nil nil "-C" default-directory
                        "config" "user.name" "Crush Test")
          (let ((f (expand-file-name "README" default-directory)))
            (write-region "hello" nil f)
            (call-process "git" nil nil nil "-C" default-directory
                          "add" "README")
            (call-process "git" nil nil nil "-C" default-directory
                          "commit" "-m" "initial commit"))
          (let* ((req (crush-openai-compose-request "Hello" nil "m"))
                 (user-content (crush--openai-alist-get
                                "content"
                                (nth 1 (alist-get 'messages req)))))
            (should-not (string-match-p "<git_state>" user-content))))
      (delete-directory default-directory t))))

(ert-deftest crush-test/openai-compose-no-git-summary-without-repo ()
  "When the project is not a git repo, no git state is injected."
  (let* ((default-directory (make-temp-file "crush-nogit-test" t))
         (crush-git-context t))
    (unwind-protect
        (let* ((req (crush-openai-compose-request "Hello" nil "m"))
               (user-content (crush--openai-alist-get
                              "content"
                              (nth 1 (alist-get 'messages req)))))
          (should-not (string-match-p "<git_state>" user-content)))
      (delete-directory default-directory t))))

;;; 2. Request composition with history (message alists)

(ert-deftest crush-test/openai-compose-history-tool-pair ()
  "History message alists (assistant with tool_calls + tool) ride as-is."
  (let ((history
         (list (list (cons 'role "user") (cons 'content "run ls"))
               (list (cons 'role "assistant")
                     (cons 'content nil)
                     (cons 'tool_calls
                           (vector (list (cons 'id "call_1")
                                         (cons 'type "function")
                                         (cons 'function
                                               (list (cons 'name "bash")
                                                     (cons 'arguments "{\"command\":\"ls\"}")))))))
               (list (cons 'role "tool")
                     (cons 'tool_call_id "call_1")
                     (cons 'content "<command>ls</command>\n<exit_code>0</exit_code>")))))
    (let* ((req (crush-openai-compose-request "explain" nil "m" history))
           (msgs (alist-get 'messages req)))
      (should (= (length msgs) 5))   ; system + 3 history + current user
      (should (string= (crush--openai-alist-get "role" (nth 0 msgs)) "system"))
      (should (string= (crush--openai-alist-get "role" (nth 1 msgs)) "user"))
      (should (string= (crush--openai-alist-get "role" (nth 2 msgs)) "assistant"))
      (should (string= (crush--openai-alist-get "role" (nth 3 msgs)) "tool"))
      (let ((tc-msg (nth 2 msgs)))
        (let ((tcs (crush--openai-alist-get "tool_calls" tc-msg)))
          (should (vectorp tcs))
          (let ((tc (aref tcs 0)))
            (should (string= (crush--openai-alist-get "id" tc) "call_1"))
            (should (string= (crush--openai-alist-get "name"
                                                      (crush--openai-alist-get "function" tc))
                             "bash"))))))))

(ert-deftest crush-test/openai-compose-history-reasoning-content ()
  "A history assistant message already carrying reasoning_content is kept."
  (let ((history
         (list (list (cons 'role "user") (cons 'content "q"))
               (list (cons 'role "assistant")
                     (cons 'content "short answer")
                     (cons 'reasoning_content "deep chain of thought")))))
    (let* ((req (crush-openai-compose-request "next" nil "m" history))
           (msgs (alist-get 'messages req)))
      (should (= (length msgs) 4))   ; system + 2 history + current user
      (let ((a (nth 2 msgs)))
        (should (string= (crush--openai-alist-get "content" a) "short answer"))
        (should (string= (crush--openai-alist-get "reasoning_content" a)
                         "deep chain of thought"))))))

;;; 3. SSE parser

(defun crush-test-openai--sse-state ()
  "Return a fresh, empty SSE parser state."
  (list :pending "" :done nil :tool-calls nil))

(ert-deftest crush-test/openai-sse-parser-single-delta ()
  "One complete delta event yields one content delta."
  (let* ((state (crush-test-openai--sse-state))
         (result (crush-openai-sse-feed
                  state
                  "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"))
         (deltas (car result)))
    (should (equal (nth 0 (car deltas)) 'content))
    (should (string= (nth 1 (car deltas)) "hi"))
    (should-not (plist-get (cdr result) :done))))

(ert-deftest crush-test/openai-sse-parser-done ()
  "[DONE] marks the stream finished."
  (let* ((state (crush-test-openai--sse-state))
         (result (crush-openai-sse-feed state "data: [DONE]\n\n"))
         (new-state (cdr result)))
    (should (plist-get new-state :done))))

(ert-deftest crush-test/openai-sse-parser-tool-calls ()
  "A tool_calls delta is accumulated into the state's :tool-calls vector."
  (let* ((state (crush-test-openai--sse-state))
         (result (crush-openai-sse-feed
                  state
                  "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]}}]}\n\n"))
         (new-state (cdr result))
         (tcs (plist-get new-state :tool-calls)))
    (should (vectorp tcs))
    (should (= (length tcs) 1))
    (should (string= (crush--openai-alist-get "id" (aref tcs 0)) "c1"))))

(ert-deftest crush-test/openai-alist-get-handles-both-key-types ()
  "`crush--openai-alist-get' finds values by symbol or string key."
  (let ((a '((role . "system") ("content" . "hi"))))
    (should (string= (crush--openai-alist-get 'role a) "system"))
    (should (string= (crush--openai-alist-get "role" a) "system"))
    (should (string= (crush--openai-alist-get 'content a) "hi"))))

;;; 4. Tool protocol (registry, struct, parse, error result)

(defun crush-test-openai--tool-call (name args-json)
  "Return a `crush-openai-tool-call' for NAME with ARGS-JSON (or nil)."
  (let ((call (crush-make-openai-tool-call :id "call_test" :name name)))
    (when args-json
      (setf (crush-openai-tool-call-args call)
            (crush-openai-parse-tool-args args-json)))
    call))

(ert-deftest crush-test/openai-tool-registry-exists ()
  "The protocol owns a registry mapping tool names to executers."
  (should (boundp 'crush-openai-tool-registry))
  (should (listp crush-openai-tool-registry)))

(ert-deftest crush-test/openai-tool-execute-dispatches ()
  "`crush-openai-execute-tool' dispatches to the registry executer.
A stubbed tool registered in the protocol registry is invoked."
  (let ((crush-openai-tool-registry
         (list (cons "testtool"
                     (lambda (_call) (cons "stub-result" 0))))))
    (let ((call (crush-test-openai--tool-call "testtool"
                                              "{\"command\":\"x\"}")))
      (let ((result (crush-openai-execute-tool call)))
        (should (equal result (cons "stub-result" 0)))))))

(ert-deftest crush-test/openai-parse-tool-args-valid ()
  "`crush-openai-parse-tool-args' turns JSON into a keyword plist."
  (should (equal (crush-openai-parse-tool-args
                  "{\"command\":\"ls\",\"working_dir\":\"/tmp\"}")
                 '(:command "ls" :working_dir "/tmp"))))

(ert-deftest crush-test/openai-parse-tool-args-malformed ()
  "Malformed or non-object arguments yield nil."
  (should (null (crush-openai-parse-tool-args "not json")))
  (should (null (crush-openai-parse-tool-args "")))
  (should (null (crush-openai-parse-tool-args nil)))
  (should (null (crush-openai-parse-tool-args "[1,2]"))))

(ert-deftest crush-test/openai-tool-error-result-shape ()
  "`crush-openai-tool-error-result' returns an error pair with exit -1."
  (let ((result (crush-openai-tool-error-result "boom")))
    (should (consp result))
    (should (= (cdr result) -1))
    (should (string-match-p "boom" (car result)))))

(provide 'crush-test-openai)
;;; crush-test-openai.el ends here
