;;; quoth-test-process.el --- Process-handler tests for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience

;;; This file is not part of GNU Emacs.

;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;; of this software and associated documentation files (the "Software"), to deal
;;; in the Software without restriction, including without limitation the
;;; rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
;;; sell copies of the Software, and to permit persons to whom the Software is
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
;;; Tests for `quoth-process.el': the session registry, PTY process
;;; spawning, the event-driven exit/window reporting (sentinel +
;;; one-shot window timers), stdin writes, and cleanup.  Exit reports
;;; arrive through the sentinel; running reports through the window
;;; timer; both deliver exactly once.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth" "quoth-process"))
    (unless (require (intern dep) nil t)
      (let* ((base (file-name-directory
                    (or buffer-file-name load-file-name default-directory)))
             (dirs (list base (expand-file-name ".." base)))
             (loaded nil))
        (dolist (dir dirs)
          (unless loaded
            (let ((file (expand-file-name (concat dep ".el") dir)))
              (when (file-exists-p file)
                (load file nil t)
                (setq loaded t)))))))))

(defun quoth-test-process--owner ()
  "Return a throwaway buffer to use as a session owner."
  (generate-new-buffer " *quoth-process-owner*"))

(defun quoth-test-process--cleanup-owner (owner)
  "Kill OWNER and any sessions it owns."
  (quoth-process--cleanup-buffer owner)
  (when (buffer-live-p owner)
    (kill-buffer owner)))

(defun quoth-test--wait-until (pred &optional timeout)
  "Spin accepting process output until PRED is non-nil.
TIMEOUT defaults to 5 seconds.  `accept-process-output' both pumps
real children and lets pending zero-timeout timers (the
`quoth--schedule' hop, window timers) run, so this drives the whole
event chain deterministically.  Returns PRED's final value."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defun quoth-test--pump ()
  "Pump one event round: a single 50ms `accept-process-output'.
Drains anything already pending (the `quoth--schedule' hop, a fired
window timer, a deleted process's sentinel) so a negative assertion —
nothing else delivers — holds after one pump without a wall-clock
wait."
  (accept-process-output nil 0.05))

(defun quoth-test-process--reporter ()
  "Return (REPORT . DELIVERED) for capturing on-exit / window reports.
REPORT is a function of one argument (the delivered value); DELIVERED
returns the list of delivered values, most recent first."
  (let ((delivered nil))
    (cons (lambda (value) (push value delivered))
          (lambda () (nreverse delivered)))))

;;; 1. Session registry

(ert-deftest quoth-test-process/registry-starts-empty ()
  "The session registry is empty at load time."
  (should (boundp 'quoth-process--sessions))
  (should (hash-table-p quoth-process--sessions))
  (should (integerp quoth-process--counter)))

(ert-deftest quoth-test-process/sessions-get-monotonic-ids ()
  "Session ids come from a monotonic counter and are unique."
  (let ((owner (quoth-test-process--owner))
        (a nil)
        (b nil))
    (unwind-protect
        (progn
          (setq a (quoth-process--start "true" nil owner)
                b (quoth-process--start "true" nil owner))
          (should (integerp (quoth-process-session-id a)))
          (should (integerp (quoth-process-session-id b)))
          (should-not (= (quoth-process-session-id a)
                         (quoth-process-session-id b))))
      (quoth-process--kill a)
      (quoth-process--kill b)
      (quoth-test-process--cleanup-owner owner))))

;;; 2. Shell selection

(ert-deftest quoth-test-process/shell-type-detects-common-shells ()
  "`quoth-process--shell-type' maps binary names to their shell type."
  (should (eq (quoth-process--shell-type "bash") 'bash))
  (should (eq (quoth-process--shell-type "/bin/bash") 'bash))
  (should (eq (quoth-process--shell-type "zsh") 'zsh))
  (should (eq (quoth-process--shell-type "sh") 'sh))
  (should (eq (quoth-process--shell-type "cmd") 'cmd))
  (should (eq (quoth-process--shell-type "cmd.exe") 'cmd))
  (should (eq (quoth-process--shell-type "powershell") 'powershell))
  (should (eq (quoth-process--shell-type "pwsh") 'powershell))
  (should (eq (quoth-process--shell-type "dash") 'sh-like)))

(ert-deftest quoth-test-process/shell-args-posix-and-login ()
  "POSIX-style shells use `-c', or `-lc' with a login request."
  (should (equal (quoth-process--shell-args "/bin/bash" "echo hi" nil)
                 '("/bin/bash" "-c" "echo hi")))
  (should (equal (quoth-process--shell-args "/bin/bash" "echo hi" t)
                 '("/bin/bash" "-lc" "echo hi")))
  (should (equal (quoth-process--shell-args "zsh" "echo hi" nil)
                 '("zsh" "-c" "echo hi"))))

(ert-deftest quoth-test-process/shell-args-powershell-and-cmd ()
  "PowerShell uses `-Command'; cmd uses `/c'."
  (should (equal (quoth-process--shell-args "powershell" "Get-Location" nil)
                 '("powershell" "-NoProfile" "-Command" "Get-Location")))
  (should (equal (quoth-process--shell-args "cmd" "dir" nil)
                 '("cmd" "/c" "dir"))))

;;; 3. Exit reporting: the sentinel

(ert-deftest quoth-test-process/sentinel-delivers-exit-once ()
  "A started session reports (CHUNK . EXIT) through its on-exit handler.
The exit report arrives exactly once, carries the full output and the
exit code, and deregisters the session (a reported exit has no later
use)."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start
                         "printf \"line1\\nline2\""
                         nil owner nil nil (car report)))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (let ((delivered (funcall (cdr report))))
            (should (= (length delivered) 1))
            (should (string-match-p "line1" (caar delivered)))
            (should (string-match-p "line2" (caar delivered)))
            (should (= (cdar delivered) 0)))
          (should-not (quoth-process--find
                       (quoth-process-session-id session))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/sentinel-delivers-nonzero-exit ()
  "A failing command reports its real exit code."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "exit 3" nil owner
                                              nil nil (car report)))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (should (= (cdar (funcall (cdr report))) 3)))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/sentinel-delivers-via-schedule-hop ()
  "The exit report rides the `quoth--schedule' hop, not the sentinel stack.
With the hop faked onto a queue, the on-exit handler runs only when
the queue is drained."
  (let ((owner (quoth-test-process--owner))
        (queue nil)
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'quoth--schedule)
                     (lambda (fn) (push fn queue) nil)))
            (setq session (quoth-process--start "echo hi" nil owner
                                                nil nil (car report)))
            (should (quoth-test--wait-until
                     (lambda () queue)))
            (should-not (funcall (cdr report)))
            (dolist (fn (nreverse queue))
              (funcall fn))
            (setq queue nil))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (should (string-match-p "hi" (caar (funcall (cdr report))))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/sentinel-collects-trailing-output ()
  "Output produced right before exit is part of the exit chunk.
The sentinel's zero-timeout poll drains output already received but
not yet delivered, so a fast-exiting command's whole output arrives."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start
                         "echo trailing-output-marker"
                         nil owner nil nil (car report)))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (should (string-match-p
                   "trailing-output-marker"
                   (caar (funcall (cdr report))))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/background-exit-keeps-session-registered ()
  "A session whose wait was abandoned (no on-exit) stays registered.
Its exit output stays unreported so a later `write_stdin' poll can
collect it, and the exit delivers nothing."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "echo done" nil owner
                                              nil nil (car report)))
          ;; Abandon the wait before the process exits.
          (setf (quoth-process-session-on-exit session) nil)
          (should (quoth-test--wait-until
                   (lambda ()
                     (not (process-live-p
                           (quoth-process-session-process session))))))
          ;; Let any (wrongly armed) delivery run: one pump drains
          ;; the schedule hop, and nothing reports.
          (quoth-test--pump)
          (should-not (funcall (cdr report)))
          ;; Still registered for a later poll.
          (should (quoth-process--find (quoth-process-session-id session))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

;;; 4. Running reports: the window timer

(ert-deftest quoth-test-process/window-reports-running ()
  "The window timer reports (CHUNK . nil) while the process is live.
The on-exit handler is detached by the report (the sentinel will not
fire a second delivery), and the session stays registered."
  (let ((owner (quoth-test-process--owner))
        (window-report (quoth-test-process--reporter))
        (exit-report (quoth-test-process--reporter))
        (session nil)
        (timer nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "sleep 5" nil owner
                                              nil nil (car exit-report)))
          ;; A short window through the real arming path; `sleep 5'
          ;; deterministically outlives it.
          (setq timer (quoth-process--arm-window session 10 (car window-report)))
          (should (timerp timer))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr window-report)))
                   2))
          (let ((delivered (funcall (cdr window-report))))
            (should (= (length delivered) 1))
            (should (stringp (caar delivered)))
            (should (null (cdar delivered))))
          ;; The wait is over: the exit handler is detached.
          (should (null (quoth-process-session-on-exit session)))
          ;; The session is still live and registered.
          (should (process-live-p (quoth-process-session-process session)))
          (should (quoth-process--find (quoth-process-session-id session))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/window-noops-when-process-exited ()
  "A window firing after the process exited delivers nothing.
The sentinel owns the exit report; the window timer no-ops on the
liveness check, so the round reports exactly once."
  (let ((owner (quoth-test-process--owner))
        (window-report (quoth-test-process--reporter))
        (exit-report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "true" nil owner
                                              nil nil (car exit-report)))
          ;; Let the process exit and the sentinel deliver first.
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr exit-report)))))
          (quoth-process--arm-window session 10 (car window-report))
          ;; The window fires with the process dead: one pump runs it,
          ;; and it no-ops (the sentinel owns the exit report).
          (quoth-test--pump)
          (should (null (funcall (cdr window-report))))
          (should (= (length (funcall (cdr exit-report))) 1)))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/window-cancel-detaches-exit-report ()
  "A session whose window timer is cancelled reports nothing on exit.
Cancelling the wait abandons it without killing the session; the
detached exit handler delivers nothing when the process later ends.
The session stays registered so a later `write_stdin' poll can
collect the exit output."
  (let ((owner (quoth-test-process--owner))
        (window-report (quoth-test-process--reporter))
        (exit-report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "sleep 5" nil owner
                                              nil nil (car exit-report)))
          (let ((timer (quoth-process--arm-window session 10000
                                                  (car window-report))))
            (cancel-timer timer))
          ;; Abandon the wait: detach the exit handler.
          (setf (quoth-process-session-on-exit session) nil)
          ;; End the process (a session kill would deregister it, which
          ;; this test must not do): the sentinel runs on the next pump
          ;; and no-ops — the wait was abandoned, so nothing reports.
          (delete-process (quoth-process-session-process session))
          (quoth-test--pump)
          (should-not (funcall (cdr window-report)))
          (should-not (funcall (cdr exit-report)))
          ;; Still registered: a later poll can collect the output.
          (should (quoth-process--find (quoth-process-session-id session))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

;;; 5. Stdin writes

(ert-deftest quoth-test-process/write-stdin-sends-without-waiting ()
  "A stdin write delivers the string to a reading process immediately.
The write returns without waiting; the reply arrives through the armed
window / exit reporting."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "read line; echo got:$line"
                                              nil owner))
          (setf (quoth-process-session-on-exit session) (car report))
          (should (quoth-process--write-stdin session "hello\n"))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (let ((delivered (funcall (cdr report))))
            (should (= (length delivered) 1))
            (should (string-match-p "got:hello" (caar delivered)))
            (should (= (cdar delivered) 0))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/write-stdin-trailing-eot-closes-stdin ()
  "A trailing \\x04 marker sends the body then delivers real EOF.
`cat' under a PTY exits only when it reads EOF, so a completed exit
report with the full body proves the stdin actually closed — via
`process-send-eof', which works over both PTY and pipe connections."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "cat; echo RC=$?" nil owner))
          (setf (quoth-process-session-on-exit session) (car report))
          (should (quoth-process--write-stdin session "payload\\x04"))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (let ((delivered (funcall (cdr report))))
            (should (= (length delivered) 1))
            ;; The PTY echoes the payload back; cat copies it; the
            ;; marker itself never travels as a byte.
            (should (string-match-p "payload" (caar delivered)))
            (should (string-match-p "RC=0" (caar delivered)))
            (should (= (cdar delivered) 0))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/write-stdin-closed-rejects-further-writes ()
  "After \\x04 closes stdin, further writes are refused without sending.
The EOF marker latches: a second write returns nil and delivers
nothing, so the child's stdin stays closed."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "cat; echo RC=$?" nil owner))
          (setf (quoth-process-session-on-exit session) (car report))
          (should (quoth-process--write-stdin session "one\\x04"))
          ;; Process still live right after EOF: the second write is
          ;; refused (nil) while the process is still running.
          (should-not (quoth-process--write-stdin session "two"))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (let ((delivered (funcall (cdr report))))
            (should (= (length delivered) 1))
            ;; 'two' never arrived: cat saw only 'one' before EOF.
            (should (string-match-p "one" (caar delivered)))
            (should-not (string-match-p "two" (caar delivered)))
            (should (= (cdar delivered) 0))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/write-stdin-dead-session-still-collects ()
  "A write to a self-exited background session reports its final output.
The session stays registered after its wait was abandoned; the poll
collects the exit chunk and exit code without waiting."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "echo final" nil owner
                                              nil nil (car report)))
          (setf (quoth-process-session-on-exit session) nil)
          (should (quoth-test--wait-until
                   (lambda ()
                     (not (process-live-p
                           (quoth-process-session-process session))))))
          ;; The caller-side dead-session poll: collect directly.
          (let ((chunk (quoth-process--collect session))
                (exit (process-exit-status
                       (quoth-process-session-process session))))
            (should (string-match-p "final" chunk))
            (should (= exit 0))
            (funcall (car report) (cons chunk exit))
            (quoth-process--kill session)))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

;;; 6. Spawn environment

(ert-deftest quoth-test-process/spawn-env-reaches-child ()
  "The sanitized environment reaches the child.
Pagers off, NO_COLOR, TERM=dumb: the child process is spawned with the
sanitized `process-environment' already in effect."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start
                         "echo PAGER=[$PAGER] GIT_PAGER=[$GIT_PAGER] NO_COLOR=[$NO_COLOR] TERM=[$TERM]"
                         nil owner nil nil (car report)))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (let ((output (caar (funcall (cdr report)))))
            (should (string-search "PAGER=[" output))
            (should-not (string-search "PAGER=[]" output))
            (should (string-search "GIT_PAGER=[cat]" output))
            (should (string-search "NO_COLOR=[1]" output))
            (should (string-search "TERM=[dumb]" output))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

;;; 7. Cleanup

(ert-deftest quoth-test-process/cleanup-buffer-kills-owned-sessions ()
  "Cleanup kills every session owned by a buffer."
  (let ((owner (quoth-test-process--owner))
        (other (quoth-test-process--owner))
        (a nil)
        (b nil)
        (c nil))
    (unwind-protect
        (progn
          (setq a (quoth-process--start "sleep 30" nil owner)
                b (quoth-process--start "sleep 30" nil owner)
                c (quoth-process--start "sleep 30" nil other))
          (let ((id-a (quoth-process-session-id a))
                (id-b (quoth-process-session-id b))
                (id-c (quoth-process-session-id c)))
            (quoth-process--cleanup-buffer owner)
            (should-not (gethash id-a quoth-process--sessions))
            (should-not (gethash id-b quoth-process--sessions))
            (should (gethash id-c quoth-process--sessions))))
      (when c (quoth-process--kill c))
      (quoth-test-process--cleanup-owner owner)
      (quoth-test-process--cleanup-owner other))))

(ert-deftest quoth-test-process/kill-unregisters-session ()
  "Kill removes the session from the registry and stops the process."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "sleep 30" nil owner))
          (let ((id (quoth-process-session-id session)))
            (quoth-process--kill session)
            (should-not (gethash id quoth-process--sessions))
            (should-not (process-live-p (quoth-process-session-process session)))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/kill-detaches-exit-report ()
  "Killing a session delivers nothing to its exit handler.
The kill detaches the handler before the sentinel can observe the
deleted process."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "sleep 5" nil owner
                                              nil nil (car report)))
          (quoth-process--kill session)
          ;; The kill deleted the process: one pump runs its sentinel,
          ;; which no-ops for the killed (deregistered) session.
          (quoth-test--pump)
          (should-not (funcall (cdr report))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/kill-frees-output-buffer ()
  "Kill frees the session's output buffer."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "sleep 30" nil owner))
          (let ((buffer (quoth-process-session-output-buffer session)))
            (should (buffer-live-p buffer))
            (quoth-process--kill session)
            (should-not (buffer-live-p buffer))))
      (when session (quoth-process--kill session))
      (quoth-test-process--cleanup-owner owner))))


;;; 9. PTY output rendering

(ert-deftest quoth-test-process/render-spinner-collapses-to-last-frame ()
  "Carriage-returned spinner frames collapse to the final frame."
  (should (equal (quoth-process--render "\u284b\r\u2859\r\u28b9\n")
                 "\u28b9\n")))

(ert-deftest quoth-test-process/render-carriage-return-keeps-tail ()
  "A CR overwrite replaces only the re-written prefix; the tail stays."
  (should (equal (quoth-process--render "abcdef\rXY\n") "XYcdef\n")))

(ert-deftest quoth-test-process/render-backspace-counter ()
  "Backspace-driven counters update in place."
  (should (equal (quoth-process--render "10%\b\b\b20%\n") "20%\n")))

(ert-deftest quoth-test-process/render-erase-line-redraw ()
  "`ESC [ 2 K' erases the line, leaving only what follows."
  (should (equal (quoth-process--render "\e[2Kdone\n") "done\n")))

(ert-deftest quoth-test-process/render-sgr-color-stripped ()
  "SGR color sequences are dropped; the visible text stays."
  (should (equal (quoth-process--render "\e[32mok\e[0m\n") "ok\n")))

(ert-deftest quoth-test-process/render-osc-dropped ()
  "OSC title writes (BEL-terminated) are dropped entirely."
  (should (equal (quoth-process--render "\e]0;title\aecho hi\n")
                 "echo hi\n")))

(ert-deftest quoth-test-process/render-osc-st-terminated ()
  "OSC writes terminated by `ESC \\` are dropped too."
  (should (equal (quoth-process--render "\e]0;t\e\\x\n") "x\n")))

(ert-deftest quoth-test-process/render-crlf-renders-as-lf ()
  "A CR before LF is a plain end-of-line artifact and renders away.
CRLF output reads as plain LF lines to the model."
  (should (equal (quoth-process--render "a\r\nb\r\n") "a\nb\n")))

(ert-deftest quoth-test-process/render-plain-text-untouched ()
  "Text without control bytes passes through unchanged.
Newlines and multibyte characters survive too."
  (should (equal (quoth-process--render "plain\u4e2d text\nmore\n")
                 "plain\u4e2d text\nmore\n")))

(ert-deftest quoth-test-process/render-tabs-expand ()
  "Tabs pad to the next 8-column stop."
  (should (equal (quoth-process--render "a\tb\n") "a       b\n")))

(ert-deftest quoth-test-process/render-cursor-moves ()
  "CUF/CUB/CHA move the cursor within the line; CUP row 1 acts as CR."
  (should (equal (quoth-process--render "ab\e[3Cz\n") "ab   z\n"))
  (should (equal (quoth-process--render "abcde\e[2DX\n") "abcXe\n"))
  (should (equal (quoth-process--render "\e[10Gend\n") "         end\n"))
  (should (equal (quoth-process--render "x\e[1;5Hy\n") "xy\n")))

(ert-deftest quoth-test-process/render-cup-deeper-row-drops ()
  "A CUP to a row below the first collapses into this line.
The one-line model applies; the cursor stays put."
  (should (equal (quoth-process--render "x\e[2;5Hy\n") "xy\n")))

(ert-deftest quoth-test-process/render-unterminated-csi-drops-line-rest ()
  "A CSI sequence unterminated at end of chunk drops the rest of the line.
It is a mid-frame artifact, and dropping it is the desired outcome."
  (should (equal (quoth-process--render "ok\e[2") "ok")))

(ert-deftest quoth-test-process/render-partial-trailing-line-kept ()
  "A trailing partial line (no final newline) renders too.
The chunk splitting on LF keeps its structure."
  (should (equal (quoth-process--render "abc\rd") "dbc")))

(ert-deftest quoth-test-process/render-chunk-split-on-line-boundary ()
  "Splitting a chunk at a line boundary renders identically to the whole.
Rendering is per line, and the join preserves structure."
  (let ((whole "resolving...\r100% done\nnext\n"))
    (should (equal (quoth-process--render whole)
                   (concat (quoth-process--render "resolving...\r100% done\n")
                           (quoth-process--render "next\n"))))))

(ert-deftest quoth-test-process/render-off-passthrough ()
  "With `quoth-process-render-output' nil, collect returns raw bytes."
  (let ((owner (quoth-test-process--owner))
        (session nil))
    (unwind-protect
        (progn
          ;; The toggle is checked at collect time, in the sentinel —
          ;; so the binding must cover the whole wait, not just the
          ;; start.
          (let* ((report (quoth-test-process--reporter))
                 (quoth-process-render-output nil))
            (setq session (quoth-process--start "printf 'a\\rXY'"
                                                nil owner nil nil (car report)))
            (should (quoth-test--wait-until
                     (lambda () (funcall (cdr report)))))
            (should (equal (caar (funcall (cdr report))) "a\rXY")))
          ;; On by default: the same command's raw bytes render.
          (let ((report (quoth-test-process--reporter)))
            (setq session (quoth-process--start "printf 'a\\rXY'"
                                                nil owner nil nil (car report)))
            (should (quoth-test--wait-until
                     (lambda () (funcall (cdr report)))))
            (should (equal (caar (funcall (cdr report))) "XY"))))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(ert-deftest quoth-test-process/render-real-process-round-trip ()
  "A real PTY session's exit report carries rendered output.
The CR overwrite and the erase-line sequence are applied; the raw
frame history is not."
  (let ((owner (quoth-test-process--owner))
        (report (quoth-test-process--reporter))
        (session nil))
    (unwind-protect
        (progn
          (setq session (quoth-process--start "printf 'a\\rXY\\033[2Kdone'"
                                              nil owner nil nil (car report)))
          (should (quoth-test--wait-until
                   (lambda () (funcall (cdr report)))))
          (should (equal (caar (funcall (cdr report))) "XYdone"))
          (should (equal (cdar (funcall (cdr report))) 0)))
      (quoth-process--kill session)
      (quoth-test-process--cleanup-owner owner))))

(provide 'quoth-test-process)
;;; quoth-test-process.el ends here
