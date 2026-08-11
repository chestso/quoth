;;; crush-run-backend.el --- crush run backend  -*- lexical-binding: t; -*-

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

;; The `crush run' CLI backend for crush.el.  Each prompt spawns a new
;; `crush run --quiet' process; session continuity is delegated to the
;; CLI through `--continue' or `--session'.  See the main crush.el file
;; for the backend protocol.

;;; Code:

(require 'cl-lib)
(require 'crush-backend)

(defcustom crush-backend-type 'run
  "Type of crush backend to use.
`run' uses the standalone `crush run' mode (per-process).
`hyper' uses direct HTTP streaming to the Charm Hyper gateway."
  :type '(choice (const run) (const hyper))
  :group 'crush)

(defcustom crush-program "crush"
  "Path to the Crush CLI executable."
  :type 'file
  :group 'crush)

(defcustom crush-args nil
  "Additional command-line arguments passed to the Crush CLI."
  :type '(repeat string)
  :group 'crush)

(defcustom crush-model nil
  "Model to use for the Crush CLI.
When nil, uses the default model configured in Crush.
Should be a model name like `claude-sonnet-4-20250514' or `gpt-4o'."
  :type '(choice (const nil) string)
  :group 'crush)

(defcustom crush-debug-mode t
  "When non-nil, log commands, input, and output to a *crush-debug* buffer."
  :type 'boolean
  :group 'crush)

(cl-defstruct (crush-run-backend
               (:include crush-backend (type 'run))
               (:constructor nil)
               (:constructor crush-make-run-backend
			     (&key buffer working-directory program args model
				   &aux (type 'run)))
               (:copier nil))
  "Standalone crush run backend."
  program
  args
  model)

(defcustom crush-working-directory nil
  "Working directory for the Crush CLI.
When nil, uses the project root if `project-current' is non-nil,
otherwise `default-directory'."
  :type '(choice (const nil) directory)
  :group 'crush)

(defcustom crush--continue nil
  "Whether to pass --continue to the Crush CLI.
When non-nil, the next prompt continues the active session in the folder.
Set to nil by `crush-new-session' and `crush-clear-buffer' so the next
prompt starts a fresh session.
Buffer-local."
  :type 'boolean
  :group 'crush)

(defcustom crush--session nil
  "Session ID to pass to the Crush CLI via --session.
When non-nil, continues a specific session by ID.
Takes precedence over `crush--continue'.
Buffer-local."
  :type '(choice (const nil) string)
  :group 'crush)

(defcustom crush-input-ring-size 32
  "Maximum number of prompts stored in the input ring."
  :type 'integer
  :group 'crush)

(defvar crush--response-start nil
  "Marker for where response text starts.
Set when prompt is sent, used by sentinel to tag response text.
Buffer-local.")

(defvar crush--pending-context nil
  "Context text stashed for stdin delivery.
Buffer-local.")

(defvar crush-process nil
  "The currently running Crush process, if any.
Buffer-local.")

(declare-function crush-backend-buffer "crush.el" (backend))
(declare-function crush--debug-log "crush.el" (category message))
(declare-function crush--output-filter "crush.el" (proc string))
(declare-function crush--process-sentinel "crush.el" (process event))

(cl-defmethod crush-backend-send-prompt
  ((backend crush-run-backend) prompt &key context session-id continue-p)
  "Send PROMPT to BACKEND via `crush run' as a new process.
For CONTEXT, SESSION-ID, and CONTINUE-P, see `crush-backend-send-prompt'."
  (with-current-buffer (crush-backend-buffer backend)
    (let* ((has-context (and context (not (string-empty-p context))))
           (base-args (append
                       (list (crush-run-backend-program backend) "run" "--quiet")
                       (crush-run-backend-args backend)
                       (when (crush-run-backend-model backend)
                         (list "--model" (crush-run-backend-model backend)))))
           (session-args (append
                          base-args
                          (when session-id
                            (list "--session" session-id))
                          (when (and continue-p (not session-id))
                            (list "--continue"))))
           (args (if has-context session-args
                   (append session-args (list prompt))))
           (real-proc (make-process
                       :name "crush"
                       :buffer (current-buffer)
                       :command args
                       :connection-type 'pipe
                       :filter #'crush--output-filter
                       :sentinel #'crush--process-sentinel
                       :stderr (get-buffer-create "*crush-errors*")
                       :noquery t)))
      (crush--debug-log 'command (format "%s" args))
      (crush--debug-log 'input (format "%S (context: %s)"
                                       prompt (if has-context "yes" "none")))      (set-marker (process-mark real-proc) (point-max))
      (setq-local crush-process real-proc)
      (setq-local crush--continue t)
      (setq-local crush--response-start (point-marker))
      (when (process-live-p real-proc)
        (when has-context
          (process-send-string real-proc context))
        ;; Always close stdin with EOF. `crush run' reads all of stdin
        ;; before processing (CRUSH-SPEC), so keeping the pipe open would
        ;; block the process indefinitely even when the prompt is a CLI arg.
        (process-send-eof real-proc))
      real-proc)))

(cl-defmethod crush-backend-interrupt ((backend crush-run-backend))
  "Interrupt the crush run process managed by BACKEND."
  (with-current-buffer (crush-backend-buffer backend)
    (when crush-process
      (interrupt-process crush-process)
      (setq-local crush-process nil))))

(cl-defmethod crush-backend-active-p ((backend crush-run-backend))
  "Return non-nil if BACKEND has a live crush run process."
  (with-current-buffer (crush-backend-buffer backend)
    (and crush-process (process-live-p crush-process))))

(cl-defmethod crush-backend-cleanup ((backend crush-run-backend))
  "Kill any running process for BACKEND."
  (with-current-buffer (crush-backend-buffer backend)
    (when (and crush-process (process-live-p crush-process))
      (delete-process crush-process))
    (setq-local crush-process nil)))

(cl-defmethod crush-backend-grant-permission ((_backend crush-run-backend) _permission-id _action)
  "No-op for run backend: permissions are auto-approved."
  nil)

(provide 'crush-run-backend)
;;; crush-run-backend.el ends here
