;;; crush-hyper-backend.el --- Charm Hyper backend for crush  -*- lexical-binding: t; -*-
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

;; The direct-HTTP backend for crush.el: streamed chat completions
;; against the Charm Hyper gateway, bypassing the Crush CLI.  Requests
;; are made with curl as a subprocess (the gptel/plz approach), with the
;; JSON body and curl config sent over stdin; SSE frames are parsed
;; incrementally in the process filter.  See the main crush.el file for
;; the backend protocol, and HYPER-API.md for the gateway API.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'auth-source)
(require 'crush-backend)
(require 'crush-xxh3)

(defcustom crush-hyper-session-cache-p t
  "Send x-session-id and x-session-affinity cache-affinity headers.
Each hyper request carries the XXH3-64 hash of the buffer's session
UUID, pinning the conversation to a server-side prefix/token cache.
The hash is opaque and stable for the session; disable to opt out of
affinity (each request misses the cache)."
  :type 'boolean
  :group 'crush)

(defcustom crush-hyper-base-url "https://hyper.charm.land/v1"
  "Base URL of the Charm Hyper gateway.
The OpenAI-compatible chat-completions endpoint is
`BASE-URL/chat/completions'.  Overridden by the HYPER_URL
environment variable when set."
  :type 'string
  :group 'crush)

(defcustom crush-hyper-token #'crush-hyper--token-from-auth-source
  "Bearer access token for the Charm Hyper gateway.
Tokens are prefixed `sk-hyper-'; get one from the Hyper Dashboard.

May be a string, a function of no arguments that returns the token,
or nil to request without a token.  The default looks the token up in
`auth-source' (see `crush-hyper--token-from-auth-source')."
  :type '(choice (function-item crush-hyper--token-from-auth-source)
                 (const :tag "No token" nil)
                 string
                 function)
  :group 'crush)

(defun crush-hyper--token-from-auth-source ()
  "Return the hyper bearer token from `auth-source'.
Looks up host `hyper.charm.land' with user `apikey'.  Signals an error
when no secret is found, with setup instructions."
  (require 'auth-source)
  (let* ((found (auth-source-search
                 :host "hyper.charm.land" :user "apikey"
                 :require '(:secret)))
         (secret (and found
                      (plist-get (car found) :secret))))
    (if (functionp secret)
        (funcall secret)
      (or secret
          (user-error
           "No hyper token in auth-source; add `machine hyper.charm.land login apikey password sk-hyper-...' to %s or set `crush-hyper-token'"
           (or (car auth-sources) "auth-sources"))))))

(defun crush-hyper--resolve-token (token)
  "Resolve TOKEN to a bearer token string, or nil.
TOKEN may be nil, a string, or a function of no arguments returning
either.  Functions are called and the result is resolved recursively."
  (when token
    (let ((resolved (if (functionp token) (funcall token) token)))
      (if (stringp resolved)
          resolved
        (crush-hyper--resolve-token resolved)))))

(defcustom crush-hyper-history-include-reasoning nil
  "When non-nil, streamed reasoning (CoT) is re-sent along with the
assistant turns as `reasoning_content' (per HYPER-API.md §3.4).
nil (default) keeps reasoning out of the model-visible history."
  :type 'boolean
  :group 'crush)

(defcustom crush-hyper-timeout 300
  "Seconds to wait for a hyper request to finish before giving up."
  :type 'number
  :group 'crush)

(defcustom crush-hyper-max-tokens 64000
  "Default `max_tokens' for hyper requests."
  :type 'number
  :group 'crush)

(defcustom crush-hyper-temperature nil
  "Sampling temperature for hyper requests; nil means unset."
  :type '(choice (const nil) number)
  :group 'crush)

(defcustom crush-hyper-thinking nil
  "Enable Hyper's chain-of-thought reasoning for each request.

When non-nil, the request body carries `thinking: t' and the model
emits a `reasoning_content' trace (streamed as reasoning deltas) before
the final answer.  When nil (default), the model skips reasoning and
answers directly.  This is the master switch: `crush-hyper-reasoning-effort'
only tunes the depth of that reasoning and is a no-op while thinking is
disabled."
  :type 'boolean
  :group 'crush)

(defcustom crush-hyper-reasoning-effort nil
  "Reasoning depth for the model; nil means use the model default.
Values like `low', `medium', `high', `max'.

Gated by `crush-hyper-thinking': effort tunes how deep the chain-of-thought
reasoning goes, but only when thinking is enabled.  Setting effort while
`crush-hyper-thinking' is nil has no effect on models whose reasoning is
switched off."
  :type '(choice (const nil) string)
  :group 'crush)

(defcustom crush-hyper-curl-program "curl"
  "Path to the curl executable used by the hyper backend."
  :type 'string
  :group 'crush)

(defconst crush-hyper-system-prompt
  "You are a helpful assistant.  You answer concisely and correctly."
  "System prompt sent with every phase-1 hyper request.")

(defconst crush-hyper-default-model "deepseek-v4-flash"
  "Model used when the backend model slot and `crush-model' are both nil.")

(declare-function crush--debug-log "crush.el" (category message))
(declare-function crush--history-for "crush.el" (buffer))

(cl-defstruct (crush-hyper-backend
               (:include crush-backend (type 'hyper))
               (:constructor nil)
               (:constructor crush-make-hyper-backend
                             (&key buffer working-directory base-url token model
                                   &aux (type 'hyper) (completion-action nil)))
               (:copier nil))
  "Backend that talks to the Charm Hyper gateway via HTTP+SSE."
  base-url
  token
  model)

(defun crush--hyper-history-messages (turns)
  "Build message alists from history TURNS.
TURNS is a list of (ROLE . TEXT) conses from the facade's history
extraction (see `crush--history-turns').  `user' and `assistant'
become messages; a `reasoning' turn immediately following an
`assistant' turn is folded into that same assistant message as the
`reasoning_content' field (HYPER-API.md §3.4).  Any other role, and
empty or whitespace-only text, is dropped.  Returns the alists in
conversation order."
  (let ((messages nil)
        (pending nil))
    (dolist (turn turns)
      (let ((role (car turn))
            (text (cdr turn)))
        (cond
         ((and (eq role 'reasoning) pending)
          ;; Attach the trace to the assistant message just built.
          (setcdr (last pending)
                  (list (cons 'reasoning_content text))))
         ((and (memq role '(user assistant))
               (stringp text)
               (> (length (string-trim text)) 0))
          (let ((msg (cons (cons 'role (symbol-name role))
                           (list (cons 'content text)))))
            (push msg messages)
            (setq pending msg)))
         (t (setq pending nil)))))
    (nreverse messages)))

(defun crush--hyper-compose-request (prompt context model &optional turns)
  "Compose a chat-completions request alist for PROMPT.
CONTEXT is optional attachment text; MODEL is the resolved model (the
caller passes the backend's model slot, already derived from the shared
`crush-model' defcustom).  Falls back to `crush-hyper-default-model'.
Prior (ROLE . TEXT) TURNS from the facade's history extraction ride
between the system prompt and the new user message; with no turns the
body carries exactly system + user (`stream: t', no tools).  History
is disabled by the caller passing nil turns (`crush-hyper-history-limit
0 means the facade extracts none)."
  (let* ((model (or model crush-hyper-default-model))
         (user-content (if (and context (not (string-empty-p context)))
                           (concat crush-context-preamble "

"
                                   context "

" prompt)
                         prompt))
         (user-message (list (list '(role . "user")
                                   (cons 'content user-content))))
         (messages (if turns
                       (append (list (list '(role . "system")
                                           (cons 'content crush-hyper-system-prompt)))
                               (crush--hyper-history-messages turns)
                               user-message)
                     (list (list '(role . "system")
                                 (cons 'content crush-hyper-system-prompt))
                           (list '(role . "user")
                                 (cons 'content user-content)))))
         (body `((model . ,model)
                 (stream . t)
                 (messages . ,messages))))
    (when crush-hyper-max-tokens
      (setq body (cons (cons 'max_tokens crush-hyper-max-tokens) body)))
    (when crush-hyper-temperature
      (setq body (cons (cons 'temperature crush-hyper-temperature) body)))
    (when crush-hyper-thinking
      (setq body (cons '(thinking . t) body)))
    (when crush-hyper-reasoning-effort
      (setq body (append body
                         `((reasoning_effort . ,crush-hyper-reasoning-effort)))))
    body))
(defun crush--hyper-sse-new-state ()
  "Return a fresh SSE parser state plist."
  (list :pending "" :done nil :error nil))

(defun crush--hyper-sse-feed (state chunk &optional &rest args)
  "Feed CHUNK into SSE parser STATE and return (DELTAS . NEW-STATE).
Each delta is a (KIND . TEXT) cons, where KIND is `content' or
`reasoning'; see `crush--hyper-sse-extract-deltas'.  Sets `:done'
when `[DONE]' or an error payload is seen; the `:pending' buffer
keeps partial events across chunk boundaries.  ARGS may contain
:on-event, a callback invoked with the raw payload of each COMPLETE
`data:' event (before it is dispatched), including `[DONE]'."
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
                    (if (and obj (crush--hyper-alist-get "error" obj))
                        (progn
                          (setq done t)
                          (setq error (crush--hyper-alist-get "error" obj)))
                      (setq deltas (nconc deltas
                                          (crush--hyper-sse-extract-deltas obj))))))))))))
      (cons deltas
            (list :pending pending :done done :error error)))))

(defun crush--hyper-alist-get (key alist)
  "Return the value for KEY in ALIST, handling symbol or string keys."
  (or (cdr (assoc key alist))
      (cdr (assoc (if (stringp key) (intern key) (symbol-name key)) alist))))

(defun crush--hyper-sse-extract-deltas (obj)
  "Return typed deltas from SSE JSON object OBJ.
A delta is a cons (KIND . TEXT) where KIND is `content' or
`reasoning'.  `content' carries `choices[0].delta.content';
`reasoning' carries `choices[0].delta.reasoning_content'.  Returns
nil when OBJ is nil or carries no delta text."
  (when obj
    (let* ((raw-choices (crush--hyper-alist-get "choices" obj))
           (first-choice (if (vectorp raw-choices)
                             (and (> (length raw-choices) 0)
                                  (aref raw-choices 0))
                           (car-safe raw-choices)))
           (delta (and first-choice
                       (crush--hyper-alist-get "delta" first-choice)))
           (content (and delta
                         (crush--hyper-alist-get "content" delta)))
           (reasoning (and delta
                           (crush--hyper-alist-get "reasoning_content" delta))))
      (delq nil
            (list (when (stringp content)
                    (cons 'content content))
                  (when (stringp reasoning)
                    (cons 'reasoning reasoning)))))))

;;; Hyper transport

;;; The transport shells out to curl (like gptel and plz.el): curl is a
;;; mature HTTP client with reliable TLS, proxies, and streaming, and its
;;; subprocess filter gives us SSE chunks as they arrive without fighting
;;; url.el or raw sockets.  Request config and body go to curl via stdin.

(defun crush--hyper-emit-delta (proc delta kind)
  "Emit DELTA text of KIND (`content' or `reasoning') to the facade.
Stores the delta as a pending `:crush-emitted' event and invokes the
facade's `:crush-on-delta' callback (a closure of (DELTA KIND)) that
owns buffer insertion, the reasoning overlay, and the cursor.  The
transport never touches buffers."
  (process-put proc :crush-emitted t)
  (let ((on-delta (process-get proc :crush-on-delta)))
    (when (functionp on-delta)
      (funcall on-delta delta kind))))

(defun crush--hyper-http-finish (proc error)
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

(defun crush--hyper-curl-filter (proc string)
  "Filter for the curl process PROC receiving SSE chunk STRING.
Feed the chunk to the SSE parser and emit any content deltas through
the facade's on-delta callback.  The HTTP response head (headers) is
not valid SSE and is ignored by the parser; the status line is parsed
for diagnostics, and errors are surfaced by the sentinel when curl
exits non-zero."
  (unless (process-get proc :crush-head-parsed)
    (setq string (crush--hyper-parse-head proc string)))
  (let* ((on-event (lambda (payload)
                     (crush--debug-log
                      'output
                      (if (crush--hyper-event-worth-pretty-p payload)
                          (concat "data:\n"
                                  (crush--hyper-json-pretty payload))
                        (concat "data: " payload)))))
         (sse-state (process-get proc :crush-sse))
         (result (crush--hyper-sse-feed sse-state string :on-event on-event))
         (deltas (car result))
         (new-state (cdr result)))
    (dolist (delta deltas)
      (crush--hyper-emit-delta proc (cdr delta) (car delta)))
    ;; Persist the full parser state: the state plist has no :sse key,
    ;; and dropping the `:pending' fragment would lose any SSE event
    ;; split across process-filter chunks.
    (process-put proc :crush-sse new-state)
    (when (plist-get new-state :done)
      (crush--hyper-http-finish proc (plist-get new-state :error)))))

(defun crush--hyper-parse-head (proc string)
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

(defun crush--hyper-curl-sentinel (proc _event)
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
      (crush--hyper-http-finish
       proc
       (if status
           (format "HTTP %s from %s" status (process-get proc :crush-url))
         "connection closed without [DONE]")))))

(defun crush--hyper-json-pretty (json-string)
  "Return JSON-STRING pretty-printed with 2-space indentation.
Uses `json-pretty-print' in a temp buffer, avoiding any dependency on
`json-pretty-print-string' (not present in older json.el)."
  (with-temp-buffer
    (insert json-string)
    (json-pretty-print (point-min) (point-max))
    (buffer-string)))

(defun crush--hyper-event-worth-pretty-p (payload)
  "Return non-nil if SSE PAYLOAD deserves pretty-printing in the log.
A payload is worth pretty-printing when it parses as JSON and either
carries the final chunk (`choices[].finish_reason' or top-level
`usage') or a long delta text (>= 40 chars).  Everything else --
short per-token deltas, `[DONE]', malformed payloads -- is kept
compact to bound the debug log during long streams."
  (when (and (string-prefix-p "{" payload))
    (let ((obj (ignore-errors (json-read-from-string payload))))
      (when obj
        (let* ((raw-choices (crush--hyper-alist-get "choices" obj))
               (first-choice (if (vectorp raw-choices)
                                 (and (> (length raw-choices) 0)
                                      (aref raw-choices 0))
                               (car-safe raw-choices)))
               (delta (and first-choice
                           (crush--hyper-alist-get "delta" first-choice)))
               (finish (and first-choice
                            (crush--hyper-alist-get "finish_reason" first-choice)))
               (usage (crush--hyper-alist-get "usage" obj))
               (content (and delta
                             (crush--hyper-alist-get "content" delta)))
               (reasoning (and delta
                               (crush--hyper-alist-get "reasoning_content" delta)))
               (text (or content reasoning)))
          (or finish usage
              (and (stringp text)
                   (>= (length text) 40))))))))

(defun crush--hyper-request (base-url token body on-delta callback &optional on-error session-id)
  "Send HTTP POST to BASE-URL with TOKEN and JSON BODY via curl.
ON-DELTA is a callback (DELTA KIND) consuming streamed deltas (the
facade's append-delta); CALLBACK runs with no args when the stream
finishes; ON-ERROR (optional) receives a stream error message;
SESSION-ID, when non-nil, is the XXH3-64 of the buffer's session UUID,
sent as x-session-id / x-session-affinity for prefix caching.  The
backend never touches buffers.  Returns the curl process."
  (let* ((payload (json-encode body))
         (config (concat
                  (format "url = %s/chat/completions\n" base-url)
                  "request = POST\n"
                  "include\n"
                  "silent\n"
                  "no-buffer\n"
                  (format "max-time = %s\n" (or crush-hyper-timeout 300))
                  "header = \"Content-Type: application/json\"\n"
                  (when token
                    (format "header = \"Authorization: Bearer %s\"\n" token))
                  (when session-id
                    (format "header = \"x-session-id: %s\"\n" session-id))
                  (when session-id
                    (format "header = \"x-session-affinity: %s\"\n" session-id))
                  "data-binary = @-\n"))
         (buf (get-buffer-create " *crush-hyper*"))
         (proc (make-process
                :name "crush-hyper"
                :buffer buf
                :command (list crush-hyper-curl-program
                               "--config" "-")
                :connection-type 'pipe
                :noquery t
                :filter #'crush--hyper-curl-filter
                :sentinel #'crush--hyper-curl-sentinel
                :stderr (get-buffer-create "*crush-errors*"))))
    (process-put proc :crush-sse (crush--hyper-sse-new-state))
    (process-put proc :crush-on-delta on-delta)
    (process-put proc :crush-on-error on-error)
    (process-put proc :crush-done-callback callback)
    ;; Request metadata for `crush--hyper-curl-filter' diagnostics.
    (process-put proc :crush-url (format "%s/chat/completions" base-url))
    (process-put proc :crush-model (crush--hyper-alist-get "model" body))
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
             (crush--hyper-json-pretty (json-encode body))))
    ;; Config + JSON body over stdin; EOF closes the request.
    (process-send-string proc config)
    (process-send-string proc payload)
    (process-send-eof proc)
    proc))
;;; Hyper backend methods

(cl-defmethod crush-backend-send-prompt
  ((backend crush-hyper-backend) prompt &key context session-id session-uuid continue-p completion buffer stderr on-delta on-error)
  "Send PROMPT to BACKEND via a direct HTTP+SSE request to Hyper.
COMPLETION is the facade's continuation invoked when the stream
finishes; ON-DELTA consumes streamed deltas; ON-ERROR receives stream
errors.  SESSION-UUID is the buffer's opaque session identifier; when
`crush-hyper-session-cache-p' is non-nil it is hashed (XXH3-64) and
sent as the x-session-id / x-session-affinity cache-affinity headers
(SESSION-ID is the CLI-only session, unused here).  The prior
conversation is read from BUFFER via the facade's `crush--history-for'
(which enters the buffer itself) and re-sent as `user'/'assistant'
messages; the facade's `crush-hyper-history-limit' decides whether any
turns exist.  The backend never touches buffers itself."
  (ignore session-id continue-p stderr)
  (let* ((history (and buffer
                       (crush--history-for buffer)))
         (body (crush--hyper-compose-request
                prompt context (crush-hyper-backend-model backend)
                history))
         (base-url (or (crush-hyper-backend-base-url backend)
                       (getenv "HYPER_URL")
                       crush-hyper-base-url))
         (token (crush-hyper--resolve-token
                 (or (crush-hyper-backend-token backend) crush-hyper-token)))
         (session-id (and crush-hyper-session-cache-p session-uuid
                          (crush-xxh3-hash64 session-uuid))))
    (setf (crush-backend-completion-action backend) completion)
    (crush--hyper-request
     base-url token body
     ;; The transport's on-delta callback is the facade's append-delta
     ;; (or a no-op fallback); no buffer knowledge leaks into the backend.
     (or on-delta #'ignore)
     ;; The done-callback is the injected completion.
     (or completion #'ignore)
     ;; Stream errors surface through the facade's on-error callback.
     (or on-error #'ignore)
     session-id)
    nil))

(cl-defmethod crush-backend-interrupt ((backend crush-hyper-backend))
  "Interrupt the hyper request for BACKEND."
  (crush-backend-cleanup backend))

(cl-defmethod crush-backend-active-p ((_backend crush-hyper-backend))
  "Return non-nil while a hyper request is in flight for BACKEND."
  nil)

(cl-defmethod crush-backend-cleanup ((_backend crush-hyper-backend))
  "Clean up any hyper request resources; phase 1 has none to kill."
  nil)

(cl-defmethod crush-backend-grant-permission ((_backend crush-hyper-backend) _permission-id _action)
  "No permissions are issued in phase 1."
  nil)

(provide 'crush-hyper-backend)
;;; crush-hyper-backend.el ends here
