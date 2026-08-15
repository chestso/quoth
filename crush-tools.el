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

;; Local tool implementations for crush.el: the `bash' tool (each
;; command runs in its own `bash -c' process, no shell state), the
;; execution policy (`crush-tool-policy yolo': tool calls run without
;; prompting), and the tool limits.  The tool *protocol* (the
;; `crush-openai-tool-call' struct, registry, dispatch, arg parsing,
;; and result format) lives in `crush-openai.el'; this file implements
;; the concrete bash tool and registers it into
;; `crush-openai-tool-registry' at load time.

;;; Code:

(require 'cl-lib)
(require 'json)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the sibling from this file's
;;; own directory so both flycheck and package-installed loads work.
(eval-and-compile
  (dolist (dep '("crush-openai"))
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

(defcustom crush-bash-program nil
  "Bash binary for tool calls.  nil means `shell-file-name'.
Tests force a fake shell script here."
  :type '(choice (const :tag "default shell" nil) string)
  :group 'crush-tool)

(defcustom crush-tool-timeout 60
  "Kill a tool call after this many seconds.
The error result says the command timed out and was killed."
  :type 'integer
  :group 'crush-tool)

(defcustom crush-tool-max-output 30000
  "Cap on tool result output, truncated head/tail with an ellipsis line."
  :type 'integer
  :group 'crush-tool)

(declare-function crush--debug-log "crush.el" (category message))
(declare-function crush-openai-tool-error-result "crush-openai" (message))
(declare-function crush-openai-tool-call-args "crush-openai" (tool-call))

(defun crush-bash--exec-command (tool-call-args)
  "Return the resolved command string for TOOL-CALL-ARGS plist, or nil.
Validates the plist from `crush-openai-parse-tool-args': the
`command' argument must be a non-empty string."
  (let ((command (plist-get tool-call-args :command)))
    (and (stringp command)
         (not (string-empty-p (string-trim command)))
         command)))

(defun crush-bash--exec (tool-call)
  "Execute TOOL-CALL with bash and return (RESULT-TEXT . EXIT-CODE).
Runs the parsed `command' arg via `crush-bash-program' (or
`shell-file-name') with `-c' in the resolved working directory.
Combined stdout+stderr are collected; output is capped at
`crush-tool-max-output' chars (head/tail split with an ellipsis line
for overflow).  A malformed or missing `command' argument, or a
timeout (`crush-tool-timeout'), yields an error result with a
negative exit code.  Logs the round to *crush-debug* (category
`tool'); commands themselves may embed secrets, so the log line is
the documented trade-off of the design."
  (let ((args (crush-openai-tool-call-args tool-call)))
    (if (not (crush-bash--exec-command args))
        (let ((result (crush-openai-tool-error-result "missing command")))
          (setf (crush-openai-tool-call-result tool-call) (car result)
                (crush-openai-tool-call-exit tool-call) (cdr result))
          result)
      (let* ((command (plist-get args :command))
             (working-dir (or (plist-get args :working_dir)
                              default-directory))
             (program (or crush-bash-program shell-file-name))
             (exit-code -1)
             (output nil))
        (with-temp-buffer
          (let* ((default-directory (file-name-as-directory
                                     (expand-file-name working-dir)))
                 (proc (make-process
                        :name "crush-bash"
                        :buffer (current-buffer)
                        :command (list program "-c" command)
                        :connection-type 'pipe
                        :noquery t
                        :stderr (get-buffer-create "*crush-errors*")))
                 (sentinel (lambda (_p _e) nil)))
            (set-process-sentinel proc sentinel)
            (setq exit-code (crush-bash--collect proc))
            ;; Strip the process-status message Emacs appends after
            ;; the sentinel fires (\"Process crush-bash finished\").
            (goto-char (point-min))
            (when (re-search-forward
                   "\nProcess crush-bash[^\n]+\n\\'" nil t)
              (let ((inhibit-read-only t))
                (delete-region (match-beginning 0) (match-end 0))))
            (setq output (buffer-string))))
        (let* ((result (crush-bash--format-result
                        command working-dir output exit-code)))
          (setf (crush-openai-tool-call-result tool-call) (car result)
                (crush-openai-tool-call-exit tool-call) (cdr result))
          (crush--debug-log
           'tool
           (format "bash %S cwd=%s exit=%s output=%S"
                   command working-dir
                   (if (= exit-code 124) "killed" exit-code)
                   (substring output 0 (min (length output) 200))))
          result)))))

(defun crush-bash--collect (proc)
  "Collect output from PROC until exit or `crush-tool-timeout'.
Returns the exit code, or 124 (the convention for `timeout --kill')
when the process had to be killed.  Output stays in the process
buffer, read back by the caller."
  (let ((deadline (+ (float-time) crush-tool-timeout))
        (exit -1))
    (while (process-live-p proc)
      (if (>= (float-time) deadline)
          (progn
            (delete-process proc)
            (setq exit 124))
        (accept-process-output proc 0.1)))
    (if (= exit 124)
        exit
      (or (process-exit-status proc) 0))))

(defun crush-bash--format-result (command working-dir output exit-code)
  "Return (RESULT-TEXT . EXIT-CODE) for COMMAND in WORKING-DIR with OUTPUT.
Truncates OUTPUT at `crush-tool-max-output' chars keeping the head
and tail with an ellipsis line; empty output renders as `no output'.
Success wraps the command in `<cwd>' markup so the model knows where
it ran."
  (let* ((capped (crush-bash--truncate-output output))
         (exit-tag (cond
                    ((= exit-code 124) "killed")
                    ((= exit-code 0) "0")
                    (t (number-to-string exit-code)))))
    (cons
     (concat
      (when (and (stringp command) (string-empty-p (string-trim output)))
        (format "<cwd>%s</cwd>\n" working-dir))
      (format "<command>%s</command>\n" command)
      (format "<output>\n%s\n</output>\n" capped)
      (format "<exit_code>%s</exit_code>" exit-tag))
     exit-code)))

(defun crush-bash--truncate-output (output)
  "Cap OUTPUT at `crush-tool-max-output' chars, head/tail with an ellipsis.
A tail of 30% is kept on overflow so the model sees the end of long
command output; empty output renders as the literal string
`no output'."
  (let* ((text (string-trim output))
         (limit crush-tool-max-output))
    (cond
     ((string-empty-p text) "no output")
     ((<= (length text) limit) text)
     (t (let* ((head-len (floor (* limit 0.7)))
               (tail-len (- limit head-len)))
          (format "%s\n... (truncated)\n%s"
                  (substring text 0 head-len)
                  (substring text (- (length text) tail-len))))))))

;;; Register the bash tool into the protocol registry.

(push (cons "bash" #'crush-bash--exec)
      crush-openai-tool-registry)

(provide 'crush-tools)
;;; crush-tools.el ends here
