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
  "Without context, messages should be system + user with just the prompt.
The system message should carry the dynamic system prompt (<env> block)."
  (let* ((req (crush-openai-compose-request "Hello" "m"))
         (msgs (alist-get 'messages req)))
    (should (string= (alist-get 'model req) "m"))
    (should (eq (alist-get 'stream req) t))
    (should (= (length msgs) 2))
    (should (string= (crush--openai-alist-get "role" (nth 0 msgs)) "system"))
    (should (string= (crush--openai-alist-get "role" (nth 1 msgs)) "user"))
    (should (string-match-p "<env>"
                            (crush--openai-alist-get "content" (nth 0 msgs))))
    (should (string= (crush--openai-alist-get "content" (nth 1 msgs)) "Hello"))))

(ert-deftest crush-test/openai-compose-respects-options ()
  "Optional max-tokens, temperature, thinking, and effort land in the body."
  (let ((crush-openai-max-tokens 1234)
        (crush-openai-temperature 0.5)
        (crush-openai-thinking t)
        (crush-openai-reasoning-effort "high"))
    (let ((req (crush-openai-compose-request "P" "my-model")))
      (should (= (alist-get 'max_tokens req) 1234))
      (should (= (alist-get 'temperature req) 0.5))
      (should (eq (alist-get 'thinking req) t))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest crush-test/openai-compose-tools-by-default ()
  "With `crush-tools-enabled' t the body announces all registered tools.
The default is non-nil, so `tool_choice' is `auto'."
  (let ((req (crush-openai-compose-request "P" "m")))
    (should (assq 'tools req))
    (should (equal (alist-get 'tool_choice req) "auto"))
    (let ((tools (alist-get 'tools req)))
      (should (vectorp tools))
      (should (>= (length tools) 2))
      (let ((names (mapcar (lambda (tool)
                             (cdr (assq 'name
                                        (cdr (assq 'function tool)))))
                           (append tools nil))))
        (should (member "exec_command" names))
        (should (member "write_stdin" names))))))

(ert-deftest crush-test/openai-compose-no-tools-when-disabled ()
  "With `crush-tools-enabled' nil the body has no `tools' or `tool_choice'."
  (let ((crush-tools-enabled nil))
    (let ((req (crush-openai-compose-request "P" "m")))
      (should-not (assq 'tools req))
      (should-not (assq 'tool_choice req)))))

(ert-deftest crush-test/openai-compose-continuation-replaces-user ()
  "A non-nil CONTINUATION replaces the user message with follow-up msgs."
  (let ((msgs (alist-get 'messages
                         (crush-openai-compose-request
                          "P" "m" nil
                          '(((role . "assistant") (content . nil)
                             (tool_calls . [(id . "c1")]))
                            ((role . "tool") (tool_call_id . "c1")
                             (content . "ok")))))))
    (should (= (length msgs) 3))  ; system + assistant + tool
    (should (string= (cdr (assoc 'role (nth 1 msgs))) "assistant"))
    (should (string= (cdr (assoc 'tool_call_id (nth 2 msgs))) "c1"))))

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
    (let* ((req (crush-openai-compose-request "explain" "m" history))
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
    (let* ((req (crush-openai-compose-request "next" "m" history))
           (msgs (alist-get 'messages req)))
      (should (= (length msgs) 4))   ; system + 2 history + current user
      (let ((a (nth 2 msgs)))
        (should (string= (crush--openai-alist-get "content" a) "short answer"))
        (should (string= (crush--openai-alist-get "reasoning_content" a)
                         "deep chain of thought"))))))

;;; 3. System prompt: <env> block

(ert-deftest crush-test/openai-env-block-no-git ()
  "The <env> block includes working dir, platform, and date.
When not in a git repo, no git lines appear."
  (let* ((default-directory "/tmp/nonexistent-project/")
         (env (crush-openai--build-env-block)))
    (should (string-match-p "<env>" env))
    (should (string-match-p "Working directory: /tmp/nonexistent-project" env))
    (should (string-match-p "Is directory a git repo: no" env))
    (should (string-match-p "Platform:" env))
    (should (string-match-p "Today's date:" env))
    (should-not (string-match-p "Git status" env))
    (should (string-match-p "</env>" env))))

(ert-deftest crush-test/openai-env-block-field-order ()
  "The <env> block fields follow the CLI order: working directory,
git repo status, platform, then date — no reversal."
  (let* ((default-directory "/tmp/nonexistent-project/")
         (env (crush-openai--build-env-block))
         (wd-pos (string-match "Working directory:" env))
         (git-pos (string-match "Is directory a git repo:" env))
         (platform-pos (string-match "Platform:" env))
         (date-pos (string-match "Today's date:" env)))
    (should (< wd-pos git-pos))
    (should (< git-pos platform-pos))
    (should (< platform-pos date-pos))))

(ert-deftest crush-test/openai-env-block-with-git ()
  "The <env> block includes git branch/status/commits when in a git repo.
Uses the crush.el repo root (always a git repo during tests)."
  (let ((default-directory
         (file-name-directory
          (or buffer-file-name load-file-name
              (expand-file-name "crush-openai.el" default-directory)))))
    (let ((env (crush-openai--build-env-block)))
      (should (string-match-p "<env>" env))
      (should (string-match-p "Is directory a git repo: yes" env))
      (should (string-match-p "Current branch:" env))
      (should (string-match-p "Status:" env))
      (should (string-match-p "Recent commits:" env))
      (should (string-match-p "</env>" env)))))

;;; 4. System prompt: context file discovery

(ert-deftest crush-test/openai-discover-context-files-finds-agents ()
  "Discover AGENTS.md in the working directory and return its content."
  (let* ((repo-root (file-name-directory
                     (or buffer-file-name load-file-name
                         (expand-file-name "crush-openai.el" default-directory))))
         (default-directory repo-root)
         (files (crush-openai--discover-context-files
                 (list "AGENTS.md"))))
    (should files)
    (should (= (length files) 1))
    (let ((entry (car files)))
      (should (string= (car entry) "AGENTS.md"))
      (should (string-match-p "crush.el" (cdr entry))))))

(ert-deftest crush-test/openai-discover-context-files-missing-returns-nil ()
  "Non-existent files are omitted from the result."
  (let* ((default-directory "/tmp/")
         (files (crush-openai--discover-context-files
                 (list "DOES-NOT-EXIST.md"))))
    (should-not files)))

;;; 5. System prompt: <project_context> and <user_preferences> blocks

(ert-deftest crush-test/openai-project-context-block-with-files ()
  "The <project_context> block wraps file contents in XML."
  (let ((block (crush-openai--build-project-context-block
                (list (cons "AGENTS.md" "Project rules here")
                      (cons "CRUSH.md" "More rules")))))
    (should (string-match-p "# Project-Specific Context" block))
    (should (string-match-p "Make sure to follow the instructions" block))
    (should (string-match-p "<project_context>" block))
    (should (string-match-p "<file path=\"AGENTS.md\">" block))
    (should (string-match-p "Project rules here" block))
    (should (string-match-p "<file path=\"CRUSH.md\">" block))
    (should (string-match-p "More rules" block))
    (should (string-match-p "</project_context>" block))))

(ert-deftest crush-test/openai-project-context-block-empty-returns-nil ()
  "Empty file list returns nil (no block)."
  (should-not (crush-openai--build-project-context-block nil)))

(ert-deftest crush-test/openai-user-preferences-block-with-files ()
  "The <user_preferences> block wraps global file contents in XML."
  (let ((block (crush-openai--build-user-preferences-block
                (list (cons "~/.config/crush/CRUSH.md" "Global rules")))))
    (should (string-match-p "# User context" block))
    (should (string-match-p "<user_preferences>" block))
    (should (string-match-p "<file path=" block))
    (should (string-match-p "Global rules" block))
    (should (string-match-p "</user_preferences>" block))))

(ert-deftest crush-test/openai-user-preferences-block-empty-returns-nil ()
  "Empty global file list returns nil (no block)."
  (should-not (crush-openai--build-user-preferences-block nil)))

;;; 6. System prompt: full assembly

(ert-deftest crush-test/openai-build-system-prompt-uncached-basic ()
  "The full system prompt contains base text, <env>, and context blocks.
Uses the crush.el repo root so AGENTS.md is discovered."
  (let* ((repo-root (file-name-directory
                     (or buffer-file-name load-file-name
                         (expand-file-name "crush-openai.el" default-directory))))
         (default-directory repo-root)
         (crush-openai-global-context-paths nil)
         (prompt (crush-openai--build-system-prompt-uncached)))
    (should (string-match-p "You are a helpful assistant" prompt))
    (should (string-match-p "<env>" prompt))
    (should (string-match-p "Working directory:" prompt))
    (should (string-match-p "</env>" prompt))
    (should (string-match-p "# Project-Specific Context" prompt))
    (should (string-match-p "<project_context>" prompt))
    (should (string-match-p "AGENTS.md" prompt))
    (should (string-match-p "</project_context>" prompt))
    (should-not (string-match-p "<user_preferences>" prompt))))

(ert-deftest crush-test/openai-build-system-prompt-uncached-no-context ()
  "With no context files, system prompt still has base text and <env>."
  (let* ((default-directory "/tmp/")
         (crush-openai-context-paths nil)
         (crush-openai-global-context-paths nil)
         (prompt (crush-openai--build-system-prompt-uncached)))
    (should (string-match-p "You are a helpful assistant" prompt))
    (should (string-match-p "<env>" prompt))
    (should (string-match-p "Working directory:" prompt))
    (should-not (string-match-p "<project_context>" prompt))
    (should-not (string-match-p "<user_preferences>" prompt))))

;;; 7. System prompt: cache (modtimes, hit, miss, invalidation)

(ert-deftest crush-test/openai-context-modtimes-existing-only ()
  "Return (path . modtime) for existing files only; skip missing."
  (let* ((repo-root (file-name-directory
                     (or buffer-file-name load-file-name
                         (expand-file-name "crush-openai.el" default-directory))))
         (default-directory repo-root)
         (mods (crush-openai--context-modtimes
                (list "AGENTS.md" "DOES-NOT-EXIST.md"))))
    (should (= (length mods) 1))
    (should (string= (car (nth 0 mods)) "AGENTS.md"))
    (should (cdr (nth 0 mods)))))

(ert-deftest crush-test/openai-context-modtimes-empty-for-nothing ()
  "No existing files yields nil."
  (let* ((default-directory "/tmp/")
         (mods (crush-openai--context-modtimes
                (list "DOES-NOT-EXIST.md"))))
    (should-not mods)))

(ert-deftest crush-test/openai-cache-hit-same-key ()
  "Second call with same key returns cached string without rebuild."
  (let* ((repo-root (file-name-directory
                     (or buffer-file-name load-file-name
                         (expand-file-name "crush-openai.el" default-directory)))))
    (setq-local default-directory repo-root)
    (setq-local crush-openai-global-context-paths nil)
    (setq-local crush-openai--cached-system-prompt nil)
    (setq-local crush-openai--cache-key nil)
    (let ((first (crush-openai--build-system-prompt))
          (second (crush-openai--build-system-prompt)))
      (should (string= first second))
      (should (string= first crush-openai--cached-system-prompt)))))

(ert-deftest crush-test/openai-cache-miss-on-working-dir-change ()
  "Changing default-directory triggers rebuild."
  (let* ((repo-root (file-name-directory
                     (or buffer-file-name load-file-name
                         (expand-file-name "crush-openai.el" default-directory)))))
    (setq-local default-directory repo-root)
    (setq-local crush-openai-global-context-paths nil)
    (setq-local crush-openai--cached-system-prompt nil)
    (setq-local crush-openai--cache-key nil)
    (let ((first (crush-openai--build-system-prompt)))
      (setq-local default-directory "/tmp/")
      (setq-local crush-openai-context-paths nil)
      (let ((second (crush-openai--build-system-prompt)))
        (should-not (string= first second))))))

(ert-deftest crush-test/openai-cache-miss-on-modtime-change ()
  "Modifying a context file triggers rebuild."
  (let* ((tmp-dir (make-temp-file "crush-test-" t))
         (ctx-file (expand-file-name "AGENTS.md" tmp-dir)))
    (setq-local default-directory (file-name-as-directory tmp-dir))
    (setq-local crush-openai-context-paths (list "AGENTS.md"))
    (setq-local crush-openai-global-context-paths nil)
    (setq-local crush-openai--cached-system-prompt nil)
    (setq-local crush-openai--cache-key nil)
    (unwind-protect
        (progn
          (write-region "version 1" nil ctx-file)
          (let ((first (crush-openai--build-system-prompt)))
            (should (string-match-p "version 1" first))
            ;; Touch the file with new content + new modtime.
            (write-region "version 2" nil ctx-file)
            (let ((second (crush-openai--build-system-prompt)))
              (should (string-match-p "version 2" second))
              (should-not (string= first second)))))
      (delete-directory tmp-dir t))))

;;; 8. SSE parser

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

;;; 9. Tool protocol (registry, struct, parse, error result)

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
