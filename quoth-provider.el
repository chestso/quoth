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

;; Shared provider protocol for quoth.el: the `quoth-provider' base struct
;; and the `quoth-provider-*' generic functions implemented by
;; `quoth-hyper-provider.el' (direct HTTP to the Charm Hyper gateway).

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

;;; Session state shared across the core, the OpenAI client, and the
;;; selector UI.  Lives here — in the protocol module — so that
;;; `quoth-openai.el' and `quoth-select.el' depend on the protocol, not
;;; on `quoth.el'.  The core sets these buffer-locally at init time.

(defvar-local quoth--session-thinking nil
  "Per-buffer thinking flag: nil (unset), t (on), or :json-false (off).
nil (the default) omits the key so the model/gateway applies its own
default.  t sends `thinking: true'; :json-false sends `thinking:
false', explicitly disabling reasoning.")

(defvar-local quoth--session-reasoning-effort nil
  "Per-buffer reasoning effort, or nil.
When non-nil, the request body carries `reasoning_effort: VALUE'.
nil (the default) omits the key.")

;;; Active provider state.  The registry and the active-provider-name
;;; defcustom live here (protocol concerns); the default registry's
;;; :factory points at `quoth--make-default-hyper-provider', defined in
;;; `quoth.el' and resolved at `funcall' time, so this file does not
;;; require `quoth.el'.  The byte-compiler is told about it via
;;; `declare-function' below.

(defcustom quoth-active-provider-name "hyper"
  "Name of the active provider for new quoth buffers.
Must match the :name of an entry in `quoth-providers'.  The chosen
provider is instantiated per-buffer in `quoth--init-buffer'.
Persisted across sessions via `savehist-mode' when enabled."
  :type 'string
  :group 'quoth)

(declare-function quoth--make-default-hyper-provider "quoth.el" (&optional buf dir))

(defvar quoth-providers-default
  (list (list :name    "hyper"
              :type    'hyper
              :factory #'quoth--make-default-hyper-provider))
  "Default value for `quoth-providers' — a registry with one entry: hyper.")

(defcustom quoth-providers quoth-providers-default
  "Registered quoth providers, in priority order.
Each entry is a plist: :name (string, display + id), :type (symbol),
:factory (function of zero args returning a configured provider
instance).  The first entry is the default active provider for new
buffers.  Add a second provider by appending an entry with its own
:factory; nothing in the protocol changes."
  :type '(repeat (plist :name string :type symbol :factory function))
  :group 'quoth)

(defvar-local quoth-active-provider nil
  "The active quoth provider for this buffer.
Set during buffer initialization; `quoth--send-prompt' and
`quoth-interrupt' dispatch through it.  Buffer-local.")

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
  ;; The live transport process (e.g. curl) returned by the provider's
  ;; `quoth-provider-send-prompt'.  Owned by the provider; the core
  ;; reads activity through `quoth-provider-active-p' and kills it via
  ;; `quoth-provider-interrupt'/`quoth-provider-cleanup'.
  (transport-process nil)
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

(cl-defgeneric quoth-provider--models (provider)
  "Return a list of model plists for PROVIDER's catalog, or nil on failure.
Each plist has keys: :id, :name, :context-window, :default-max-tokens,
:cost-in, :cost-out, :cost-in-cached, :cost-out-cached, :can-reason,
:reasoning-levels, :default-reasoning-effort, :supports-attachments.
Fetches live (sync) when the provider supports it; nil signals the
caller to fall back to a static list."
  (ignore provider)
  nil)

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
