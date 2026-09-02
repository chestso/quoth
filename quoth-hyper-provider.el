;;; quoth-hyper-provider.el --- Charm Hyper provider for quoth  -*- lexical-binding: t; -*-
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

;; The Charm Hyper provider for quoth.el: streamed chat completions
;; against the Charm Hyper gateway.  The HTTP+SSE wire work (request
;; composition, SSE parsing, curl transport) lives in the reusable
;; OpenAI client `quoth-openai.el'; this file supplies the hyper
;; configuration (base URL, token, session affinity) and wires the
;; provider protocol through it.  See HYPER-API.md for the gateway API.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The order follows the dependency graph: `quoth-provider'
;;; first, then `quoth-openai' (the client it delegates to), then
;;; `quoth-xxh3' which it uses.
(eval-and-compile
  (dolist (dep '("quoth-json" "quoth-provider" "quoth-openai" "quoth-xxh3" "quoth-tools"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defcustom quoth-hyper-session-cache-p t
  "Send x-session-id and x-session-affinity cache-affinity headers.
Each hyper request carries the XXH3-64 hash of the buffer's session
UUID, pinning the conversation to a server-side prefix/token cache.
The hash is opaque and stable for the session; disable to opt out of
affinity (each request misses the cache)."
  :type 'boolean
  :group 'quoth-hyper)

(defcustom quoth-hyper-base-url "https://hyper.charm.land/v1"
  "Base URL of the Charm Hyper gateway.
The OpenAI-compatible chat-completions endpoint is
`BASE-URL/chat/completions'.  Overridden by the HYPER_URL
environment variable when set."
  :type 'string
  :group 'quoth-hyper)

(defcustom quoth-hyper-token #'quoth-hyper--token-from-auth-source
  "Bearer access token for the Charm Hyper gateway.
Tokens are prefixed `sk-hyper-'; get one from the Hyper Dashboard.

May be a string, a function of no arguments that returns the token,
or nil to request without a token.  The default looks the token up in
`auth-source' (see `quoth-hyper--token-from-auth-source')."
  :type '(choice (function-item quoth-hyper--token-from-auth-source)
                 (const :tag "No token" nil)
                 string
                 function)
  :group 'quoth-hyper)

(defun quoth-hyper--token-from-auth-source ()
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
           "No hyper token in auth-source; add `machine hyper.charm.land login apikey password sk-hyper-...' to %s or set `quoth-hyper-token'"
           (or (car auth-sources) "auth-sources"))))))

(defun quoth-hyper--resolve-token (token)
  "Resolve TOKEN to a bearer token string, or nil.
TOKEN may be nil, a string, or a function of no arguments returning
either.  Functions are called and the result is resolved recursively."
  (when token
    (let ((resolved (if (functionp token) (funcall token) token)))
      (if (stringp resolved)
          resolved
        (quoth-hyper--resolve-token resolved)))))

(defun quoth-hyper--catalog-filter (proc string)
  "Filter for the catalog curl process PROC receiving chunk STRING.
Accumulates raw output in the process's `:quoth-catalog-body' property,
skipping any `Process ...' status lines Emacs writes to the process
buffer (they are not curl output)."
  (process-put proc :quoth-catalog-body
               (concat (or (process-get proc :quoth-catalog-body) "")
                       string)))

(defun quoth-hyper--catalog-parse (raw)
  "Parse the catalog RAW output into (CATALOG . MODELS), or nil.
The raw is the JSON body (the request runs without `include', so no
HTTP head arrives).  An empty, unparseable, or models-less payload
yields nil; the failure is debug-logged so the cache keeps its entry."
  (condition-case err
      (progn
        (when (string-empty-p (string-trim raw))
          (error "empty catalog response"))
        (let* ((catalog (quoth-json-read (string-trim raw)))
               (models (quoth--openai-alist-get "models" catalog)))
          (unless models
            (error "catalog has no models key"))
          (cons catalog models)))
    (error
     (quoth--debug-log
      'model-catalog
      (format "catalog parse failed: %s" err))
     nil)))

(defun quoth-hyper--catalog-sentinel (proc _event)
  "Sentinel for the catalog curl process PROC.
Drains output already received but not yet dispatched to the filter
(the single permitted zero-timeout poll pattern), parses the
accumulated body, and delivers the catalog (or nil on failure) to the
process's :quoth-catalog-callback via the `quoth--schedule' hop."
  ;; Drain the tail before reading the accumulated body.
  (when (and (processp proc) (not (process-live-p proc)))
    (accept-process-output proc 0))
  (let* ((raw (or (process-get proc :quoth-catalog-body) ""))
         (callback (process-get proc :quoth-catalog-callback))
         (parsed (quoth-hyper--catalog-parse raw)))
    (quoth--schedule (lambda () (funcall callback parsed)))))

