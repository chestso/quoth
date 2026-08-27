;;; quoth-tools.el --- Local tool implementations for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/quoth
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

;; Local tool implementations for quoth.el: the `exec_command' and
;; `write_stdin' tools.  Both are thin
;; wrappers over the general-purpose process handler in
;; `quoth-process.el': `exec_command' starts a session and yields,
;; `write_stdin' feeds input to a live session.  Results use Codex's
;; prose status convention (`Process exited with code N' / `Process
;; running with session ID N' + `Output:') so models read them
;; naturally and echo the session id back verbatim.
;;
;; The tool *protocol* (the `quoth-openai-tool-call' struct, registry,
;; dispatch, arg parsing, and the execution policy) lives in
;; `quoth-openai.el'; this file implements the concrete tools and
;; registers them into `quoth-openai-tool-registry' at load time.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the sibling from this file's
;;; own directory so both flycheck and package-installed loads work.
(eval-and-compile
  (dolist (dep '("quoth-openai" "quoth-process"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defgroup quoth-tool nil
  "Execution policy and limits for quoth tool calls."
  :group 'quoth
  :prefix "quoth-tool-")

(defcustom quoth-tool-policy 'yolo
  "Tool execution policy.
The only value in v1 is `yolo': tool calls run without prompt.
`ask' and `allowlist' arrive with the permission policy (TODO.md)."
  :type '(choice (const yolo))
  :group 'quoth-tool)

(defcustom quoth-tool-max-output 30000
  "Cap on tool result output, truncated head/tail with an omission line.
A chunk larger than this keeps a 70% head and 30% tail with an
`... N bytes omitted ...' marker between them."
  :type 'integer
  :group 'quoth-tool)

(defcustom quoth-tool-allow-login-shell nil
  "Whether `exec_command' may run login shells.
When nil, a `login' argument of t is rejected.  The model must still
request `login' on the tool call for it to take effect."
  :type 'boolean
  :group 'quoth-tool)

(declare-function quoth-openai-tool-error-result "quoth-openai" (message))
(declare-function quoth-openai-tool-call-args "quoth-openai" (tool-call))
(declare-function quoth-process--start "quoth-process" (command working-directory owner &optional shell login))
(declare-function quoth-process--yield "quoth-process" (session yield-ms))
(declare-function quoth-process--write-stdin "quoth-process" (session input yield-ms))
(declare-function quoth-process--find "quoth-process" (id))
(declare-function quoth-process--kill "quoth-process" (session))
(declare-function quoth-process--cleanup-buffer "quoth-process" (owner))

(defvar quoth-tool--owner nil
  "Buffer owning sessions started by the current tool round.")
(make-variable-buffer-local 'quoth-tool--owner)

(defun quoth-exec--cmd (tool-call-args)
  "Return the resolved command string for TOOL-CALL-ARGS plist, or nil.
Validates the plist from `quoth-openai-parse-tool-args': the `cmd'
argument must be a non-empty string."
  (let ((cmd (plist-get tool-call-args :cmd)))
    (and (stringp cmd)
         (not (string-empty-p (string-trim cmd)))
         cmd)))

(defun quoth-exec--yield-ms (tool-call-args default-ms)
  "Resolve the yield window from TOOL-CALL-ARGS or DEFAULT-MS.
The `yield_time_ms' argument is clamped to the 250-30000 effective range
\(mirrors Codex's exec_command)."
  (let ((raw (plist-get tool-call-args :yield_time_ms)))
    (if (numberp raw)
        (max 250 (min 30000 raw))
      default-ms)))

(defun quoth-exec--login (tool-call-args)
  "Resolve the login-shell flag from TOOL-CALL-ARGS.
Returns t when the caller requests a login shell and it is allowed by
`quoth-tool-allow-login-shell'; signals an error when requested but
disallowed.  Returns nil otherwise."
  (let ((requested (plist-get tool-call-args :login)))
    (when (and requested
               (not (eq requested :json-false))
               (not quoth-tool-allow-login-shell))
      (error "Login shell is disabled by config; omit `login' or set it to false"))
    (and requested (not (eq requested :json-false)) t)))

(defun quoth-exec--shell (tool-call-args)
  "Return the shell binary path requested by TOOL-CALL-ARGS, or nil."
  (let ((shell (plist-get tool-call-args :shell)))
    (and (stringp shell)
         (not (string-empty-p (string-trim shell)))
         shell)))

(defun quoth-exec--error (message tool-call)
  "Store an error result on TOOL-CALL with MESSAGE and return the error pair."
  (let ((result (quoth-openai-tool-error-result message)))
    (setf (quoth-openai-tool-call-result tool-call) (car result)
          (quoth-openai-tool-call-exit tool-call) (cdr result))
    result))

(defun quoth-exec--truncate-output (output)
  "Cap OUTPUT at `quoth-tool-max-output' chars, head/tail with an omission.
Leading whitespace is preserved so indented output (trees, diffs,
markdown) renders correctly; only trailing whitespace is trimmed so an
empty result reads as `no output' and the fence is always clean."
  (let* ((text (string-trim-right output))
         (limit quoth-tool-max-output))
    (cond
     ((string-empty-p text) "no output")
     ((<= (length text) limit) text)
     (t (let* ((head-len (floor (* limit 0.7)))
               (tail-len (- limit head-len))
               (omitted (- (length text) limit)))
          (format "%s\n... %d bytes omitted ...\n%s"
                  (substring text 0 head-len)
                  omitted
                  (substring text (- (length text) tail-len))))))))

(defun quoth-exec--format-result (output exit-code)
  "Return the finished-result text for OUTPUT and EXIT-CODE.
Uses Codex's prose convention: status line, then `Output:' and the
chunk."
  (concat
   (format "Process exited with code %s\n" exit-code)
   "Output:\n"
   (quoth-exec--truncate-output output)))

(defun quoth-exec--format-running (output session-id)
  "Return the still-running result text for OUTPUT and SESSION-ID.
The status line carries the session id the model echoes into
`write_stdin'."
  (concat
   (format "Process running with session ID %d\n" session-id)
   "Output:\n"
   (quoth-exec--truncate-output output)))

(defun quoth-exec-command--exec (tool-call)
  "Execute TOOL-CALL as `exec_command' and return (RESULT . EXIT-OR-NIL).
Runs the parsed `cmd' arg in a new `quoth-process' session and yields
for the resolved `yield_time_ms' (default `quoth-process-yield-ms').
A finished command reports `Process exited with code N'; a still-running
one reports `Process running with session ID N' with a nil exit slot.
A missing/empty `cmd', a session-cap overflow, or a spawn failure yields
an error result with exit code -1."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (cmd (quoth-exec--cmd args)))
    (if (not cmd)
        (quoth-exec--error "Missing cmd" tool-call)
      (condition-case err
          (let* ((working-dir (or (plist-get args :workdir) default-directory))
                 (yield-ms (quoth-exec--yield-ms args quoth-process-yield-ms))
                 (shell (quoth-exec--shell args))
                 (login (quoth-exec--login args))
                 (session (quoth-process--start
                           cmd working-dir
                           (or quoth-tool--owner (current-buffer))
                           shell login)))
            (if (not (quoth-process-session-p session))
                ;; Spawn failed without signalling.
                (quoth-exec--error "Failed to start command" tool-call)
              (let* ((result (quoth-process--yield session yield-ms))
                     (chunk (car result))
                     (exit (cdr result))
                     (id (quoth-process-session-id session)))
                (if exit
                    (let* ((text (quoth-exec--format-result chunk exit)))
                      (setf (quoth-openai-tool-call-result tool-call) text
                            (quoth-openai-tool-call-exit tool-call) exit)
                      (quoth-process--kill session)
                      (cons text exit))
                  (let* ((text (quoth-exec--format-running chunk id)))
                    (cons text nil))))))
        (error (quoth-exec--error (error-message-string err) tool-call))))))

(defun quoth-write-stdin--exec (tool-call)
  "Execute TOOL-CALL as `write_stdin' and return (RESULT . EXIT-OR-NIL).
Looks up the `session_id' arg, writes optional `input' to the session's
stdin, and reports the output produced since the last report.  A live
session reports `Process running with session ID N' (nil exit); a
session that finished during the read reports `Process exited with code
N' and is deregistered.  An unknown session id yields an error result."
  (let ((args (quoth-openai-tool-call-args tool-call))
        (session-id (plist-get (quoth-openai-tool-call-args tool-call)
                               :session_id)))
    (let ((session (and (integerp session-id)
                        (quoth-process--find session-id))))
      (if (not session)
          (quoth-exec--error (format "unknown session id %S" session-id)
                             tool-call)
        (let* ((input (or (plist-get args :input) ""))
               (yield-ms (quoth-exec--yield-ms args quoth-process-write-yield-ms))
               (result (quoth-process--write-stdin session input yield-ms))
               (chunk (car result))
               (exit (cdr result))
               (id (quoth-process-session-id session)))
          (if exit
              (let* ((text (quoth-exec--format-result chunk exit)))
                (setf (quoth-openai-tool-call-result tool-call) text
                      (quoth-openai-tool-call-exit tool-call) exit)
                (quoth-process--kill session)
                (cons text exit))
            (let* ((text (quoth-exec--format-running chunk id)))
              (cons text nil))))))))

;;; Register the tools into the protocol registry.

(push (cons "exec_command" #'quoth-exec-command--exec)
      quoth-openai-tool-registry)
(push (cons "write_stdin" #'quoth-write-stdin--exec)
      quoth-openai-tool-registry)

(provide 'quoth-tools)
;;; quoth-tools.el ends here
