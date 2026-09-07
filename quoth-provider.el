;;; quoth-provider.el --- quoth provider protocol  -*- lexical-binding: t; -*-
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

;; Shared provider protocol for quoth.el: the `quoth-provider' base
;; struct, the `quoth-provider-*' generic functions implemented by
;; `quoth-hyper-provider.el' (direct HTTP to the Charm Hyper gateway)
;; and `quoth-ollama-provider.el' (Ollama Cloud over its
;; OpenAI-compatible surface), the shared buffer-local session slots,
;; the global defaults that seed them, and the provider registry.

;;; Code:

(require 'cl-lib)

;;; Configuration

(defgroup quoth nil
  "Chat with AI providers from GNU Emacs."
  :group 'tools
  :prefix "quoth-")

(defgroup quoth-openai nil
  "Reusable OpenAI-compatible client."
  :group 'quoth
  :prefix "quoth-openai-")

(defgroup quoth-hyper nil
  "Charm Hyper gateway provider."
  :group 'quoth
  :prefix "quoth-hyper-")

(defgroup quoth-ollama nil
  "Ollama Cloud provider."
  :group 'quoth
  :prefix "quoth-ollama-")

;;; Session state shared across the core, the OpenAI client, and the
;;; selector UI.  Lives here — in the protocol module — so that
;;; `quoth-openai-client.el' and `quoth-select.el' depend on the protocol, not
;;; on `quoth.el'.  The core sets these buffer-locally at init time,
;;; seeded from the global defaults (`quoth-default-thinking',
;;; `quoth-default-reasoning-effort'); every transient selection the
;;; selector applies writes a buffer-local slot, never a global.

(defvar-local quoth--session-provider nil
  "Per-buffer active provider name, a string.
Seeded from `quoth-default-provider' at buffer init; set by the
selector's provider switch.  The dispatch handle
`quoth-active-provider' is derived state, (re)instantiated from this
name whenever it changes.")

(defvar-local quoth--session-model nil
  "Per-buffer model id, or nil for the provider default.
Seeded at buffer init from the model chain (the sticky
`quoth-model-by-provider' entry for the session provider, else the
registry entry's :default-model, else `quoth-default-model'); set by
the model picker.  nil means the request falls back to that same
chain.")

