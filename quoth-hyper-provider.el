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
;; against the Charm Hyper gateway, a thin subclass of the shared
;; `quoth-openai-provider' base carrying the hyper configuration (base
;; URL, token, session affinity, x-crush-id) and its model catalog.  See
;; HYPER-API.md for the gateway API.

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'subr-x)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The order follows the dependency graph: the shared
;;; OpenAI-provider base first (it pulls the wire client, the context
;;; assembly, and the protocol), then `quoth-xxh3' for the affinity hash.
(eval-and-compile
  (dolist (dep '("quoth-openai-provider" "quoth-xxh3" "quoth-tools"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(declare-function quoth--openai-alist-get "quoth-openai-client" (key alist))
(declare-function quoth--debug-log "quoth.el" (category message))
(declare-function quoth-openai-provider--token-from-auth-source
                  "quoth-openai-provider" (host user label custom))
(declare-function quoth-openai-provider--fetch-json
                  "quoth-openai-provider" (url token method body on-done))
(declare-function quoth-openai-provider--models-seed-read
                  "quoth-openai-provider" (file decode))

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

(defun quoth-hyper--token-from-auth-source ()
  "Return the hyper bearer token from `auth-source'.
Looks up host `hyper.charm.land' with user `apikey'.  Signals an error
when no secret is found, with setup instructions."
  (quoth-openai-provider--token-from-auth-source
   "hyper.charm.land" "apikey" "hyper" "quoth-hyper-token"))

(defun quoth-hyper--resolve-token (token)
  "Resolve TOKEN to a bearer token string, or nil.
TOKEN may be nil, a string, or a function of no arguments returning
either.  Functions are called and the result is resolved recursively."
  (quoth-openai-provider--resolve-token token))

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

(defun quoth-hyper--base-url (provider)
  "Return PROVIDER's resolved OpenAI base URL.
The provider slot wins, then the HYPER_URL environment variable,
then the `quoth-hyper-base-url' default."
  (or (quoth-hyper-provider-base-url provider)
      (getenv "HYPER_URL")
      quoth-hyper-base-url))

(cl-defstruct (quoth-hyper-provider
               (:include quoth-openai-provider (type 'hyper))
               (:constructor nil)
               (:constructor quoth-make-hyper-provider
                             (&key buffer working-directory base-url token model
                                   &aux (type 'hyper) (completion-action nil)))
               (:copier nil))
  "Provider that talks to the Charm Hyper gateway via HTTP+SSE.")

;;; Hyper provider methods.

(cl-defmethod quoth-openai-provider--provider-token
  ((_provider quoth-hyper-provider))
  "The hyper token defcustom."
  quoth-hyper-token)

(cl-defmethod quoth-provider--request-extras ((_provider quoth-hyper-provider)
                                              session-uuid)
  "Return hyper's wire extras: the affinity hash and the x-crush-id.
The hash is the XXH3-64 of SESSION-UUID, sent as the x-session-id /
x-session-affinity prefix-cache headers when
`quoth-hyper-session-cache-p' is non-nil.  The x-crush-id mirrors the
Crush CLI's per-machine header."
  (list :session-id (and quoth-hyper-session-cache-p session-uuid
                         (quoth-xxh3-hash64 session-uuid))
        :x-crush-id (quoth-hyper--x-crush-id)))

(cl-defmethod quoth-provider--usage ((_provider quoth-hyper-provider) handle)
  "Return one round's usage as a normalized plist, or nil.
Reads the `usage' object the SSE parser stashed on the request
HANDLE's curl process and normalizes it into the contract shape
\(:input-tokens :output-tokens :cached-tokens :cost-unit :cost-value
:accumulated).  Hyper reports usage per HTTP request only (no
server-side session total), so :accumulated is nil and the core
sums across rounds."
  (let ((process (and (listp handle) (plist-get handle :curl))))
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
                    :accumulated     nil))))))))

;;; Model catalog: GET /v1/provider, one request.

(defun quoth-hyper--catalog-parse (raw)
  "Parse the catalog RAW output into (CATALOG . MODELS), or nil.
The raw is the JSON body (the request runs without `include', so no
HTTP head arrives).  An empty, unparseable, or models-less payload
yields nil; the failure is debug-logged so the cache keeps its entry."
  (condition-case err
      (progn
        (when (string-empty-p (string-trim raw))
          (error "Empty catalog response"))
        (let* ((catalog (quoth-json-read (string-trim raw)))
               (models (quoth--openai-alist-get "models" catalog)))
          (unless models
            (error "Catalog has no models key"))
          (cons catalog models)))
    (error
     (quoth--debug-log
      'model-catalog
      (format "catalog parse failed: %s" err))
     nil)))

(defun quoth-hyper--normalize-model (m)
  "Normalize a JSON model entry M into a structured plist.
Keys: :id, :name, :context-window, :default-max-tokens, :cost-in,
:cost-out, :cost-cache-write, :cost-cache-hit, :can-reason,
:reasoning-levels, :default-reasoning-effort,
:supports-attachments.

The gateway's cached-cost field names are misleading (verified
against `/v1/models' on all 32 models, 2026-09): `cost_per_1m_in_cached'
is the cache-WRITE price (what building a fresh prefix costs) and
`cost_per_1m_out_cached' the cache-HIT read price (what replaying a
cached prefix's input tokens costs) — not cached input/output.  Both
are mapped under truthful names."
  (let ((get (lambda (k) (quoth--openai-alist-get k m))))
    (list :id                       (funcall get "id")
          :name                     (funcall get "name")
          :context-window           (funcall get "context_window")
          :default-max-tokens       (funcall get "default_max_tokens")
          :cost-in                  (funcall get "cost_per_1m_in")
          :cost-out                 (funcall get "cost_per_1m_out")
          :cost-cache-write         (funcall get "cost_per_1m_in_cached")
          :cost-cache-hit           (funcall get "cost_per_1m_out_cached")
          :can-reason               (eq (funcall get "can_reason") t)
          :reasoning-levels         (let ((v (funcall get "reasoning_levels")))
                                      (if (vectorp v) (append v nil) v))
          :default-reasoning-effort (funcall get "default_reasoning_effort")
          :supports-attachments     (eq (funcall get "supports_attachments") t))))

(defconst quoth-hyper--models-seed-file "quoth-hyper-models.json"
  "Bundled `/v1/provider' snapshot that seeds the model catalog.
Regenerated by `make models'; shipped in the package tarball.")

(defun quoth-hyper--fetch-models-async (base-url token on-done)
  "Fetch the model catalog from BASE-URL, delivering it to ON-DONE once.
BASE-URL is the hyper gateway base (e.g. `https://hyper.charm.land/v1');
the catalog lives at `BASE-URL/provider' (HYPER-API.md section 5).
TOKEN is resolved via `quoth-hyper--resolve-token' and sent as a
bearer header when present.  ON-DONE receives the cons
\(CATALOG-ALIST . MODELS-VECTOR) — CATALOG-ALIST the parsed top-level
JSON (with the `models' key), MODELS-VECTOR the `models' array — or nil
when the fetch fails (network error, non-200, or unparseable body).
Never logs the token; failures are debug-logged and swallowed so the
cache keeps its entry.  Returns the curl process."
  (quoth-openai-provider--fetch-json
   (concat base-url "/provider")
   (quoth-hyper--resolve-token token) "GET" nil
   (lambda (parsed)
     (funcall on-done (and parsed (quoth-hyper--catalog-parse-obj parsed))))))

(defun quoth-hyper--catalog-parse-obj (obj)
  "Validate the parsed catalog object OBJ into (CATALOG . MODELS).
Returns nil when OBJ is nil or carries no `models' key; the failure is
debug-logged so the cache keeps its entry."
  (if (and obj (quoth--openai-alist-get "models" obj))
      (cons obj (quoth--openai-alist-get "models" obj))
    (quoth--debug-log 'model-catalog "catalog parse failed: no models")
    nil))

(defun quoth-hyper--models-seed-read (file)
  "Read the bundled catalog snapshot FILE into normalized plists.
Returns nil when FILE is missing, unreadable, or unparseable — the
seed is absent, never an error, so the cache read falls through to
the cold fallback path."
  (and (file-exists-p file)
       (condition-case nil
           (let* ((raw (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))
                  (parsed (and (stringp raw)
                               (not (string-empty-p (string-trim raw)))
                               (quoth-hyper--catalog-parse raw))))
             (when parsed
               (let ((models (cdr parsed)))
                 (when (vectorp models)
                   (mapcar #'quoth-hyper--normalize-model
                           (append models nil))))))
         (error nil))))

(cl-defmethod quoth-provider--models-key ((provider quoth-hyper-provider))
  "The hyper catalog key: the PROVIDER type and the resolved base URL."
  (cons 'hyper (quoth-hyper--base-url provider)))

(cl-defmethod quoth-provider--models-seed ((provider quoth-hyper-provider))
  "Seed the catalog for PROVIDER from the bundled snapshot.
Reads `quoth-hyper--models-seed-file' next to this module through the
same parse + normalize pipeline as the live fetch, so the seed is
byte-compatible with what the network refresh delivers and the
override is a plain cache overwrite.  Only the default gateway is
seeded: a custom base URL (`HYPER_URL' or `quoth-hyper-base-url')
points at another server and gets no snapshot.  Returns nil when the
file is missing or bad — never an error."
  (when (string= (quoth-hyper--base-url provider)
                 quoth-hyper-base-url)
    (quoth-hyper--models-seed-read
     (expand-file-name quoth-hyper--models-seed-file
                       quoth-openai-provider--models-seed-directory))))

(cl-defmethod quoth-provider--models-async ((provider quoth-hyper-provider)
                                            on-done)
  "Fetch the hyper model catalog for PROVIDER and deliver the normalized plists.
The raw catalog fetch rides `quoth-hyper--fetch-models-async'; each
entry normalizes through `quoth-hyper--normalize-model'.  ON-DONE
receives the model list, or nil when the fetch fails.  Returns the
curl process."
  (quoth-hyper--fetch-models-async
   (quoth-hyper--base-url provider)
   (quoth-hyper-provider-token provider)
   (lambda (fetched)
     (funcall on-done
              (when fetched
                (let ((models (cdr fetched)))
                  (mapcar #'quoth-hyper--normalize-model
                          (if (vectorp models) (append models nil) models))))))))

(provide 'quoth-hyper-provider)
;;; quoth-hyper-provider.el ends here
