;;; crush-test-hyper.el --- Hyper backend tests for crush  -*- lexical-binding: t; -*-
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

(require 'crush)

;;; 91. Hyper backend: request composition

(ert-deftest crush-test/hyper-compose-no-context ()
  "Without context, messages should be system + user with just the prompt."
  (let ((crush-model nil))
    (let* ((req (crush--hyper-compose-request "Hello" nil "m"))
           (msgs (alist-get 'messages req)))
      (should (string= (alist-get 'model req) "m"))
      (should (eq (alist-get 'stream req) t))
      (should (= (length msgs) 2))
      (should (string= (crush--hyper-alist-get "role" (nth 0 msgs)) "system"))
      (should (string= (crush--hyper-alist-get "role" (nth 1 msgs)) "user"))
      (should (string= (crush--hyper-alist-get "content" (nth 1 msgs)) "Hello")))))

(ert-deftest crush-test/hyper-compose-with-context-merges-preamble ()
  "With context, the user message should carry preamble + context + prompt."
  (let* ((req (crush--hyper-compose-request "Do the thing" "**Attachment: foo**" "m"))
         (user-content (crush--hyper-alist-get "content"
                                               (nth 1 (alist-get 'messages req)))))
    (should (string-match-p "The following markdown fenced code blocks" user-content))
    (should (string-match-p "\\*\\*Attachment: foo\\*\\*" user-content))
    (should (string-match-p "Do the thing$" user-content))))

(ert-deftest crush-test/hyper-compose-respects-defcustoms ()
  "Model, max-tokens, temperature, thinking, reasoning-effort should land in body."
  (let ((crush-model "my-model")
        (crush-hyper-max-tokens 1234)
        (crush-hyper-temperature 0.5)
        (crush-hyper-thinking t)
        (crush-hyper-reasoning-effort "high"))
    ;; The model is resolved by the caller (the facade passes the backend
    ;; model slot derived from `crush-model'); compose uses it directly.
    (let ((req (crush--hyper-compose-request "P" nil crush-model)))
      (should (string= (alist-get 'model req) "my-model"))
      (should (= (alist-get 'max_tokens req) 1234))
      (should (= (alist-get 'temperature req) 0.5))
      (should (eq (alist-get 'thinking req) t))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest crush-test/hyper-compose-model-default ()
  "When no model is set, the crush default model is used."
  (let ((crush-model nil))
    (should (string= (alist-get 'model (crush--hyper-compose-request "P" nil nil))
                     crush-hyper-default-model))))

(ert-deftest crush-test/hyper-compose-tools-by-default ()
  "With `crush-tools-enabled' t the body announces the bash tool.
The default is non-nil, so `tool_choice' is `auto'."
  (let ((req (crush--hyper-compose-request "P" nil "m")))
    (should (assq 'tools req))
    (should (equal (alist-get 'tool_choice req) "auto"))
    (let ((tools (alist-get 'tools req)))
      (should (vectorp tools))
      (should (= (length tools) 1))
      (should (equal (cdr (assq 'name (cdr (assq 'function (aref tools 0)))))
                     "bash")))))

(ert-deftest crush-test/hyper-compose-no-tools-when-disabled ()
  "With `crush-tools-enabled' nil the body matches the pre-tools format.
It is byte-identical, with no `tools' or `tool_choice' key."
  (let ((crush-tools-enabled nil))
    (let ((req (crush--hyper-compose-request "P" nil "m")))
      (should-not (assq 'tools req))
      (should-not (assq 'tool_choice req)))))

;;; 92. Hyper backend: SSE parser

(defun crush-test--sse-state ()
  "Return a fresh, empty SSE parser state."
  (list :pending "" :done nil :tool-calls nil))

(ert-deftest crush-test/sse-parser-single-delta ()
  "A single data event should yield its content delta."
  (let* ((result (crush--hyper-sse-feed
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
         (result (crush--hyper-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((content . "one") (content . "two"))))
    (should (plist-get (cdr result) :done))))

(ert-deftest crush-test/sse-parser-chunk-split-mid-line ()
  "Events split across chunk boundaries should still parse."
  (let* ((state (crush-test--sse-state))
         (r1 (crush--hyper-sse-feed state "data: {\"choices\":[{\"delta\":{\"con"))
         (r2 (crush--hyper-sse-feed (cdr r1) "tent\":\"abc\"}}]}\n\n"))
         (r3 (crush--hyper-sse-feed (cdr r2) "data: [DONE]\n\n")))
    (should (equal (car r1) nil))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car r2))
                   '((content . "abc"))))
    (should (plist-get (cdr r3) :done))))

(ert-deftest crush-test/sse-parser-crlf ()
  "CRLF line endings should be handled."
  (let* ((result (crush--hyper-sse-feed
                  (crush-test--sse-state)
                  "data: {\"choices\":[{\"delta\":{\"content\":\"CR\"}}]}\r\n\r\n")))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((content . "CR"))))))

(ert-deftest crush-test/sse-parser-multiline-data-payload ()
  "A data payload spanning several data: lines should be joined."
  (let* ((chunk (concat "data: {\"choices\":[{\"delta\":{\"content\":\"line"
                        "\"}}]}\n"
                        "data: {\"choices\":[{\"delta\":{\"content\":\" two\"}}]}\n\n"))
         (result (crush--hyper-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((content . "line") (content . " two"))))))

(ert-deftest crush-test/sse-parser-reasoning-delta ()
  "A reasoning_content delta should yield a reasoning-typed delta."
  (let* ((result (crush--hyper-sse-feed
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
         (result (crush--hyper-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))
                   '((reasoning . "think") (content . "seen"))))))

(ert-deftest crush-test/sse-tool-calls-delta ()
  "A tool_calls delta should yield a (tool_calls nil ORIG) delta."
  (let* ((result (crush--hyper-sse-feed
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
         (r1 (crush--hyper-sse-feed
              s1 (concat "data: " json1 "\n\n")))
         (r2 (crush--hyper-sse-feed
              (cdr r1) (concat "data: " json2 "\n\n"))))
    (let ((tcs (plist-get (cdr r2) :tool-calls)))
      (should (vectorp tcs))
      (should (>= (length tcs) 1))
      (let ((args (crush--hyper-alist-get
                   "arguments"
                   (crush--hyper-alist-get
                    "function"
                    (aref tcs 0)))))
        (should (string= args "part1part2"))))))

(ert-deftest crush-test/sse-mixed-content-and-tool-calls ()
  "A chunk with both content and tool_calls should yield both deltas."
  (let* ((result (crush--hyper-sse-feed
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
  (let* ((result (crush--hyper-sse-feed
                  (crush-test--sse-state)
                  "data: {\"error\":\"boom\"}\n\n")))
    (should (plist-get (cdr result) :done))
    (should (string= (plist-get (cdr result) :error) "boom"))))

(ert-deftest crush-test/sse-on-event-fires-per-data-event ()
  "With `:on-event', the callback sees every raw payload.
It fires for each complete `data:' event, in order, before dispatch."
  (let ((events nil))
    (let* ((result (crush--hyper-sse-feed
                    (crush-test--sse-state)
                    "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n"
                    :on-event (lambda (payload) (push payload events))))
           (more (crush--hyper-sse-feed
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
    (let* ((partial (crush--hyper-sse-feed
                     (crush-test--sse-state)
                     "data: {\"choices\":[{\"delta\":{\"con"
                     :on-event on-event))
           (a (crush--hyper-sse-feed
               (cdr partial)
               "tent\":\"x\"}}]}\n\n"
               :on-event on-event))
           (b (crush--hyper-sse-feed
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
    (should (crush--hyper-event-worth-pretty-p payload))))

(ert-deftest crush-test/sse-event-worth-pretty-long-content ()
  "A delta with long content (>= 40 chars) is pretty-printed.
Large streamed chunks stay readable in the debug log."
  (let ((payload (concat
                  "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\""
                  (make-string 40 ?a)
                  "\"},\"finish_reason\":null}]}")))
    (should (crush--hyper-event-worth-pretty-p payload))))

(ert-deftest crush-test/sse-event-not-worth-pretty-short-delta ()
  "A short per-token delta stays compact.
It is not pretty-printed, keeping the debug log bounded during streams."
  (dolist (payload '("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"We\"},\"finish_reason\":null}]}"
                     "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"Hello\"},\"finish_reason\":null}]}"
                     "data: [DONE]"))
    (should-not (crush--hyper-event-worth-pretty-p payload))))




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
            (process-put proc :crush-sse (crush--hyper-sse-new-state))
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
            (crush--hyper-curl-filter
             proc "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"choices\":[{\"delta\":{\"con")
            ;; Chunk 2: the rest of the event plus [DONE].  With the bug
            ;; this chunk's `:pending' was lost, so \"hi\" never streamed.
            (crush--hyper-curl-filter
             proc "tent\":\"hi\"}}]}\n\ndata: [DONE]\n\n")
            (with-current-buffer target
              (goto-char (point-min))
              (should (search-forward "hi" nil t)))
            (when (process-live-p proc) (delete-process proc))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-transport-timeout-in-curl-config ()
  "`crush-hyper-timeout' should reach the curl config as max-time."
  (let ((received nil)
        (proc (make-pipe-process :name "crush-hyper-test-cap" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _args) proc))
                  ((symbol-function 'process-send-string)
                   (lambda (_p string) (push string received)))
                  ((symbol-function 'process-send-eof) #'ignore))
          (let ((crush-hyper-timeout 45))
            (crush--hyper-request
             "http://127.0.0.1:1" "tok"
             (crush--hyper-compose-request "hi" nil "m")
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
          (crush--hyper-request
           "http://127.0.0.1:1" "tok"
           (crush--hyper-compose-request "hi" nil "m")
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
          (crush--hyper-request
           "http://127.0.0.1:1" "tok"
           (crush--hyper-compose-request "hi" nil "m")
           #'ignore #'ignore))
      (delete-process proc))
    (should (string-match-p
             "header = \"User-Agent: Charm-Fantasy/0.41.0"
             (mapconcat #'identity (nreverse received) "\n")))))

(ert-deftest crush-test/hyper-method-sends-x-crush-id-by-default ()
  "The default setting passes a stable per-machine ID.
Repeated sends resolve to the same value."
  (let ((captured nil))
    (cl-letf (((symbol-function 'crush--hyper-request)
               (lambda (_base _tok _body _on _cb &optional _err _sess id)
                 (setq captured id)
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t)))
              ((symbol-function 'crush--history-for) (lambda (_b) nil)))
      (unwind-protect
          (let ((backend (crush-make-hyper-backend
                          :buffer (current-buffer)
                          :base-url "http://127.0.0.1:1"
                          :token "tok")))
            (crush-backend-send-prompt backend "hi")
            (should (string-match-p "[0-9a-f]\\{16\\}" (or captured "")))
            (let ((first captured))
              (crush-backend-send-prompt backend "hi")
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
                      (crush--hyper-request
                       "http://127.0.0.1:1" "tok"
                       (crush--hyper-compose-request "hi" nil "m")
                       #'ignore #'ignore nil nil id))
                  (delete-process proc))
                (mapconcat #'identity (nreverse received) "\n"))))
    (should (string-match-p "header = \"x-crush-id: my-id\""
                            (capture "my-id")))
    (should-not (string-match-p "x-crush-id" (capture nil)))))

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
          (crush--hyper-request
           "http://127.0.0.1:1" "tok"
           (crush--hyper-compose-request "hi" nil "m")
           #'ignore #'ignore))
      (delete-process proc))
    (let ((config (mapconcat #'identity (nreverse received) "\n")))
      (should-not (string-match-p "x-session-id" config))
      (should-not (string-match-p "x-session-affinity" config)))))

(ert-deftest crush-test/hyper-method-gates-session-id-on-defcustom ()
  "The session hash is computed only when the cache gate is on.\nWith the gate off, nil is passed for the session headers."
  (let ((captured-session nil))
    (cl-letf (((symbol-function 'crush--hyper-request)
               (lambda (&rest args)
                 (setq captured-session (nth 6 args))
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t)))
              ((symbol-function 'crush--history-for) (lambda (_b) nil)))
      (unwind-protect
          (let ((backend (crush-make-hyper-backend
                          :buffer (current-buffer)
                          :base-url "http://127.0.0.1:1"
                          :token "tok"))
                (crush-hyper-session-cache-p nil))
            (crush-backend-send-prompt
             backend "hi" :session-uuid "f47ac10b-58cc-4372-a567-0e02b2c3d479")
            (should (null captured-session)))
        (crush-test--cleanup)))))

(ert-deftest crush-test/hyper-method-hashes-session-uuid-when-enabled ()
  "With the cache gate on, the method passes the XXH3-64 hash.
This is of the session UUID, which matching the run backend's
`--session' would not."
  (let ((captured-session nil))
    (cl-letf (((symbol-function 'crush--hyper-request)
               (lambda (&rest args)
                 (setq captured-session (nth 6 args))
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t)))
              ((symbol-function 'crush--history-for) (lambda (_b) nil)))
      (unwind-protect
          (let ((backend (crush-make-hyper-backend
                          :buffer (current-buffer)
                          :base-url "http://127.0.0.1:1"
                          :token "tok"))
                (crush-hyper-session-cache-p t))
            (crush-backend-send-prompt
             backend "hi" :session-uuid "f47ac10b-58cc-4372-a567-0e02b2c3d479")
            (should (string= captured-session "db22027126414ba6")))
        (crush-test--cleanup)))))

;;; 92b. Hyper backend: token resolution

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

(ert-deftest crush-test/hyper-token-backend-slot-beats-custom ()
  "A token on the backend struct wins over `crush-hyper-token'."
  (let ((backend (crush-make-hyper-backend
                  :buffer (current-buffer)
                  :base-url "http://127.0.0.1:1"
                  :token "sk-hyper-slot")))
    (let ((crush-hyper-token "sk-hyper-custom"))
      (let ((token (crush-hyper--resolve-token
                    (or (crush-hyper-backend-token backend)
                        crush-hyper-token))))
        (should (string= token "sk-hyper-slot"))))))

(ert-deftest crush-test/hyper-send-injects-completion ()
  "Crush-backend-send-prompt for hyper should use the injected completion.
The completion is the facade's continuation; the backend must invoke it
on stream completion instead of finalizing or touching buffers itself."
  (let ((captured-completion nil)
        (injected (lambda () (setq captured-completion 'called)))
        (base "http://127.0.0.1:1"))
    (cl-letf (((symbol-function 'crush--hyper-request)
               (lambda (&rest args)
                 (setq captured-completion (nth 4 args))
                 (make-pipe-process :name "crush-hyper-test-fake"
                                    :noquery t))))
      (let ((backend (crush-make-hyper-backend
                      :buffer (current-buffer)
                      :base-url base
                      :token "tok")))
        (unwind-protect
            (progn
              (crush-backend-send-prompt
               backend "hi" :completion injected)
              ;; The backend must have threaded the injected completion
              ;; into the transport instead of a buffer-based finalizer:
              ;; running it must trigger the injected side effect.
              (should (eq captured-completion injected)))
          (crush-test--cleanup))))))

;;; 93. Hyper backend: wire integration via dummy server

;;; The dummy Hyper gateway is a small Python server
;;; (test/hyper-server.py), started as a subprocess per test, that
;;; captures every request to a file and streams SSE responses.  This is
;;; the same philosophy as `test/mock-crush.sh' for the CLI.

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
                    (let ((proc (crush--hyper-request
                                 base "tok-rf"
                                 (crush--hyper-compose-request "hi" nil "m")
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
        (should (string= (crush--hyper-alist-get "model" decoded) "m"))
        (should (eq (crush--hyper-alist-get "stream" decoded) t))))))

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
                 (let ((proc (crush--hyper-request
                              base "tok" (crush--hyper-compose-request "hi" nil "m")
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
               (search-backward "crush> ")
               (should (not (string= crush--prompt-id old-prompt-id)))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-reasoning-stream-highlights-cot ()
  "A reasoning_content stream should be highlighted and tagged."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((old-prompt-id crush--prompt-id))
            (crush-test--with-hyper-server
             'reasoning
             (lambda (base)
               (save-excursion (goto-char (point-max)) (newline))
               (setq-local crush--response-start (point-marker))
               (let ((buf (current-buffer)))
                 (let ((proc (crush--hyper-request
                              base "tok" (crush--hyper-compose-request "hi" nil "m")
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
             (let ((proc (crush--hyper-request
                          base "tok" (crush--hyper-compose-request "hi" nil "m")
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
             (let* ((proc (crush--hyper-request
                           base "tok" (crush--hyper-compose-request "hi" nil "m")
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
             (let ((proc (crush--hyper-request
                          base "sk-hyper-supersecret"
                          (crush--hyper-compose-request "hi" nil "m")
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

;;; 94. Hyper backend: conversation history

;;; Prior turns always ride in the composed request body as
;;; [system, prior-user, prior-assistant, ..., current-user]; with no
;;; prior turns the messages array stays a plain [system, user].
;;; `crush-hyper-history-limit' (0 = off) is the only switch.

(ert-deftest crush-test/hyper-history-compose-prepends-turns ()
  "Prior turns ride before the new user message."
  (let* ((req (crush--hyper-compose-request
               "second" nil "m"
               '((user . "first") (assistant . "one"))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 4))
    (should (string= (crush--hyper-alist-get "role" (nth 0 msgs)) "system"))
    (should (string= (crush--hyper-alist-get "content" (nth 1 msgs)) "first"))
    (should (string= (crush--hyper-alist-get "role" (nth 2 msgs)) "assistant"))
    (should (string= (crush--hyper-alist-get "content" (nth 2 msgs)) "one"))
    (should (string= (crush--hyper-alist-get "content" (nth 3 msgs)) "second"))))

(ert-deftest crush-test/hyper-history-compose-plain-with-no-turns ()
  "With no prior turns the request is exactly system + user.
This covers the first prompt, or a limit of 0."
  (let* ((req (crush--hyper-compose-request "second" nil "m" nil))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 2))
    (should (string= (crush--hyper-alist-get "content" (nth 1 msgs))
                     "second"))))

(ert-deftest crush-test/hyper-history-compose-drops-junk-turns ()
  "Unrecognized roles and empty text never reach the messages array."
  (let* ((req (crush--hyper-compose-request
               "hi" nil "m"
               '((user . "a") (reasoning . "hidden") (assistant . "")
                 (user . "   "))))
         (msgs (alist-get 'messages req)))
    ;; system + the single meaningful user turn + new user.
    (should (= (length msgs) 3))
    (should (string= (crush--hyper-alist-get "content" (nth 1 msgs)) "a"))))

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
                      (let ((backend (crush-make-hyper-backend
                                      :buffer buf
                                      :base-url base
                                      :token "tok")))
                        (crush-backend-send-prompt
                         backend "first"
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
                      (crush--insert-prompt)
                      (goto-char (point-max))
                      (newline)
                      (insert "second")
                      (goto-char (point-max))
                      (setq-local crush--response-start (point-marker))
                      (let ((backend (crush-make-hyper-backend
                                      :buffer buf
                                      :base-url base
                                      :token "tok")))
                        (crush-backend-send-prompt
                         backend "second"
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
                     (msgs (crush--hyper-alist-get "messages" body)))
                (should (= (length msgs) 2))
                (should (string= (crush--hyper-alist-get "content" (aref msgs 1))
                                 "first")))
              (let* ((req (nth 1 requests))
                     (body (json-read-from-string (nth 3 req)))
                     (msgs (crush--hyper-alist-get "messages" body)))
                (should (= (length msgs) 4))
                (should (string= (crush--hyper-alist-get "role" (aref msgs 0))
                                 "system"))
                (should (string= (crush--hyper-alist-get "content" (aref msgs 1))
                                 "first"))
                (should (string= (crush--hyper-alist-get "role" (aref msgs 2))
                                 "assistant"))
                (should (string= (crush--hyper-alist-get "content" (aref msgs 2))
                                 "first"))
                (should (string= (crush--hyper-alist-get "content" (aref msgs 3))
                                 "second")))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/hyper-history-real-send-input-flow ()
  "Driving `crush-send-input' twice re-sends prior turns as history.
The second request body must be [system, user \"hi\", assistant reply,
user \"hello\"]; the first stays [system, user \"hi\"]."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-backend
                      (crush-make-hyper-backend
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model crush-model))
          (let ((result
                 (crush-test--with-hyper-server
                  'history
                  (lambda (base)
                    (setf (crush-hyper-backend-base-url crush-active-backend) base)
                    (let ((buf (current-buffer)))
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
                     (m1 (crush--hyper-alist-get "messages"
                                                 (json-read-from-string (nth 3 r1)))))
                (should (= (length m1) 2))
                (should (string= (crush--hyper-alist-get "content" (aref m1 1))
                                 "hi")))
              (let* ((r2 (nth 1 requests))
                     (m2 (crush--hyper-alist-get "messages"
                                                 (json-read-from-string (nth 3 r2)))))
                (should (= (length m2) 4))
                (should (string= (crush--hyper-alist-get "content" (aref m2 1))
                                 "hi"))
                (should (string= (crush--hyper-alist-get "role" (aref m2 2))
                                 "assistant"))
                (should (string= (crush--hyper-alist-get "content" (aref m2 3))
                                 "hello")))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/hyper-history-limit-zero-disables ()
  "Setting `crush-hyper-history-limit' to 0 disables history.
The second request is a plain [system, user]."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-backend
                      (crush-make-hyper-backend
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model crush-model))
          (let ((crush-hyper-history-limit 0))
            (let ((result
                   (crush-test--with-hyper-server
                    'history
                    (lambda (base)
                      (setf (crush-hyper-backend-base-url crush-active-backend) base)
                      (let ((buf (current-buffer)))
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
                       (m2 (crush--hyper-alist-get "messages"
                                                   (json-read-from-string (nth 3 r2)))))
                  (should (= (length m2) 2))
                  (should (string= (crush--hyper-alist-get "content" (aref m2 1))
                                   "hello"))))))))
    (crush-test--cleanup)))

(ert-deftest crush-test/hyper-history-compose-excluded-stays-plain ()
  "Excluded reasoning: the assistant message has only `content'."
  (let* ((req (crush--hyper-compose-request
               "hello" nil "m"
               '((user . "first")
                 (assistant . "answer"))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 4))
    (let ((a (nth 2 msgs)))
      (should (string= (crush--hyper-alist-get "role" a) "assistant"))
      (should (string= (crush--hyper-alist-get "content" a) "answer"))
      (should-not (assoc 'reasoning_content a)))))

(ert-deftest crush-test/hyper-history-compose-reasoning-wire-shape ()
  "Included reasoning yields one assistant message.\nIt carries both `content' and `reasoning_content'; there is no\nstandalone reasoning message."
  (let* ((req (crush--hyper-compose-request
               "hello" nil "m"
               '((user . "first")
                 (assistant . "answer")
                 (reasoning . "trace"))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 4))
    (let ((a (nth 2 msgs)))
      (should (string= (crush--hyper-alist-get "role" a) "assistant"))
      (should (string= (crush--hyper-alist-get "content" a) "answer"))
      (should (string= (crush--hyper-alist-get "reasoning_content" a)
                       "trace")))
    ;; No message has role "reasoning".
    (should-not (cl-some (lambda (m)
                           (string= (crush--hyper-alist-get "role" m)
                                    "reasoning"))
                         msgs))))

(ert-deftest crush-test/hyper-history-compose-reasoning-orphan-dropped ()
  "A `reasoning' record with no preceding assistant turn is dropped."
  (let* ((req (crush--hyper-compose-request
               "hello" nil "m"
               '((reasoning . "stray"))))
         (msgs (alist-get 'messages req)))
    (should (= (length msgs) 2))))

(ert-deftest crush-test/hyper-history-wire-reasoning-content-field ()
  "A later request's assistant message carries both fields.\nWith `crush-hyper-history-include-reasoning', `content' and\n`reasoning_content' are siblings (HYPER-API.md section 3.4)."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (setq-local crush-active-backend
                      (crush-make-hyper-backend
                       :buffer (current-buffer)
                       :working-directory default-directory
                       :token "tok"
                       :model crush-model))
          (let ((crush-hyper-history-include-reasoning t))
            (let ((result
                   (crush-test--with-hyper-server
                    'reasoning-history
                    (lambda (base)
                      (setf (crush-hyper-backend-base-url crush-active-backend) base)
                      (let ((buf (current-buffer)))
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
                       (m2 (crush--hyper-alist-get "messages"
                                                   (json-read-from-string (nth 3 r2)))))
                  (should (= (length m2) 4))
                  (let ((a (aref m2 2)))
                    (should (string= (crush--hyper-alist-get "role" a)
                                     "assistant"))
                    (should (string= (crush--hyper-alist-get "content" a)
                                     "answer out"))
                    (should (string= (crush--hyper-alist-get "reasoning_content" a)
                                     "think step hidden")))))))))
    (crush-test--cleanup)))

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
               (let ((proc (crush--hyper-request
                            base "tok" (crush--hyper-compose-request "hi" nil "m")
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
                     (should (string= (crush--hyper-alist-get "id" (aref tcs 0))
                                      "call_abc")))))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-compose-disabled-tools-no-key ()
  "With `crush-tools-enabled' nil the body lacks the tool keys.\nNeither `tools' nor `tool_choice' appears."
  (let ((crush-tools-enabled nil))
    (let ((req (crush--hyper-compose-request "P" nil "m")))
      (should-not (assq 'tools req))
      (should-not (assq 'tool_choice req)))))

(provide 'crush-test-hyper)
;;; crush-test-hyper.el ends here
