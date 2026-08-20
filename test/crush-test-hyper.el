;;; crush-test-hyper.el --- Hyper provider tests for crush  -*- lexical-binding: t; -*-
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
;;; Request composition, SSE parser, curl transport, token resolution, wire tests via dummy server.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("crush"))
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

;;; Shared harness helpers live in `crush-test.el', loaded at runtime by
;;; the test runner; declare them here so byte-compiling this file in
;;; isolation produces no warnings.
(defvar crush-test--root)
(declare-function crush-test--fresh-buffer "crush-test" ())
(declare-function crush-test--cleanup "crush-test" ())

(defvar crush-test--captured-completion nil
  "Capture slot for `crush-test/hyper-send-injects-completion'.")

;;; 91. Hyper provider: request composition

(ert-deftest crush-test/hyper-compose-no-context ()
  "Without context, messages should be system + user with just the prompt."
  (let ((crush-model nil))
    (let* ((req (crush-openai-compose-request "Hello" nil "m"))
           (msgs (alist-get 'messages req)))
      (should (string= (alist-get 'model req) "m"))
      (should (eq (alist-get 'stream req) t))
      (should (= (length msgs) 2))
      (should (string= (crush--openai-alist-get "role" (nth 0 msgs)) "system"))
      (should (string= (crush--openai-alist-get "role" (nth 1 msgs)) "user"))
      (should (string= (crush--openai-alist-get "content" (nth 1 msgs)) "Hello")))))

(ert-deftest crush-test/hyper-compose-with-context-merges-preamble ()
  "With context, the user message should carry preamble + context + prompt."
  (let* ((req (crush-openai-compose-request "Do the thing" "**Attachment: foo**" "m"))
         (user-content (crush--openai-alist-get "content"
                                                (nth 1 (alist-get 'messages req)))))
    (should (string-match-p "The following markdown fenced code blocks" user-content))
    (should (string-match-p "\\*\\*Attachment: foo\\*\\*" user-content))
    (should (string-match-p "Do the thing$" user-content))))

(ert-deftest crush-test/hyper-compose-respects-defcustoms ()
  "Model, max-tokens, temperature, thinking, reasoning-effort should land in body."
  (let ((crush-model "my-model")
        (crush-openai-max-tokens 1234)
        (crush-openai-temperature 0.5)
        (crush-openai-thinking t)
        (crush-openai-reasoning-effort "high"))
    ;; The model is resolved by the caller (the facade passes the provider
    ;; model slot derived from `crush-model'); compose uses it directly.
    (let ((req (crush-openai-compose-request "P" nil crush-model)))
      (should (string= (alist-get 'model req) "my-model"))
      (should (= (alist-get 'max_tokens req) 1234))
      (should (= (alist-get 'temperature req) 0.5))
      (should (eq (alist-get 'thinking req) t))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest crush-test/hyper-compose-model-default ()
  "When no model is set, the crush default model is used."
  (let ((crush-model nil))
    (should (string= (alist-get 'model (crush-openai-compose-request "P" nil nil))
                     crush-openai-default-model))))

(ert-deftest crush-test/hyper-compose-tools-by-default ()
  "With `crush-tools-enabled' t the body announces all registered tools.
The default is non-nil, so `tool_choice' is `auto'."
  (let ((req (crush-openai-compose-request "P" nil "m")))
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

(ert-deftest crush-test/hyper-compose-no-tools-when-disabled ()
  "With `crush-tools-enabled' nil the body matches the pre-tools format.
It is byte-identical, with no `tools' or `tool_choice' key."
  (let ((crush-tools-enabled nil))
    (let ((req (crush-openai-compose-request "P" nil "m")))
      (should-not (assq 'tools req))
      (should-not (assq 'tool_choice req)))))

;;; 92. Hyper provider: SSE parser

(defun crush-test--sse-state ()
  "Return a fresh, empty SSE parser state."
  (list :pending "" :done nil :tool-calls nil))

(ert-deftest crush-test/sse-parser-single-delta ()
  "A single data event should yield its content delta."
  (let* ((result (crush-openai-sse-feed
                  (crush-test--sse-state)
                  "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"))
         (deltas (car result)))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) deltas)
                   '((content . "Hello"))))
    (should-not (plist-get (cdr result) :done))))

(ert-deftest crush-test/sse-parser-multiple-events-per-chunk ()
  "A chunk with several events should yield several deltas."
  (let* ((chunk (concat
                 "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n"
                 "data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n"
                 "data: [DONE]\n\n"))
         (result (crush-openai-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((content . "one") (content . "two"))))
    (should (plist-get (cdr result) :done))))

(ert-deftest crush-test/sse-parser-chunk-split-mid-line ()
  "Events split across chunk boundaries should still parse."
  (let* ((state (crush-test--sse-state))
         (r1 (crush-openai-sse-feed state "data: {\"choices\":[{\"delta\":{\"con"))
         (r2 (crush-openai-sse-feed (cdr r1) "tent\":\"abc\"}}]}\n\n"))
         (r3 (crush-openai-sse-feed (cdr r2) "data: [DONE]\n\n")))
    (should (equal (car r1) nil))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car r2))
                   '((content . "abc"))))
    (should (plist-get (cdr r3) :done))))

(ert-deftest crush-test/sse-parser-crlf ()
  "CRLF line endings should be handled."
  (let* ((result (crush-openai-sse-feed
                  (crush-test--sse-state)
                  "data: {\"choices\":[{\"delta\":{\"content\":\"CR\"}}]}\r\n\r\n")))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((content . "CR"))))))

(ert-deftest crush-test/sse-parser-multiline-data-payload ()
  "A data payload spanning several data: lines should be joined."
  (let* ((chunk (concat "data: {\"choices\":[{\"delta\":{\"content\":\"line"
                        "\"}}]}\n"
                        "data: {\"choices\":[{\"delta\":{\"content\":\" two\"}}]}\n\n"))
         (result (crush-openai-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((content . "line") (content . " two"))))))

(ert-deftest crush-test/sse-parser-reasoning-delta ()
  "A reasoning_content delta should yield a reasoning-typed delta."
  (let* ((result (crush-openai-sse-feed
                  (crush-test--sse-state)
                  "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n")))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((reasoning . "think"))))
    (should-not (plist-get (cdr result) :done))))

(ert-deftest crush-test/sse-parser-reasoning-then-content ()
  "Reasoning deltas and content deltas should be typed distinctly.
Both arrive in the same stream; the caller must be able to tell
which region each delta belongs to."
  (let* ((chunk (concat
                 "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n"
                 "data: {\"choices\":[{\"delta\":{\"content\":\"seen\"}}]}\n\n"))
         (result (crush-openai-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((reasoning . "think") (content . "seen"))))))

(ert-deftest crush-test/sse-tool-calls-delta ()
  "A tool_calls delta should yield a (tool_calls nil ORIG) delta."
  (let* ((result (crush-openai-sse-feed
                  (crush-test--sse-state)
                  (concat "data: {\"choices\":[{\"delta\":"
                          "{\"tool_calls\":[{\"index\":0,\"id\":\"call_x\","
                          "\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"com\"}}]}}]}\n\n"))))
    (let ((deltas (car result)))
      (should (= (length deltas) 1))
      (should (eq (nth 0 (nth 0 deltas)) 'tool_calls))
      (should (null (nth 1 (nth 0 deltas))))
      (should (nth 2 (nth 0 deltas))))))

(ert-deftest crush-test/sse-tool-calls-merge-by-index ()
  "Tool calls delta arguments should be glued across chunks by index."
  (let* ((s1 (crush-test--sse-state))
         (json1 (json-encode '((choices . [((delta (tool_calls . [((index . 0) (id . "call_x") (function (name . "bash") (arguments . "part1")))])))]))))
         (json2 (json-encode '((choices . [((delta (tool_calls . [((index . 0) (function (arguments . "part2")))])))]))))
         (r1 (crush-openai-sse-feed
              s1 (concat "data: " json1 "\n\n")))
         (r2 (crush-openai-sse-feed
              (cdr r1) (concat "data: " json2 "\n\n"))))
    (let ((tcs (plist-get (cdr r2) :tool-calls)))
      (should (vectorp tcs))
      (should (>= (length tcs) 1))
      (let ((args (crush--openai-alist-get
                   "arguments"
                   (crush--openai-alist-get
                    "function"
                    (aref tcs 0)))))
        (should (string= args "part1part2"))))))

(ert-deftest crush-test/sse-mixed-content-and-tool-calls ()
  "A chunk with both content and tool_calls should yield both deltas."
  (let* ((result (crush-openai-sse-feed
                  (crush-test--sse-state)
                  (concat "data: {\"choices\":[{\"delta\":"
                          "{\"tool_calls\":[{\"index\":0,\"id\":\"call_x\","
                          "\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n\n"
                          "data: {\"choices\":[{\"delta\":"
                          "{\"content\":\"text\"}}]}\n\n"))))
    (let ((deltas (car result)))
      (should (= (length deltas) 2))
      (should (eq (nth 0 (nth 0 deltas)) 'tool_calls))
      (should (eq (nth 0 (nth 1 deltas)) 'content))
      (should (string= (nth 1 (nth 1 deltas)) "text")))))

(ert-deftest crush-test/sse-parser-error-payload ()
  "An error data payload should set done and surface the message."
  (let* ((result (crush-openai-sse-feed
                  (crush-test--sse-state)
                  "data: {\"error\":\"boom\"}\n\n")))
    (should (plist-get (cdr result) :done))
    (should (string= (plist-get (cdr result) :error) "boom"))))

(ert-deftest crush-test/sse-on-event-fires-per-data-event ()
  "With `:on-event', the callback sees every raw payload.
It fires for each complete `data:' event, in order, before dispatch."
  (let ((events nil))
    (let* ((result (crush-openai-sse-feed
                    (crush-test--sse-state)
                    "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n"
                    :on-event (lambda (payload) (push payload events))))
           (more (crush-openai-sse-feed
                  (cdr result)
                  "data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n"
                  :on-event (lambda (payload) (push payload events)))))
      (ignore more)
      (should (equal (nreverse events)
                     '("{\"choices\":[{\"delta\":{\"content\":\"one\"}}]}"
                       "{\"choices\":[{\"delta\":{\"content\":\"two\"}}]}"))))))

(ert-deftest crush-test/sse-on-event-fires-only-for-done-events ()
  "The callback fires only for complete `data:' events.
An unterminated fragment (no blank line) is not an event; `[DONE]'
is, with its raw text."
  (let* ((events nil)
         (on-event (lambda (payload) (push payload events))))
    (let* ((partial (crush-openai-sse-feed
                     (crush-test--sse-state)
                     "data: {\"choices\":[{\"delta\":{\"con"
                     :on-event on-event))
           (a (crush-openai-sse-feed
               (cdr partial)
               "tent\":\"x\"}}]}\n\n"
               :on-event on-event))
           (b (crush-openai-sse-feed
               (cdr a)
               "data: [DONE]\n\n"
               :on-event on-event)))
      (ignore b)
      (should (equal (nreverse events)
                     '("{\"choices\":[{\"delta\":{\"content\":\"x\"}}]}"
                       "[DONE]"))))))

(ert-deftest crush-test/sse-event-worth-pretty-final-usage-chunk ()
  "The final chunk is worth pretty-printing.
It carries finish_reason and usage, the conversation's statistics,
regardless of formatting."
  (let ((payload (concat
                  "{\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{},"
                  "\"finish_reason\":\"stop\"}],"
                  "\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":70,"
                  "\"total_tokens\":90}}")))
    (should (crush--openai-event-worth-pretty-p payload))))

(ert-deftest crush-test/sse-event-worth-pretty-long-content ()
  "A delta with long content (>= 40 chars) is pretty-printed.
Large streamed chunks stay readable in the debug log."
  (let ((payload (concat
                  "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\""
                  (make-string 40 ?a)
                  "\"},\"finish_reason\":null}]}")))
    (should (crush--openai-event-worth-pretty-p payload))))

(ert-deftest crush-test/sse-event-not-worth-pretty-short-delta ()
  "A short per-token delta stays compact.
It is not pretty-printed, keeping the debug log bounded during streams."
  (dolist (payload '("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"We\"},\"finish_reason\":null}]}"
                     "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"Hello\"},\"finish_reason\":null}]}"
                     "data: [DONE]"))
    (should-not (crush--openai-event-worth-pretty-p payload))))

;;; 92c. Hyper transport: filter state persistence and curl config

(ert-deftest crush-test/hyper-transport-filter-persists-split-events ()
  "A JSON SSE event split across filter chunks must fully stream.
Regression test: the filter previously persisted the non-existent
`:sse' key of the parser state, dropping the `:pending' fragment between
chunks and silently discarding any event split across them."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((target (current-buffer))
                (proc (make-pipe-process :name "crush-hyper-test-filter"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-sse (crush-openai-sse-new-state))
            (process-put proc :crush-on-delta
                         (crush-test--hyper-on-delta target))
            (process-put proc :crush-done-callback #'ignore)
            (process-put proc :crush-head "")
            (process-put proc :crush-head-parsed nil)
            (process-put proc :crush-status nil)
            (process-put proc :crush-url "http://test/chat/completions")
            (process-put proc :crush-model "m")
            (process-put proc :crush-token-p nil)
            ;; Chunk 1: HTTP head plus the first half of a JSON SSE event.
            (crush--openai-curl-filter
             proc "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"choices\":[{\"delta\":{\"con")
            ;; Chunk 2: the rest of the event plus [DONE].  With the bug
            ;; this chunk's `:pending' was lost, so \"hi\" never streamed.
            (crush--openai-curl-filter
             proc "tent\":\"hi\"}}]}\n\ndata: [DONE]\n\n")
            (with-current-buffer target
              (goto-char (point-min))
              (should (search-forward "hi" nil t)))
            (when (process-live-p proc) (delete-process proc))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-transport-timeout-in-curl-config ()
  "`crush-openai-timeout' should reach the curl config as max-time."
  (let ((received nil)
        (proc (make-pipe-process :name "crush-hyper-test-cap" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _args) proc))
                  ((symbol-function 'process-send-string)
                   (lambda (_p string) (push string received)))
                  ((symbol-function 'process-send-eof) #'ignore))
          (let ((crush-openai-timeout 45))
            (crush-openai-request
             "http://127.0.0.1:1" "tok"
             (crush-openai-compose-request "hi" nil "m")
             #'ignore #'ignore)))
      (delete-process proc))
    (should (string-match-p "max-time = 45"
                            (mapconcat #'identity (nreverse received) "\n")))))

(ert-deftest crush-test/hyper-request-emits-session-headers ()
  "With the cache gate on, both session headers are sent.
They are `x-session-id' and `x-session-affinity', with the same
XXH3-64 hash."
  (let ((received nil)
        (proc (make-pipe-process :name "crush-hyper-test-cap" :noquery t))
        (crush-hyper-session-cache-p t)
        (uuid "f47ac10b-58cc-4372-a567-0e02b2c3d479"))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _args) proc))
                  ((symbol-function 'process-send-string)
                   (lambda (_p string) (push string received)))
                  ((symbol-function 'process-send-eof) #'ignore))
          (crush-openai-request
           "http://127.0.0.1:1" "tok"
           (crush-openai-compose-request "hi" nil "m")
           #'ignore #'ignore nil (crush-xxh3-hash64 uuid)))
      (delete-process proc))
    (let ((config (mapconcat #'identity (nreverse received) "\n")))
      (should (string-match-p "header = \"x-session-id: db22027126414ba6\""
                              config))
      (should (string-match-p
               "header = \"x-session-affinity: db22027126414ba6\""
               config)))))

(ert-deftest crush-test/hyper-request-sends-user-agent ()
  "The curl config carries a User-Agent header.\nIt defaults to the same value Hyper receives from the Crush CLI's\nfantasy SDK."
  (let ((received nil)
        (proc (make-pipe-process :name "crush-hyper-test-ua" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _args) proc))
                  ((symbol-function 'process-send-string)
                   (lambda (_p string) (push string received)))
                  ((symbol-function 'process-send-eof) #'ignore))
          (crush-openai-request
           "http://127.0.0.1:1" "tok"
           (crush-openai-compose-request "hi" nil "m")
           #'ignore #'ignore))
      (delete-process proc))
    (should (string-match-p
             "header = \"User-Agent: Charm-Fantasy/0.41.0"
             (mapconcat #'identity (nreverse received) "\n")))))

(ert-deftest crush-test/hyper-method-sends-x-crush-id-by-default ()
  "The default setting passes a stable per-machine ID.
Repeated sends resolve to the same value."
  (let ((captured nil))
    (cl-letf (((symbol-function 'crush-openai-request)
               (lambda (_base _tok _body _on _cb &optional _err _sess id)
                 (setq captured id)
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t)))
              ((symbol-function 'crush--history-for) (lambda (_b) nil)))
      (unwind-protect
          (let ((provider (crush-make-hyper-provider
                           :buffer (current-buffer)
                           :base-url "http://127.0.0.1:1"
                           :token "tok")))
            (crush-provider-send-prompt provider "hi")
            (should (string-match-p "[0-9a-f]\\{16\\}" (or captured "")))
            (let ((first captured))
              (crush-provider-send-prompt provider "hi")
              (should (string= first captured))))
        (crush-test--cleanup)))))

(ert-deftest crush-test/hyper-x-crush-id-forms ()
  "The resolver accepts several value forms.
It accepts t (derive), a string (verbatim), a function (called), and
nil (omit); the transport emits the header only when the value is
non-nil."
  (should (string-match-p "[0-9a-f]\\{16\\}" (crush-hyper--x-crush-id)))
  (let ((crush-hyper-x-crush-id "my-id"))
    (should (string= "my-id" (crush-hyper--x-crush-id))))
  (let ((crush-hyper-x-crush-id (lambda () "fn-id")))
    (should (string= "fn-id" (crush-hyper--x-crush-id))))
  (let ((crush-hyper-x-crush-id nil))
    (should-not (crush-hyper--x-crush-id)))
  ;; Wire: an explicit id lands in the config; nil omits it.
  (cl-flet ((capture (id)
              (let ((received nil)
                    (proc (make-pipe-process :name "crush-hyper-test-xf"
                                             :noquery t)))
                (unwind-protect
                    (cl-letf (((symbol-function 'make-process)
                               (lambda (&rest _args) proc))
                              ((symbol-function 'process-send-string)
                               (lambda (_p string) (push string received)))
                              ((symbol-function 'process-send-eof) #'ignore))
                      (crush-openai-request
                       "http://127.0.0.1:1" "tok"
                       (crush-openai-compose-request "hi" nil "m")
                       #'ignore #'ignore nil nil id))
                  (delete-process proc))
                (mapconcat #'identity (nreverse received) "\n"))))
    (should (string-match-p "header = \"x-crush-id: my-id\""
                            (capture "my-id")))
    (should-not (string-match-p "header = \"x-crush-id" (capture nil)))))

(ert-deftest crush-test/hyper-request-omits-session-headers-when-gate-off ()
  "With the cache gate off, neither session header is emitted."
  (let ((received nil)
        (proc (make-pipe-process :name "crush-hyper-test-cap" :noquery t))
        (crush-hyper-session-cache-p nil))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _args) proc))
                  ((symbol-function 'process-send-string)
                   (lambda (_p string) (push string received)))
                  ((symbol-function 'process-send-eof) #'ignore))
          (crush-openai-request
           "http://127.0.0.1:1" "tok"
           (crush-openai-compose-request "hi" nil "m")
           #'ignore #'ignore))
      (delete-process proc))
    (let ((config (mapconcat #'identity (nreverse received) "\n")))
      (should-not (string-match-p "header = \"x-session-id" config))
      (should-not (string-match-p "header = \"x-session-affinity" config)))))

(ert-deftest crush-test/hyper-method-gates-session-id-on-defcustom ()
  "The session hash is computed only when the cache gate is on.\nWith the gate off, nil is passed for the session headers."
  (let ((captured-session nil))
    (cl-letf (((symbol-function 'crush-openai-request)
               (lambda (&rest args)
                 (setq captured-session (nth 6 args))
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t)))
              ((symbol-function 'crush--history-for) (lambda (_b) nil)))
      (unwind-protect
          (let ((provider (crush-make-hyper-provider
                           :buffer (current-buffer)
                           :base-url "http://127.0.0.1:1"
                           :token "tok"))
                (crush-hyper-session-cache-p nil))
            (crush-provider-send-prompt
             provider "hi" :session-uuid "f47ac10b-58cc-4372-a567-0e02b2c3d479")
            (should (null captured-session)))
        (crush-test--cleanup)))))

(ert-deftest crush-test/hyper-method-hashes-session-uuid-when-enabled ()
  "Test that with the cache gate on, the method passes the XXH3-64 hash.
The hash is of the session UUID as the cache-affinity session id."
  (let ((captured-session nil))
    (cl-letf (((symbol-function 'crush-openai-request)
               (lambda (&rest args)
                 (setq captured-session (nth 6 args))
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t)))
              ((symbol-function 'crush--history-for) (lambda (_b) nil)))
      (unwind-protect
          (let ((provider (crush-make-hyper-provider
                           :buffer (current-buffer)
                           :base-url "http://127.0.0.1:1"
                           :token "tok"))
                (crush-hyper-session-cache-p t))
            (crush-provider-send-prompt
             provider "hi" :session-uuid "f47ac10b-58cc-4372-a567-0e02b2c3d479")
            (should (string= captured-session "db22027126414ba6")))
        (crush-test--cleanup)))))

;;; 92b. Hyper provider: token resolution

(defun crush-test--hyper-on-delta (buf)
  "Return the facade append-delta closure for BUF (buffer-aware)."
  (lambda (delta kind)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (crush-facade--append-delta delta kind)))))

(defun crush-test--hyper-completion (buf)
  "Return the facade finalize closure for BUF (buffer-aware)."
  (lambda ()
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (crush-facade--finalize)))))

(defun crush-test--hyper-on-error (buf)
  "Return the facade record-error closure for BUF (buffer-aware)."
  (lambda (message)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (crush-facade--record-error message)))))

;;; `crush-hyper--resolve-token' supports string, function, and nil
;;; tokens; the default `crush-hyper-token' function reads from
;;; `auth-source' (like gptel).

(ert-deftest crush-test/hyper-token-resolve-string ()
  "A string token resolves to itself."
  (should (string= (crush-hyper--resolve-token "sk-hyper-abc") "sk-hyper-abc")))

(ert-deftest crush-test/hyper-token-resolve-nil ()
  "A nil token resolves to nil (no authorization header)."
  (should-not (crush-hyper--resolve-token nil)))

(ert-deftest crush-test/hyper-token-resolve-function ()
  "A function token is called and its string result used."
  (let ((calls 0))
    (should (string= (crush-hyper--resolve-token
                      (lambda () (setq calls (1+ calls)) "sk-hyper-fn"))
                     "sk-hyper-fn"))
    (should (= calls 1))))

(ert-deftest crush-test/hyper-token-resolve-function-returns-function ()
  "A function returning another function is resolved recursively."
  (let ((token (lambda () (lambda () "sk-hyper-nested"))))
    (should (string= (crush-hyper--resolve-token token) "sk-hyper-nested"))))

(ert-deftest crush-test/hyper-token-from-auth-source-found ()
  "The default lookup returns the authinfo secret for hyper.charm.land."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest args)
               (should (string= (plist-get args :host) "hyper.charm.land"))
               (should (string= (plist-get args :user) "apikey"))
               (list (list :host "hyper.charm.land" :user "apikey"
                           :secret "sk-hyper-authinfo")))))
    (should (string= (crush-hyper--token-from-auth-source)
                     "sk-hyper-authinfo"))))

(ert-deftest crush-test/hyper-token-from-auth-source-missing ()
  "Missing authinfo entry signals a setup error, not a silent nil."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _args) nil)))
    (should-error (crush-hyper--token-from-auth-source) :type 'user-error)))

(ert-deftest crush-test/hyper-token-default-reads-authinfo ()
  "The default `crush-hyper-token' resolves through auth-source."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _args)
               (list (list :secret "sk-hyper-default")))))
    (let ((crush-hyper-token #'crush-hyper--token-from-auth-source))
      (should (string= (crush-hyper--resolve-token crush-hyper-token)
                       "sk-hyper-default")))))

(ert-deftest crush-test/hyper-token-provider-slot-beats-custom ()
  "A token on the provider struct wins over `crush-hyper-token'."
  (let ((provider (crush-make-hyper-provider
                   :buffer (current-buffer)
                   :base-url "http://127.0.0.1:1"
                   :token "sk-hyper-slot")))
    (let ((crush-hyper-token "sk-hyper-custom"))
      (let ((token (crush-hyper--resolve-token
                    (or (crush-hyper-provider-token provider)
                        crush-hyper-token))))
        (should (string= token "sk-hyper-slot"))))))

(ert-deftest crush-test/hyper-send-injects-completion ()
  "Crush-provider-send-prompt for hyper should use the injected completion.
The completion is the facade's continuation; the provider must invoke it
on stream completion instead of finalizing or touching buffers itself."
  (let ((crush-test--captured-completion nil)
        (injected (lambda () (setq crush-test--captured-completion 'called)))
        (base "http://127.0.0.1:1"))
    (cl-letf (((symbol-function 'crush-openai-request)
               (lambda (&rest args)
                 (setq crush-test--captured-completion (nth 4 args))
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t))))
      (let ((provider (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :base-url base
                       :token "tok")))
        (unwind-protect
            (progn
              (crush-provider-send-prompt
               provider "hi" :completion injected)
              ;; The provider must have threaded the injected completion
              ;; into the transport instead of a buffer-based finalizer:
              ;; running it must trigger the injected side effect.
              (should (eq crush-test--captured-completion injected)))
          (crush-test--cleanup))))))

;;; 93. Hyper provider: wire integration via dummy server

;;; The dummy Hyper gateway is a small Python server
;;; (test/hyper-server.py), started as a subprocess per test, that
;;; captures every request to a file and streams SSE responses.

(defun crush-test--hyper-cap-file ()
  "Return a fresh capture-file path for the hyper dummy server."
  (make-temp-file "crush-hyper-capture"))

(defun crush-test--read-hyper-capture (file)
  "Read the dummy server capture FILE, returning (BASE-URL . REQUESTS)."
  (let ((base nil)
        (requests nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((first-line (buffer-substring-no-properties
                         (point) (line-end-position))))
        (setq base (if (string-prefix-p "http" first-line) first-line nil)))
      (goto-char (point-min))
      (while (re-search-forward "^REQUEST \\([^ ]+\\) \\([^ ]+\\)$" nil t)
        (let ((method (match-string 1))
              (path (match-string 2))
              (headers nil)
              (body nil))
          (forward-line 1)
          ;; Collect headers until BODY.
          (while (and (not (eobp))
                      (not (looking-at "^BODY ")))
            (when (looking-at "^\\([^: ]+\\): \\(.*\\)$")
              (push (cons (downcase (match-string 1)) (match-string 2))
                    headers))
            (forward-line 1))
          (when (looking-at "^BODY \\(.*\\)$")
            (setq body (match-string 1)))
          (push (list method path headers body) requests))))
    (list base (nreverse requests))))

(defun crush-test--hyper-server-program ()
  "Return path to the dummy hyper server script."
  (expand-file-name "hyper-server.py"
                    (file-name-directory (locate-library "crush-test"))))

(defun crush-test--with-hyper-server (mode body-fn)
  "Start a dummy hyper server in MODE, call BODY-FN with its BASE-URL.
Returns the capture output."
  (let* ((cap (crush-test--hyper-cap-file))
         (proc (make-process
                :name "crush-hyper-test"
                :command (list (crush-test--hyper-server-program)
                               cap (symbol-name mode))
                :noquery t))
         (base nil)
         (deadline (+ (float-time) 5)))
    (unwind-protect
        (progn
          ;; Wait for the server to write its base URL.
          (while (and (null base) (< (float-time) deadline))
            (accept-process-output nil 0.1)
            (when (file-exists-p cap)
              (with-temp-buffer
                (insert-file-contents cap)
                (goto-char (point-min))
                (let ((l (buffer-substring-no-properties
                          (point) (line-end-position))))
                  (when (string-prefix-p "http" l)
                    (setq base l))))))
          (unless base
            (error "Hyper dummy server failed to start"))
          (funcall body-fn base)
          (crush-test--read-hyper-capture cap))
      (when proc (delete-process proc))
      (when (file-exists-p cap) (delete-file cap)))))

(ert-deftest crush-test/hyper-wire-captures-request-body ()
  "The dummy server should capture the composed JSON request body."
  (let* ((result (crush-test--with-hyper-server
                  'ok-stream
                  (lambda (base)
                    (let ((proc (crush-openai-request
                                 base "tok-rf"
                                 (crush-openai-compose-request "hi" nil "m")
                                 #'ignore #'ignore nil
                                 (crush-xxh3-hash64
                                  "f47ac10b-58cc-4372-a567-0e02b2c3d479"))))
                      (let ((deadline (+ (float-time) 6)))
                        (while (and (process-live-p proc)
                                    (null (process-get proc :crush-finished))
                                    (< (float-time) deadline))
                          (accept-process-output nil 0.1)))
                      nil))))
         (base (nth 0 result))
         (requests (nth 1 result)))
    (should base)
    (should (= (length requests) 1))
    (let* ((req (car requests))
           (method (nth 0 req))
           (path (nth 1 req))
           (headers (nth 2 req))
           (body (nth 3 req)))
      (should (string= method "POST"))
      (should (string= path "/chat/completions"))
      (should (string= (cdr (assoc "authorization" headers))
                       "Bearer tok-rf"))
      (should (string= (cdr (assoc "content-type" headers))
                       "application/json"))
      (should (string= (cdr (assoc "x-session-id" headers))
                       "db22027126414ba6"))
      (should (string= (cdr (assoc "x-session-affinity" headers))
                       "db22027126414ba6"))
      (let ((decoded (json-read-from-string body)))
        (should (string= (crush--openai-alist-get "model" decoded) "m"))
        (should (eq (crush--openai-alist-get "stream" decoded) t))))))

(ert-deftest crush-test/hyper-wire-streams-deltas-into-buffer ()
  "The transport should insert streamed deltas into the crush buffer."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((old-prompt-id crush--prompt-id))
            (crush-test--with-hyper-server
             'ok-stream
             (lambda (base)
               (save-excursion (goto-char (point-max)) (newline))
               (setq-local crush--response-start (point-marker))
               (let ((buf (current-buffer)))
                 (let ((proc (crush-openai-request
                              base "tok" (crush-openai-compose-request "hi" nil "m")
                              (crush-test--hyper-on-delta buf)
                              (crush-test--hyper-completion buf))))
                   (let ((deadline (+ (float-time) 6)))
                     (while (and (process-live-p proc)
                                 (null (process-get proc :crush-finished))
                                 (< (float-time) deadline))
                       (accept-process-output nil 0.1)
                       (sit-for 0.02)))))
               ;; Streamed content landed in the buffer.
               (goto-char (point-min))
               (should (search-forward "mock response!" nil t))
               ;; The [DONE] event finalized the response: tagged text
               ;; (crush-response-to) and a fresh prompt.
               (search-backward "mock response!")
               (let* ((resp-start (point))
                      (resp-end (+ resp-start (length "mock response!"))))
                 (should (eq (get-text-property resp-start 'crush-region-type)
                             'response))
                 (should (string= (get-text-property resp-end 'crush-response-to)
                                  old-prompt-id)))
               (goto-char (point-max))
               (search-backward "---")
               (should (not (string= crush--prompt-id old-prompt-id)))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-reasoning-stream-highlights-cot ()
  "A reasoning_content stream should be highlighted and tagged."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((_old-prompt-id crush--prompt-id))
            (crush-test--with-hyper-server
             'reasoning
             (lambda (base)
               (save-excursion (goto-char (point-max)) (newline))
               (setq-local crush--response-start (point-marker))
               (let ((buf (current-buffer)))
                 (let ((proc (crush-openai-request
                              base "tok" (crush-openai-compose-request "hi" nil "m")
                              (crush-test--hyper-on-delta buf)
                              (crush-test--hyper-completion buf))))
                   (let ((deadline (+ (float-time) 6)))
                     (while (and (process-live-p proc)
                                 (null (process-get proc :crush-finished))
                                 (< (float-time) deadline))
                       (accept-process-output nil 0.1)
                       (sit-for 0.02)))))
               ;; Wait until the streamed text actually landed: the
               ;; process loop can exit the instant :crush-finished is
               ;; set, before the finalize callback's insertion is
               ;; flushed and visible.  Finalize auto-collapses the
               ;; reasoning, so expand the fold to inspect the body.
               (let ((deadline (+ (float-time) 6)))
                 (while (and (< (float-time) deadline)
                             (not (save-excursion
                                    (goto-char (point-min))
                                    (cl-some (lambda (o)
                                               (overlay-get o 'crush-fold-state))
                                             (overlays-in (point-min) (point-max))))))
                   (accept-process-output nil 0.1)
                   (sit-for 0.02)))
               (let ((ov (cl-some (lambda (o)
                                    (overlay-get o 'crush-fold-state))
                                  (overlays-in (point-min) (point-max)))))
                 (when (and (overlayp ov)
                            (eq (overlay-get ov 'crush-fold-state) 'collapsed))
                   (goto-char (overlay-start ov))
                   (crush-reasoning-toggle)))
               (goto-char (point-min))
               (should (search-forward "mock think harder" nil t))
               (search-backward "mock")
               (let ((rs (point)))
                 (search-forward "harder")
                 (should (eq (get-text-property rs 'crush-region-type)
                             'reasoning)))
               ;; The answer after it is tagged response.
               (search-forward "answer")
               (let ((as (point)))
                 (should (eq (get-text-property (- as 6) 'crush-region-type)
                             'response)))
               ;; An overlay with the reasoning face covers the CoT.
               (let ((found nil))
                 (dolist (ov (overlays-in (point-min) (point-max)))
                   (when (and (eq (overlay-get ov 'face) 'crush-reasoning-face)
                              (overlay-get ov 'crush-overlay))
                     (setq found ov)))
                 (should (overlayp found))
                 (should (string= (buffer-substring-no-properties
                                   (overlay-start found) (overlay-end found))
                                  "mock think harder")))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-error-http-surfaces ()
  "A non-200 status should surface an error instead of streaming."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush-test--with-hyper-server
           'error-http
           (lambda (base)
             (setq-local crush--response-start (point-marker))
             (let ((proc (crush-openai-request
                          base "tok" (crush-openai-compose-request "hi" nil "m")
                          (crush-test--hyper-on-delta (current-buffer))
                          (crush-test--hyper-completion (current-buffer))
                          (crush-test--hyper-on-error (current-buffer)))))
               (let ((deadline (+ (float-time) 6)))
                 (while (and (process-live-p proc)
                             (null (process-get proc :crush-finished))
                             (< (float-time) deadline))
                   (accept-process-output nil 0.1)
                   (sit-for 0.02))))
             (goto-char (point-min))
             (should (search-forward "[crush error:" nil t)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-404-reports-status ()
  "An HTML 404 should be reported with its status code."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush-test--with-hyper-server
           'not-found
           (lambda (base)
             (setq-local crush--response-start (point-marker))
             (let* ((proc (crush-openai-request
                           base "tok" (crush-openai-compose-request "hi" nil "m")
                           (crush-test--hyper-on-delta (current-buffer))
                           (crush-test--hyper-completion (current-buffer))
                           (crush-test--hyper-on-error (current-buffer))))
                    (deadline (+ (float-time) 6)))
               (while (and (process-live-p proc)
                           (null (process-get proc :crush-finished))
                           (< (float-time) deadline))
                 (accept-process-output nil 0.1)
                 (sit-for 0.02))
               ;; Check the parsed status before the process is deleted.
               (let ((status (process-get proc :crush-status)))
                 (should (= status 404))))
             (goto-char (point-min))
             (should (search-forward "[crush error: HTTP 404" nil t)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-logs-request-without-token ()
  "The request diagnostic line in *crush-debug* should not contain the token."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush-test--with-hyper-server
           'ok-stream
           (lambda (base)
             (setq-local crush--response-start (point-marker))
             (let ((proc (crush-openai-request
                          base "sk-hyper-supersecret"
                          (crush-openai-compose-request "hi" nil "m")
                          (crush-test--hyper-on-delta (current-buffer))
                          (crush-test--hyper-completion (current-buffer)))))
               (let ((deadline (+ (float-time) 6)))
                 (while (and (process-live-p proc)
                             (null (process-get proc :crush-finished))
                             (< (float-time) deadline))
                   (accept-process-output nil 0.1)
                   (sit-for 0.02))))
             ;; The request diagnostic must be logged without the token.
             (let ((debug-buf (get-buffer "*crush-debug*")))
               (should (buffer-live-p debug-buf))
               (with-current-buffer debug-buf
                 (goto-char (point-min))
                 (should (search-forward "request: POST" nil t))
                 (should (search-forward "body:" nil t))
                 (goto-char (point-min))
                 (should (search-forward "response: POST" nil t))
                 (goto-char (point-min))
                 (should-not (search-forward "sk-hyper-supersecret" nil t)))))))
      (crush-test--cleanup))))

;;; 94. Hyper provider: conversation history

;;; Prior turns always ride in the composed request body as
;;; [system, prior-user, prior-assistant, ..., current-user]; with no
;;; prior turns the messages array stays a plain [system, user].
;;; `crush-hyper-history-limit' (0 = off) is the only switch.

(ert-deftest crush-test/hyper-history-compose-prepends-turns ()
  "Prior messages (alists) ride before the new user message."
  (let* ((req (crush-openai-compose-request
               "second" nil "m"
               (list (list (cons 'role "user") (cons 'content "first"))
                     (list (cons 'role "assistant") (cons 'content "one")))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 4))
    (should (string= (crush--openai-alist-get "role" (nth 0 msgs)) "system"))
    (should (string= (crush--openai-alist-get "content" (nth 1 msgs)) "first"))
    (should (string= (crush--openai-alist-get "role" (nth 2 msgs)) "assistant"))
    (should (string= (crush--openai-alist-get "content" (nth 2 msgs)) "one"))
    (should (string= (crush--openai-alist-get "content" (nth 3 msgs)) "second"))))

(ert-deftest crush-test/hyper-history-compose-plain-with-no-turns ()
  "With no prior messages the request is exactly system + user.
This covers the first prompt, or a limit of 0."
  (let* ((req (crush-openai-compose-request "second" nil "m" nil))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 2))
    (should (string= (crush--openai-alist-get "content" (nth 1 msgs))
                     "second"))))

(ert-deftest crush-test/hyper-history-compose-drops-junk-turns ()
  "History is already message alists, so nothing is filtered here;
the caller (crush--history-turns) is responsible for dropping junk."
  (let* ((req (crush-openai-compose-request
               "hi" nil "m"
               (list (list (cons 'role "user") (cons 'content "a")))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 3))
    (should (string= (crush--openai-alist-get "content" (nth 1 msgs)) "a"))))

(ert-deftest crush-test/hyper-history-wire-roundtrip ()
  "A second prompt is sent with the prior user+assistant turns as history.
The first request is a plain [system, user]; the second request body's
messages array is [system, prior-user, prior-assistant, current]."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((capture
                 (crush-test--with-hyper-server
                  'history
                  (lambda (base)
                    (let ((buf (current-buffer)))
                      ;; Turn 1: type the prompt, send with history on.
                      (goto-char (point-max))
                      (insert "first")
                      (save-excursion (goto-char (point-max)) (newline))
                      (setq-local crush--response-start (point-marker))
                      (let ((provider (crush-make-hyper-provider
                                       :buffer buf
                                       :base-url base
                                       :token "tok")))
                        (crush-provider-send-prompt
                         provider "first"
                         :completion (crush-test--hyper-completion buf)
                         :on-delta (crush-test--hyper-on-delta buf)
                         :on-error (crush-test--hyper-on-error buf)
                         :buffer buf)
                        (let ((deadline (+ (float-time) 6)))
                          (while (and (< (float-time) deadline)
                                      (< (length (crush-get-all-prompts)) 2))
                            (accept-process-output nil 0.1)
                            (sit-for 0.02))))
                      ;; Turn 2: fresh prompt, send "second".
                      (setq-local crush--prompt-id (crush--generate-id))
                      (crush--insert-input-separator)
                      (goto-char (point-max))
                      (newline)
                      (insert "second")
                      (goto-char (point-max))
                      (setq-local crush--response-start (point-marker))
                      (let ((provider (crush-make-hyper-provider
                                       :buffer buf
                                       :base-url base
                                       :token "tok")))
                        (crush-provider-send-prompt
                         provider "second"
                         :completion (crush-test--hyper-completion buf)
                         :on-delta (crush-test--hyper-on-delta buf)
                         :on-error (crush-test--hyper-on-error buf)
                         :buffer buf)
                        (let ((deadline (+ (float-time) 6)))
                          (while (and (< (float-time) deadline)
                                      (not (save-excursion
                                             (goto-char (point-min))
                                             (search-forward "ack" nil t))))
                            (accept-process-output nil 0.1)
                            (sit-for 0.02)))))))))
            (let* ((base (nth 0 capture))
                   (requests (nth 1 capture)))
              (should base)
              (should (= (length requests) 2))
              (let* ((req (nth 0 requests))
                     (body (json-read-from-string (nth 3 req)))
                     (msgs (crush--openai-alist-get "messages" body)))
                (should (= (length msgs) 2))
                (should (string= (crush--openai-alist-get "content" (aref msgs 1))
                                 "first")))
              (let* ((req (nth 1 requests))
                     (body (json-read-from-string (nth 3 req)))
                     (msgs (crush--openai-alist-get "messages" body)))
                (should (= (length msgs) 4))
                (should (string= (crush--openai-alist-get "role" (aref msgs 0))
                                 "system"))
                (should (string= (crush--openai-alist-get "content" (aref msgs 1))
                                 "first"))
                (should (string= (crush--openai-alist-get "role" (aref msgs 2))
                                 "assistant"))
                (should (string= (crush--openai-alist-get "content" (aref msgs 2))
                                 "first"))
                (should (string= (crush--openai-alist-get "content" (aref msgs 3))
                                 "second"))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-history-real-send-input-flow ()
  "Driving `crush-send-input' twice re-sends prior turns as history.
The second request body must be [system, user \"hi\", assistant reply,
user \"hello\"]; the first stays [system, user \"hi\"]."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model crush-model))
          (let ((result
                 (crush-test--with-hyper-server
                  'history
                  (lambda (base)
                    (setf (crush-hyper-provider-base-url crush-active-provider) base)
                    (let ((_buf (current-buffer)))
                      (goto-char (point-max))
                      (insert "hi")
                      (crush-send-input)
                      (let ((dl (+ (float-time) 6)))
                        (while (and (< (float-time) dl)
                                    (< (length (crush-get-all-prompts)) 2))
                          (accept-process-output nil 0.1) (sit-for 0.02)))
                      (goto-char (point-max))
                      (insert "hello")
                      (crush-send-input)
                      (let ((dl (+ (float-time) 6)) (found nil))
                        (while (and (< (float-time) dl) (not found))
                          (accept-process-output nil 0.1) (sit-for 0.02)
                          (setq found (save-excursion
                                        (goto-char (point-min))
                                        (search-forward "ack" nil t))))
                        (should found)))))))
            (let ((requests (nth 1 result)))
              (should (= (length requests) 2))
              (let* ((r1 (nth 0 requests))
                     (m1 (crush--openai-alist-get "messages"
                                                  (json-read-from-string (nth 3 r1)))))
                (should (= (length m1) 2))
                (should (string= (crush--openai-alist-get "content" (aref m1 1))
                                 "hi")))
              (let* ((r2 (nth 1 requests))
                     (m2 (crush--openai-alist-get "messages"
                                                  (json-read-from-string (nth 3 r2)))))
                (should (= (length m2) 4))
                (should (string= (crush--openai-alist-get "content" (aref m2 1))
                                 "hi"))
                (should (string= (crush--openai-alist-get "role" (aref m2 2))
                                 "assistant"))
                (should (string= (crush--openai-alist-get "content" (aref m2 3))
                                 "hello"))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-history-limit-zero-disables ()
  "Setting `crush-hyper-history-limit' to 0 disables history.
The second request is a plain [system, user]."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model crush-model))
          (let ((crush-hyper-history-limit 0))
            (let ((result
                   (crush-test--with-hyper-server
                    'history
                    (lambda (base)
                      (setf (crush-hyper-provider-base-url crush-active-provider) base)
                      (let ((_buf (current-buffer)))
                        (goto-char (point-max))
                        (insert "hi")
                        (crush-send-input)
                        (let ((dl (+ (float-time) 6)))
                          (while (and (< (float-time) dl)
                                      (< (length (crush-get-all-prompts)) 2))
                            (accept-process-output nil 0.1) (sit-for 0.02)))
                        (goto-char (point-max))
                        (insert "hello")
                        (crush-send-input)
                        (let ((dl (+ (float-time) 6)) (found nil))
                          (while (and (< (float-time) dl) (not found))
                            (accept-process-output nil 0.1) (sit-for 0.02)
                            (setq found (save-excursion
                                          (goto-char (point-min))
                                          (search-forward "first" nil t))))
                          (should found)))))))
              (let ((requests (nth 1 result)))
                (should (= (length requests) 2))
                (let* ((r2 (nth 1 requests))
                       (m2 (crush--openai-alist-get "messages"
                                                    (json-read-from-string (nth 3 r2)))))
                  (should (= (length m2) 2))
                  (should (string= (crush--openai-alist-get "content" (aref m2 1))
                                   "hello")))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-history-compose-excluded-stays-plain ()
  "Excluded reasoning: the assistant message has only `content'."
  (let* ((req (crush-openai-compose-request
               "hello" nil "m"
               (list (list (cons 'role "user") (cons 'content "first"))
                     (list (cons 'role "assistant") (cons 'content "answer")))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 4))
    (let ((a (nth 2 msgs)))
      (should (string= (crush--openai-alist-get "role" a) "assistant"))
      (should (string= (crush--openai-alist-get "content" a) "answer"))
      (should-not (assoc 'reasoning_content a)))))

(ert-deftest crush-test/hyper-history-compose-reasoning-wire-shape ()
  "Included reasoning yields one assistant message.
It carries both `content' and `reasoning_content'; there is no
standalone reasoning message."
  (let* ((req (crush-openai-compose-request
               "hello" nil "m"
               (list (list (cons 'role "user") (cons 'content "first"))
                     (list (cons 'role "assistant")
                           (cons 'content "answer")
                           (cons 'reasoning_content "trace")))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 4))
    (let ((a (nth 2 msgs)))
      (should (string= (crush--openai-alist-get "role" a) "assistant"))
      (should (string= (crush--openai-alist-get "content" a) "answer"))
      (should (string= (crush--openai-alist-get "reasoning_content" a)
                       "trace")))
    ;; No message has role "reasoning".
    (should-not (cl-some (lambda (m)
                           (string= (crush--openai-alist-get "role" m)
                                    "reasoning"))
                         msgs))))

(ert-deftest crush-test/hyper-history-compose-reasoning-orphan-dropped ()
  "A stray `reasoning' message with no assistant is dropped by the caller;
history arrives pre-filtered here, so the request stays system + user."
  (let* ((req (crush-openai-compose-request
               "hello" nil "m" nil))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 2))))

(ert-deftest crush-test/hyper-history-wire-reasoning-content-field ()
  "A later request's assistant message carries both fields.\nWith `crush-hyper-history-include-reasoning', `content' and\n`reasoning_content' are siblings (HYPER-API.md section 3.4)."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model crush-model))
          (let ((crush-hyper-history-include-reasoning t))
            (let ((result
                   (crush-test--with-hyper-server
                    'reasoning-history
                    (lambda (base)
                      (setf (crush-hyper-provider-base-url crush-active-provider) base)
                      (let ((_buf (current-buffer)))
                        ;; Turn 1 through the real send path: reasoning
                        ;; deltas stream, finalize tags them.
                        (goto-char (point-max))
                        (insert "first")
                        (crush-send-input)
                        (let ((dl (+ (float-time) 6)))
                          (while (and (< (float-time) dl)
                                      (< (length (crush-get-all-prompts)) 2))
                            (accept-process-output nil 0.1) (sit-for 0.02)))
                        ;; Turn 2: history must carry reasoning_content.
                        (goto-char (point-max))
                        (insert "second")
                        (crush-send-input)
                        (let ((dl (+ (float-time) 6)) (found nil))
                          (while (and (< (float-time) dl) (not found))
                            (accept-process-output nil 0.1) (sit-for 0.02)
                            (setq found (save-excursion
                                          (goto-char (point-min))
                                          (search-forward "ack" nil t))))
                          (should found)))))))
              (let ((requests (nth 1 result)))
                (should (>= (length requests) 2))
                (let* ((r2 (nth 1 requests))
                       (m2 (crush--openai-alist-get "messages"
                                                    (json-read-from-string (nth 3 r2)))))
                  (should (= (length m2) 4))
                  (let ((a (aref m2 2)))
                    (should (string= (crush--openai-alist-get "role" a)
                                     "assistant"))
                    (should (string= (crush--openai-alist-get "content" a)
                                     "answer out"))
                    (should (string= (crush--openai-alist-get "reasoning_content" a)
                                     "think step hidden"))))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-tool-call-finish-reason ()
  "A `finish_reason: tool_calls' surfaces its tool calls.
The SSE state carries them and the parser reports them."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush-test--with-hyper-server
           'tool-call
           (lambda (base)
             (setq-local crush--response-start (point-marker))
             (let ((buf (current-buffer)))
               (let ((proc (crush-openai-request
                            base "tok" (crush-openai-compose-request "hi" nil "m")
                            (crush-test--hyper-on-delta buf)
                            (lambda ()
                              (with-current-buffer buf
                                (message "tool-call done"))))))
                 (let ((deadline (+ (float-time) 6)))
                   (while (and (process-live-p proc)
                               (null (process-get proc :crush-finished))
                               (< (float-time) deadline))
                     (accept-process-output nil 0.1)
                     (sit-for 0.02)))
                 (let ((sse (process-get proc :crush-sse)))
                   (should sse)
                   (let ((tcs (plist-get sse :tool-calls)))
                     (should (vectorp tcs))
                     (should (>= (length tcs) 1))
                     (should (string= (crush--openai-alist-get "id" (aref tcs 0))
                                      "call_abc")))))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-compose-disabled-tools-no-key ()
  "With `crush-tools-enabled' nil the body lacks the tool keys.\nNeither `tools' nor `tool_choice' appears."
  (let ((crush-tools-enabled nil))
    (let ((req (crush-openai-compose-request "P" nil "m")))
      (should-not (assq 'tools req))
      (should-not (assq 'tool_choice req)))))

(ert-deftest crush-test/hyper-wire-reasoning-tool-no-prompt-swallow ()
  "Reasoning followed by tool_calls (no content) must not swallow the next prompt.
The reasoning overlay's rear-advance must not eat the input separator
inserted at finalization.  This reproduces the bug where a reasoning-only
stream (reasoning + tool_calls, no content delta) leaves the overlay
un-frozen, so its advancing end marker hides the next prompt under
`invisible t'."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((old-prompt-id crush--prompt-id))
            (crush-test--with-hyper-server
             'reasoning-tool
             (lambda (base)
               (save-excursion (goto-char (point-max)) (newline))
               (setq-local crush--response-start (point-marker))
               (let ((buf (current-buffer)))
                 (let ((proc (crush-openai-request
                              base "tok" (crush-openai-compose-request "hi" nil "m")
                              (crush-test--hyper-on-delta buf)
                              (crush-test--hyper-completion buf))))
                   (let ((deadline (+ (float-time) 6)))
                     (while (and (process-live-p proc)
                                 (null (process-get proc :crush-finished))
                                 (< (float-time) deadline))
                       (accept-process-output nil 0.1)
                       (sit-for 0.02)))))
               ;; Wait for the fold overlay to appear (finalize installs it).
               (let ((deadline (+ (float-time) 6)))
                 (while (and (< (float-time) deadline)
                             (not (cl-some (lambda (o)
                                             (overlay-get o 'crush-fold-state))
                                           (overlays-in (point-min) (point-max)))))
                   (accept-process-output nil 0.1)
                   (sit-for 0.02)))
               ;; The reasoning text should be present (folded).
               (goto-char (point-min))
               (should (search-forward "think step hidden" nil t))
               ;; The new prompt must be visible (not invisible).
               (goto-char (point-max))
               (should (search-backward "---" nil t))
               (let ((prompt-pos (point)))
                 (should (not (get-char-property prompt-pos 'invisible)))
                 ;; The fold overlay must not cover the prompt.
                 (dolist (ov (overlays-in (point-min) (point-max)))
                   (when (overlay-get ov 'crush-fold-state)
                     (should (<= (overlay-end ov) prompt-pos))))
                 ;; New prompt ID was generated.
                 (should (not (string= crush--prompt-id old-prompt-id))))))))
      (crush-test--cleanup))))

;;; Tool loop: the hyper provider must execute tool calls and send
;;; follow-up requests with the results, looping up to
;;; `crush-tool-loop-max' rounds.

(ert-deftest crush-test/hyper-tool-loop-executes-and-resends ()
  "A tool_calls response triggers bash execution and a follow-up request.
The first request gets tool_calls; the loop executes `echo hi', inserts
a tool block, and sends a second request carrying the tool result.
The second request gets a content answer and finalizes."
  (let ((default-directory crush-test--root)
        (crush-tools-enabled t))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model "m"))
          (let ((result
                 (crush-test--with-hyper-server
                  'tool-call
                  (lambda (base)
                    (setf (crush-hyper-provider-base-url crush-active-provider) base)
                    (let ((_buf (current-buffer)))
                      (goto-char (point-max))
                      (insert "ls")
                      (crush-send-input)
                      (let ((dl (+ (float-time) 10)))
                        (while (and (< (float-time) dl)
                                    (< (length (crush-get-all-prompts)) 2))
                          (accept-process-output nil 0.1) (sit-for 0.02)))
                      (let ((found nil)
                            (dl2 (+ (float-time) 6)))
                        (while (and (< (float-time) dl2) (not found))
                          (accept-process-output nil 0.1) (sit-for 0.02)
                          ;; The call id no longer renders in the header
                          ;; (it's display noise); it lives in the
                          ;; `crush-tool-call' text property for wire
                          ;; resume.
                          (setq found (save-excursion
                                        (goto-char (point-min))
                                        (cl-loop with pos = (point-min)
                                                 while (< pos (point-max))
                                                 for props = (text-properties-at pos)
                                                 thereis (and (plist-get props 'crush-tool-call)
                                                              (string= (plist-get
                                                                        (plist-get props 'crush-tool-call)
                                                                        :id)
                                                                       "call_abc"))
                                                 do (setq pos (or (next-property-change pos)
                                                                  (point-max)))))))
                        (should found))
                      (let ((found nil)
                            (dl3 (+ (float-time) 6)))
                        (while (and (< (float-time) dl3) (not found))
                          (accept-process-output nil 0.1) (sit-for 0.02)
                          (setq found (save-excursion
                                        (goto-char (point-min))
                                        (search-forward "tool-result-ack" nil t))))
                        (should found)))))))
            (let ((requests (nth 1 result)))
              (should (= (length requests) 2))
              (let* ((r1 (nth 0 requests))
                     (m1 (crush--openai-alist-get "messages"
                                                  (json-read-from-string (nth 3 r1)))))
                (should (= (length m1) 2))
                (should (string= (crush--openai-alist-get "content" (aref m1 1))
                                 "ls")))
              (let* ((r2 (nth 1 requests))
                     (m2 (crush--openai-alist-get "messages"
                                                  (json-read-from-string (nth 3 r2)))))
                (should (>= (length m2) 4))
                (should (string= (crush--openai-alist-get "role" (aref m2 2))
                                 "assistant"))
                (should (string= (crush--openai-alist-get "role" (aref m2 3))
                                 "tool"))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-tool-loop-cap-stops-and-finalizes ()
  "The tool loop stops after `crush-tool-loop-max' rounds and finalizes.
Uses a server that always returns tool_calls; the loop should hit
the cap, insert a final prompt, and stop sending requests."
  (let ((default-directory crush-test--root)
        (crush-tools-enabled t)
        (crush-tool-loop-max 2))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model "m"))
          (let ((result
                 (crush-test--with-hyper-server
                  'tool-call-loop
                  (lambda (base)
                    (setf (crush-hyper-provider-base-url crush-active-provider) base)
                    (let ((_buf (current-buffer)))
                      (goto-char (point-max))
                      (insert "go")
                      (crush-send-input)
                      (let ((dl (+ (float-time) 10)))
                        (while (and (< (float-time) dl)
                                    (< (length (crush-get-all-prompts)) 2))
                          (accept-process-output nil 0.1) (sit-for 0.02)))
                      (let ((found nil)
                            (dl2 (+ (float-time) 6)))
                        (while (and (< (float-time) dl2) (not found))
                          (accept-process-output nil 0.1) (sit-for 0.02)
                          (setq found (save-excursion
                                        (goto-char (point-min))
                                        (search-forward "---" nil t)
                                        (search-forward "---" nil t))))
                        (should found)))))))
            ;; Should have sent exactly crush-tool-loop-max + 1 requests
            ;; (initial + 2 tool-loop rounds), then finalized.
            (let ((requests (nth 1 result)))
              (should (= (length requests) 3)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-tool-loop-accumulates-continuation ()
  "Each tool-loop follow-up carries every prior tool call + result.
When a turn spans multiple tool rounds, the wire continuation must
accumulate, not replace, so the model sees its earlier calls."
  (let ((default-directory crush-test--root)
        (crush-tools-enabled t)
        (crush-tool-loop-max 2))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model "m"))
          (let ((result
                 (crush-test--with-hyper-server
                  'tool-call-loop
                  (lambda (base)
                    (setf (crush-hyper-provider-base-url crush-active-provider) base)
                    (goto-char (point-max))
                    (insert "go")
                    (crush-send-input)
                    (let ((dl (+ (float-time) 10)))
                      (while (and (< (float-time) dl)
                                  (< (length (crush-get-all-prompts)) 2))
                        (accept-process-output nil 0.1) (sit-for 0.02)))))))
            (let ((requests (nth 1 result)))
              (should (= (length requests) 3))
              (let ((r1 (json-read-from-string (nth 3 (nth 1 requests))))
                    (r2 (json-read-from-string (nth 3 (nth 2 requests)))))
                ;; system + user + assistant + tool (round 1).
                (should (= (length (crush--openai-alist-get "messages" r1)) 4))
                ;; system + user + 2x assistant + 2x tool (round 2).
                (should (= (length (crush--openai-alist-get "messages" r2)) 6))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-tool-loop-finalizes-after-content-answer ()
  "After a tool loop round, a content answer finalizes normally.
The first request gets tool_calls; the follow-up gets a content
answer; the buffer should have a new prompt and the response tagged."
  (let ((default-directory crush-test--root)
        (crush-tools-enabled t))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model "m"))
          (let ((old-prompt-id crush--prompt-id))
            (crush-test--with-hyper-server
             'tool-call
             (lambda (base)
               (setf (crush-hyper-provider-base-url crush-active-provider) base)
               (let ((_buf (current-buffer)))
                 (goto-char (point-max))
                 (insert "ls")
                 (crush-send-input)
                 (let ((dl (+ (float-time) 10)))
                   (while (and (< (float-time) dl)
                               (< (length (crush-get-all-prompts)) 2))
                     (accept-process-output nil 0.1) (sit-for 0.02)))
                 (let ((found nil)
                       (dl2 (+ (float-time) 6)))
                   (while (and (< (float-time) dl2) (not found))
                     (accept-process-output nil 0.1) (sit-for 0.02)
                     (setq found (save-excursion
                                   (goto-char (point-min))
                                   (search-forward "tool-result-ack" nil t))))
                   (should found)))))
            ;; New prompt was inserted after finalization.
            (should (not (string= crush--prompt-id old-prompt-id)))
            ;; Response is tagged with the old prompt ID.
            (goto-char (point-min))
            (should (search-forward "tool-result-ack" nil t))
            (should (eq (get-text-property (match-beginning 0) 'crush-region-type)
                        'response))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-tool-loop-header-shows-region-tool ()
  "Test that after a tool round-trip, the header line shows the region.
When point is on the tool block, it shows `region: tool', and `region:
response' on the final content."
  (let ((default-directory crush-test--root)
        (crush-tools-enabled t)
        (buf (crush-test--fresh-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq-local crush-active-provider
                      (crush-make-hyper-provider
                       :buffer buf
                       :working-directory default-directory
                       :token "tok"
                       :model "m"))
          (crush-test--with-hyper-server
           'tool-call
           (lambda (base)
             (setf (crush-hyper-provider-base-url crush-active-provider) base)
             (goto-char (point-max))
             (insert "ls")
             (crush-send-input)
             (let ((dl (+ (float-time) 10)))
               (while (and (< (float-time) dl)
                           (< (length (crush-get-all-prompts)) 2))
                 (accept-process-output nil 0.1) (sit-for 0.02)))
             (let ((found nil)
                   (dl2 (+ (float-time) 6)))
               (while (and (< (float-time) dl2) (not found))
                 (accept-process-output nil 0.1) (sit-for 0.02)
                 (setq found (save-excursion
                               (goto-char (point-min))
                               (search-forward "tool-result-ack" nil t))))
               (should found)))))
      ;; Point on the first tool region: header shows tool.
      (with-current-buffer buf
        (let ((tool-pos (text-property-any (point-min) (point-max)
                                           'crush-region-type 'tool)))
          (should tool-pos)
          (when tool-pos
            (goto-char tool-pos)
            (crush--update-header-line)
            (should (string-match-p "region: tool" (format "%s" header-line-format)))))
        (let ((resp-pos (text-property-any (point-min) (point-max)
                                           'crush-region-type 'response)))
          (should resp-pos)
          (when resp-pos
            (goto-char resp-pos)
            (crush--update-header-line)
            (should (string-match-p "region: response"
                                    (format "%s" header-line-format))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-history-replays-tool-pair-with-real-id ()
  "Test that a follow-up request replays the tool call as a valid pair.
It replays an assistant message carrying the persisted tool_calls id,
and a tool result whose tool_call_id matches it.  The live tool loop
already sends correct ids; this pins the history-replay path."
  (let ((default-directory crush-test--root)
        (crush-tools-enabled t))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local crush-active-provider
                        (crush-make-hyper-provider
                         :buffer buf
                         :working-directory default-directory
                         :token "tok"
                         :model "m"))
            (let ((result
                   (crush-test--with-hyper-server
                    'tool-call
                    (lambda (base)
                      (setf (crush-hyper-provider-base-url crush-active-provider) base)
                      (goto-char (point-max))
                      (insert "ls")
                      (crush-send-input)
                      (let ((dl (+ (float-time) 10)))
                        (while (and (< (float-time) dl)
                                    (< (length (crush-get-all-prompts)) 2))
                          (accept-process-output nil 0.1) (sit-for 0.02)))
                      (let ((found nil)
                            (dl2 (+ (float-time) 6)))
                        (while (and (< (float-time) dl2) (not found))
                          (accept-process-output nil 0.1) (sit-for 0.02)
                          (setq found (save-excursion
                                        (goto-char (point-min))
                                        (search-forward "tool-result-ack" nil t))))
                        (should found))
                      ;; Second prompt: history now includes the tool call.
                      (goto-char (point-max))
                      (insert "hello")
                      (crush-send-input)
                      (let ((dl3 (+ (float-time) 6))
                            (done nil))
                        (while (and (< (float-time) dl3) (not done))
                          (accept-process-output nil 0.1) (sit-for 0.02)
                          (setq done (save-excursion
                                       (goto-char (point-min))
                                       (search-forward "tool-result-ack" nil t)))))))))
              (let ((requests (nth 1 result)))
                (should (>= (length requests) 3))
                ;; Find a request whose messages contain the tool role.
                (let ((found nil))
                  (dolist (req requests)
                    (let* ((body (json-read-from-string (nth 3 req)))
                           (msgs (crush--openai-alist-get "messages" body))
                           (tool-idx nil))
                      (let ((i 0))
                        (while (and (null tool-idx) (< i (length msgs)))
                          (when (string= (crush--openai-alist-get "role" (aref msgs i))
                                         "tool")
                            (setq tool-idx i))
                          (setq i (1+ i))))
                      (when (and tool-idx (not found))
                        (setq found (cons msgs tool-idx)))))
                  (should found)
                  (let* ((msgs (car found))
                         (tool-idx (cdr found))
                         ;; The pair is (assistant-with-tool_calls, tool).
                         (assistant-msg (aref msgs (1- tool-idx)))
                         (tool-msg (aref msgs tool-idx)))
                    (should (string= (crush--openai-alist-get "role" assistant-msg)
                                     "assistant"))
                    (let ((tcs (crush--openai-alist-get "tool_calls" assistant-msg)))
                      (should (vectorp tcs))
                      (should (= (length tcs) 1))
                      (let ((tc (aref tcs 0)))
                        (should (string-match-p "call_" (crush--openai-alist-get "id" tc)))
                        (should (string= (crush--openai-alist-get "tool_call_id" tool-msg)
                                         (crush--openai-alist-get "id" tc)))))))))))
      (crush-test--cleanup))))

;;; C5. The hyper provider is a thin shim over the OpenAI client.

(ert-deftest crush-test/hyper-provider-is-thin-shim ()
  "The hyper provider must not reimplement the OpenAI wire layer.
It delegates to `crush-openai-compose-request' and
`crush-openai-request', and defines no SSE/curl wire functions of its
own (those live in crush-openai.el)."
  (let* ((lib (or (locate-library "crush-hyper-provider")
                  (expand-file-name "crush-hyper-provider.el"
                                    (file-name-directory
                                     (locate-library "crush-test")))))
         (file (if (string-suffix-p ".elc" lib)
                   (replace-regexp-in-string "\\.elc\\'" ".el" lib)
                 lib))
         (src (with-temp-buffer
                (insert-file-contents file)
                (buffer-string))))
    (should (string-match-p "crush-openai-compose-request" src))
    (should (string-match-p "crush-openai-request" src))
    ;; No wire/transport implementation in the provider.
    (should-not (string-match-p "defun crush--openai-\\(sse\\|curl\\|emit\\|http\\)" src))
    (should-not (string-match-p "defun crush-openai-\\(sse\\|compose\\|request\\)" src))))

;;; C6. Model catalog: fetch, choices, and interactive selection

(ert-deftest crush-test/hyper-fetch-models-parses-catalog ()
  "`crush-hyper--fetch-models' parses the /provider catalog into an alist.
The dummy server's catalog has three models; the first must carry the
id, name, context window, and reasoning flag."
  (let ((fetched (cons 'unset nil)))
    (let ((result (crush-test--with-hyper-server
                   'ok-stream
                   (lambda (base)
                     (setq fetched (crush-hyper--fetch-models base "tok"))))))
      (should (consp fetched))
      (should-not (eq (car fetched) 'unset))
      (let* ((catalog (car fetched))
             (models (crush--openai-alist-get "models" catalog)))
        (should (vectorp models))
        (should (= (length models) 3))
        (let ((m (aref models 0)))
          (should (string= (crush--openai-alist-get "id" m)
                           "deepseek-v4-flash-0731"))
          (should (string= (crush--openai-alist-get "name" m)
                           "DeepSeek V4 Flash"))
          (should (= (crush--openai-alist-get "context_window" m) 131072))
          (should (crush--openai-alist-get "can_reason" m)))
        (let ((m (aref models 2)))
          (should (string= (crush--openai-alist-get "id" m) "mini-no-reason"))
          ;; `can_reason' is `:json-false' (Emacs's JSON false), which is
          ;; truthy in Lisp; assert it is not a reason-capable model.
          (should-not (eq (crush--openai-alist-get "can_reason" m) t))))
      ;; The capture records the GET /provider request.
      (let ((requests (nth 1 result)))
        (should (= (length requests) 1))
        (should (string= (nth 0 (car requests)) "GET"))
        (should (string= (nth 1 (car requests)) "/provider"))))))

(ert-deftest crush-test/hyper-fetch-models-nil-on-failure ()
  "`crush-hyper--fetch-models' returns nil when the gateway is unreachable."
  (should (null (crush-hyper--fetch-models "http://127.0.0.1:1" "tok"))))

(ert-deftest crush-test/hyper-model-choices-format ()
  "`crush-hyper--model-choices' maps catalog entries to (ID . DISPLAY)."
  (let* ((catalog '((models .
                            [(("id" . "m1") ("name" . "Model One")
                              ("context_window" . 4096) ("cost_per_1m_in" . 0.5)
                              ("can_reason" . t))
                             (("id" . "m2") ("name" . "Model Two")
                              ("context_window" . 8192) ("cost_per_1m_in" . 0.1)
                              ("can_reason" . nil))])))
         (choices (crush-hyper--model-choices catalog)))
    (should (= (length choices) 2))
    (should (string= (caar choices) "m1"))
    (should (string-match-p "Model One" (cdar choices)))
    (should (string-match-p "4096" (cdar choices)))
    (should (string-match-p "reason" (cdar choices)))
    (should (string-match-p "no reason" (cdr (cadr choices))))))

(ert-deftest crush-test/select-model-sets-provider-and-global ()
  "`crush-select-model' updates the provider slot, `crush-model', and header.
The catalog is fetched from the dummy server; picking a model applies
it to the current buffer and the global default."
  (let ((crush-model nil))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (let ((result (crush-test--with-hyper-server
                           'ok-stream
                           (lambda (base)
                             (setf (crush-hyper-provider-base-url
                                    crush-active-provider)
                                   base)
                             (cl-letf (((symbol-function 'completing-read)
                                        (lambda (&rest _) "qwen3.7-plus")))
                               (crush-select-model))))))
              (should (string= (crush-hyper-provider-model
                                crush-active-provider)
                               "qwen3.7-plus"))
              (should (string= crush-model "qwen3.7-plus"))
              (crush--update-header-line)
              (should (string-match-p "qwen3.7-plus"
                                      (format "%s" header-line-format)))
              (let ((requests (nth 1 result)))
                (should (string= (nth 0 (car requests)) "GET"))
                (should (string= (nth 1 (car requests)) "/provider"))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/select-model-resets-to-default ()
  "Choosing the `default' entry clears the model back to the default."
  (let ((crush-model "qwen3.7-plus"))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (setf (crush-hyper-provider-model crush-active-provider)
                  "qwen3.7-plus")
            (crush-test--with-hyper-server
             'ok-stream
             (lambda (base)
               (setf (crush-hyper-provider-base-url crush-active-provider)
                     base)
               (cl-letf (((symbol-function 'completing-read)
                          (lambda (&rest _) "default")))
                 (crush-select-model))))
            (should (null (crush-hyper-provider-model crush-active-provider)))
            (should (null crush-model))))
      (crush-test--cleanup))))

(ert-deftest crush-test/select-model-fallback-on-fetch-failure ()
  "When the catalog fetch fails, `crush-select-model' offers a fallback list."
  (let ((crush-model nil))
    (unwind-protect
        (let ((buf (crush-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'crush-hyper--fetch-models)
                       (lambda (&rest _) nil))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt coll &rest _)
                         (should (assoc crush-openai-default-model coll))
                         "qwen3.7-plus")))
              (crush-select-model))
            (should (string= (crush-hyper-provider-model
                              crush-active-provider)
                             "qwen3.7-plus"))
            (should (string= crush-model "qwen3.7-plus"))))
      (crush-test--cleanup))))

(provide 'crush-test-hyper)
;;; crush-test-hyper.el ends here
