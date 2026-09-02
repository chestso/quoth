;;; quoth-process.el --- Interactive process sessions for quoth tools  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience
;;; Prefix: quoth-process-

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
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
;;; THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

;;; Commentary:

;; The general-purpose process handler for quoth.el.  Owns interactive
;; process sessions: PTY spawning, output buffering, event-driven exit
;; and running-window reporting, stdin writes, and cleanup.  Model-neutral
;; and buffer-unaware: it never reads the quoth buffer, the provider, or
;; the OpenAI protocol.  The `exec_command' and `write_stdin' tools in
;; `quoth-tools.el' are thin wrappers over this layer.
;;
;; Every wait is an event: exit reports arrive through the process
;; sentinel, running reports through a one-shot window timer, and both
;; deliver exactly once.  A session whose wait was abandoned (no exit
;; handler attached) stays registered when its process exits, so a
;; later `write_stdin' poll can collect the final output — the same
;; semantics as a session that never exited.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function quoth--schedule "quoth" (fn))

(defgroup quoth-process nil
  "Interactive process sessions for quoth tool calls."
  :group 'quoth
  :prefix "quoth-process-")

(defcustom quoth-process-max-sessions 128
  "Maximum number of live process sessions.
Spawning past this cap yields an error result instead of a new process."
  :type 'integer
  :group 'quoth-process)

(defcustom quoth-process-yield-ms 10000
  "Default yield window for `exec_command', in milliseconds.
A command still running after this long reports a session id instead of
an exit code.  Effective range is 250-30000 (clamped)."
  :type 'integer
  :group 'quoth-process)

(defcustom quoth-process-write-yield-ms 1000
  "Default read window for `write_stdin', in milliseconds."
  :type 'integer
  :group 'quoth-process)

(cl-defstruct (quoth-process-session
               (:constructor quoth-process--make-session)
               (:copier nil))
  "A live command session managed by the process handler.
The output buffer is append-only; LAST-REPORT is a character offset into
it marking the start of the as-yet-unreported region.  ON-EXIT is the
exit-report handler attached to the live wait (nil once the wait is
abandoned); WINDOW is the armed running-report timer, or nil."
  id
  owner
  process
  output-buffer
  command
  working-directory
  last-report
  on-exit
  window)

(defvar quoth-process--sessions (make-hash-table :test 'eql)
  "Hash table mapping session ids to `quoth-process-session' structs.")

(defvar quoth-process--counter 0
  "Monotonic counter for session ids.")

(defun quoth-process--next-id ()
  "Return the next session id."
  (setq quoth-process--counter (1+ quoth-process--counter)))

(defun quoth-process--register (session)
  "Record SESSION in the registry."
  (puthash (quoth-process-session-id session) session quoth-process--sessions)
  session)

(defun quoth-process--unregister (session)
  "Remove SESSION from the registry."
  (remhash (quoth-process-session-id session) quoth-process--sessions)
  session)

(defun quoth-process--find (id)
  "Return the session for ID, or nil."
  (gethash id quoth-process--sessions))

(defun quoth-process--shell-type (shell-path)
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

(defun quoth-process--shell-args (shell-path command login)
  "Return the argument vector to run COMMAND under SHELL-PATH.
LOGIN non-nil requests a login shell where the shell supports one.
Mirrors Codex's `derive_exec_args' (shell.rs): bash/zsh/sh use `-c'
\(or `-lc'), powershell uses `-Command', and cmd uses `/c'."
  (let ((type (quoth-process--shell-type shell-path)))
    (pcase type
      ((or 'bash 'zsh 'sh 'sh-like)
       (list shell-path (if login "-lc" "-c") command))
      ('powershell
       (append (list shell-path)
               (unless login (list "-NoProfile"))
               (list "-Command" command)))
      ('cmd
       (list shell-path "/c" command)))))

(defun quoth-process--spawn-env ()
  "Return the `process-environment' for a spawned session.
Disable interactive pagers and git terminal prompts so PTY reads
never block on `Press RETURN to continue', and
set a dumb terminal so columnated tools degrade to plain output."
  (append (list (concat "PAGER=" (or (executable-find "cat") "cat"))
                "GIT_PAGER=cat"
                "GIT_TERMINAL_PROMPT=0"
                "MANPAGER=cat"
                "TERM=dumb")
          process-environment))

(defun quoth-process--spawn (command cwd id &optional shell login)
  "Spawn COMMAND in CWD under the nth session ID.
SHELL is the shell binary to run the command under (nil means
`shell-file-name'); LOGIN requests a login shell.  Returns
\(PROCESS . OUTPUT-BUFFER), or nil when the environment fails.  The
command runs with a PTY connection and merged stdout/stderr under a
sanitized `process-environment'."
  (let* ((shell-path (or shell shell-file-name))
         (argv (quoth-process--shell-args shell-path command login))
         (output-buffer (generate-new-buffer " *quoth-session-output*")))
    (with-current-buffer output-buffer
      ;; The child inherits the output buffer's default-directory.
      (setq-local default-directory cwd)
      (let ((process-environment (quoth-process--spawn-env)))
        (let ((proc (make-process
                     :name (format "quoth-exec-%d" id)
                     :buffer output-buffer
                     :command argv
                     :connection-type 'pty
                     :noquery t
                     :sentinel #'quoth-process--sentinel)))
          (when (processp proc)
            (process-put proc :quoth-session-id id)
            (cons proc output-buffer)))))))

(defun quoth-process--start (command working-directory owner &optional shell login on-exit)
  "Start COMMAND in WORKING-DIRECTORY owned by OWNER.
COMMAND runs under SHELL (nil means `shell-file-name'); a non-nil LOGIN
requests a login shell.  WORKING-DIRECTORY is resolved against
`default-directory'.  OWNER is a buffer scoping cleanup.  ON-EXIT, when
a function, receives the exit report \(CHUNK . EXIT-CODE) exactly once
when the process finishes — delivered on the `quoth--schedule' hop, not
the sentinel stack.  Returns the session, or nil when the cap is hit or
the spawn fails."
  (when (>= (hash-table-count quoth-process--sessions)
            quoth-process-max-sessions)
    (error "quoth-process: Session cap of %d reached"
           quoth-process-max-sessions))
  (let* ((cwd (file-name-as-directory
               (expand-file-name (or working-directory default-directory))))
         (id (quoth-process--next-id))
         (spawned (quoth-process--spawn command cwd id shell login)))
    (when spawned
      (let* ((proc (car spawned))
             (output-buffer (cdr spawned))
             (session (quoth-process--make-session
                       :id id
                       :owner owner
                       :process proc
                       :output-buffer output-buffer
                       :command command
                       :working-directory cwd
                       :last-report (point-min)
                       :on-exit on-exit)))
        (process-put proc :quoth-session session)
        (quoth-process--register session)))))

(defun quoth-process--collect (session)
  "Return output produced since SESSION's last report.
Advances the session's last-report offset to the end of the buffer."
  (let ((buffer (quoth-process-session-output-buffer session))
        (start (quoth-process-session-last-report session)))
    (with-current-buffer buffer
      (let ((end (point-max)))
        (prog1
            (buffer-substring-no-properties start end)
          (setf (quoth-process-session-last-report session) end))))))

(defun quoth-process--collect-final (session)
  "Drain output received but not yet delivered for SESSION.
Runs a single zero-timeout `accept-process-output' poll — the one
permitted blocking-primitive use in the runtime sources — so trailing
PTY output already received by Emacs lands in the session's output
buffer before the final chunk is collected.  Nothing is waited for."
  (let ((proc (quoth-process-session-process session)))
    (when (and (processp proc) (not (process-live-p proc)))
      (accept-process-output proc 0))))

(defun quoth-process--reap (session)
  "Deregister SESSION and free its output buffer.
The session's process has finished; a reported exit has no later use."
  (quoth-process--unregister session)
  (let ((buffer (quoth-process-session-output-buffer session)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun quoth-process--sentinel (proc _event)
  "Sentinel reporting PROC's exit for its session.
Cancels the armed window timer (the sentinel owns exit reports), drains
trailing output, and — while a wait is attached — collects the final
chunk, detaches the handler, deregisters the session, and delivers
\(CHUNK . EXIT-CODE) to the handler on the `quoth--schedule' hop.  With
no wait attached the session stays registered: a later `write_stdin'
poll still finds it and collects the exit output."
  (let ((session (process-get proc :quoth-session)))
    (when (and (quoth-process-session-p session)
               ;; A killed session was already deregistered; its
               ;; handler was detached by the kill.
               (eq (quoth-process--find (quoth-process-session-id session))
                   session))
      (let ((timer (quoth-process-session-window session)))
        (when (timerp timer)
          (cancel-timer timer))
        (setf (quoth-process-session-window session) nil))
      (quoth-process--collect-final session)
      (let ((on-exit (quoth-process-session-on-exit session)))
        (when (functionp on-exit)
          (let ((chunk (quoth-process--collect session))
                (exit (process-exit-status proc)))
            (setf (quoth-process-session-on-exit session) nil)
            (quoth-process--reap session)
            (quoth--schedule (lambda () (funcall on-exit (cons chunk exit))))))))))

(defun quoth-process--arm-window (session ms callback)
  "Arm a one-shot running-report window of MS milliseconds on SESSION.
When the timer fires with the process still live, the output since the
last report is collected and delivered as \(CHUNK . nil) to CALLBACK,
the wait's exit handler is detached (the sentinel will not deliver a
second report), and the session stays registered as a poll target.
When the process already exited the timer no-ops: the sentinel owns the
exit report.  Returns the timer."
  (let ((timer
         (run-at-time
          (/ (float ms) 1000.0) nil
          (lambda ()
            (setf (quoth-process-session-window session) nil)
            (when (process-live-p (quoth-process-session-process session))
              (setf (quoth-process-session-on-exit session) nil)
              (let ((chunk (quoth-process--collect session)))
                (funcall callback (cons chunk nil))))))))
    (setf (quoth-process-session-window session) timer)
    timer))

(defun quoth-process--write-stdin (session input)
  "Write INPUT to SESSION's stdin without waiting.
A literal `\\x04' run in INPUT is sent as a control-D (EOT) to close the
session's stdin, matching the `write_stdin' tool description.  Returns
non-nil when something was sent.  The caller attaches the wait's exit
handler (`quoth-process-session-on-exit') and arms its own read window
\(`quoth-process--arm-window')."
  (let ((proc (quoth-process-session-process session)))
    (when (and proc
               (process-live-p proc)
               (stringp input)
               (> (length input) 0))
      (process-send-string proc (replace-regexp-in-string
                                 "\\\\x04" "\C-d" input t t))
      t)))

(defun quoth-process--kill (session)
  "Stop SESSION's process, free its output buffer, and unregister it.
Detaches the exit handler and cancels the armed window first so the
sentinel cannot deliver to a killed session."
  (when session
    (setf (quoth-process-session-on-exit session) nil)
    (let ((timer (quoth-process-session-window session)))
      (when (timerp timer)
        (cancel-timer timer))
      (setf (quoth-process-session-window session) nil))
    (quoth-process--unregister session)
    (let ((proc (quoth-process-session-process session)))
      (when (and proc (process-live-p proc))
        (delete-process proc)))
    (let ((buffer (quoth-process-session-output-buffer session)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun quoth-process--cleanup-buffer (owner)
  "Kill every session whose owner is OWNER."
  (let ((owned nil))
    (maphash
     (lambda (_id session)
       (when (eq (quoth-process-session-owner session) owner)
         (push session owned)))
     quoth-process--sessions)
    (dolist (session owned)
      (quoth-process--kill session))))

(provide 'quoth-process)
;;; quoth-process.el ends here