(defun quoth-hyper--fetch-models-async (base-url token on-done)
  "Fetch the model catalog from BASE-URL, delivering it to ON-DONE once.
BASE-URL is the hyper gateway base (e.g. `https://hyper.charm.land/v1');
the catalog lives at `BASE-URL/provider' (HYPER-API.md section 5).
TOKEN is resolved via `quoth-hyper--resolve-token' and sent as a
bearer header when present.  ON-DONE receives the cons
(CATALOG-ALIST . MODELS-VECTOR) — CATALOG-ALIST the parsed top-level
JSON (with the `models' key), MODELS-VECTOR the `models' array — or nil
when the fetch fails (network error, non-200, or unparseable body).
Never logs the token; failures are debug-logged and swallowed so the
cache keeps its entry.  Returns the curl process."
  (let* ((token (quoth-hyper--resolve-token token))
         (config (concat
                  (format "url = %s/provider\n" base-url)
                  "request = GET\n"
                  "silent\n"
                  "no-buffer\n"
                  (format "max-time = %s\n" (or quoth-openai-timeout 300))
                  (format "header = \"User-Agent: %s\"\n" quoth-openai-user-agent)
                  (when token
                    (format "header = \"Authorization: Bearer %s\"\n" token))))
         ;; The buffer receives no data (the filter diverges it), but
         ;; `make-process' still needs a buffer for `:buffer'.
         (buf (get-buffer-create " *quoth-hyper-catalog*"))
         (proc (make-process
                :name "quoth-hyper-catalog"
                :buffer buf
                :command (list quoth-openai-curl-program "--config" "-")
                :connection-type 'pipe
                :noquery t
                :filter #'quoth-hyper--catalog-filter
                :sentinel #'quoth-hyper--catalog-sentinel
                :stderr (get-buffer-create "*quoth-errors*"))))
    (process-put proc :quoth-catalog-callback on-done)
    (process-send-string proc config)
    (process-send-eof proc)
    proc))

(defcustom quoth-hyper-history-limit 200
  "Maximum number of prior prompts sent as history by the hyper provider.
0 disables history entirely (each prompt is a single request).  Only
the last LIMIT complete exchanges are sent; the current turn is always
sent in full."
  :type 'integer
  :group 'quoth-hyper)

(defcustom quoth-hyper-history-include-reasoning nil
  "Non-nil re-sends streamed reasoning (CoT) with assistant turns.
The reasoning is emitted as `reasoning_content' (per HYPER-API.md
section 3.4).  The default nil keeps reasoning out of the
model-visible history."
  :type 'boolean
  :group 'quoth-hyper)

(defcustom quoth-hyper-x-crush-id t
  "Value for the x-crush-id header on hyper requests.

The Crush CLI sends its per-machine ID in this header on every Hyper
chat-completions request.  When t (default), a stable per-machine ID
is derived locally; a string is sent verbatim; a function is called
for the value; nil omits the header.

The wire header is intentionally named `x-crush-id' (not
`x-quoth-id'): it is specific to the Charm Hyper provider and mirrors
the external Crush CLI convention, so it is not renamed with the
package."
  :type '(choice (const :tag "Derive per-machine ID" t)
                 (const :tag "Omit" nil)
                 string
                 function)
  :group 'quoth-hyper)

(defcustom quoth-hyper-usage-currency 'credits
  "Currency unit shown for usage cost in the header line.
Hyper reports both USD and hypercredits per request; this selects
which the provider surfaces to the core.  `credits' (default) emits
hypercredits with unit \"hc\"; `dollars' emits USD with unit \"$\"."
  :type '(choice (const :tag "Hypercredits" credits)
                 (const :tag "US dollars"  dollars))
  :group 'quoth-hyper)

(defun quoth-hyper--x-crush-id ()
  "Return the resolved x-crush-id value, or nil to omit."
  (let ((id (cond
             ((functionp quoth-hyper-x-crush-id)
              (funcall quoth-hyper-x-crush-id))
             ((stringp quoth-hyper-x-crush-id)
              quoth-hyper-x-crush-id)
             (quoth-hyper-x-crush-id
              ;; Stable per-machine: XXH3-64 of system identity.
              (quoth-xxh3-hash64
               (concat (system-name) "@" (getenv "HOME")))))))
    (and (stringp id) (> (length id) 0) id)))

(declare-function quoth--debug-log "quoth.el" (category message))
(declare-function quoth-openai-abort "quoth-openai" (proc))
(declare-function quoth--history-for "quoth.el" (buffer))
(declare-function quoth--openai-alist-get "quoth-openai" (key alist))
(declare-function quoth--schedule "quoth.el" (fn))

(defun quoth-hyper--model-choices (catalog)
  "Return completion choices from CATALOG, an alist with a `models' key.
Each choice is (ID . DISPLAY) where DISPLAY annotates the model with its
name, context window, input cost, and reasoning support, e.g.
\"m1 - Model One (context 4096, $0.50/1M in, can reason)\"."
  (let ((models (quoth--openai-alist-get "models" catalog)))
    (mapcar
     (lambda (m)
       (let* ((id (quoth--openai-alist-get "id" m))
              (name (quoth--openai-alist-get "name" m))
              (ctx (quoth--openai-alist-get "context_window" m))
              (cost (quoth--openai-alist-get "cost_per_1m_in" m))
              (reason (quoth--openai-alist-get "can_reason" m)))
         (cons id
               (string-trim
                (format "%s - %s (context %s, $%s/1M in, %s)"
                        id name
                        (or ctx "?")
                        (if (numberp cost)
                            (format "%.2f" cost)
                          "?")
                        (if reason "can reason" "no reason"))))))
     (if (vectorp models)
         (append models nil)
       models))))

(cl-defstruct (quoth-hyper-provider
               (:include quoth-provider (type 'hyper))
               (:constructor nil)
               (:constructor quoth-make-hyper-provider
                             (&key buffer working-directory base-url token model
                                   &aux (type 'hyper) (completion-action nil)))
               (:copier nil))
  "Provider that talks to the Charm Hyper gateway via HTTP+SSE."
  base-url
  token
  model)

;;; Hyper provider methods

(cl-defmethod quoth-provider-send-prompt
  ((provider quoth-hyper-provider) prompt &key session-id session-uuid continue-p completion buffer stderr on-delta on-error continuation)
  "Send PROMPT to PROVIDER via a direct HTTP+SSE request to Hyper.
COMPLETION is the core's continuation invoked when the stream
finishes; ON-DELTA consumes streamed deltas; ON-ERROR receives stream
errors.  SESSION-UUID is the buffer's opaque session identifier; when
`quoth-hyper-session-cache-p' is non-nil it is hashed (XXH3-64) and
sent as the x-session-id / x-session-affinity cache-affinity headers.
The prior conversation is read from BUFFER via the core's
`quoth--history-for', which enters the buffer itself, and re-sent as
message alists; `quoth-hyper-history-include-reasoning' controls whether
reasoning is replayed, and the core's `quoth-hyper-history-limit'
decides whether history exists.  CONTINUATION, when non-nil, is a list
of message alists (user, assistant with `tool_calls', `role: \"tool\"')
that replace the user message — used by the tool loop to send follow-up
requests with tool results.  The provider never touches buffers itself."
  (ignore session-id continue-p stderr)
  ;; A previous in-flight request must not outlive this send.
  (quoth-provider-cleanup provider)
  (let* ((history (and buffer
                       (quoth--history-for buffer)))
         (body (quoth-openai-compose-request
                prompt (quoth-hyper-provider-model provider)
                history continuation))
         (base-url (or (quoth-hyper-provider-base-url provider)
                       (getenv "HYPER_URL")
                       quoth-hyper-base-url))
         (token (quoth-hyper--resolve-token
                 (or (quoth-hyper-provider-token provider) quoth-hyper-token)))
         (session-id (and quoth-hyper-session-cache-p session-uuid
                          (quoth-xxh3-hash64 session-uuid)))
         (x-crush-id (quoth-hyper--x-crush-id)))
    (setf (quoth-provider-completion-action provider) completion)
    (setf (quoth-provider-transport-process provider)
          (quoth-openai-request
           base-url token body
           (or on-delta #'ignore)
           (or completion #'ignore)
           (or on-error #'ignore)
           session-id
           x-crush-id))))

(cl-defmethod quoth-provider-interrupt ((provider quoth-hyper-provider))
  "Interrupt the hyper request for PROVIDER."
  (quoth-provider-cleanup provider))

(cl-defmethod quoth-provider-active-p ((provider quoth-hyper-provider))
  "Return non-nil while a hyper request is in flight for PROVIDER."
  (let ((proc (quoth-provider-transport-process provider)))
    (and (processp proc) (process-live-p proc))))

(cl-defmethod quoth-provider-cleanup ((provider quoth-hyper-provider))
  "Clean up any hyper request resources held by PROVIDER.
Aborts the live curl transport (if any), clears the transport slot, and
drops the injected completion action so a late sentinel cannot run it."
  (let ((proc (quoth-provider-transport-process provider)))
    (when (processp proc)
      (quoth-openai-abort proc))
    (setf (quoth-provider-transport-process provider) nil)
    (setf (quoth-provider-completion-action provider) nil)))

(cl-defmethod quoth-provider-grant-permission ((_provider quoth-hyper-provider) _permission-id _action)
  "No permissions are issued in phase 1."
  nil)

(cl-defmethod quoth-provider--usage ((_provider quoth-hyper-provider) process)
  "Return one round's usage as a normalized plist, or nil.
Reads the `usage' object the SSE parser stashed on PROCESS and
normalizes it into the contract shape
\(:input-tokens :output-tokens :cached-tokens :cost-unit :cost-value
:accumulated).  Hyper reports usage per HTTP request only (no
server-side session total), so :accumulated is nil and the core
sums across rounds."
  (when (processp process)
    (let ((sse (process-get process :quoth-sse)))
      (when sse
        (let* ((u    (plist-get sse :usage))
               (aget (lambda (k) (and u (quoth--openai-alist-get k u))))
               (ptd  (funcall aget "prompt_tokens_details"))
               (cost (funcall aget "cost"))
               (cur  quoth-hyper-usage-currency))
          (when u
            (list :input-tokens  (or (funcall aget "prompt_tokens") 0)
                  :output-tokens (or (funcall aget "completion_tokens") 0)
                  :cached-tokens (or (and ptd
                                          (quoth--openai-alist-get "cached_tokens" ptd))
                                     0)
                  :cost-unit      (if (eq cur 'dollars) "$" "hc")
                  :cost-value     (if (eq cur 'dollars)
                                      (or (and cost
                                               (quoth--openai-alist-get "usd" cost))
                                          0)
                                    (or (and cost
                                             (quoth--openai-alist-get "hypercredits" cost))
                                        0))
                  :accumulated     nil)))))))

(cl-defmethod quoth-provider--tool-calls ((_provider quoth-hyper-provider) process)
  "Return the tool-calls vector from the SSE state on PROCESS, or nil.
The SSE parser accumulates `tool_calls' deltas into the state's
`:tool-calls' slot.  Works on deleted processes (process properties
persist until GC)."
  (when (processp process)
    (let ((sse (process-get process :quoth-sse)))
      (and sse (plist-get sse :tool-calls)))))

(defun quoth-hyper--normalize-model (m)
  "Normalize a JSON model entry M into a structured plist.
Keys: :id, :name, :context-window, :default-max-tokens, :cost-in,
:cost-out, :cost-in-cached, :cost-out-cached, :can-reason,
:reasoning-levels, :default-reasoning-effort,
:supports-attachments."
  (let ((get (lambda (k) (quoth--openai-alist-get k m))))
    (list :id                       (funcall get "id")
          :name                     (funcall get "name")
          :context-window           (funcall get "context_window")
          :default-max-tokens       (funcall get "default_max_tokens")
          :cost-in                  (funcall get "cost_per_1m_in")
          :cost-out                 (funcall get "cost_per_1m_out")
          :cost-in-cached           (funcall get "cost_per_1m_in_cached")
          :cost-out-cached          (funcall get "cost_per_1m_out_cached")
          :can-reason               (eq (funcall get "can_reason") t)
          :reasoning-levels         (let ((v (funcall get "reasoning_levels")))
                                      (if (vectorp v) (append v nil) v))
          :default-reasoning-effort (funcall get "default_reasoning_effort")
          :supports-attachments     (eq (funcall get "supports_attachments") t))))

(cl-defmethod quoth-provider--models-key ((provider quoth-hyper-provider))
  "The hyper catalog key: the provider type and the resolved base URL."
  (cons 'hyper
        (or (quoth-hyper-provider-base-url provider)
            (getenv "HYPER_URL")
            quoth-hyper-base-url)))

(cl-defmethod quoth-provider--models-async ((provider quoth-hyper-provider)
                                            on-done)
  "Fetch the hyper model catalog and deliver the normalized plists.
The raw catalog fetch rides `quoth-hyper--fetch-models-async'; each
entry normalizes through `quoth-hyper--normalize-model'.  ON-DONE
receives the model list, or nil when the fetch fails.  Returns the
curl process."
  (quoth-hyper--fetch-models-async
   (or (quoth-hyper-provider-base-url provider)
       (getenv "HYPER_URL")
       quoth-hyper-base-url)
   (quoth-hyper-provider-token provider)
   (lambda (fetched)
     (funcall on-done
              (when fetched
                (let ((models (cdr fetched)))
                  (mapcar #'quoth-hyper--normalize-model
                          (if (vectorp models) (append models nil) models))))))))

(cl-defmethod quoth-provider--apply-model ((provider quoth-hyper-provider) model-entry)
  "Apply MODEL-ENTRY to PROVIDER by setting its model slot from :id."
  (setf (quoth-hyper-provider-model provider)
        (plist-get model-entry :id)))

(cl-defmethod quoth-provider-model ((provider quoth-hyper-provider))
  "Return PROVIDER's active model id."
  (quoth-hyper-provider-model provider))

(provide 'quoth-hyper-provider)
;;; quoth-hyper-provider.el ends here
