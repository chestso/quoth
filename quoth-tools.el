;;; quoth-tools.el --- Local tool implementations for quoth  -*- lexical-binding: t; -*-
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

;; Local tool implementations for quoth.el: `exec_command',
;; `write_stdin', `write_file', and `read_file'.  The first two are thin
;; wrappers over the general-purpose process handler in
;; `quoth-process.el': `exec_command' starts a session and yields,
;; `write_stdin' feeds input to a live session.  Results use Codex's
;; prose status convention (`Process exited with code N' / `Process
;; running with session ID N' + `Output:') so models read them
;; naturally and echo the session id back verbatim.  The latter two do
;; byte-exact file I/O: `write_file' writes `content' to `path'
;; (atomic on a fresh file, byte-exact line endings, optional `mode'
;; permission bits applied after the write) and `read_file'
;; reads a file back byte-exact, erroring on non-UTF-8 content.
;; `read_file' additionally takes three shape args: `line_numbers'
;; (default off) prefixes each line with its 1-based true number in
;; `cat -n' style; `offset' (1-based) and `limit' window the read;
;; both error on non-positive values and clamp past EOF silently.
;; Oversized reads are truncated line-aware and head-only: a marker
;; names the dropped lines and the `offset' that fetches them.
;;
;; The tool *protocol* (the `quoth-openai-tool-call' struct, registry,
;; dispatch, arg parsing, and the execution policy) lives in
;; `quoth-openai.el'; this file implements the concrete tools and
;; registers them into `quoth-openai-tool-registry' at load time.
;; Entries report to ON-DONE exactly once: `exec_command' and
;; `write_stdin' through the event-driven session layer (window timer
;; for running reports, sentinel for exit reports), `read_file' and
;; `write_file' inline.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
;;; flycheck's emacs-lisp checker byte-compiles each file in isolation,
;;; and its batch child's `load-path' excludes the package directory.
;;; Prefer `require'; fall back to loading the sibling from this file's
;;; own directory so both flycheck and package-installed loads work.
(eval-and-compile
  (dolist (dep '("quoth-json" "quoth-provider" "quoth-openai" "quoth-process"))
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
  "Byte budget for a tool result body.
`read_file' spends it on whole rendered lines, head first: when the
read exceeds the budget, the head is reported and a marker names the
dropped lines and the offset that fetches them.  `exec_command' and
`write_stdin' currently keep a 70/30 head/tail split with a byte
omission marker."
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
(declare-function quoth-process--start "quoth-process" (command working-directory owner &optional shell login on-exit))
(declare-function quoth-process--arm-window "quoth-process" (session ms callback))
(declare-function quoth-process--write-stdin "quoth-process" (session input))
(declare-function quoth-process--find "quoth-process" (id))
(declare-function quoth-process--kill "quoth-process" (session))
(declare-function quoth-process--cleanup-buffer "quoth-process" (owner))
(declare-function quoth-process-session-on-exit "quoth-process" (session))

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

