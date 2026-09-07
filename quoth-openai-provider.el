;;; quoth-openai-provider.el --- Shared base for OpenAI-compatible providers  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience
;;; Prefix: quoth-

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

;; The shared base for quoth providers on OpenAI-compatible endpoints:
;; the provider struct (base URL, token, model slots), the token
;; plumbing (auth-source lookup, symbol/string/function resolution),
;; the one-shot curl JSON fetch the model catalogs ride, the bundled
;; seed shell, and the default provider methods (the staged send over
;; the wire client).  A concrete provider subclasses
;; `quoth-openai-provider', sets its type, and overrides the catalog
;; generic plus whatever protocol extras its endpoint wants — see
;; `quoth-hyper-provider.el' and `quoth-ollama-provider.el'.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'subr-x)

;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The order follows the dependency graph: `quoth-provider'
;;; (the protocol), then `quoth-openai-client' (the wire client the
;;; default send rides), then `quoth-context' (the staged system
;;; prompt).
(eval-and-compile
  (dolist (dep '("quoth-json" "quoth-provider" "quoth-openai-client"
                 "quoth-context"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(declare-function quoth--debug-log "quoth.el" (category message))
(declare-function quoth--schedule "quoth.el" (fn))
(declare-function quoth--busy-p "quoth.el" ())
(declare-function quoth--phase-set "quoth.el" (phase &rest keys))
(declare-function quoth--history-for "quoth.el" (buffer))
(declare-function quoth--openai-alist-get "quoth-openai-client" (key alist))

(defgroup quoth-openai-provider nil
  "Shared base for OpenAI-compatible providers."
  :group 'quoth
  :prefix "quoth-openai-provider-")

;;; The base provider struct.

(cl-defstruct (quoth-openai-provider
               (:include quoth-provider)
               (:constructor nil)
               (:constructor quoth-make-openai-provider
                             (&key buffer working-directory base-url token model
                                   &aux (type 'openai) (completion-action nil)))
               (:copier nil))
  "Base provider for OpenAI-compatible endpoints.
Carries the shared configuration: BASE-URL (the OpenAI-compatible
root, `BASE-URL/chat/completions' on the wire), TOKEN (the bearer
token form), and MODEL (a cache of the buffer's session model).
Concrete providers subclass it and set their own TYPE."
  base-url
  token
  model)

;;; Token plumbing.

(defun quoth-openai-provider--token-from-auth-source (host user label custom)
  "Return the bearer token for HOST and USER from `auth-source'.
LABEL names the provider in the error message (e.g. \"hyper\"); CUSTOM
is the defcustom users set instead (e.g. `quoth-hyper-token').
Signals an error when no secret is found, with setup instructions."
  (require 'auth-source)
  (let* ((found (auth-source-search
                 :host host :user user
                 :require '(:secret)))
         (secret (and found
                      (plist-get (car found) :secret))))
    (if (functionp secret)
        (funcall secret)
      (or secret
          (user-error
           "No %s token in auth-source; add `machine %s login %s password ...' to %s or set `%s'"
           label host user
           (or (car auth-sources) "auth-sources")
           custom)))))

(defun quoth-openai-provider--resolve-token (token)
  "Resolve TOKEN to a bearer token string, or nil.
TOKEN may be nil, a string, or a function of no arguments returning
either.  Functions are called and the result is resolved recursively."
  (when token
    (let ((resolved (if (functionp token) (funcall token) token)))
      (if (stringp resolved)
          resolved
        (quoth-openai-provider--resolve-token resolved)))))

;;; One-shot curl JSON fetch (GET or POST), used by the model catalogs.

