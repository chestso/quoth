;;; crush-openai.el --- OpenAI chat-completions client for crush  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/crush.el
;;; Version: 0.1.0
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience
;;; Prefix: crush-

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

;; The reusable OpenAI chat-completions client for crush.el: request
;; composition (history + tool-request shape), streaming SSE parsing,
;; and the curl transport.  The Charm Hyper provider
;; (`crush-hyper-provider.el') uses this for its HTTP+SSE path; other
;; OpenAI-compatible providers can reuse it by supplying their own
;; config and composing requests through `crush-openai-compose-request'
;; and `crush-openai-request'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'auth-source)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the sibling from this file's
;;; own directory so both flycheck and package-installed loads work.
(eval-and-compile
  (dolist (dep '("crush-provider"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defcustom crush-openai-timeout 300
  "Seconds to wait for an OpenAI-compatible request before giving up."
  :type 'number
  :group 'crush)

(defcustom crush-openai-max-tokens 64000
  "Default `max_tokens' for OpenAI-compatible requests."
  :type 'number
  :group 'crush)

(defcustom crush-openai-temperature nil
  "Sampling temperature for OpenAI-compatible requests; nil means unset."
  :type '(choice (const nil) number)
  :group 'crush)

(defcustom crush-openai-thinking nil
  "Enable chain-of-thought reasoning for each request.
When non-nil, the request body carries `thinking: t' and the model
emits a `reasoning_content' trace (streamed as reasoning deltas)
before the final answer.  This is the master switch:
`crush-openai-reasoning-effort' only tunes the depth of that reasoning
and is a no-op while thinking is disabled."
  :type 'boolean
  :group 'crush)

(defcustom crush-openai-reasoning-effort nil
  "Reasoning depth for the model; nil means use the model default.
Values like `low', `medium', `high', `max'.  Gated by
`crush-openai-thinking': effort tunes how deep the chain-of-thought
reasoning goes, but only when thinking is enabled."
  :type '(choice (const nil) string)
  :group 'crush)

(defcustom crush-openai-curl-program "curl"
  "Path to the curl executable used by the OpenAI client transport."
  :type 'string
  :group 'crush)

(defcustom crush-openai-user-agent
  "Charm-Fantasy/0.41.0 (https://charm.land/fantasy)"
  "User-Agent header value for OpenAI chat-completions requests.
The Crush CLI does not set its own User-Agent on the Hyper chat path;
the value Hyper receives is the default of the fantasy SDK pinned in
the CLI's go.mod (charm.land/fantasy v0.41.0), rendered as
`Charm-Fantasy/<version> (https://charm.land/fantasy)'.  We send the
same string so the gateway sees an identical client."
  :type 'string
  :group 'crush)

(defconst crush-openai-system-prompt
  "You are a helpful assistant.  You answer concisely and correctly."
  "System prompt sent with every request.")

(defconst crush-openai-default-model "deepseek-v4-flash"
  "Model used when the provider model slot and `crush-model' are both nil.")

(declare-function crush--debug-log "crush.el" (category message))

;;; Tool protocol: the OpenAI function-calling shape the client speaks.

(defcustom crush-tools-enabled t
  "Announce the registered tools and allow tool-call rounds.
When nil, requests are byte-identical to the pre-tools format with no
`tools' key in the request body."
  :type 'boolean
  :group 'crush)

(defcustom crush-tool-loop-max 8
  "Tool rounds per user prompt before the loop stops.
When the loop cap is hit, a final result tells the model to stop and
the request finalizes."
  :type 'integer
  :group 'crush)

(defvar crush-openai-tool-registry
  (list)
  "Alist mapping tool-call names to executer functions.
An executer takes a `crush-openai-tool-call' struct whose `args' slot
holds the parsed argument plist and returns (RESULT-TEXT . EXIT-CODE).
Local tool files (e.g. `crush-tools.el') push their tools here at load
time.")

(cl-defstruct (crush-openai-tool-call
               (:constructor nil)
               (:constructor crush-make-openai-tool-call
                             (&key id name &aux (args nil) (result nil) (exit nil))))
  "A single tool call in flight.
ID is the model's call id; NAME the tool name; ARGS the parsed
argument plist (filled by the executor); RESULT the result text;
EXIT the exit code (filled after execution)."
  id
  name
  args
  result
  exit)

(defun crush-openai-parse-tool-args (args-json)
  "Parse ARGS-JSON (a JSON string) into a plist, or nil when malformed.
Unknown keys are ignored; a non-alist payload yields nil."
  (when (and (stringp args-json) (> (length args-json) 0))
    (let ((obj (ignore-errors (json-read-from-string args-json))))
      (when (consp obj)
        (let (plist)
          (pcase-dolist (`(,key . ,value) obj)
            (let ((sym (intern (format ":%s" key))))
              (setq plist (plist-put plist sym value))))
          plist)))))