(defun quoth-exec--abandon (session timer)
  "Return the cancel thunk for the live process wait on SESSION.
TIMER is the armed window timer.  Cancels it and detaches the session's exit
handler, so the abandoned wait reports no more.  The session itself
keeps running: its id was already reported to the model in the block
text, so a later prompt can `write_stdin' to it; sessions are reaped
by clear/kill."
  (lambda ()
    (when (timerp timer)
      (cancel-timer timer))
    (when (quoth-process-session-p session)
      (setf (quoth-process-session-on-exit session) nil))))

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

(defun quoth-exec-command--exec (tool-call on-done)
  "Execute TOOL-CALL as `exec_command', reporting to ON-DONE once.
Runs the parsed `cmd' arg in a new `quoth-process' session and arms a
running-report window for the resolved `yield_time_ms' (default
`quoth-process-yield-ms').  ON-DONE receives (RESULT . EXIT-OR-NIL): a
finished command reports `Process exited with code N' through the
session sentinel; a still-running one reports `Process running with
session ID N' through the window timer, with a nil exit.  A missing/empty
`cmd', a session-cap overflow, or a spawn failure delivers an error
result immediately.  Returns a cancel thunk that abandons the wait
without killing the session."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (cmd (quoth-exec--cmd args)))
    (if (not cmd)
        (progn
          (funcall on-done (quoth-openai-tool-error-result "Missing cmd"))
          nil)
      (condition-case err
          (let* ((working-dir (or (plist-get args :workdir) default-directory))
                 (yield-ms (quoth-exec--yield-ms args quoth-process-yield-ms))
                 (shell (quoth-exec--shell args))
                 (login (quoth-exec--login args))
                 (session (quoth-process--start
                           cmd working-dir
                           (or quoth-tool--owner (current-buffer))
                           shell login
                           (lambda (result)
                             (funcall on-done
                                      (cons (quoth-exec--format-result
                                             (car result) (cdr result))
                                            (cdr result)))))))
            (if (not (quoth-process-session-p session))
                ;; Spawn failed without signalling.
                (progn
                  (funcall on-done
                           (quoth-openai-tool-error-result
                            "Failed to start command"))
                  nil)
              (let ((timer
                     (quoth-process--arm-window
                      session yield-ms
                      (lambda (result)
                        (funcall on-done
                                 (cons (quoth-exec--format-running
                                        (car result)
                                        (quoth-process-session-id session))
                                       nil))))))
                (quoth-exec--abandon session timer))))
        (error
         (funcall on-done (quoth-openai-tool-error-result
                           (error-message-string err)))
         nil)))))

(defun quoth-exec--validate-stdin-input (input)
  "Return INPUT when its \\x04 markers are well-formed, else nil.
The close-stdin marker may appear only at the very end of INPUT: an
interior \\x04 would be delivered as literal data after a truncated
write, so it is rejected.  An absent or short INPUT (four characters
or fewer) is always well-formed."
  (if (and (stringp input)
           (> (length input) 4)
           (string-match-p "\\\\x04" (substring input 0 -4)))
      nil
    input))

(defun quoth-write-stdin--exec (tool-call on-done)
  "Execute TOOL-CALL as `write_stdin', reporting to ON-DONE once.
Looks up the `session_id' arg, writes optional `input' to the session's
stdin, and arms a read window (default `quoth-process-write-yield-ms`)
for the output produced since the last report.  A trailing \\x04 in
`input' closes the session's stdin (via `process-send-eof'); an
interior \\x04 delivers an error result instead of a truncated write.
ON-DONE receives
RESULT as (RESULT . EXIT-OR-NIL): a live session reports `Process running with
session ID N' through the window timer; a session that finishes reports
`Process exited with code N' through the sentinel and is deregistered.
A session whose process already exited reports its final output
immediately, without waiting.  An unknown session id delivers an error
result.  Returns a cancel thunk that abandons the wait without killing
the session."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (session-id (plist-get args :session_id))
         (session (and (integerp session-id)
                       (quoth-process--find session-id))))
    (cond
     ((not (quoth-process-session-p session))
      (funcall on-done (quoth-openai-tool-error-result
                        (format "unknown session id %S" session-id)))
      nil)
     ((and (stringp (plist-get args :input))
           (not (quoth-exec--validate-stdin-input (plist-get args :input))))
      (funcall on-done (quoth-openai-tool-error-result
                        "input may contain \\x04 only at the end (it closes stdin)"))
      nil)
     ;; A background session whose process exited on its own reports
     ;; its final output now, without arming a wait.
     ((not (process-live-p (quoth-process-session-process session)))
      (let* ((chunk (quoth-process--collect session))
             (exit (process-exit-status
                    (quoth-process-session-process session))))
        (quoth-process--kill session)
        (funcall on-done
                 (cons (quoth-exec--format-result chunk exit) exit))
        nil))
     (t
      (let ((yield-ms (quoth-exec--yield-ms args quoth-process-write-yield-ms)))
        (setf (quoth-process-session-on-exit session)
              (lambda (result)
                (funcall on-done
                         (cons (quoth-exec--format-result
                                (car result) (cdr result))
                               (cdr result)))))
        (quoth-process--write-stdin
         session (or (plist-get args :input) ""))
        (let ((timer
               (quoth-process--arm-window
                session yield-ms
                (lambda (result)
                  (funcall on-done
                           (cons (quoth-exec--format-running
                                  (car result)
                                  (quoth-process-session-id session))
                                 nil))))))
          (quoth-exec--abandon session timer)))))))

