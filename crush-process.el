;;; crush-process.el --- Interactive process sessions for crush tools  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/crush.el
;;; Version: 0.1.0
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience
;;; Prefix: crush-process-

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

;; The general-purpose process handler for crush.el.  Owns interactive process sessions: PTY spawning, output
;; buffering, yield, stdin writes, and cleanup.  Model-neutral and
;; buffer-unaware: it never reads the crush buffer, the provider, or the
;; OpenAI protocol.  The `exec_command' and `write_stdin' tools in
;; `crush-tools.el' are thin wrappers over this layer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup crush-process nil
  "Interactive process sessions for crush tool calls."
  :group 'crush
  :prefix "crush-process-")

(defcustom crush-process-max-sessions 128
  "Maximum number of live process sessions.
Spawning past this cap yields an error result instead of a new process."
  :type 'integer
  :group 'crush-process)

(defcustom crush-process-yield-ms 10000
  "Default yield window for `exec_command', in milliseconds.
A command still running after this long reports a session id instead of
an exit code.  Effective range is 250-30000 (clamped)."
  :type 'integer
  :group 'crush-process)

(defcustom crush-process-write-yield-ms 1000
  "Default read window for `write_stdin', in milliseconds."
  :type 'integer
  :group 'crush-process)

(cl-defstruct (crush-process-session
               (:constructor crush-process--make-session)
               (:copier nil))
  "A live command session managed by the process handler.
The output buffer is append-only; LAST-REPORT is a character offset into
it marking the start of the as-yet-unreported region."
  id
  owner
  process
  output-buffer
  command
  working-directory
  last-report)

(defvar crush-process--sessions (make-hash-table :test 'eql)
  "Hash table mapping session ids to `crush-process-session' structs.")

(defvar crush-process--counter 0
  "Monotonic counter for session ids.")

(defun crush-process--next-id ()
  "Return the next session id."
  (setq crush-process--counter (1+ crush-process--counter)))

(defun crush-process--register (session)
  "Record SESSION in the registry."
  (puthash (crush-process-session-id session) session crush-process--sessions)
  session)

(defun crush-process--unregister (session)
  "Remove SESSION from the registry."
  (remhash (crush-process-session-id session) crush-process--sessions)
  session)

(defun crush-process--find (id)
  "Return the session for ID, or nil."
  (gethash id crush-process--sessions))

(defun crush-process--shell-type (shell-path)
  "Return the shell type for SHELL-PATH.
SHELL-PATH is a shell binary path or name; the type is one of `bash',
`zsh', `sh', `cmd', `powershell', or `sh-like' (the fallback for any
unknown POSIX-style shell)."
  (let ((name (downcase (file-name-nondirectory shell-path))))
    (cond
     ((string= name "bash") 'bash)
     ((string= name "zsh") 'zsh)
     ((string= name "sh") 'sh)
     ((or (string= name "cmd") (string= name "cmd.exe")) 'cmd)
     ((or (string= name "powershell") (string= name "powershell.exe")
          (string= name "pwsh") (string= name "pwsh.exe"))
      'powershell)
     (t 'sh-like))))

(defun crush-process--shell-args (shell-path command login)
  "Return the argument vector to run COMMAND under SHELL-PATH.
LOGIN non-nil requests a login shell where the shell supports one.
Mirrors Codex's `derive_exec_args' (shell.rs): bash/zsh/sh use `-c'
(or `-lc'), powershell uses `-Command', and cmd uses `/c'."
  (let ((type (crush-process--shell-type shell-path)))
    (pcase type
      ((or 'bash 'zsh 'sh 'sh-like)
       (list shell-path (if login "-lc" "-c") command))
      ('powershell
       (append (list shell-path)
               (unless login (list "-NoProfile"))
               (list "-Command" command)))
      ('cmd
       (list shell-path "/c" command)))))

(defun crush-process--spawn (command cwd id &optional shell login)
  "Spawn COMMAND in CWD under the nth session ID.
SHELL is the shell binary to run the command under (nil means
`shell-file-name'); LOGIN requests a login shell.  Returns
(PROCESS . OUTPUT-BUFFER), or nil when the environment fails.  The
command runs with a PTY connection and merged stdout/stderr."
  (let* ((shell-path (or shell shell-file-name))
         (argv (crush-process--shell-args shell-path command login))
         (output-buffer (generate-new-buffer " *crush-session-output*")))
    (with-current-buffer output-buffer
      ;; The child inherits the output buffer's default-directory.
      (setq-local default-directory cwd)
      (let ((proc (make-process
                   :name (format "crush-exec-%d" id)
                   :buffer output-buffer
                   :command argv
                   :connection-type 'pty
                   :noquery t
                   :sentinel #'ignore)))
        (when (processp proc)
          (cons proc output-buffer))))))

(defun crush-process--start (command working-directory owner &optional shell login)
  "Start COMMAND in WORKING-DIRECTORY owned by OWNER.
COMMAND runs under SHELL (nil means `shell-file-name'); a non-nil LOGIN
requests a login shell.  WORKING-DIRECTORY is resolved against
`default-directory'.  OWNER is a buffer scoping cleanup.  Returns the
session, or nil when the cap is hit or the spawn fails."
  (when (>= (hash-table-count crush-process--sessions)
            crush-process-max-sessions)
    (error "crush-process: session cap of %d reached"
           crush-process-max-sessions))
  (let* ((cwd (file-name-as-directory
               (expand-file-name (or working-directory default-directory))))
         (id (crush-process--next-id))
         (spawned (crush-process--spawn command cwd id shell login)))
    (when spawned
      (let* ((proc (car spawned))
             (output-buffer (cdr spawned))
             (session (crush-process--make-session
                       :id id
                       :owner owner
                       :process proc
                       :output-buffer output-buffer
                       :command command
                       :working-directory cwd
                       :last-report (point-min))))
        (crush-process--register session)))))

(defun crush-process--collect (session)
  "Return output produced since SESSION's last report.
Advances the session's last-report offset to the end of the buffer."
  (let ((buffer (crush-process-session-output-buffer session))
        (start (crush-process-session-last-report session)))
    (with-current-buffer buffer
      (let ((end (point-max)))
        (prog1
            (buffer-substring-no-properties start end)
          (setf (crush-process-session-last-report session) end))))))

(defun crush-process--exit-code (session)
  "Return SESSION's process exit code, or nil when still running."
  (let ((proc (crush-process-session-process session)))
    (when (and proc (not (process-live-p proc)))
      (process-exit-status proc))))

(defun crush-process--drain (session deadline)
  "Accept output for SESSION until DEADLINE or process exit.
Flushes a final batch after exit so the last chunk is delivered."
  (let ((proc (crush-process-session-process session)))
    (while (and proc
                (process-live-p proc)
                (< (float-time) deadline))
      (accept-process-output proc 0.05))
    (when proc
      (accept-process-output proc 0.05))
    (not (and proc (process-live-p proc)))))

(defun crush-process--yield (session yield-ms)
  "Wait up to YIELD-MS for SESSION, returning (CHUNK . EXIT-OR-NIL).
The chunk is the output produced since the last report (always returned,
even while the process is still running).  EXIT-OR-NIL is the exit code
once the process finished, or nil while it is still live; the caller
reports a session id when it is nil."
  (let ((deadline (+ (float-time) (/ (float yield-ms) 1000.0)))
        (proc (crush-process-session-process session)))
    (crush-process--drain session deadline)
    (let ((chunk (crush-process--collect session))
          (exit (and proc
                     (not (process-live-p proc))
                     (process-exit-status proc))))
      (cons chunk exit))))

(defun crush-process--write-stdin (session input yield-ms)
  "Write INPUT to SESSION's stdin and read output for YIELD-MS.
Returns (CHUNK . EXIT-OR-NIL), or nil when the process is still running."
  (let ((proc (crush-process-session-process session)))
    (when (and proc
               (process-live-p proc)
               (stringp input)
               (> (length input) 0))
      (process-send-string proc input))
    (crush-process--yield session yield-ms)))

(defun crush-process--kill (session)
  "Stop SESSION's process, free its output buffer, and unregister it."
  (when session
    (crush-process--unregister session)
    (let ((proc (crush-process-session-process session)))
      (when (and proc (process-live-p proc))
        (delete-process proc)))
    (let ((buffer (crush-process-session-output-buffer session)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun crush-process--cleanup-buffer (owner)
  "Kill every session whose owner is OWNER."
  (let ((owned nil))
    (maphash
     (lambda (_id session)
       (when (eq (crush-process-session-owner session) owner)
         (push session owned)))
     crush-process--sessions)
    (dolist (session owned)
      (crush-process--kill session))))

(provide 'crush-process)
;;; crush-process.el ends here
