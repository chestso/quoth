;;; crush-backend.el --- crush backend protocol  -*- lexical-binding: t; -*-

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

;; Shared backend protocol for crush.el: the `crush-backend' base struct
;; and the `crush-backend-*' generic functions implemented by
;; `crush-run-backend.el' (the `crush run' CLI) and
;; `crush-hyper-backend.el' (direct HTTP to the Charm Hyper gateway).

;;; Code:

(require 'cl-lib)

(cl-defstruct (crush-backend
               (:constructor nil)
               (:copier nil))
  "Base structure for a crush backend."
  buffer
  working-directory
  (type nil))

(defconst crush-context-preamble
  "The following markdown fenced code blocks contain code context from the
user's editor. Each block has a header line indicating the source file and
optional line range. Paths are relative to the project root. Use this context
to answer the prompt."
  "Preamble used before attached context by both backends.")

(cl-defgeneric crush-backend-send-prompt (backend prompt &key context session-id continue-p)
  "Send PROMPT to BACKEND with optional CONTEXT, SESSION-ID, and CONTINUE-P.")

(cl-defgeneric crush-backend-interrupt (backend)
  "Interrupt the currently running operation on BACKEND.")

(cl-defgeneric crush-backend-active-p (backend)
  "Return non-nil if BACKEND has an active operation.")

(cl-defgeneric crush-backend-cleanup (backend)
  "Clean up any resources held by BACKEND.")

(cl-defgeneric crush-backend-grant-permission (backend permission-id action)
  "Respond to a permission request on BACKEND identified by PERMISSION-ID.
ACTION is `allow', `allow-session', or `deny'.")

(provide 'crush-backend)
;;; crush-backend.el ends here