;;; 5. read_file and write_file

(defun quoth-file--resolve-path (tool-call-args)
  "Return the absolute target path from TOOL-CALL-ARGS, or nil.
Resolves the `path' arg against `workdir' (or `default-directory') and
expands a leading tilde.  Returns nil when `path' is missing, not a
string, or empty after trim."
  (let* ((path (plist-get tool-call-args :path))
         (base (or (plist-get tool-call-args :workdir) default-directory)))
    (and (stringp path)
         (not (string-empty-p (string-trim path)))
         (expand-file-name (string-trim path) (expand-file-name base)))))

(defun quoth-file--read-bytes (path)
  "Return the raw bytes of the file at PATH as a unibyte string.
Reads into a unibyte temp buffer with `coding-system-for-read' bound to
`binary', so no newline translation or charset conversion happens on the
way in and each byte is a plain 0-255 value; the caller re-decodes these
bytes as text.  This keeps the read byte-exact."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (insert-file-contents path))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun quoth-file--write-mode (args)
  "Return the validated `mode' permission bits from ARGS, or nil.
MODE is an integer 0..4095 (the full POSIX permission set: setuid,
setgid, sticky, and rwxrwxrwx).  Absent returns nil; a present but
non-integer or out-of-range value errors with a message naming the
offending argument."
  (let ((raw (plist-get args :mode)))
    (when raw
      (unless (and (integerp raw) (>= raw 0) (<= raw 4095))
        (error "Mode must be a decimal integer 0-4095 (POSIX permission bits; 420 = 0644, 493 = 0755), got %S"
               raw))
      raw)))

(defun quoth-write-file--exec (tool-call on-done)
  "Execute TOOL-CALL as `write_file', reporting to ON-DONE inline.
Writes the parsed `content' arg byte-exact to `path', creating missing
parent directories and replacing an existing file unless `overwrite' is
false.  Fresh-file writes go through a temp file + rename so a reader
never observes a half-written file; overwriting an existing target
falls back to a direct write (rename cannot replace an existing file on
Windows).  A `mode' arg (POSIX permission bits) is applied to the file
after the write, on both paths.  A missing `path' or `content' delivers
an error result immediately.  An immediate tool: returns nil (no cancel
thunk)."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (path (quoth-file--resolve-path args))
         (content (plist-get args :content)))
    (cond
     ((not path)
      (funcall on-done (quoth-openai-tool-error-result
                        "Missing or empty path"))
      nil)
     ((not (stringp content))
      (funcall on-done (quoth-openai-tool-error-result
                        "Missing or empty content"))
      nil)
     (t
      (condition-case err
          (let* ((overwrite (not (eq (plist-get args :overwrite) :json-false)))
                 (mode (quoth-file--write-mode args))
                 (dir (file-name-directory path)))
            (when (and (not overwrite) (file-exists-p path))
              (error "File exists: %s" path))
            ;; Create parent directories, ignoring failure when present.
            (make-directory dir t)
            ;; `utf-8-unix' pins the write coding so the write stays
            ;; byte-exact for text.  Content always arrives as a multibyte
            ;; string (decoded from JSON) whose line endings were preserved
            ;; by `quoth-file--read-content'; a `\r\n' on disk is a CR and
            ;; an LF character in that string.  Writing under the `unix'
            ;; EOL is the identity: `\n' -> LF and `\r' is left untouched,
            ;; so a byte-exact round trip survives.  A bare `utf-8' or a
            ;; platform-default EOL could translate `\n' to `\r\n' (or
            ;; vice versa) and corrupt the file.
            (let ((coding-system-for-write 'utf-8-unix))
              (if (file-exists-p path)
                  ;; Overwrite: rename-file cannot replace on all
                  ;; platforms, so write directly.  Atomicity is a bonus
                  ;; here, not the requirement byte-exactness is.
                  (write-region content nil path)
                ;; Fresh file: write a temp sibling, then atomically
                ;; rename it into place.
                (let ((tmp (make-temp-file
                            (concat (file-name-directory path)
                                    (file-name-nondirectory path) ".tmp"))))
                  (unwind-protect
                      (progn
                        (write-region content nil tmp)
                        (rename-file tmp path))
                    (when (file-exists-p tmp)
                      (ignore-errors (delete-file tmp)))))))
            ;; Chmod after the write so both the fresh-file (temp +
            ;; rename, created 0600) and overwrite paths end up with
            ;; the requested bits; set-file-modes ignores umask.
            (when mode
              (set-file-modes path mode))
            (let ((text (quoth-exec--format-result
                         (format "Wrote %s" path) 0)))
              (funcall on-done (cons text 0))
              nil))
        (error
         (funcall on-done (quoth-openai-tool-error-result
                           (error-message-string err)))
         nil))))))

