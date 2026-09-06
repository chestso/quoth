;;; quoth-ollama-provider.el --- Ollama Cloud provider for quoth  -*- lexical-binding: t; -*-
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

;; The Ollama Cloud provider for quoth.el: streamed chat completions
;; against ollama.com's OpenAI-compatible surface (`/v1'), built on the
;; reusable client `quoth-openai.el'.  The native `/api' surface is used
;; for exactly one thing the OpenAI protocol cannot do: the model
;; catalog, assembled from `GET /api/tags' (membership) plus a parallel
;; `POST /api/show' fan-out (capabilities and context length).  See
;; OLLAMA-CLOUD-API.md for the API reference.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The order follows the dependency graph: `quoth-provider'
;;; first, then `quoth-openai' (the client it delegates to).
(eval-and-compile
  (dolist (dep '("quoth-json" "quoth-provider" "quoth-openai"))
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
(declare-function quoth-openai-abort "quoth-openai" (proc))
(declare-function quoth-openai--system-prompt-async "quoth-openai" (buf on-ready))
(declare-function quoth-provider-cleanup "quoth-provider" (provider))

(defgroup quoth-ollama nil
  "Ollama Cloud provider."
  :group 'quoth
  :prefix "quoth-ollama-")

(defcustom quoth-ollama-base-url "https://ollama.com/v1"
  "Base URL of the Ollama OpenAI-compatible endpoint.
Chat completions ride `BASE-URL/chat/completions'; the native catalog
endpoints (`/api/tags', `/api/show') derive from the server root.
Overridden by the OLLAMA_URL environment variable when set."
  :type 'string
  :group 'quoth-ollama)

(defcustom quoth-ollama-token #'quoth-ollama--token-from-auth-source
  "Bearer access token for Ollama Cloud.
Get one at `https://ollama.com/settings/keys'.

May be a string, a function of no arguments that returns the token,
or nil to request without a token.  The default looks the token up in
`auth-source' (see `quoth-ollama--token-from-auth-source')."
  :type '(choice (function-item quoth-ollama--token-from-auth-source)
                 (const :tag "No token" nil)
                 string
                 function)
  :group 'quoth-ollama)

(cl-defstruct (quoth-ollama-provider
               (:include quoth-provider (type 'ollama))
               (:constructor nil)
               (:constructor quoth-make-ollama-provider
                             (&key buffer working-directory base-url token model
                                   &aux (type 'ollama) (completion-action nil)))
               (:copier nil))
  "Provider that talks to Ollama Cloud's OpenAI-compatible surface."
  base-url
  token
  model)

(defun quoth-ollama--token-from-auth-source ()
  "Return the ollama bearer token from `auth-source'.
Looks up host `ollama.com' with user `apikey'.  Signals an error
when no secret is found, with setup instructions."
  (require 'auth-source)
  (let* ((found (auth-source-search
                 :host "ollama.com" :user "apikey"
                 :require '(:secret)))
         (secret (and found
                      (plist-get (car found) :secret))))
    (if (functionp secret)
        (funcall secret)
      (or secret
          (user-error
           "No ollama token in auth-source; add `machine ollama.com login apikey password ...' to %s or set `quoth-ollama-token'"
           (or (car auth-sources) "auth-sources"))))))

(defun quoth-ollama--resolve-token (token)
  "Resolve TOKEN to a bearer token string, or nil.
TOKEN may be nil, a string, or a function of no arguments returning
either.  Functions are called and the result is resolved recursively."
  (when token
    (let ((resolved (if (functionp token) (funcall token) token)))
      (if (stringp resolved)
          resolved
        (quoth-ollama--resolve-token resolved)))))

(defun quoth-ollama--base-url (provider)
  "Return PROVIDER's resolved OpenAI base URL.
The provider slot wins, then the OLLAMA_URL environment variable,
then the `quoth-ollama-base-url' default."
  (or (quoth-ollama-provider-base-url provider)
      (getenv "OLLAMA_URL")
      quoth-ollama-base-url))

(defun quoth-ollama--api-root (base-url)
  "Return the native API root for the server behind BASE-URL.
The provider targets `.../v1' (the OpenAI surface); the native
catalog endpoints live at the server root: `https://ollama.com/v1'
maps to `https://ollama.com/api'.  A trailing `/v1' is stripped; a
base URL without it is used as-is."
  (let ((root (if (string-suffix-p "/v1" base-url)
                  (substring base-url 0 (- (length base-url) 3))
                base-url)))
    (concat root "/api")))

(defun quoth-ollama--resolve-token-for (provider)
  "Return the resolved bearer token for PROVIDER.
The provider's token slot wins over `quoth-ollama-token'."
  (quoth-ollama--resolve-token
   (or (quoth-ollama-provider-token provider) quoth-ollama-token)))

;;; One-shot curl JSON fetch (GET or POST), used by the catalog.

(defun quoth-ollama--fetch-json-filter (proc string)
  "Filter for a one-shot curl process PROC receiving chunk STRING.
Accumulates raw output in the process's `:quoth-catalog-body'
property, skipping any `Process ...' status lines Emacs writes to the
process buffer (they are not curl output)."
  (process-put proc :quoth-catalog-body
               (concat (or (process-get proc :quoth-catalog-body) "")
                       string)))

(defun quoth-ollama--fetch-json-sentinel (proc _event)
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

(defun quoth-ollama--fetch-json (url token method body on-done)
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
         (buf (get-buffer-create " *quoth-ollama-catalog*"))
         (proc (make-process
                :name "quoth-ollama-catalog"
                :buffer buf
                :command (list quoth-openai-curl-program "--config" "-")
                :connection-type 'pipe
                :noquery t
                :filter #'quoth-ollama--fetch-json-filter
                :sentinel #'quoth-ollama--fetch-json-sentinel
                :stderr (get-buffer-create "*quoth-errors*"))))
    (process-put proc :quoth-catalog-callback on-done)
    (process-send-string proc config)
    (when (and (string= method "POST") body)
      (process-send-string proc body))
    (process-send-eof proc)
    proc))

;;; Model catalog: /api/tags + /api/show fan-out.

(defun quoth-ollama--tags-names (obj)
  "Return the model names listed by a parsed /api/tags object OBJ.
The `models' array's `name' fields carry the membership; anything
else is informational.  Returns a list of strings, or nil when the
shape is wrong."
  (let ((models (and obj (quoth--openai-alist-get "models" obj))))
    (when (vectorp models)
      (delq nil
            (mapcar (lambda (m)
                      (let ((name (and m
                                       (quoth--openai-alist-get "name" m))))
                        (and (stringp name) name)))
                    (append models nil))))))

(defun quoth-ollama--context-length (model-info)
  "Return the context length from a parsed MODEL-INFO alist, or nil.
The key is architecture-prefixed (`gptoss.context_length',
`gemma4.context_length'), so the `.context_length' suffix is matched,
not a fixed key name."
  (when (and model-info (consp model-info))
    (let ((hit (cl-find-if
                (lambda (cell)
                  (and (stringp (car cell))
                       (string-suffix-p ".context_length" (car cell))))
                model-info)))
      (and hit (numberp (cdr hit)) (cdr hit)))))

(defun quoth-ollama--normalize-model (id capabilities context-length)
  "Normalize one catalog entry into the protocol model plist.
ID is the model name; CAPABILITIES is the vector (or list) of
capability strings from /api/show; CONTEXT-LENGTH is the decoded
`<arch>.context_length'.  The cloud reports no pricing or
default-max-tokens, so those keys stay nil and the selector renders
its `?' placeholders.  Used by both the bundled-seed reader and the
live refresh, so the two are byte-compatible."
  (let ((caps (if (vectorp capabilities)
                  (append capabilities nil)
                capabilities)))
    (list :id id
          :name id
          :context-window context-length
          :default-max-tokens nil
          :cost-in nil
          :cost-out nil
          :cost-cache-write nil
          :cost-cache-hit nil
          :can-reason (and (member "thinking" caps) t)
          :reasoning-levels nil
          :default-reasoning-effort nil
          :supports-attachments (and (member "vision" caps) t))))

(defconst quoth-ollama--models-seed-file "quoth-ollama-models.json"
  "Bundled catalog snapshot that seeds the ollama model catalog.
Regenerated by `make models'; shipped in the package tarball.")

(defconst quoth-ollama--models-seed-directory
  (file-name-directory
   (or load-file-name buffer-file-name default-directory))
  "Directory the ollama module itself was loaded from.
The bundled catalog snapshot lives next to it; the .elc sits in the
same directory as the .el and the data file in every install style
\(source checkout, package install, tarball).")

(defun quoth-ollama--models-seed-read (file)
  "Read the bundled catalog snapshot FILE into normalized plists.
The snapshot is a JSON array, one object per model, with the keys
`id', `capabilities', `context_length', `parameter_size', and
`quantization_level'.  Returns nil when FILE is missing, unreadable,
or unparseable — the seed is absent, never an error, so the cache
read falls through to the cold fallback path."
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
                     (mapcar
                      (lambda (m)
                        (let ((id (and m
                                       (quoth--openai-alist-get "id" m))))
                          (and (stringp id)
                               (quoth-ollama--normalize-model
                                id
                                (quoth--openai-alist-get "capabilities" m)
                                (quoth--openai-alist-get
                                 "context_length" m)))))
                      (append parsed nil)))))
         (error nil))))

(defun quoth-ollama--show-one-async (api token name on-done)
  "Fetch one model's /api/show metadata and deliver the normalized plist.
API is the native catalog root; NAME is the model name; TOKEN is the
resolved bearer (or nil).  ON-DONE receives the plist, or nil when
the show fails."
  (quoth-ollama--fetch-json
   (concat api "/show")
   token "POST"
   (quoth-json-write `((model . ,name)))
   (lambda (show)
     (funcall on-done
              (when show
                (let ((caps (quoth--openai-alist-get "capabilities" show))
                      (mi (quoth--openai-alist-get "model_info" show)))
                  (quoth-ollama--normalize-model
                   name caps (quoth-ollama--context-length mi))))))))

(defun quoth-ollama--show-all-async (api token names on-done)
  "Fan out one POST /api/show per name in NAMES, all in parallel.
API is the native catalog root and TOKEN the resolved bearer (or
nil).  The join is all-or-nothing: every show must land, or ON-DONE
receives nil overall (a single flaky show keeps the previous cache
entry).  On success ON-DONE receives the normalized plist list in
NAMES order."
  (let* ((pending (length names))
         (results (make-vector (length names) nil))
         (failed nil))
    (cl-loop for name in names
             for i from 0
             do (quoth-ollama--show-one-async
                 api token name
                 (lambda (entry)
                   (if (null entry)
                       (setq failed t)
                     (aset results i entry))
                   ;; Join: deliver once every show landed.
                   (setq pending (1- pending))
                   (when (zerop pending)
                     (funcall on-done
                              (unless failed
                                (append results nil)))))))))

(defun quoth-ollama--fetch-models-async (provider on-done)
  "Fetch the model catalog for PROVIDER, delivering it to ON-DONE once.
The catalog is assembled in two steps: `GET /api/tags' yields the
model names, then one `POST /api/show' per name — all spawned in
parallel — contributes capabilities and the context length.  The
join is all-or-nothing: every show must land, or the whole fetch
delivers nil (the cache keeps its previous entry).  ON-DONE receives
the normalized plist list, or nil.  Returns the tags curl process."
  (let ((token (quoth-ollama--resolve-token-for provider))
        (api (quoth-ollama--api-root (quoth-ollama--base-url provider))))
    (quoth-ollama--fetch-json
     (concat api "/tags")
     token "GET" nil
     (lambda (tags)
       (let ((names (quoth-ollama--tags-names tags)))
         (if (null names)
             ;; No membership: an empty or broken tags fetch fails the
             ;; whole catalog (an empty cloud is not a catalog).
             (progn
               (quoth--debug-log
                'model-catalog "ollama tags fetch failed")
               (funcall on-done nil))
           (quoth-ollama--show-all-async
            api token names on-done)))))))

;;; Ollama provider methods

(cl-defmethod quoth-provider-send-prompt
  ((provider quoth-ollama-provider) prompt &key session-id session-uuid continue-p completion buffer stderr on-delta on-error continuation)
  "Send PROMPT to PROVIDER via a direct HTTP+SSE request to Ollama Cloud.
COMPLETION is the core's continuation invoked when the stream
finishes; ON-DELTA consumes streamed deltas; ON-ERROR receives stream
errors.  The prior conversation is read from BUFFER via the core's
`quoth--history-for', which enters the buffer itself, and re-sent as
message alists; the buffer-local `quoth-history-limit' decides whether
history exists.  CONTINUATION, when non-nil, is a list of message
alists (user, assistant with `tool_calls', `role: \"tool\"') that
replace the user message — used by the tool loop to send follow-up
requests with tool results.  Ollama sends no session-affinity or
machine-id headers (it has no prefix-cache protocol; session
continuity rides the re-sent history).  The request body gains one
provider extra on top of the composed alist:
`stream_options: {include_usage: true}', so the final SSE chunk
carries usage.  The provider never touches buffers itself."
  (ignore session-id session-uuid continue-p stderr)
  ;; A previous in-flight request must not outlive this send.
  (quoth-provider-cleanup provider)
  (let* ((stage-handle (list :stage-process nil :curl nil :done-p nil))
         (base-url (quoth-ollama--base-url provider))
         (token (quoth-ollama--resolve-token-for provider)))
    ;; Stage the system prompt first (usually a cache hit); the curl
    ;; fires once it lands.  The handle covers both stages.
    (setf (quoth-provider-completion-action provider) completion)
    (setf (quoth-provider-request provider) stage-handle)
    (setf (plist-get stage-handle :stage-process)
          (quoth-openai--system-prompt-async
           (quoth-provider-buffer provider)
           (lambda (_prompt)
             (when (bufferp buffer)
               (with-current-buffer buffer
                 (when (quoth--busy-p)
                   (quoth--phase-set 'streaming))))
             (let* ((history (and buffer
                                  (quoth--history-for buffer)))
                    (model (quoth-ollama-provider-model provider))
                    (body (if (bufferp buffer)
                              (with-current-buffer buffer
                                (quoth-openai-compose-request
                                 prompt model history continuation))
                            (quoth-openai-compose-request
                             prompt model history continuation))))
               ;; Provider extras: append keys to the composed alist
               ;; before the request fires.  Ollama's usage rides a
               ;; final chunk gated on stream_options.include_usage
               ;; (the chunk's empty `choices' array is tolerated by
               ;; the SSE parser).
               (setq body (append body
                                  '((stream_options .
                                                    ((include_usage . t))))))
               (setf (plist-get stage-handle :curl)
                     (quoth-openai-request
                      base-url token body
                      (or on-delta #'ignore)
                      (or completion #'ignore)
                      (or on-error #'ignore)))))))
    stage-handle))

(cl-defmethod quoth-provider-interrupt ((provider quoth-ollama-provider))
  "Interrupt the ollama request for PROVIDER."
  (quoth-provider-cleanup provider))

(cl-defmethod quoth-provider-active-p ((provider quoth-ollama-provider))
  "Return non-nil while an ollama request is in flight for PROVIDER.
Covers both stages: the async system-prompt process and the curl
transport."
  (let ((request (quoth-provider-request provider)))
    (and (listp request)
         (or (and (processp (plist-get request :stage-process))
                  (process-live-p (plist-get request :stage-process)))
             (and (processp (plist-get request :curl))
                  (process-live-p (plist-get request :curl)))))))

(cl-defmethod quoth-provider-cleanup ((provider quoth-ollama-provider))
  "Clean up any ollama request resources held by PROVIDER.
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

(cl-defmethod quoth-provider-grant-permission ((_provider quoth-ollama-provider) _permission-id _action)
  "No permissions are issued by the ollama provider."
  nil)

(cl-defmethod quoth-provider--usage ((_provider quoth-ollama-provider) handle)
  "Return one round's usage as a normalized plist, or nil.
Reads the `usage' object the SSE parser stashed on the request
HANDLE's curl process and normalizes it into the contract shape
\(:input-tokens :output-tokens :cached-tokens).  Ollama reports no
caching and no per-request cost (the plist carries no :cost keys; the
header renders tokens only), and no server-side session total, so
:accumulated is nil and the core sums across rounds."
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

(cl-defmethod quoth-provider--tool-calls ((_provider quoth-ollama-provider)
                                          handle)
  "Return the tool-calls vector from the request HANDLE's curl SSE state.
The SSE parser accumulates `tool_calls' deltas into the state's
`:tool-calls' slot.  Works on deleted processes (process properties
persist until GC)."
  (when (processp (and (listp handle) (plist-get handle :curl)))
    (let ((sse (process-get (plist-get handle :curl) :quoth-sse)))
      (and sse (plist-get sse :tool-calls)))))

(cl-defmethod quoth-provider--models-key ((provider quoth-ollama-provider))
  "The ollama catalog key: the PROVIDER type and the resolved base URL."
  (cons 'ollama (quoth-ollama--base-url provider)))

(cl-defmethod quoth-provider--models-seed ((provider quoth-ollama-provider))
  "Seed the catalog for PROVIDER from the bundled snapshot.
Reads `quoth-ollama--models-seed-file' next to this module through the
same normalize pipeline as the live refresh, so the seed is
byte-compatible with what the network refresh delivers and the
override is a plain cache overwrite.  Only the default server is
seeded: a custom base URL (`OLLAMA_URL' or `quoth-ollama-base-url')
points at another server and gets no snapshot.  Returns nil when the
file is missing or bad — never an error."
  (when (string= (quoth-ollama--base-url provider)
                 quoth-ollama-base-url)
    (quoth-ollama--models-seed-read
     (expand-file-name quoth-ollama--models-seed-file
                       quoth-ollama--models-seed-directory))))

(cl-defmethod quoth-provider--models-async ((provider quoth-ollama-provider)
                                            on-done)
  "Fetch the ollama model catalog for PROVIDER and deliver the plists.
The tags + show fan-out runs in `quoth-ollama--fetch-models-async';
ON-DONE receives the model list, or nil when the fetch fails.  Returns
the tags curl process."
  (quoth-ollama--fetch-models-async provider on-done))

(cl-defmethod quoth-provider--apply-model ((provider quoth-ollama-provider) model-entry)
  "Apply MODEL-ENTRY to PROVIDER by setting its model slot from :id."
  (setf (quoth-ollama-provider-model provider)
        (plist-get model-entry :id)))

(cl-defmethod quoth-provider-model ((provider quoth-ollama-provider))
  "Return PROVIDER's active model id."
  (quoth-ollama-provider-model provider))

(provide 'quoth-ollama-provider)
;;; quoth-ollama-provider.el ends here