(defun crush-openai-tool-error-result (message)
  "Return an error (RESULT-TEXT . EXIT-CODE) pair for MESSAGE.
Renders the error in the `<output>' slot with exit code -1."
  (cons (format "<output>\n%s\n</output>\n<exit_code>-1</exit_code>"
                message)
        -1))

(defun crush-openai-execute-tool (tool-call)
  "Execute TOOL-CALL and return (RESULT-TEXT . EXIT-CODE).
Looks up the tool name in `crush-openai-tool-registry'; an unknown
tool yields an error result without spawning any process."
  (let ((entry (assoc (crush-openai-tool-call-name tool-call)
                      crush-openai-tool-registry)))
    (if entry
        (funcall (cdr entry) tool-call)
      (crush-openai-tool-error-result
       (format "unknown tool %S" (crush-openai-tool-call-name tool-call))))))

(defun crush-openai-history-messages (turns)
  "Build message alists from conversation history.
TURNS is a list of (ROLE . TEXT) conses from the facade's history
extraction (see `crush--history-turns').  `user' and `assistant'
become messages; a `reasoning' turn immediately following an
`assistant' turn is folded into that same assistant message as the
`reasoning_content' field (HYPER-API.md section 3.4).  A `tool' turn
carrying (ID NAME ARGS . TEXT) emits, per the OpenAI function-calling
shape, the assistant `tool_calls' declaration followed by the
`role: \"tool\"' result message with the matching `tool_call_id'; a
bare (tool . TEXT) turn keeps the legacy `tool_call_id: \"unknown\"'.
Any other role, and empty or whitespace-only text, is dropped.
Returns the alists in conversation order."
  (let ((messages nil)
        (pending nil))
    (dolist (turn turns)
      (let ((role (car turn))
            (text (cdr turn)))
        (cond
         ((and (eq role 'reasoning) pending)
          (setcdr (last pending)
                  (list (cons 'reasoning_content text))))
         ((eq role 'tool)
          (if (and (consp text) (not (stringp text)))
              ;; With metadata: assistant tool_calls + tool result pair.
              ;; TEXT is a dotted list (ID NAME ARGS . CONTENT); use
              ;; car/cadr/caddr/cdddr (nth cannot walk a dotted tail).
              (let ((id (car text))
                    (name (cadr text))
                    (args (caddr text))
                    (content (cdddr text)))
                (when (and (stringp id) (stringp name))
                  (push (list (cons 'role "assistant")
                              (cons 'content :null)
                              (cons 'tool_calls
                                    (vector
                                     (list (cons 'id id)
                                           (cons 'type "function")
                                           (cons 'function
                                                 (list (cons 'name name)
                                                       (cons 'arguments
                                                             (or args ""))))))))
                        messages)
                  (push (list (cons 'role "tool")
                              (cons 'tool_call_id id)
                              (cons 'content (or content "")))
                        messages)))
            ;; Legacy: bare (tool . TEXT).
            (push (list (cons 'role "tool")
                        (cons 'tool_call_id "unknown")
                        (cons 'content text))
                  messages))
          (setq pending nil))
         ((and (memq role '(user assistant))
               (stringp text)
               (> (length (string-trim text)) 0))
          (let ((msg (cons (cons 'role (symbol-name role))
                           (list (cons 'content text)))))
            (push msg messages)
            (setq pending msg)))
         (t (setq pending nil)))))
    (nreverse messages)))

(defun crush-openai-compose-request (prompt context model &optional turns continuation)
  "Compose a chat-completions request alist for PROMPT.
CONTEXT is optional attachment text; MODEL is the resolved model (the
caller passes the backend's model slot, already derived from the shared
`crush-model' defcustom).  Falls back to `crush-openai-default-model'.
Prior (ROLE . TEXT) TURNS from the facade's history extraction ride
between the system prompt and the new user message; with no turns the
body carries exactly system + user (`stream: t', no tools).  History
is disabled by the caller passing nil turns (`crush-hyper-history-limit
0 means the facade extracts none).  CONTINUATION, when non-nil, is a
list of structured message alists (assistant with `tool_calls'
followed by `role: \"tool\"' messages) that replace the user message;
used by the tool loop to send follow-up requests with tool results.
When `crush-tools-enabled' is non-nil (the default), the request
announces the `bash' tool and `tool_choice: \"auto\"'."
  (let* ((model (or model crush-openai-default-model))
         (user-content
          (if (and context (not (string-empty-p context)))
              (concat crush-context-preamble "\n\n"
                      context "\n\n"
                      prompt)
            prompt))
         (messages
          (cond
           (continuation
            (append (list (list '(role . "system")
                                (cons 'content crush-openai-system-prompt)))
                    (when turns (crush-openai-history-messages turns))
                    continuation))
           (turns
            (append (list (list '(role . "system")
                                (cons 'content crush-openai-system-prompt)))
                    (crush-openai-history-messages turns)
                    (list (list '(role . "user")
                                (cons 'content user-content)))))
           (t
            (list (list '(role . "system")
                        (cons 'content crush-openai-system-prompt))
                  (list '(role . "user")
                        (cons 'content user-content))))))
         (body `((model . ,model)
                 (stream . t)
                 (messages . ,messages))))
    (when crush-openai-max-tokens
      (setq body (cons (cons 'max_tokens crush-openai-max-tokens) body)))
    (when crush-openai-temperature
      (setq body (cons (cons 'temperature crush-openai-temperature) body)))
    (when crush-openai-thinking
      (setq body (cons '(thinking . t) body)))
    (when crush-openai-reasoning-effort
      (setq body (append body
                         `((reasoning_effort . ,crush-openai-reasoning-effort)))))
    (when crush-tools-enabled
      (setq body (append body
                         (list (cons 'tools (crush--openai-tool-schema))
                               (cons 'tool_choice "auto")))))
    body))

(defun crush--openai-tool-schema ()
  "Return the tool schema vector for the `bash' tool."
  (let ((param-props
         `((command . ((type . "string")
                       (description . "The shell command to execute")))
           (working_dir . ((type . "string")
                           (description . "Working directory (defaults to the buffer's project root)"))))))
    `[((type . "function")
       (function . ((name . "bash")
                    (description . "Run a shell command in the user's environment and return its combined standard output and error, with the exit code appended. Anything can be run through bash.")
                    (parameters . ((type . "object")
                                   (properties . ,param-props)
                                   (required . ["command"]))))))]))

(defun crush-openai-sse-new-state ()
  "Return a fresh SSE parser state plist."
  (list :pending "" :done nil :error nil :tool-calls nil))

(defun crush-openai-sse-feed (state chunk &optional &rest args)
  "Feed CHUNK into SSE parser STATE and return (DELTAS . NEW-STATE).
Each delta is a (KIND TEXT ORIG) list, where KIND is `content',
`reasoning', or `tool_calls' (TEXT nil for tool_calls).
Sets `:done' when `[DONE]' or an error payload is seen; the
`:pending' buffer keeps partial events across chunk boundaries.
ARGS may contain :on-event, a callback invoked with the raw payload
of each COMPLETE `data:' event (before it is dispatched), including
`[DONE]'."
  (let ((pending (concat (plist-get state :pending) chunk))
        (done (plist-get state :done))
        (error (plist-get state :error))
        (on-event (plist-get args :on-event))
        (deltas nil))
    ;; Normalize CRLF, then split into events.  An event is one or more
    ;; lines followed by a blank line (\"\\n\\n\").  A trailing fragment
    ;; with no blank line yet stays pending.
    (let* ((text (replace-regexp-in-string "\r\n" "\n" pending))
           (complete-p (string-suffix-p "\n\n" text))
           (events (mapcar (lambda (b) (split-string b "\n" t))
                           (split-string (if complete-p
                                             (substring text 0 -2)
                                           text)
                                         "\n\n" t))))
      ;; When incomplete the last element is an unterminated fragment.
      (setq pending (if complete-p
                        ""
                      (string-join (car (last events)) "\n")))
      (unless complete-p
        (setq events (nreverse (cdr (nreverse events)))))
      (unless done
        (dolist (event events)
          (let ((data-lines (seq-filter
                             (lambda (l) (string-prefix-p "data:" l))
                             event)))
            ;; Each data: line is an independent payload (OpenAI/Hyper
            ;; never splits a JSON event across lines).
            (dolist (data-line data-lines)
              (let ((payload (string-trim (substring data-line 5))))
                (when (functionp on-event)
                  (funcall on-event payload))
                (cond
                 ((string= payload "[DONE]")
                  (setq done t))
                 ((string-prefix-p "{" payload)
                  (let ((obj (ignore-errors (json-read-from-string payload))))
                    (if (and obj (crush--openai-alist-get "error" obj))
                        (progn
                          (setq done t)
                          (setq error (crush--openai-alist-get "error" obj)))
                      (setq deltas (nconc deltas
                                          (crush--openai-sse-extract-deltas obj))))
                    (when obj
                      (crush--openai-sse-merge-tool-calls state obj))))))))))
      (cons deltas
            (list :pending pending :done done :error error
                  :tool-calls (plist-get state :tool-calls))))))

(defun crush--openai-alist-get (key alist)
  "Return the value for KEY in ALIST, handling symbol or string keys."
  (or (cdr (assoc key alist))
      (cdr (assoc (if (stringp key) (intern key) (symbol-name key)) alist))))

(defun crush--openai-alist-set (key alist value)
  "Set KEY to VALUE in ALIST, handling symbol or string keys.
Mutates the existing cell in place when found (either key type);
otherwise prepends a new (KEY . VALUE) cell and returns ALIST.
KEY is stored as a string to match `json-read-from-string' convention."
  (let ((cell (or (assoc key alist)
                  (assoc (if (stringp key) (intern key) (symbol-name key)) alist))))
    (if cell
        (setcdr cell value)
      (setcar alist (cons (if (stringp key) key (symbol-name key)) value)))
    alist))

(defun crush--openai-first-choice (obj)
  "Return the first choices[] entry from SSE JSON object OBJ, or nil."
  (let ((raw-choices (crush--openai-alist-get "choices" obj)))
    (if (vectorp raw-choices)
        (and (> (length raw-choices) 0)
             (aref raw-choices 0))
      (car-safe raw-choices))))

(defun crush--openai-sse-extract-deltas (obj)
  "Return typed deltas from SSE JSON object OBJ.
Each delta is a list (KIND TEXT ORIG) where KIND is `content',
`reasoning', or `tool_calls'; TEXT is the delta text (nil for
tool_calls); ORIG is the parsed JSON object (nil when OBJ is nil)."
  (when obj
    (let* ((first-choice (crush--openai-first-choice obj))
           (delta (and first-choice
                       (crush--openai-alist-get "delta" first-choice)))
           (content (and delta
                         (crush--openai-alist-get "content" delta)))
           (reasoning (and delta
                           (crush--openai-alist-get "reasoning_content" delta)))
           (tool-calls (and delta
                            (crush--openai-alist-get "tool_calls" delta))))
      (delq nil
            (list (when (stringp content)
                    (list 'content content obj))
                  (when (stringp reasoning)
                    (list 'reasoning reasoning obj))
                  (when (and tool-calls (vectorp tool-calls))
                    (list 'tool_calls nil obj)))))))

(defun crush--openai-sse-merge-tool-calls (state obj)
  "Merge tool-call deltas from OBJ into STATE's :tool-calls vector.
OpenAI emits each tool call as several deltas: every delta carries
an index, an id (on the first chunk), and function name/arguments.
Arguments accumulate across chunks by index."
  (let* ((first-choice (crush--openai-first-choice obj))
         (delta (and first-choice
                     (crush--openai-alist-get "delta" first-choice)))
         (tc-delta (and delta
                        (crush--openai-alist-get "tool_calls" delta))))
    (when (and tc-delta (vectorp tc-delta))
      (let ((tcs (plist-get state :tool-calls)))
        (unless tcs (setq tcs (make-vector 0 nil)))
        (seq-do
         (lambda (tc)
           (let ((idx (crush--openai-alist-get "index" tc)))
             (when (and idx (integerp idx))
               (while (>= idx (length tcs))
                 (setq tcs (vconcat tcs [nil])))
               (let ((existing (aref tcs idx)))
                 (if existing
                     ;; Merge: glue new arguments onto the existing
                     ;; function's arguments cell.
                     (let* ((new-fn (crush--openai-alist-get
                                     "function" tc))
                            (new-args (and new-fn
                                           (crush--openai-alist-get
                                            "arguments" new-fn)))
                            (ex-fn (crush--openai-alist-get
                                    "function" existing)))
                       (when (and new-args ex-fn)
                         (let ((cur-args (crush--openai-alist-get
                                          "arguments" ex-fn)))
                           (crush--openai-alist-set
                            "arguments" ex-fn
                            (concat (or cur-args "") new-args)))))
                   ;; First delta for this index: store as-is.
                   (aset tcs idx tc))))))
         tc-delta)
        (plist-put state :tool-calls tcs)))))

;;; Hyper transport

;;; The transport shells out to curl (like gptel and plz.el): curl is a
;;; mature HTTP client with reliable TLS, proxies, and streaming, and its
;;; subprocess filter gives us SSE chunks as they arrive without fighting
;;; url.el or raw sockets.  Request config and body go to curl via stdin.

(defun crush--openai-emit-delta (proc delta kind)
  "Emit DELTA text of KIND (`content' or `reasoning') for PROC.
Store the delta as a pending `:crush-emitted' event on PROC and
invoke the facade's `:crush-on-delta' callback, which is a closure
taking (DELTA KIND), that owns buffer insertion, the reasoning
overlay, and the cursor.  The transport never touches buffers."
  (process-put proc :crush-emitted t)
  (let ((on-delta (process-get proc :crush-on-delta)))
    (when (functionp on-delta)
      (funcall on-delta delta kind))))

(defun crush--openai-http-finish (proc error)
  "Finalize the curl request on PROC with optional ERROR.
Emits ERROR through the facade's `:crush-on-error' callback when
non-nil, then runs the finalize callback exactly once."
  (unless (process-get proc :crush-finished)
    ;; Mark finished first so a sentinel racing the [DONE] filter path
    ;; cannot double-finalize.
    (process-put proc :crush-finished t)
    (when error
      (let ((on-error (process-get proc :crush-on-error)))
        (when (functionp on-error)
          (funcall on-error error))))
    (let ((finish (process-get proc :crush-done-callback)))
      (when finish (funcall finish)))
    (when (process-live-p proc)
      (delete-process proc))))

(defun crush--openai-curl-filter (proc string)
  "Filter for the curl process PROC receiving SSE chunk STRING.
Feed the chunk to the SSE parser and emit any content deltas through
the facade's on-delta callback.  The HTTP response head (headers) is
not valid SSE and is ignored by the parser; the status line is parsed
for diagnostics, and errors are surfaced by the sentinel when curl
exits non-zero."
  (unless (process-get proc :crush-head-parsed)
    (setq string (crush--openai-parse-head proc string)))
  (let* ((on-event (lambda (payload)
                     (crush--debug-log
                      'output
                      (if (crush--openai-event-worth-pretty-p payload)
                          (concat "data:\n"
                                  (crush--openai-json-pretty payload))
                        (concat "data: " payload)))))
         (sse-state (process-get proc :crush-sse))
         (result (crush-openai-sse-feed sse-state string :on-event on-event))
         (deltas (car result))
         (new-state (cdr result)))
    (dolist (delta deltas)
      (when (nth 1 delta)
        (crush--openai-emit-delta proc (nth 1 delta) (nth 0 delta))))
    ;; Persist the full parser state: the state plist has no :sse key,
    ;; and dropping the `:pending' fragment would lose any SSE event
    ;; split across process-filter chunks.
    (process-put proc :crush-sse new-state)
    (when (plist-get new-state :done)
      (crush--openai-http-finish proc (plist-get new-state :error)))))

(defun crush--openai-parse-head (proc string)
  "Parse the HTTP status line out of the first chunks from PROC.
Accumulates chunks in `:crush-head' until a double newline, then
records `:crush-status' and `:crush-content-type', logs a request
diagnostic line, and returns the remainder of STRING after the head.
The token is never logged."
  (let ((head (concat (process-get proc :crush-head) string)))
    (if (string-match "\r?\n\r?\n" head)
        (let* ((head-text (substring head 0 (match-beginning 0)))
               (status (and (string-match "HTTP/[0-9.]+ \\([0-9]+\\)" head-text)
                            (string-to-number (match-string 1 head-text))))
               (content-type (and (string-match
                                   "content-type: *\\([^\r\n]+\\)"
                                   head-text)
                                  (downcase (match-string 1 head-text)))))
          (process-put proc :crush-status status)
          (process-put proc :crush-content-type content-type)
          (process-put proc :crush-head-parsed t)
          (crush--debug-log 'output (string-replace "\r" "" head-text))
          (crush--debug-log
           'response
           (format "POST %s model=%S status=%s content-type=%s token=%s"
                   (process-get proc :crush-url)
                   (process-get proc :crush-model)
                   (if status (number-to-string status) "?")
                   (or content-type "?")
                   (if (process-get proc :crush-token-p) "present" "none")))
          (substring head (match-end 0)))
      (progn
        (process-put proc :crush-head head)
        ""))))

(defun crush--openai-curl-sentinel (proc _event)
  "Sentinel for the curl process PROC.
If the stream did not end with `[DONE]' (e.g. connection dropped or
HTTP error), finish with an error; otherwise ensure cleanup."
  (let ((status (process-get proc :crush-status)))
    (crush--debug-log
     'sentinel
     (format "curl exited; status=%s finished=%S"
             (if status (number-to-string status) "?")
             (process-get proc :crush-finished)))
    (unless (process-get proc :crush-finished)
      (crush--openai-http-finish
       proc
       (if status
           (format "HTTP %s from %s" status (process-get proc :crush-url))
         "connection closed without [DONE]")))))

(defun crush--openai-json-pretty (json-string)
  "Return JSON-STRING pretty-printed with 2-space indentation.
Uses `json-pretty-print' in a temp buffer, avoiding any dependency on
`json-pretty-print-string' (not present in older json.el)."
  (with-temp-buffer
    (insert json-string)
    (json-pretty-print (point-min) (point-max))
    (buffer-string)))

(defun crush--openai-event-worth-pretty-p (payload)
  "Return non-nil if SSE PAYLOAD deserves pretty-printing in the log.
A payload is worth pretty-printing when it parses as JSON and either
carries the final chunk (`choices[].finish_reason' or top-level
`usage') or a long delta text (>= 40 chars).  Everything else --
short per-token deltas, `[DONE]', malformed payloads -- is kept
compact to bound the debug log during long streams."
  (when (and (string-prefix-p "{" payload))
    (let ((obj (ignore-errors (json-read-from-string payload))))
      (when obj
        (let* ((first-choice (crush--openai-first-choice obj))
               (delta (and first-choice
                           (crush--openai-alist-get "delta" first-choice)))
               (finish (and first-choice
                            (crush--openai-alist-get "finish_reason" first-choice)))
               (usage (crush--openai-alist-get "usage" obj))
               (content (and delta
                             (crush--openai-alist-get "content" delta)))
               (reasoning (and delta
                               (crush--openai-alist-get "reasoning_content" delta)))
               (text (or content reasoning)))
          (or finish usage
              (and (stringp text)
                   (>= (length text) 40))))))))

(defun crush-openai-request (base-url token body on-delta callback &optional on-error session-id x-crush-id)
  "Send HTTP POST to BASE-URL with TOKEN and JSON BODY via curl.
ON-DELTA is a callback (DELTA KIND) consuming streamed deltas (the
facade's append-delta); CALLBACK runs with no args when the stream
finishes; ON-ERROR (optional) receives a stream error message;
SESSION-ID, when non-nil, is the XXH3-64 of the buffer's session UUID,
sent as x-session-id / x-session-affinity for prefix caching.
X-CRUSH-ID, when non-nil, is sent as the x-crush-id header (matching
the Crush CLI's per-machine ID).  The backend never touches buffers.
Returns the curl process."
  (let* ((payload (json-encode body))
         (config (concat
                  (format "url = %s/chat/completions\n" base-url)
                  "request = POST\n"
                  "include\n"
                  "silent\n"
                  "no-buffer\n"
                  (format "max-time = %s\n" (or crush-openai-timeout 300))
                  "header = \"Content-Type: application/json\"\n"
                  (format "header = \"User-Agent: %s\"\n" crush-openai-user-agent)
                  (when token
                    (format "header = \"Authorization: Bearer %s\"\n" token))
                  (when session-id
                    (format "header = \"x-session-id: %s\"\n" session-id))
                  (when session-id
                    (format "header = \"x-session-affinity: %s\"\n" session-id))
                  (when x-crush-id
                    (format "header = \"x-crush-id: %s\"\n" x-crush-id))
                  "data-binary = @-\n"))
         (buf (get-buffer-create " *crush-hyper*"))
         (proc (make-process
                :name "crush-hyper"
                :buffer buf
                :command (list crush-openai-curl-program
                               "--config" "-")
                :connection-type 'pipe
                :noquery t
                :filter #'crush--openai-curl-filter
                :sentinel #'crush--openai-curl-sentinel
                :stderr (get-buffer-create "*crush-errors*"))))
    (process-put proc :crush-sse (crush-openai-sse-new-state))
    (process-put proc :crush-on-delta on-delta)
    (process-put proc :crush-on-error on-error)
    (process-put proc :crush-done-callback callback)
    ;; Request metadata for `crush--openai-curl-filter' diagnostics.
    (process-put proc :crush-url (format "%s/chat/completions" base-url))
    (process-put proc :crush-model (crush--openai-alist-get "model" body))
    (process-put proc :crush-token-p (and token t))
    (process-put proc :crush-head "")
    (process-put proc :crush-head-parsed nil)
    (process-put proc :crush-status nil)
    (crush--debug-log
     'request
     (format "POST %s model=%S token=%s sess=%s\nbody:\n%s"
             (process-get proc :crush-url)
             (process-get proc :crush-model)
             (if (process-get proc :crush-token-p) "present" "none")
             (or session-id "-")
             (crush--openai-json-pretty (json-encode body))))
    ;; Config + JSON body over stdin; EOF closes the request.
    (process-send-string proc config)
    (process-send-string proc payload)
    (process-send-eof proc)
    proc))
(provide 'crush-openai)
;;; crush-openai.el ends here
