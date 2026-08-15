;;; crush-provider.el --- crush provider protocol  -*- lexical-binding: t; -*-
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

;; Shared provider protocol for crush.el: the `crush-provider' base struct
;; and the `crush-provider-*' generic functions implemented by
;; `crush-hyper-provider.el' (direct HTTP to the Charm Hyper gateway).

;;; Code:

(require 'cl-lib)

(cl-defstruct (crush-provider
               (:constructor nil)
               (:copier nil))
  "Base structure for a crush provider."
  buffer
  completion-action
  working-directory
  ;; Application count: the number of pipeline applications (runnable,
  ;; inflight, blocked) this provider accounts for.  The facade reads it
  ;; via stream progress; a value of 0 means the provider is idle.
  (application-count 1)
  (type nil))

(defconst crush-context-preamble
  "The following markdown fenced code blocks contain code context from the
user's editor. Each block has a header line indicating the source file and
optional line range. Paths are relative to the project root. Use this context
to answer the prompt."
  "Preamble used before attached context by both providers.")

(cl-defgeneric crush-provider-send-prompt (provider prompt &key context session-id continue-p completion buffer stderr on-delta on-error continuation)
  "Send PROMPT to PROVIDER with optional CONTEXT, SESSION-ID, and CONTINUE-P.
COMPLETION is a zero-argument closure (the facade's continuation) that
the provider must invoke exactly once when the response stream finishes.
BUFFER is the crush buffer the provider may associate its transport
process with, and STDERR is the stderr buffer; both are passed purely
as data objects, never read or switched to.  ON-DELTA is a (DELTA
KIND) callback that consumes streamed output, and ON-ERROR receives
stream error messages, for providers that stream (hyper).
CONTINUATION, when non-nil, is a list of structured message alists
(assistant with `tool_calls' followed by `role: \"tool\"' messages)
that replace the user message in the request body; used by the
tool loop to send follow-up requests with tool results.")

(cl-defgeneric crush-provider-interrupt (provider)
  "Interrupt the currently running operation on PROVIDER.")

(cl-defgeneric crush-provider-active-p (provider)
  "Return non-nil if PROVIDER has an active operation.")

(cl-defgeneric crush-provider-cleanup (provider)
  "Clean up any resources held by PROVIDER.")

(cl-defgeneric crush-provider-grant-permission (provider permission-id action)
  "Respond to a permission request on PROVIDER identified by PERMISSION-ID.
ACTION is `allow', `allow-session', or `deny'.")

(cl-defgeneric crush-provider--tool-results (provider tool-calls)
  "Build the tool-result messages and display blocks for TOOL-CALLS.
TOOL-CALLS is a vector of tool-call alists from the SSE stream,
accumulated by `crush--hyper-sse-merge-tool-calls'.  Returns a
list (ASSISTANT-MSG TOOL-RESULT-MSGS TOOL-BLOCKS) where
ASSISTANT-MSG is the assistant message carrying `tool_calls',
TOOL-RESULT-MSGS is a list of `role: \"tool\"' messages, and
TOOL-BLOCKS is a list of plists (:name :id :args-json :result
:exit) for `crush--tool-block-insert'."
  (ignore provider tool-calls)
  nil)

(cl-defgeneric crush-provider--tool-calls (provider process)
  "Return the accumulated tool-calls vector from PROVIDER's PROCESS, or nil.
PROCESS is the transport process returned by `crush-provider-send-prompt'.
For streaming providers, the SSE state on PROCESS carries the
`:tool-calls' vector accumulated by the parser; non-streaming
providers return nil."
  (ignore provider process)
  nil)

(provide 'crush-provider)
;;; crush-provider.el ends here