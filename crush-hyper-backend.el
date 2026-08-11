;;; crush-hyper-backend.el --- Charm Hyper backend for crush  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Thomas Christensen

;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;; URL: https://github.com/thomasc1971/crush.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, ai, convenience
;; Prefix: crush-

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

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
answers directly.  This is the on/off switch; `crush-hyper-reasoning-effort'
independently controls how deep the reasoning goes when enabled."
  :type 'boolean
  :group 'crush)

(defcustom crush-hyper-reasoning-effort nil
  "Reasoning depth for the model; nil means use the model default.
Values like `low', `medium', `high', `max'.

Independent of `crush-hyper-thinking': effort selects how deep the
reasoning goes, while `thinking' decides whether reasoning happens at
all.  Setting effort without thinking has no visible effect on models
that only reason when thinking is enabled."
  :type '(choice (const nil) string)
  :group 'crush)

(defcustom crush-hyper-curl-program "curl"
  "Path to the curl executable used by the hyper backend."
  :type 'string
  :group 'crush)

(defconst crush-hyper-system-prompt
  "You are a helpful assistant.  You answer concisely and correctly."
  "System prompt sent with every phase-1 hyper request.")

(defconst crush-hyper-default-model "qwen3.7-plus"
  "Model used when `crush-model' and the backend model are both nil.")

(defvar crush-model nil
  "Model to use for hyper requests.
Defined in `crush-run-backend.el' as a defcustom; shadowed here so
the compiler knows the free reference in `crush--hyper-compose-request'
is a variable.")

(declare-function crush--debug-log "crush.el" (category message))
(declare-function crush--finalize-response "crush.el" ())

(cl-defstruct (crush-hyper-backend
               (:include crush-backend (type 'hyper))
               (:constructor nil)
               (:constructor crush-make-hyper-backend
                             (&key buffer working-directory base-url token model
                                   &aux (type 'hyper)))
               (:copier nil))
  "Backend that talks to the Charm Hyper gateway via HTTP+SSE."
  base-url
  token
  model)

(defun crush--hyper-compose-request (prompt context model)
  "Compose a chat-completions request alist for PROMPT.
CONTEXT is optional attachment text; MODEL overrides the configured model.
The body carries `stream: t' and no tools (phase 1)."
  (let* ((model (or model crush-model crush-hyper-default-model))
         (user-content (if (and context (not (string-empty-p context)))
                           (concat crush-context-preamble "\n\n"
                                   context "\n\n" prompt)
                         prompt))
         (body `((model . ,model)
                 (stream . t)
                 (messages . ,(list (list '(role . "system")
                                          (cons 'content crush-hyper-system-prompt))
                                    (list '(role . "user")
                                          (cons 'content user-content)))))))
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

(defun crush--hyper-sse-feed (state chunk)
  "Feed CHUNK into SSE parser STATE and return (DELTAS . NEW-STATE).
Each delta is the text content of a `choices[0].delta.content' field.
Sets `:done' when `[DONE]' or an error payload is seen; the `:pending'
buffer keeps partial events across chunk boundaries."
  (let ((pending (concat (plist-get state :pending) chunk))
        (done (plist-get state :done))
        (error (plist-get state :error))
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
                (cond
                 ((string= payload "[DONE]")
                  (setq done t))
                 ((string-prefix-p "{" payload)
                  (let ((obj (ignore-errors (json-read-from-string payload))))
                    (if (and obj (crush--hyper-alist-get "error" obj))
                        (progn
                          (setq done t)
                          (setq error (crush--hyper-alist-get "error" obj)))
                      (let ((content (crush--hyper-sse-extract-content obj)))
                        (when content
                          (push content deltas))))))))))))
      (cons (nreverse deltas)
            (list :pending pending :done done :error error)))))

(defun crush--hyper-alist-get (key alist)
  "Return the value for KEY in ALIST, handling symbol or string keys."
  (or (cdr (assoc key alist))
      (cdr (assoc (if (stringp key) (intern key) (symbol-name key)) alist))))

(defun crush--hyper-sse-extract-content (obj)
  "Return the content delta from SSE JSON object OBJ, or nil."
  (when obj
    (let* ((raw-choices (crush--hyper-alist-get "choices" obj))
           (first-choice (if (vectorp raw-choices)
                             (and (> (length raw-choices) 0)
                                  (aref raw-choices 0))
                           (car-safe raw-choices)))
           (delta (and first-choice
                       (crush--hyper-alist-get "delta" first-choice)))
           (content (and delta
                         (crush--hyper-alist-get "content" delta))))
      (when (stringp content)
        content))))

;;; Hyper transport

;;; The transport shells out to curl (like gptel and plz.el): curl is a
;;; mature HTTP client with reliable TLS, proxies, and streaming, and its
;;; subprocess filter gives us SSE chunks as they arrive without fighting
;;; url.el or raw sockets.  Request config and body go to curl via stdin.

(defun crush--hyper-insert-delta (proc delta)
  "Insert DELTA text into the crush buffer served by PROC.
Appends at the end of the buffer (the growing response area) so
streamed deltas stay in order.  `crush--response-start' is not touched;
it continues to mark the start of the response for
`crush--finalize-response'."
  (let ((target (process-get proc :crush-target)))
    (when (buffer-live-p target)
      (with-current-buffer target
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t))
          (save-excursion
            (goto-char (point-max))
            (insert delta)))))))

(defun crush--hyper-http-finish (proc error)
  "Finalize the curl request on PROC with optional ERROR.
Inserts an error line when ERROR is non-nil and runs the finalize
callback exactly once."
  (unless (process-get proc :crush-finished)
    (process-put proc :crush-finished t)
    (when error
      (crush--hyper-insert-delta proc (format "
[crush-hyper error: %s]" error)))
    (let ((finish (process-get proc :crush-done-callback)))
      (when finish (funcall finish)))
    (when (process-live-p proc)
      (delete-process proc))))

(defun crush--hyper-curl-filter (proc string)
  "Filter for the curl process PROC receiving SSE chunk STRING.
Feed the chunk to the SSE parser and insert any content deltas into the
crush buffer.  The HTTP response head (headers) is not valid SSE and is
ignored by the parser; the status line is parsed for diagnostics, and
errors are surfaced by the sentinel when curl exits non-zero."
  (crush--debug-log 'output (format "%S" (string-replace "\r" "" string)))
  (unless (process-get proc :crush-head-parsed)
    (setq string (crush--hyper-parse-head proc string)))
  (let* ((sse-state (process-get proc :crush-sse))
         (result (crush--hyper-sse-feed sse-state string))
         (deltas (car result))
         (new-state (cdr result)))
    (dolist (delta deltas)
      (crush--hyper-insert-delta proc delta))
    (process-put proc :crush-sse (plist-get new-state :sse))
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

(defun crush--hyper-request (base-url token body target callback)
  "Send HTTP POST to BASE-URL with TOKEN and JSON BODY via curl.
TARGET is the crush buffer to insert streamed content into; CALLBACK
is called with no args when the stream finishes.  Returns the curl
process."
  (let* ((payload (json-encode body))
         (config (concat
                  (format "url = %s/chat/completions\n" base-url)
                  "request = POST\n"
                  "include\n"
                  "silent\n"
                  "no-buffer\n"
                  "header = \"Content-Type: application/json\"\n"
                  (when token
                    (format "header = \"Authorization: Bearer %s\"\n" token))
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
    (process-put proc :crush-target target)
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
     (format "POST %s model=%S token=%s body=%S"
             (process-get proc :crush-url)
             (process-get proc :crush-model)
             (if (process-get proc :crush-token-p) "present" "none")
             (json-encode body)))
    ;; Config + JSON body over stdin; EOF closes the request.
    (process-send-string proc config)
    (process-send-string proc payload)
    (process-send-eof proc)
    proc))
;;; Hyper backend methods

(cl-defmethod crush-backend-send-prompt
  ((backend crush-hyper-backend) prompt &key context session-id continue-p)
  "Send PROMPT to BACKEND via a direct HTTP+SSE request to Hyper."
  (ignore session-id continue-p)
  (let* ((body (crush--hyper-compose-request
                prompt context (crush-hyper-backend-model backend)))
         (base-url (or (crush-hyper-backend-base-url backend)
                       (getenv "HYPER_URL")
                       crush-hyper-base-url))
         (token (crush-hyper--resolve-token
                 (or (crush-hyper-backend-token backend) crush-hyper-token)))
         (buffer (crush-backend-buffer backend)))
    (with-current-buffer buffer
      (setq-local crush--response-start (point-marker)))
    (crush--hyper-request
     base-url token body buffer
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (crush--finalize-response)))))
    (with-current-buffer buffer
      (setq-local crush-process nil))))

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
