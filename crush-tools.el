;;; crush-tools.el --- Local tool implementations for crush  -*- lexical-binding: t; -*-
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

;; Local tool implementations for crush.el: the `exec_command' and
;; `write_stdin' tools.  Both are thin
;; wrappers over the general-purpose process handler in
;; `crush-process.el': `exec_command' starts a session and yields,
;; `write_stdin' feeds input to a live session.  Results use Codex's
;; prose status convention (`Process exited with code N' / `Process
;; running with session ID N' + `Output:') so models read them
;; naturally and echo the session id back verbatim.
;;
;; The tool *protocol* (the `crush-openai-tool-call' struct, registry,
;; dispatch, arg parsing, and the execution policy) lives in
;; `crush-openai.el'; this file implements the concrete tools and
;; registers them into `crush-openai-tool-registry' at load time.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the sibling from this file's
;;; own directory so both flycheck and package-installed loads work.
(eval-and-compile
  (dolist (dep '("crush-openai" "crush-process"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defgroup crush-tool nil
  "Execution policy and limits for crush tool calls."
  :group 'crush
  :prefix "crush-tool-")

(defcustom crush-tool-policy 'yolo
  "Tool execution policy.
The only value in v1 is `yolo': tool calls run without prompt.
`ask' and `allowlist' arrive with the permission policy (TODO.md)."
  :type '(choice (const yolo))
  :group 'crush-tool)

(defcustom crush-tool-max-output 30000
  "Cap on tool result output, truncated head/tail with an omission line.
A chunk larger than this keeps a 70% head and 30% tail with an
`... N bytes omitted ...' marker between them."
  :type 'integer
  :group 'crush-tool)

(defcustom crush-tool-allow-login-shell nil
  "Whether `exec_command' may run login shells.
When nil, a `login' argument of t is rejected.  The model must still
request `login' on the tool call for it to take effect."
  :type 'boolean
  :group 'crush-tool)

(declare-function crush-openai-tool-error-result "crush-openai" (message))
(declare-function crush-openai-tool-call-args "crush-openai" (tool-call))
(declare-function crush-process--start "crush-process" (command working-directory owner &optional shell login))
(declare-function crush-process--yield "crush-process" (session yield-ms))
(declare-function crush-process--write-stdin "crush-process" (session input yield-ms))
(declare-function crush-process--find "crush-process" (id))
(declare-function crush-process--kill "crush-process" (session))
(declare-function crush-process--cleanup-buffer "crush-process" (owner))

(defvar crush-tool--owner nil
  "Buffer owning sessions started by the current tool round.")
(make-variable-buffer-local 'crush-tool--owner)

(defun crush-exec--cmd (tool-call-args)
  "Return the resolved command string for TOOL-CALL-ARGS plist, or nil.
Validates the plist from `crush-openai-parse-tool-args': the `cmd'
argument must be a non-empty string."
  (let ((cmd (plist-get tool-call-args :cmd)))
    (and (stringp cmd)
         (not (string-empty-p (string-trim cmd)))
         cmd)))

(defun crush-exec--yield-ms (tool-call-args default-ms)
  "Resolve the yield window from TOOL-CALL-ARGS or DEFAULT-MS.
The `yield_time_ms' argument is clamped to the 250-30000 effective range
(mirrors Codex's exec_command)."
  (let ((raw (plist-get tool-call-args :yield_time_ms)))
    (if (numberp raw)
        (max 250 (min 30000 raw))
      default-ms)))

(defun crush-exec--login (tool-call-args)
  "Resolve the login-shell flag from TOOL-CALL-ARGS.
Returns t when the caller requests a login shell and it is allowed by
`crush-tool-allow-login-shell'; signals an error when requested but
disallowed.  Returns nil otherwise."
  (let ((requested (plist-get tool-call-args :login)))
    (when (and requested
               (not (eq requested :json-false))
               (not crush-tool-allow-login-shell))
      (error "login shell is disabled by config; omit `login' or set it to false"))
    (and requested (not (eq requested :json-false)) t)))

(defun crush-exec--shell (tool-call-args)
  "Return the shell binary path requested by TOOL-CALL-ARGS, or nil."
  (let ((shell (plist-get tool-call-args :shell)))
    (and (stringp shell)
         (not (string-empty-p (string-trim shell)))
         shell)))

(defun crush-exec--error (message tool-call)
  "Store an error result on TOOL-CALL and return the error pair."
  (let ((result (crush-openai-tool-error-result message)))
    (setf (crush-openai-tool-call-result tool-call) (car result)
          (crush-openai-tool-call-exit tool-call) (cdr result))
    result))

(defun crush-exec--truncate-output (output)
  "Cap OUTPUT at `crush-tool-max-output' chars, head/tail with an omission.
Leading whitespace is preserved so indented output (trees, diffs,
markdown) renders correctly; only trailing whitespace is trimmed so an
empty result reads as `no output' and the fence is always clean."
  (let* ((text (string-trim-right output))
         (limit crush-tool-max-output))
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

(defun crush-exec--format-result (output exit-code)
  "Return the finished-result text for OUTPUT and EXIT-CODE.
Uses Codex's prose convention: status line, then `Output:' and the
chunk."
  (concat
   (format "Process exited with code %s\n" exit-code)
   "Output:\n"
   (crush-exec--truncate-output output)))

(defun crush-exec--format-running (output session-id)
  "Return the still-running result text for OUTPUT and SESSION-ID.
The status line carries the session id the model echoes into
`write_stdin'."
  (concat
   (format "Process running with session ID %d\n" session-id)
   "Output:\n"
   (crush-exec--truncate-output output)))

(defun crush-exec-command--exec (tool-call)
  "Execute TOOL-CALL as `exec_command' and return (RESULT . EXIT-OR-NIL).
Runs the parsed `cmd' arg in a new `crush-process' session and yields
for the resolved `yield_time_ms' (default `crush-process-yield-ms').
A finished command reports `Process exited with code N'; a still-running
one reports `Process running with session ID N' with a nil exit slot.
A missing/empty `cmd', a session-cap overflow, or a spawn failure yields
an error result with exit code -1."
  (let* ((args (crush-openai-tool-call-args tool-call))
         (cmd (crush-exec--cmd args)))
    (if (not cmd)
        (crush-exec--error "missing cmd" tool-call)
      (condition-case err
          (let* ((working-dir (or (plist-get args :workdir) default-directory))
                 (yield-ms (crush-exec--yield-ms args crush-process-yield-ms))
                 (shell (crush-exec--shell args))
                 (login (crush-exec--login args))
                 (session (crush-process--start
                           cmd working-dir
                           (or crush-tool--owner (current-buffer))
                           shell login)))
            (if (not (crush-process-session-p session))
                ;; Spawn failed without signalling.
                (crush-exec--error "failed to start command" tool-call)
              (let* ((result (crush-process--yield session yield-ms))
                     (chunk (car result))
                     (exit (cdr result))
                     (id (crush-process-session-id session)))
                (if exit
                    (let* ((text (crush-exec--format-result chunk exit)))
                      (setf (crush-openai-tool-call-result tool-call) text
                            (crush-openai-tool-call-exit tool-call) exit)
                      (crush-process--kill session)
                      (cons text exit))
                  (let* ((text (crush-exec--format-running chunk id)))
                    (cons text nil))))))
        (error (crush-exec--error (error-message-string err) tool-call))))))

(defun crush-write-stdin--exec (tool-call)
  "Execute TOOL-CALL as `write_stdin' and return (RESULT . EXIT-OR-NIL).
Looks up the `session_id' arg, writes optional `input' to the session's
stdin, and reports the output produced since the last report.  A live
session reports `Process running with session ID N' (nil exit); a
session that finished during the read reports `Process exited with code
N' and is deregistered.  An unknown session id yields an error result."
  (let ((args (crush-openai-tool-call-args tool-call))
        (session-id (plist-get (crush-openai-tool-call-args tool-call)
                               :session_id)))
    (let ((session (and (integerp session-id)
                        (crush-process--find session-id))))
      (if (not session)
          (crush-exec--error (format "unknown session id %S" session-id)
                             tool-call)
        (let* ((input (or (plist-get args :input) ""))
               (yield-ms (crush-exec--yield-ms args crush-process-write-yield-ms))
               (result (crush-process--write-stdin session input yield-ms))
               (chunk (car result))
               (exit (cdr result))
               (id (crush-process-session-id session)))
          (if exit
              (let* ((text (crush-exec--format-result chunk exit)))
                (setf (crush-openai-tool-call-result tool-call) text
                      (crush-openai-tool-call-exit tool-call) exit)
                (crush-process--kill session)
                (cons text exit))
            (let* ((text (crush-exec--format-running chunk id)))
              (cons text nil))))))))

;;; Register the tools into the protocol registry.

(push (cons "exec_command" #'crush-exec-command--exec)
      crush-openai-tool-registry)
(push (cons "write_stdin" #'crush-write-stdin--exec)
      crush-openai-tool-registry)

(provide 'crush-tools)
;;; crush-tools.el ends here