(defvar-local quoth--session-thinking nil
  "Per-buffer thinking flag: nil (unset), t (on), or :json-false (off).
nil (the default) omits the key so the model/gateway applies its own
default.  t sends `thinking: true'; :json-false sends `thinking:
false', explicitly disabling reasoning.")

(defvar-local quoth--session-reasoning-effort nil
  "Per-buffer reasoning effort, or nil.
When non-nil, the request body carries `reasoning_effort: VALUE'.
nil (the default) omits the key.")

;;; Global defaults.  These seed the buffer-local session slots at
;;; init time; no transient action ever writes them.

(defcustom quoth-default-provider "hyper"
  "Provider name used for new quoth buffers.
Must match the :name of an entry in `quoth-providers'; when it names
nothing, the first registry entry is used instead.  Persisted across
sessions via `savehist-mode' when enabled."
  :type 'string
  :group 'quoth)

(defcustom quoth-default-model nil
  "Cross-provider fallback model id, or nil.
May be provider-qualified (\"ollama/gemma\"): when the prefix before
the first `/' names a registered provider (see
`quoth-provider-parse-model-id'), a new buffer starts on that
provider with the bare model, overriding `quoth-default-provider'.
An unqualified id seeds a new buffer's session model when no
per-provider default applies (the sticky `quoth-model-by-provider'
entry and the registry entry's :default-model are consulted first).
nil defers to the provider's own fallback at request time."
  :type '(choice (const :tag "Provider default" nil) string)
  :group 'quoth)

(defcustom quoth-default-thinking nil
  "Thinking state seeded into new quoth buffers.
nil (the default) means unset: the request omits the key and the
provider applies its own default.  t sends `thinking: true';
:json-false sends `thinking: false'."
  :type '(choice (const :tag "Unset (provider default)" nil)
                 (const :tag "On" t)
                 (const :tag "Off (send thinking: false)" :json-false))
  :group 'quoth)

(defcustom quoth-default-reasoning-effort nil
  "Reasoning effort seeded into new quoth buffers, or nil.
nil (the default) omits `reasoning_effort' from the request."
  :type '(choice (const :tag "Unset (provider default)" nil)
                 (string :tag "Effort level"))
  :group 'quoth)

(defvar quoth-model-by-provider nil
  "Alist of last-used model per provider name, the sticky model memory.
The model picker writes the active provider's entry so the next
buffer on that provider starts where the last one left off.  A plain
defvar (not a defcustom): it is runtime state persisted by savehist,
not a user option owned by Customize.")

;;; Provider registry.  The factory functions live in `quoth.el' and
;;; are resolved at `funcall' time, so this file does not require
;;; `quoth.el'.  The byte-compiler is told about them via
;;; `declare-function' below.

(declare-function quoth--make-default-hyper-provider "quoth.el" (&optional buf dir))
(declare-function quoth--make-default-ollama-provider "quoth.el" (&optional buf dir))

(defvar quoth-builtin-providers
  (list (list :name    "hyper"
              :type    'hyper
              :factory #'quoth--make-default-hyper-provider)
        (list :name    "ollama"
              :type    'ollama
              :factory #'quoth--make-default-ollama-provider
              :default-model "gpt-oss:20b"))
  "Every provider shipped with quoth, in priority order.
Each entry is a plist: :name (string, display + id), :type (symbol),
:factory (function of two arguments returning a configured provider
instance), and the optional :default-model (string) — the model a new
buffer on this provider starts with when no sticky
`quoth-model-by-provider' entry exists.  `quoth-providers' defaults
to this list; users override, reorder, or prune it there.")

(defcustom quoth-providers quoth-builtin-providers
  "Registered quoth providers, in priority order.
Each entry is a plist: :name (string, display + id), :type (symbol),
:factory (function of two arguments returning a configured provider
instance), and the optional :default-model (string) seeding a new
buffer's session model.  The first entry is the fallback active
provider for new buffers when `quoth-default-provider' names nothing.
Add a provider by appending an entry with its own :factory; nothing in
the protocol changes."
  :type '(repeat (plist :name string :type symbol :factory function))
  :group 'quoth)

(defun quoth-provider-parse-model-id (id)
  "Split a provider-qualified model ID into its route, or nil.
ID is qualified when the prefix before its first `/' names a
registered provider (`quoth-providers'); return
\(:provider \"ollama\" :model \"gemma\") for \"ollama/gemma\".
Return nil for anything else — an id with no `/', one whose prefix
names no provider (e.g. \"meta-llama/Llama-3\", a real model id that
contains a slash), or an empty model part — so callers pass the
string through untouched and only qualified ids route."
  (when (and (stringp id)
             (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" id))
    (let* ((prefix (match-string 1 id))
           (model (match-string 2 id))
           (entry (cl-find prefix quoth-providers
                           :test #'string=
                           :key (lambda (e) (plist-get e :name)))))
      (when entry
        (list :provider prefix :model model)))))

(defun quoth-provider-bare-model-id (id)
  "Return ID's model part, stripped of a provider prefix when qualified.
\"ollama/gemma\" yields \"gemma\"; any other string returns unchanged,
so this is safe on any model id — unqualified ids pass through, and
ids with a slash that names no provider keep their slash."
  (or (plist-get (quoth-provider-parse-model-id id) :model)
      id))

(defvar-local quoth-active-provider nil
  "The active quoth provider for this buffer.
Derived state, (re)instantiated from `quoth--session-provider' and
`quoth--session-model' whenever either changes or the buffer
initializes.  `quoth--send-prompt' and `quoth-interrupt' dispatch
through it.  Buffer-local.")

(defvar quoth-after-model-change-hook nil
  "Hook run after a model, thinking, or effort change is applied to a buffer.
Functions are called with the chat buffer current, so they can refresh
buffer-local UI (e.g. the header line).  The core wires
`quoth--update-header-line' here; the selector runs this hook instead
of calling the core directly, avoiding a load-time dependency on
`quoth.el'.")

(cl-defstruct (quoth-provider
               (:constructor nil)
               (:constructor make-quoth-provider)
               (:copier nil))
  "Base structure for a quoth provider."
  buffer
  completion-action
  working-directory
  ;; The request handle covering both stages of a send: the staged
  ;; system-prompt process (:stage-process, the async git stage) and
  ;; the curl transport (:curl), plus a done flag.  Owned by the
  ;; provider; the core reads activity through `quoth-provider-active-p'
  ;; and aborts via `quoth-provider-interrupt'/`quoth-provider-cleanup'.
  (request nil)
  ;; Application count: the number of pipeline applications (runnable,
  ;; inflight, blocked) this provider accounts for.  The core reads it
  ;; via stream progress; a value of 0 means the provider is idle.
  (application-count 1)
  (type nil))

(cl-defgeneric quoth-provider-send-prompt (provider prompt &key session-id continue-p completion buffer stderr on-delta on-error continuation)
  "Send PROMPT to PROVIDER with optional CONTEXT, SESSION-ID, and CONTINUE-P.
COMPLETION is a zero-argument closure (the core's continuation) that
the provider must invoke exactly once when the response stream finishes.
BUFFER is the quoth buffer the provider may associate its transport
process with, and STDERR is the stderr buffer; both are passed purely
as data objects, never read or switched to.  ON-DELTA is a (DELTA
KIND) callback that consumes streamed output, and ON-ERROR receives
stream error messages, for providers that stream (hyper).
CONTINUATION, when non-nil, is a list of structured message alists
\(assistant with `tool_calls' followed by `role: \"tool\"' messages)
that replace the user message in the request body; used by the
tool loop to send follow-up requests with tool results.")

(cl-defgeneric quoth-provider-interrupt (provider)
  "Interrupt the currently running operation on PROVIDER.
Providers own their transport processes; the core dispatches through
this method rather than checking or interrupting a buffer-local process.")

(cl-defgeneric quoth-provider-active-p (provider)
  "Return non-nil if PROVIDER has an active operation.
Providers should return the liveness of their transport process.")

(cl-defgeneric quoth-provider-cleanup (provider)
  "Clean up any resources held by PROVIDER.
Kill any live transport process, clear the transport slot, and clear
`quoth-provider-completion-action'.")

(cl-defgeneric quoth-provider-grant-permission (provider permission-id action)
  "Respond to a permission request on PROVIDER identified by PERMISSION-ID.
ACTION is `allow', `allow-session', or `deny'.")

(cl-defgeneric quoth-provider--tool-calls (provider process)
  "Return the accumulated tool-calls vector from PROVIDER's PROCESS, or nil.
PROCESS is the transport process returned by `quoth-provider-send-prompt'.
For streaming providers, the SSE state on PROCESS carries the
`:tool-calls' vector accumulated by the parser; non-streaming
providers return nil."
  (ignore provider process)
  nil)

(cl-defgeneric quoth-provider--usage (provider process)
  "Return one round's usage as a normalized plist, or nil.
PROCESS is the transport process returned by `quoth-provider-send-prompt'
for the round that just finished.  Returns nil when the provider has no
usage to surface (before any response, or a PROVIDER that does not
report usage).

The plist may carry any subset of these keys; the core renders only
those that are present:

  :input-tokens    integer   prompt/context tokens for this round
  :output-tokens   integer   completion tokens for this round
  :cached-tokens   integer   cache-hit input tokens (0 when the provider
                             has no caching, or this round was a cold miss);
                             caching applies to input tokens only, so this
                             never exceeds :input-tokens
  :cost-unit       string    display unit, e.g. \"hc\" or \"$\"; nil to omit
  :cost-value      number    cost in :cost-unit for this round
  :accumulated     boolean   non-nil means :input-tokens, :output-tokens,
                             and :cost-value are ALREADY summed across the
                             session (or prompt) by the provider; the core
                             renders them verbatim and skips its own
                             summation.  nil (the default) means the values
                             describe ONLY the last request, and the core
                             sums them across tool-loop rounds itself.

When :accumulated is nil the values describe exactly the last request,
NOT an accumulated total — the core sums them.  When :accumulated is
non-nil the values are already a running total — the core must not
re-sum (it would double-count); it still manages the buffer-local reset
on new prompt / clear."
  (ignore provider process)
  nil)

(cl-defgeneric quoth-provider--models-key (provider)
  "Return the cache key for PROVIDER's model catalog.
The key identifies the catalog source across buffers; the default
derives it from the provider's :type slot.  Providers whose catalog
depends on configuration (e.g. the gateway base URL) override this."
  (ignore provider)
  nil)

(cl-defgeneric quoth-provider--models-seed (provider)
  "Return PROVIDER's bundled model-catalog seed, or nil.
The seed is a list of model plists (same shape as
`quoth-provider--models-async' delivers) sourced from a snapshot
shipped with the package — no network.  `quoth-provider-models-cached'
stores it on a cache miss with FETCHED-AT 0, so the entry counts as
stale and the first read kicks the background refresh that overrides
it with live data.  Providers with no bundled snapshot deliver nil;
a failed or partial seed is absent (nil), never an error."
  (ignore provider)
  nil)

(cl-defgeneric quoth-provider--models-async (provider on-done)
  "Fetch PROVIDER's model catalog, delivering it to ON-DONE once.
The delivered value is a list of model plists (keys: :id, :name,
:context-window, :default-max-tokens, :cost-in, :cost-out,
:cost-cache-write, :cost-cache-hit, :can-reason, :reasoning-levels,
:default-reasoning-effort, :supports-attachments), or nil on failure.
Providers that have no catalog deliver nil without fetching.  Returns
a cancel thunk or nil.  The cache layer (`quoth-provider-models-refresh')
is the intended caller; UI code reads through the cache."
  (ignore provider)
  (funcall on-done nil)
  nil)

(defcustom quoth-provider-models-ttl 600
  "Seconds a catalog cache entry stays fresh.
A read past the TTL returns the stale entry immediately and kicks a
background refresh (stale-while-revalidate)."
  :type 'integer
  :group 'quoth)

(defcustom quoth-provider-models-prefetch t
  "Non-nil prefetches the model catalog when a chat buffer initializes.
Keeps the selector (C-c \" m) warm for the first open."
  :type 'boolean
  :group 'quoth)

(defvar quoth-provider-models-hook nil
  "Hook run after a model-catalog refresh lands.
Runs with no args, in whatever buffer was current at delivery; subscribers
refresh buffer-local UI (e.g. the transient's model info) and guard on
buffer liveness themselves.")

(defvar quoth-provider--models-cache (make-hash-table :test 'equal)
  "Global catalog cache, keyed by `quoth-provider--models-key'.
Entries are (MODELS . FETCHED-AT) with FETCHED-AT an epoch float;
the cache is shared across buffers of the same provider and catalog
source.")

(defvar quoth-provider--models-inflight (make-hash-table :test 'equal)
  "In-flight catalog fetches, keyed by `quoth-provider--models-key'.
Values are the ON-DONE fan-out list for the pending fetch; one fetch
runs per key regardless of how many refreshes requested it.")

(defun quoth-provider-model-supports-attachments-p (provider)
  "Return whether PROVIDER's active model accepts image attachments.
Reads the model id through `quoth-provider-model' and looks it up in
the cached catalog (never a fetch).  Returns t or nil when the
catalog knows the model, or `unknown' when the provider has no
model selected or the catalog has not loaded — callers treat
`unknown' as permissive (the server strips images silently rather
than erroring) and stay silent rather than blocking."
  (if (not (and provider (quoth-provider-p provider)))
      'unknown
    (let* ((model (quoth-provider-model provider))
           (models (and model (quoth-provider-models-cached provider)))
           (entry (and models
                       (cl-find model models
                                :test #'string=
                                :key (lambda (m) (plist-get m :id))))))
      (if entry
          (if (plist-get entry :supports-attachments) t nil)
        'unknown))))

(defun quoth-provider-model-context-window (provider)
  "Return PROVIDER's active model context window in tokens.
Reads the model id through `quoth-provider-model' and looks it up in
the cached catalog (never a fetch).  Returns an integer when the
catalog reports `:context-window' for the model, or `unknown' when
the provider has no model selected, the catalog has not loaded, or
the entry carries no window — callers treat `unknown' as \"omit the
display\" rather than guessing a default."
  (if (not (and provider (quoth-provider-p provider)))
      'unknown
    (let* ((model (quoth-provider-model provider))
           (models (and model (quoth-provider-models-cached provider)))
           (entry (and models
                       (cl-find model models
                                :test #'string=
                                :key (lambda (m) (plist-get m :id))))))
      (or (and entry (plist-get entry :context-window))
          'unknown))))

(defun quoth-provider-models-cached (provider)
  "Return PROVIDER's cached catalog, or nil when never fetched.
A fresh entry (inside `quoth-provider-models-ttl') returns directly.
A stale entry returns immediately and kicks exactly one background
refresh (stale-while-revalidate).  On a cache miss the bundled seed
\(`quoth-provider--models-seed') is stored first — stamped
FETCHED-AT 0, i.e. stale — so it returns through the same
stale-while-revalidate path and the live refresh overrides it; with
no seed a nil entry returns nil and the caller falls back to a
static list."
  (let* ((key (quoth-provider--models-key provider))
         (entry (and key (gethash key quoth-provider--models-cache))))
    (unless entry
      (let ((seed (and key (quoth-provider--models-seed provider))))
        (when seed
          (setq entry (cons seed 0.0))
          (puthash key entry quoth-provider--models-cache))))
    (when entry
      (when (and quoth-provider-models-ttl
                 (> (- (float-time) (cdr entry))
                    quoth-provider-models-ttl))
        (quoth-provider-models-refresh provider))
      (car entry))))

(defun quoth-provider-models-refresh (provider &optional force)
  "Refresh the cached catalog for PROVIDER asynchronously.
Deduplicated: one fetch runs per key while another is in flight; FORCE
non-nil refetches even when the cached entry is fresh.  A successful
fetch writes the cache (stamping the fetch time) and runs
`quoth-provider-models-hook'; a failed fetch (nil delivery) keeps the
existing cache entry.  Returns non-nil when a fetch was started."
  (let ((key (quoth-provider--models-key provider)))
    (when key
      (unless (or (gethash key quoth-provider--models-inflight)
                  (and (not force)
                       (let ((entry (gethash key quoth-provider--models-cache)))
                         (and entry
                              (<= (- (float-time) (cdr entry))
                                  quoth-provider-models-ttl)))))
        (progn
          (puthash key
                   (lambda (models)
                     (remhash key quoth-provider--models-inflight)
                     (when models
                       (puthash key (cons models (float-time))
                                quoth-provider--models-cache)
                       (run-hooks 'quoth-provider-models-hook)))
                   quoth-provider--models-inflight)
          (quoth-provider--models-async
           provider
           (lambda (models)
             (let ((fan (gethash key quoth-provider--models-inflight)))
               (when fan
                 (funcall fan models)))))
          t)))))

(cl-defgeneric quoth-provider--apply-model (provider model-entry)
  "Apply MODEL-ENTRY (a plist from `quoth-provider--models') to PROVIDER.
Sets the provider's model slot from (:id MODEL-ENTRY); returns nil.
Providers override to pin provider-specific state."
  (ignore provider model-entry)
  nil)

(cl-defgeneric quoth-provider-model (provider)
  "Return PROVIDER's active model id, or nil.
Lets the selector and the header line read the current model through
the protocol instead of reaching into a concrete provider struct."
  (ignore provider)
  nil)

(provide 'quoth-provider)
;;; quoth-provider.el ends here