(defun quoth-openai-provider--fetch-json-filter (proc string)
  "Filter for a one-shot curl process PROC receiving chunk STRING.
Accumulates raw output in the process's `:quoth-catalog-body'
property, skipping any `Process ...' status lines Emacs writes to the
process buffer (they are not curl output)."
  (process-put proc :quoth-catalog-body
               (concat (or (process-get proc :quoth-catalog-body) "")
                       string)))

(defun quoth-openai-provider--fetch-json-sentinel (proc _event)
  "Sentinel for a one-shot curl process PROC.
Drain output already received but not yet dispatched to the filter
\(the single permitted zero-timeout poll pattern), parse the
accumulated body, and deliver the parsed object (or nil on failure)
to the process's :quoth-catalog-callback via the `quoth--schedule' hop."
  ;; Drain the tail before reading the accumulated body.
  (when (and (processp proc) (not (process-live-p proc)))
    (accept-process-output proc 0))
  (let* ((raw (or (process-get proc :quoth-catalog-body) ""))
         (callback (process-get proc :quoth-catalog-callback))
         (body (string-trim raw))
         (parsed (and (not (string-empty-p body))
                      (condition-case nil
                          (quoth-json-read body)
                        (error nil)))))
    (quoth--schedule (lambda () (funcall callback parsed)))))

(defun quoth-openai-provider--fetch-json (url token method body on-done)
  "Fetch JSON from URL with TOKEN, delivering the parsed object to ON-DONE.
METHOD is \"GET\" or \"POST\"; BODY (a JSON string) rides a POST via
`data-binary = @-' (the last config line, so curl reads the rest of
stdin as the body).  ON-DONE receives the parsed object, or nil when
the fetch fails (network error, unparseable body).  Never logs the
token; failures are debug-logged and swallowed so the catalog cache
keeps its entry.  Returns the curl process."
  (let* ((config (concat
                  (format "url = %s\n" url)
                  (format "request = %s\n" method)
                  "silent\n"
                  "no-buffer\n"
                  (format "max-time = %s\n" (or quoth-openai-timeout 300))
                  (format "header = \"User-Agent: %s\"\n"
                          quoth-openai-user-agent)
                  (when token
                    (format "header = \"Authorization: Bearer %s\"\n" token))
                  (when (string= method "POST")
                    "header = \"Content-Type: application/json\"\n"
                    "data-binary = @-\n")))
         ;; The buffer receives no data (the filter diverges it), but
         ;; `make-process' still needs a buffer for `:buffer'.
         (buf (get-buffer-create " *quoth-openai-catalog*"))
         (proc (make-process
                :name "quoth-openai-catalog"
                :buffer buf
                :command (list quoth-openai-curl-program "--config" "-")
                :connection-type 'pipe
                :noquery t
                :filter #'quoth-openai-provider--fetch-json-filter
                :sentinel #'quoth-openai-provider--fetch-json-sentinel
                :stderr (get-buffer-create "*quoth-errors*"))))
    (process-put proc :quoth-catalog-callback on-done)
    (process-send-string proc config)
    (when (and (string= method "POST") body)
      (process-send-string proc body))
    (process-send-eof proc)
    proc))

;;; Bundled seed shell.

(defun quoth-openai-provider--models-seed-read (file decode)
  "Read the bundled catalog snapshot FILE through the entry decoder DECODE.
DECODE receives each parsed JSON entry object and returns one
normalized model plist, or nil to skip it.  Returns the plist list,
or nil when FILE is missing, unreadable, or unparseable — the seed is
absent, never an error, so the cache read falls through to the cold
fallback path."
  (and (file-exists-p file)
       (condition-case nil
           (let* ((raw (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))
                  (parsed (and (stringp raw)
                               (not (string-empty-p (string-trim raw)))
                               (quoth-json-read (string-trim raw)))))
             (when (vectorp parsed)
               (delq nil
                     (mapcar decode (append parsed nil)))))
         (error nil))))