;;; Line-aware read helpers for `read_file'.

;; Text coming back from `quoth-file--read-content' is a multibyte
;; string with line terminators preserved byte-exact (LF, CRLF, and
;; pathological CR-only all possible; CR is content here, never a
;; terminator).  The helpers below split on LF only, the way cat(1)
;; splits, so CRLF's CR stays glued to its content line: the
;; un-numbered read stays byte-exact over CRLF, and the numbered
;; prefix lands before the CR, never on it.

(defun quoth-file--lines (text)
  "Return the LF-split lines of TEXT, one string per line.
The file's final LF (when present) does not produce a trailing
empty line.  Interior empty lines are kept: an empty line is a real
line, `cat -n' numbers it, and dropping one would shift every
following number.  Empty input produces nil."
  (let ((n (length text)))
    (if (= n 0)
        nil
      (split-string
       (if (= (aref text (1- n)) ?\n)
           (substring text 0 (1- n))
         text)
       "\n"))))

(defun quoth-file--number-prefix (n)
  "Return the `cat -n' prefix for line number N.
A right-aligned 6-character field, then a TAB; the fixed width
keeps prefix overhead predictable on large files and the format
knowable before the first response."
  (format "%6d\t" n))

(defun quoth-file--numbered-line (n line)
  "Return the rendered numbered line for LINE content at number N.
The prefix carries the line's true file number; a CRLF file's CR
stays inside LINE right after the TAB, never re-cooked."
  (concat (quoth-file--number-prefix n) line "\n"))