(defconst quoth-openai-provider--models-seed-directory
  (file-name-directory
   (or load-file-name buffer-file-name default-directory))
  "Directory the concrete provider module was loaded from.
The bundled catalog snapshots live next to it; the .elc sits in the
same directory as the .el and the data files in every install style
\(source checkout, package install, tarball).")

;;; Protocol extras: the per-endpoint knobs of the default send.

(cl-defgeneric quoth-provider--request-extras (provider session-uuid)
  "Return wire-request extras for PROVIDER's next send, or nil.
SESSION-UUID is the buffer's opaque session identifier.  The value is
a plist the default `quoth-provider-send-prompt' method understands:
`:session-id' (a hash sent as the x-session-id / x-session-affinity
prefix-cache headers) and `:x-crush-id' (sent as the x-crush-id
header).  Providers with neither return nil (the default)."
  (ignore provider session-uuid)
  nil)

(cl-defgeneric quoth-provider--body-extras (provider)
  "Return body keys to append to PROVIDER's composed request, or nil.
The default send appends the returned alist keys to the composed
request body before the request fires.  Providers whose endpoints
want no extra keys return nil (the default)."
  (ignore provider)
  nil)

;;; Default provider methods.

(cl-defmethod quoth-provider-send-prompt
  ((provider quoth-openai-provider) prompt &key session-id session-uuid continue-p completion buffer stderr on-delta on-error continuation)
  "Send PROMPT to PROVIDER via a staged HTTP+SSE request.
Stages the system prompt first (usually a cache hit; see
`quoth-context-async'), then fires the curl request over the wire
client.  COMPLETION is the core's continuation invoked when the stream
finishes; ON-DELTA consumes streamed deltas; ON-ERROR receives stream
errors.  The prior conversation is read from BUFFER via the core's
`quoth--history-for', which enters the buffer itself, and re-sent as
message alists; the buffer-local `quoth-history-limit' decides whether
history exists.  CONTINUATION, when non-nil, is a list of message
alists (user, assistant with `tool_calls', `role: \"tool\"') that
replace the user message — used by the tool loop to send follow-up
requests with tool results.  Wire extras (`quoth-provider--request-extras')
and body extras (`quoth-provider--body-extras') ride per the concrete
provider.  The provider never touches buffers itself."
  (ignore session-id continue-p stderr)
  ;; A previous in-flight request must not outlive this send.
  (quoth-provider-cleanup provider)
  (let* ((stage-handle (list :stage-process nil :curl nil :done-p nil))
         (base-url (quoth-openai-provider-base-url provider))
         (token (quoth-openai-provider--resolve-token
                 (or (quoth-openai-provider-token provider)
                     (quoth-openai-provider--provider-token provider))))
         (extras (quoth-provider--request-extras provider session-uuid)))
    ;; Stage the system prompt first (usually a cache hit); the curl
    ;; fires once it lands.  The handle covers both stages.
    (setf (quoth-provider-completion-action provider) completion)
    (setf (quoth-provider-request provider) stage-handle)
    (setf (plist-get stage-handle :stage-process)
          (quoth-context-async
           (quoth-provider-buffer provider)
           (lambda (system-prompt)
             (when (bufferp buffer)
               (with-current-buffer buffer
                 (when (quoth--busy-p)
                   (quoth--phase-set 'streaming))))
             (let* ((history (and buffer
                                  (quoth--history-for buffer)))
                    (model (quoth-openai-provider-model provider))
                    (body (if (bufferp buffer)
                              (with-current-buffer buffer
                                (quoth-openai-compose-request
                                 prompt model system-prompt
                                 history continuation))
                            (quoth-openai-compose-request
                             prompt model system-prompt
                             history continuation)))
                    (body (append body (quoth-provider--body-extras provider))))
               (setf (plist-get stage-handle :curl)
                     (quoth-openai-request
                      base-url token body
                      (or on-delta #'ignore)
                      (or completion #'ignore)
                      (or on-error #'ignore)
                      (plist-get extras :session-id)
                      (plist-get extras :x-crush-id)))))))
    stage-handle))

(cl-defmethod quoth-provider-interrupt ((provider quoth-openai-provider))
  "Interrupt the in-flight request for PROVIDER."
  (quoth-provider-cleanup provider))

(cl-defmethod quoth-provider-active-p ((provider quoth-openai-provider))
  "Return non-nil while a request is in flight for PROVIDER.
Covers both stages: the async system-prompt process and the curl
transport."
  (let ((request (quoth-provider-request provider)))
    (and (listp request)
         (or (and (processp (plist-get request :stage-process))
                  (process-live-p (plist-get request :stage-process)))
             (and (processp (plist-get request :curl))
                  (process-live-p (plist-get request :curl)))))))

(cl-defmethod quoth-provider-cleanup ((provider quoth-openai-provider))
  "Clean up any request resources held by PROVIDER.
Aborts the live stages (the async system-prompt process and the curl
transport), clears the request handle, and drops the injected
completion action so a late sentinel cannot run it."
  (let ((request (quoth-provider-request provider)))
    (when (listp request)
      (let ((stage (plist-get request :stage-process)))
        (when (and (processp stage) (process-live-p stage))
          (delete-process stage)))
      (let ((curl (plist-get request :curl)))
        (when (processp curl)
          (quoth-openai-abort curl)))))
  (setf (quoth-provider-request provider) nil)
  (setf (quoth-provider-completion-action provider) nil))

(cl-defmethod quoth-provider-grant-permission ((_provider quoth-openai-provider) _permission-id _action)
  "No permissions are issued by OpenAI-compatible providers."
  nil)

(cl-defmethod quoth-provider--usage ((_provider quoth-openai-provider) handle)
  "Return one round's usage as a normalized plist, or nil.
Reads the `usage' object the SSE parser stashed on the request
HANDLE's curl process and normalizes it into the contract shape
\(:input-tokens :output-tokens :cached-tokens).  No cost keys; a
provider with per-request pricing overrides this to add them.  No
server-side session total, so :accumulated is nil and the core sums
across rounds."
  (let ((process (and (listp handle) (plist-get handle :curl))))
    (when (processp process)
      (let ((sse (process-get process :quoth-sse)))
        (when sse
          (let* ((u (plist-get sse :usage))
                 (aget (lambda (k) (and u (quoth--openai-alist-get k u)))))
            (when u
              (list :input-tokens  (or (funcall aget "prompt_tokens") 0)
                    :output-tokens (or (funcall aget "completion_tokens") 0)
                    :cached-tokens 0
                    :accumulated     nil))))))))

(cl-defmethod quoth-provider--tool-calls ((_provider quoth-openai-provider)
                                          handle)
  "Return the tool-calls vector from the request HANDLE's curl SSE state.
The SSE parser accumulates `tool_calls' deltas into the state's
`:tool-calls' slot.  Works on deleted processes (process properties
persist until GC)."
  (when (processp (and (listp handle) (plist-get handle :curl)))
    (let ((sse (process-get (plist-get handle :curl) :quoth-sse)))
      (and sse (plist-get sse :tool-calls)))))

(cl-defmethod quoth-provider--apply-model ((provider quoth-openai-provider) model-entry)
  "Apply MODEL-ENTRY to PROVIDER by setting its model slot from :id."
  (setf (quoth-openai-provider-model provider)
        (plist-get model-entry :id)))

(cl-defmethod quoth-provider-model ((provider quoth-openai-provider))
  "Return PROVIDER's active model id."
  (quoth-openai-provider-model provider))

(cl-defgeneric quoth-openai-provider--provider-token (provider)
  "Return PROVIDER's defcustom token fallback, or nil.
The send resolves the token slot first, then this.  Each concrete
provider implements it returning its own token defcustom
\(e.g. `quoth-hyper-token'); the default reads the TOKEN slot."
  (quoth-openai-provider-token provider))

(provide 'quoth-openai-provider)
;;; quoth-openai-provider.el ends here