(defun quoth-file--apply-line-numbers (lines starting-at)
  "Return the numbered rendering of LINES, numbered from STARTING-AT.
LINES holds one string per line without its LF; the rendering
LF-separates the numbered lines (the numbered view is a rendering,
not a byte image)."
  (let ((i starting-at)
        (out '()))
    (dolist (line lines)
      (push (quoth-file--numbered-line i line) out)
      (setq i (1+ i)))
    (apply #'concat (nreverse out))))

(defun quoth-file--bol (text line)
  "Return the byte index where line LINE (1-based) begins in TEXT.
Interior empty lines count as lines, matching `quoth-file--lines'.
For a LINE one past the last line start the return value is (length
TEXT): callers use it as the exclusive slice end after the final
line.  Returns nil only beyond that."
  (let ((idx 0)
        (ln 1)
        (n (length text)))
    (while (and (< idx n) (< ln line))
      (when (= (aref text idx) ?\n)
        (setq ln (1+ ln)))
      (setq idx (1+ idx)))
    (and (>= ln line) idx)))

(defun quoth-file--utf8-valid-p (bytes)
  "Return non-nil when unibyte string BYTES is valid UTF-8.
Scans byte-by-byte without decoding to multibyte, so newline bytes
\(`\\n' and `\\r') are never subject to Emacs EOL conversion, which would
normalize `\\r\\n' to `\\n'.  Accepts the 1-4 byte UTF-8 sequences and
rejects overlongs, surrogates, and values above U+10FFFF."
  (let ((i 0)
        (n (length bytes))
        (valid-p t))
    (while (and valid-p (< i n))
      (let ((b (aref bytes i)))
        (cond
         ((< b 128) (setq i (1+ i)))                     ; ASCII
         ((<= #xC2 b #xDF)                               ; 2-byte
          (if (and (< (1+ i) n)
                   (<= #x80 (aref bytes (1+ i)) #xBF))
              (setq i (+ i 2))
            (setq valid-p nil)))
         ((<= #xE0 b #xEF)                               ; 3-byte
          (if (and (< (+ i 2) n)
                   (<= #x80 (aref bytes (1+ i)) #xBF)
                   ;; Reject overlong E0 80..9F and surrogates ED A0..BF.
                   (not (and (= b #xE0) (< (aref bytes (1+ i)) #xA0)))
                   (not (and (= b #xED) (>= (aref bytes (1+ i)) #xA0))))
              (setq i (+ i 3))
            (setq valid-p nil)))
         ((<= #xF0 b #xF4)                               ; 4-byte
          (if (and (< (+ i 3) n)
                   (<= #x80 (aref bytes (1+ i)) #xBF)
                   (<= #x80 (aref bytes (+ i 2)) #xBF)
                   (<= #x80 (aref bytes (+ i 3)) #xBF)
                   ;; Reject overlong F0 80..8F and values above U+10FFFF.
                   (not (and (= b #xF0) (< (aref bytes (1+ i)) #x90)))
                   (not (and (= b #xF4) (> (aref bytes (1+ i)) #x8F))))
              (setq i (+ i 4))
            (setq valid-p nil)))
         (t (setq valid-p nil)))))                       ; continuation or invalid lead
    valid-p))

(defun quoth-file--utf8-next (bytes i)
  "Return (CODEPOINT . LEN) for the UTF-8 sequence in BYTES starting at I.
Decodes a 2-4 byte UTF-8 sequence whose validity was established by
`quoth-file--utf8-valid-p'.  LEN is the sequence length in bytes; the
codepoint is independent of the surrounding ASCII/CR/LF bytes."
  (let* ((b (aref bytes i))
         (len (if (<= #xC2 b #xDF) 2
                (if (<= #xE0 b #xEF) 3 4)))
         (mask (cond ((= len 2) #x1F)
                     ((= len 3) #x0F)
                     (t #x07)))
         (cp (logand b mask)))
    (dotimes (k (1- len))
      (setq cp (logior (ash cp 6)
                       (logand (aref bytes (+ i 1 k)) #x3F))))
    (cons cp len)))

(defun quoth-file--read-content (path)
  "Return the UTF-8 text of the file at PATH as a multibyte string.
Reads the file as raw unibyte bytes and decodes the UTF-8 sequences to
characters byte-by-byte, so ASCII bytes (including CR and LF) are
preserved verbatim rather than normalized by Emacs EOL handling.  Signals
an error when the file is not valid UTF-8.  The result is byte-exact for
line endings: a `\\r\\n' on disk stays `\\r\\n' in the returned text."
  (let* ((bytes (quoth-file--read-bytes path))
         (n (length bytes))
         (chars nil)
         (i 0))
    (unless (quoth-file--utf8-valid-p bytes)
      (error "File is not valid UTF-8: %s" path))
    (while (< i n)
      (let ((b (aref bytes i)))
        (if (< b 128)
            (progn
              (push b chars)
              (setq i (1+ i)))
          (let* ((seq (quoth-file--utf8-next bytes i))
                 (cp (car seq))
                 (len (cdr seq)))
            (push cp chars)
            (setq i (+ i len))))))
    ;; `apply #'string' builds a proper multibyte string from the decoded
    ;; codepoints.  A pre-allocated `make-string' is unibyte and `aset'
    ;; cannot store a character >= #x100 into it, so we accumulate a list
    ;; of characters instead of writing into a fixed-length buffer.
    (apply #'string (nreverse chars))))


(defun quoth-file--read-line-numbered-p (args)
  "Return the resolved `line_numbers' flag from ARGS.
Off when the arg is absent or JSON false (`:json-false'); on
otherwise."
  (let ((raw (plist-get args :line_numbers)))
    (and raw (not (eq raw :json-false)))))

(defun quoth-file--read-range (args)
  "Return the validated window (OFFSET . LIMIT) from ARGS.
OFFSET is the 1-based first line (1 when absent); LIMIT is the max
line count (nil when absent).  A present-but-invalid value errors
with a message naming the offending argument."
  (let ((off (plist-get args :offset))
        (lim (plist-get args :limit)))
    (unless (or (null off) (and (integerp off) (> off 0)))
      (error "Offset must be a positive integer, got %S" off))
    (unless (or (null lim) (and (integerp lim) (> lim 0)))
      (error "Limit must be a positive integer, got %S" lim))
    (cons (or off 1) lim)))

(defun quoth-read-file--render (text lines start end numbered-p)
  "Return the rendered body for lines START..END of the file.
START and END are 1-based line numbers, END exclusive.  LINES is the
file's split lines (from `quoth-file--lines' on TEXT).  NUMBERED-P
selects the rendering:

- numbered: `cat -n' prefixes on true line numbers, LF-separated;
- plain: the byte-exact slice of TEXT covering those lines, so a
  file without a trailing newline keeps its true ending and CRLF
  bytes survive verbatim."
  (if numbered-p
      (quoth-file--apply-line-numbers (cl-subseq lines (1- start) (1- end))
                                      start)
    ;; Byte-exact window of the original text: from the start of line
    ;; START through the start of line END (its LF included when the
    ;; file has one there; the file's true end otherwise).
    (let* ((from (if (= start 1) 0 (quoth-file--bol text start)))
           (to (quoth-file--bol text end)))
      (substring text (or from 0) (or to (length text))))))

(defun quoth-read-file--marker (dropped first-dropped last-dropped)
  "Return the truncation marker for DROPPED lines, or \"\".
LAST-DROPPED is the final dropped line number.  The marker names
the dropped line range (its numbers are true file line numbers, so
the range doubles as the file's tail extent), the
dropped count, and FIRST-DROPPED as the exact `offset' that fetches
the lost lines.  The same shape serves windowed and full-file reads:
the range is never wrong, and the resume offset always names an
existing line."
  (if (= dropped 0)
      ""
    (format "... lines %d-%d omitted (%d %s). Use offset=%d to resume ...\n"
            first-dropped last-dropped dropped
            (if (= dropped 1) "line" "lines")
            first-dropped)))

(defun quoth-read-file--exec (tool-call on-done)
  "Execute TOOL-CALL as `read_file', reporting to ON-DONE inline.
Reads the file at `path' as UTF-8 text with line endings preserved
byte-exact (a `\\r\\n' on disk stays `\\r\\n'), optionally numbers it,
and reports it under the `quoth-tool-max-output' byte budget.
Three shape args:

- `line_numbers' (default off): prefix each line with its 1-based
  true line number, `cat -n' style (right-aligned 6 chars, then a
  TAB).
- `offset': 1-based first line.  Errors when non-positive or past
  the last line.
- `limit': max lines returned.  Errors when non-positive; a window
  running past the last line is clamped to it.

The budget is spent on whole rendered lines, head first.  When the
window does not fit, the head is reported and a marker names the
dropped lines and the `offset' that fetches them; the tail is never
emitted.  An empty file reports the status header only.

A missing or unreadable path, an invalid `offset' / `limit', or
content that is not valid UTF-8 delivers an error result
immediately.  An immediate tool: returns nil (no cancel thunk)."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (path (quoth-file--resolve-path args))
         (numbered-p (quoth-file--read-line-numbered-p args)))
    (cond
     ((not path)
      (funcall on-done (quoth-openai-tool-error-result
                        "Missing or empty path"))
      nil)
     (t
      (condition-case err
          (progn
            (unless (file-readable-p path)
              (error "Cannot read %s" path))
            ;; Resolve the window inside the condition-case so an
            ;; invalid value becomes an error result, not a raw
            ;; signal out of the entry.
            (let* ((range (quoth-file--read-range args))
                   (offset (car range))
                   (limit (cdr range))
                   (text (quoth-file--read-content path))
                   (lines (quoth-file--lines text))
                   (line-count (length lines))
                   (header "Process exited with code 0\nOutput:\n")
                   (header-len (length header)))
              (cond
               ;; Empty file: header only, no body, no marker.  Must
               ;; short-circuit before the offset-past-EOF check,
               ;; because offset 1 is trivially past an empty file.
               ((= line-count 0)
                (funcall on-done (cons header 0))
                nil)
               (t
                (when (> offset line-count)
                  (error "Offset %d is past the last line (%d)"
                         offset line-count))
                (let* (;; window-end doubles as the exclusive end
                       ;; index into LINES: line N lives at index
                       ;; N-1, so the slice (1- offset)..window-end
                       ;; covers lines offset..window-end inclusive.
                       (window-end (if limit
                                       (min (+ offset limit -1)
                                            line-count)
                                     line-count))
                       (windowed (vconcat
                                  (cl-subseq lines
                                             (1- offset)
                                             window-end)))
                       (window-size (length windowed))
                       (keep 0)
                       (consumed header-len)
                       (fit-p t))
                  ;; Spend the budget on whole rendered lines, head
                  ;; first.  A blank line renders to one byte (its
                  ;; LF) so files of blank lines still terminate.
                  (while (and fit-p (< keep window-size))
                    (let* ((line (aref windowed keep))
                           (cost (if numbered-p
                                     (length
                                      (quoth-file--numbered-line
                                       (+ offset keep) line))
                                   ;; + 1 for the LF the render adds;
                                   ;; a final line the file ends
                                   ;; without is over-charged by that
                                   ;; one byte (conservative).
                                   (1+ (length line)))))
                      (if (> (+ consumed cost) quoth-tool-max-output)
                          (setq fit-p nil)
                        (setq consumed (+ consumed cost))
                        (setq keep (1+ keep)))))
                  (let* ((body (quoth-read-file--render
                                text lines offset (+ offset keep) numbered-p))
                         (dropped (- window-size keep))
                         (first-dropped (+ offset keep))
                         (marker (quoth-read-file--marker
                                  dropped
                                  first-dropped
                                  ;; window-end: the last line of the
                                  ;; requested window, dropped or not.
                                  window-end)))
                    (funcall on-done
                             (cons (concat header body marker) 0))
                    nil))))))
        (error
         (funcall on-done (quoth-openai-tool-error-result
                           (error-message-string err)))
         nil))))))

;;; Register the tools into the protocol registry.

(push (cons "exec_command" #'quoth-exec-command--exec)
      quoth-openai-tool-registry)
(push (cons "write_stdin" #'quoth-write-stdin--exec)
      quoth-openai-tool-registry)
(push (cons "write_file" #'quoth-write-file--exec)
      quoth-openai-tool-registry)
(push (cons "read_file" #'quoth-read-file--exec)
      quoth-openai-tool-registry)

(provide 'quoth-tools)
;;; quoth-tools.el ends here
