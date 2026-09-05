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
;; `read_file' is image-aware: an image file (by extension or magic
;; bytes) is reported as a markdown image-link line the chat walk
;; attaches as pixels, never decoded as text; a model without image
;; support or a past-cap image is an error result the model can adapt
;; to. `read_file' additionally takes three shape args: `line_numbers'
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

(declare-function quoth-provider-model-supports-attachments-p "quoth-provider" (provider))
(defvar quoth-image-max-raw-bytes 3750000
  "Raw-size cap for one image attachment, in bytes.
The `defcustom' in `quoth.el' owns the option; this plain `defvar'
declares the binding so this file byte-compiles and loads
standalone.  A `defvar' never overwrites an existing binding, so
when `quoth.el' loads this file first the later `defcustom' (and
the user's Customize value) still wins.")
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
markdown) renders correctly; only trailing whitespace is trimmed so
an empty result reads as nil from here and the caller can mark it
structurally."
  (let* ((text (string-trim-right output))
         (limit quoth-tool-max-output))
    (cond
     ((string-empty-p text) nil)
     ((<= (length text) limit) text)
     (t (let* ((head-len (floor (* limit 0.7)))
               (tail-len (- limit head-len))
               (omitted (- (length text) limit)))
          (format "%s\n... %d bytes omitted ...\n%s"
                  (substring text 0 head-len)
                  omitted
                  (substring text (- (length text) tail-len))))))))

(defun quoth-exec--output-section (text)
  "Return the `Output:' section for body TEXT.
The single rendering decision every tool result goes through.  nil
means there is nothing to show at all and renders as the structural
`Output: (empty)' marker on the status line - never as body text a
reader could mistake for literal output.  A string (even empty)
renders as `Output:' on its own line followed by the body: an empty
string is a real body, as when a budget marker follows and the body
itself was dropped.  New tools build results with this helper
instead of hand-writing the `Output:' line."
  (if text
      (concat "Output:\n" text)
    "Output: (empty)\n"))

(defun quoth-exec--format-result (output exit-code)
  "Return the finished-result text for OUTPUT and EXIT-CODE.
Uses Codex's prose convention: status line, then the `Output:'
section (`quoth-exec--output-section')."
  (concat
   (format "Process exited with code %s\n" exit-code)
   (quoth-exec--output-section (quoth-exec--truncate-output output))))

(defun quoth-exec--format-running (output session-id)
  "Return the still-running result text for OUTPUT and SESSION-ID.
The status line carries the session id the model echoes into
`write_stdin'."
  (concat
   (format "Process running with session ID %d\n" session-id)
   (quoth-exec--output-section (quoth-exec--truncate-output output))))

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

(defun quoth-file--read-bytes-prefix (path count)
  "Return the first COUNT raw bytes of the file at PATH, or nil.
The magic-byte sniff: a short unibyte read that never touches UTF-8
decoding.  Returns nil when the file is unreadable; a shorter file
yields all its bytes."
  (when (file-readable-p path)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((coding-system-for-read 'binary))
        (ignore-errors
          (insert-file-contents path nil 0 count)))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun quoth-file--image-magic-mime (path)
  "Return PATH's image MIME type by magic bytes, or nil.
Matches the PNG / JPEG / GIF / WebP signatures in the first 12
bytes; the declared extension is never trusted alone."
  (let ((head (quoth-file--read-bytes-prefix path 12)))
    (and head
         (cond ((string-prefix-p "\x89PNG" head) "image/png")
               ((string-prefix-p "\xff\xd8\xff" head) "image/jpeg")
               ((string-prefix-p "GIF8" head) "image/gif")
               ((and (string-prefix-p "RIFF" head)
                     (> (length head) 11)
                     (string= (substring head 8 12) "WEBP"))
                "image/webp")))))

(defun quoth-file--image-mime (path)
  "Return the image MIME type for PATH, or nil for a non-image.
The extension decides when it names a known image type; otherwise
the magic bytes do (an extension can lie, and unknown extensions
still carry real images)."
  (or (pcase (downcase (or (file-name-extension path) ""))
        ("png" "image/png")
        ("jpg" "image/jpeg")
        ("jpeg" "image/jpeg")
        ("webp" "image/webp")
        ("gif" "image/gif")
        (_ nil))
      (quoth-file--image-magic-mime path)))

(defun quoth-file--image-supported-p ()
  "Return whether the active model accepts image attachments.
Delegates to the cached-catalog lookup on `quoth-active-provider'
\(t / nil / `unknown'); `unknown' is permissive — the server strips
images silently rather than erroring, so an uncertain catalog never
blocks the read."
  (quoth-provider-model-supports-attachments-p
   (and (boundp 'quoth-active-provider) quoth-active-provider)))

(defun quoth-file--image-supported-error ()
  "Return the blindness error result for an image read."
  (quoth-openai-tool-error-result
   "This model does not support image data; describe the file textually instead"))

(defun quoth-file--image-size-error (path)
  "Return the past-cap error result for the image at PATH."
  (quoth-openai-tool-error-result
   (format "Image %s exceeds the raw-size attachment cap (%d bytes); resize or crop it first"
           (file-name-nondirectory path) quoth-image-max-raw-bytes)))

(defun quoth-read-file--image-result (path)
  "Return the image read result (TEXT . 0) for the image at PATH.
The result body is the file's markdown image-link line
\(`![name](path)'): compact display text in the tool block, and the
marker the chat walk recognizes to attach the pixels in a synthetic
user message — the model cannot consume image bytes as text, so the
bytes never ride this result.  PATH is written verbatim into the
link (as the tool call passed it), so the buffer display names what
the model asked for and the walk resolves it the same way on every
replay."
  (cons (concat (format "Process exited with code %s\n" 0)
                (quoth-exec--output-section
                 (format "![%s](%s)"
                         (file-name-nondirectory path) path)))
        0))

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

(defun quoth-file--write-text (path content)
  "Write CONTENT byte-exact to the existing file at PATH.
The shared write choke point for `write_file' and `edit_file':
`utf-8-unix' pins the write coding so the write stays byte-exact for
text.  CONTENT is a multibyte string (decoded from JSON, or spliced
from `quoth-file--read-content') whose line endings are preserved
byte-exact; a `\\r\\n' on disk is a CR and an LF character in that
string.  Writing under the `unix' EOL is the identity: `\\n' -> LF
and `\\r' is left untouched, so a byte-exact round trip survives.
A bare `utf-8' or a platform-default EOL could translate `\\n' to
`\\r\\n' (or vice versa) and corrupt the file.  PATH must already
exist: rename-file cannot replace an existing file on all platforms,
so the write is direct; atomicity is a bonus here, not the
requirement byte-exactness is."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region content nil path)))

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
            (if (file-exists-p path)
                (quoth-file--write-text path content)
              ;; Fresh file: write a temp sibling, then atomically
              ;; rename it into place.  `utf-8-unix' applies to the temp
              ;; write too, so the renamed file is byte-exact.
              (let ((coding-system-for-write 'utf-8-unix))
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

;;; 5b. edit_file

;; `edit_file' splices text: the model supplies an `old_string' that
;; must match the file byte-exact and a `new_string' written verbatim.
;; The JSON string is the only quoting layer — no shell, so no shell
;; escaping.  Matching is literal over the whole file text (never
;; per-line, never regexp), so multiline spans are first-class: an
;; embedded newline in `old_string' is just another character, and on
;; a CRLF file the match is CR-sensitive (a normalized `\n' fails
;; loudly, leaving the file untouched — the same safety property the
;; unique-match requirement gives).

(defun quoth-edit-file--find-all (text needle)
  "Return the 0-based start indices of every literal NEEDLE in TEXT.
Empty NEEDLE returns nil: an empty search string matches everywhere
and means nothing."
  (when (> (length needle) 0)
    (let ((hits nil)
          (i 0))
      (while (< i (length text))
        (let ((hit (cl-search needle text :start2 i)))
          (if hit
              (progn
                (push hit hits)
                (setq i (+ hit (length needle))))
            (setq i (length text)))))
      (nreverse hits))))

(defun quoth-edit-file--line-at (text pos)
  "Return the 1-based line number of the 0-based offset POS in TEXT.
Lines split on LF only (the `quoth-file--lines' convention), so a
CRLF file's CR stays glued to its content line."
  (1+ (cl-count ?\n (substring text 0 pos))))

(defun quoth-edit-file--replace-all (text old new)
  "Return TEXT with every literal OLD replaced by NEW, and the count."
  (let ((hits (quoth-edit-file--find-all text old)))
    (cons (if hits
              (let ((parts nil)
                    (prev 0))
                (dolist (hit hits)
                  (push (substring text prev hit) parts)
                  (push new parts)
                  (setq prev (+ hit (length old))))
                (push (substring text prev) parts)
                (apply #'concat (nreverse parts)))
            text)
          (length hits))))

(defun quoth-edit-file--context-diff (old new)
  "Return a mini-diff of the replaced span OLD -> NEW.
`-'-prefixed lines for the old span, `+'-prefixed lines for the new
one; the match line numbers live in the status line above it.  The
span is short by construction (one `old_string'), so no truncation
here; the caller's output budget applies to the whole result."
  (let* ((split (lambda (s)
                  (if (string-empty-p s)
                      nil
                    (split-string
                     (if (string-suffix-p "\n" s)
                         (substring s 0 -1)
                       s)
                     "\n"))))
         (old-lines (funcall split old))
         (new-lines (funcall split new))
         (body (concat
                (mapconcat (lambda (l) (concat "-" l))
                           old-lines "\n")
                (unless (or (null old-lines) (null new-lines)) "\n")
                (mapconcat (lambda (l) (concat "+" l))
                           new-lines "\n"))))
    (if (string-empty-p body)
        "(empty)"
      body)))

(defun quoth-edit-file--exec (tool-call on-done)
  "Execute TOOL-CALL as `edit_file', reporting to ON-DONE inline.
Replaces one literal `old_string' occurrence in the file at `path'
with `new_string', written verbatim through the shared write choke
point (`quoth-file--write-text'), so the round trip from an
un-numbered `read_file' is byte-exact and CRLF files keep their CRs.
Multiline spans are first-class: matching runs over the whole file
text, never per line, so embedded newlines are literal characters.
`old_string' must occur exactly once unless `replace_all' is true;
zero occurrences and ambiguous matches are error results naming the
match lines, so a stale copy fails loudly instead of clobbering the
file.  `new_string' may be empty (deletion); a missing `new_string'
is an error — absence is not rejection.  A missing path, an empty or
absent `old_string', a no-op edit (`old_string' = `new_string'), an
unwritable target, or non-UTF-8 content delivers an error result
immediately.  An immediate tool: returns nil (no cancel thunk)."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (path (quoth-file--resolve-path args))
         (old (plist-get args :old_string))
         (new (plist-get args :new_string)))
    (cond
     ((not path)
      (funcall on-done (quoth-openai-tool-error-result
                        "Missing or empty path"))
      nil)
     ((not (stringp old))
      (funcall on-done (quoth-openai-tool-error-result
                        "Missing old_string"))
      nil)
     ((string-empty-p old)
      (funcall on-done (quoth-openai-tool-error-result
                        "old_string is empty: an empty search string \
matches everywhere and means nothing"))
      nil)
     ((not (stringp new))
      (funcall on-done (quoth-openai-tool-error-result
                        "Missing new_string (use an empty string to \
delete the matched text)"))
      nil)
     ((string= old new)
      (funcall on-done (quoth-openai-tool-error-result
                        (format "old_string and new_string are \
identical (no-op edit)")))
      nil)
     (t
      (condition-case err
          (progn
            (unless (file-readable-p path)
              (error "Cannot read %s" path))
            (unless (file-writable-p path)
              (error "Cannot write %s" path))
            (let* ((text (quoth-file--read-content path))
                   (hits (quoth-edit-file--find-all text old))
                   (replace-all (and (plist-get args :replace_all)
                                     (not (eq (plist-get args :replace_all)
                                              :json-false)))))
              (cond
               ((null hits)
                (let ((first-line
                       (or (car (split-string old "\n" t)) "")))
                  (error "old_string not found in %s (starts %S); \
read the file fresh before editing"
                         path (substring first-line 0
                                         (min (length first-line) 60)))))
               ((and (> (length hits) 1) (not replace-all))
                (error "old_string occurs %d times (lines %s); \
include surrounding lines to make it unique, or set replace_all"
                       (length hits)
                       (mapconcat
                        (lambda (i)
                          (number-to-string
                           (quoth-edit-file--line-at text i)))
                        hits ", ")))
               (t
                (let* ((spliced (quoth-edit-file--replace-all
                                 text old new))
                       (count (cdr spliced)))
                  (quoth-file--write-text path (car spliced))
                  (funcall
                   on-done
                   (cons
                    (quoth-exec--format-result
                     (format
                      "Edited %s: replaced %d occurrence%s at line%s %s\n%s"
                      path count (if (= count 1) "" "s")
                      (if (= count 1) "" "s")
                      (mapconcat
                       (lambda (i)
                         (number-to-string
                          (quoth-edit-file--line-at text i)))
                       hits ", ")
                      (quoth-edit-file--context-diff old new))
                     0)
                    0))
                  nil)))))
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
immediately.  An image file (by extension or magic bytes) never
reaches the text path: a past-cap image or a model without image
support is an error result the model can adapt to, otherwise the
result is the markdown image-link line the chat walk attaches as
pixels.  An immediate tool: returns nil (no cancel thunk)."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (path (quoth-file--resolve-path args))
         (as-written (plist-get args :path))
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
            ;; Image files never ride the text path: the model cannot
            ;; consume image bytes as UTF-8 text, so the result is the
            ;; image-link line the chat walk fans out into a synthetic
            ;; user message (blindness and size errors mirror the
            ;; gateway's own limits, so the model learns and adapts).
            (let ((mime (quoth-file--image-mime path)))
              (cond
               ((and mime
                     (> (or (file-attribute-size
                             (file-attributes path)) 0)
                        quoth-image-max-raw-bytes))
                (funcall on-done (quoth-file--image-size-error path))
                nil)
               ((and mime (eq (quoth-file--image-supported-p) nil))
                (funcall on-done (quoth-file--image-supported-error))
                nil)
               (mime
                (funcall on-done
                         (quoth-read-file--image-result
                          (or as-written path)))
                nil)
               (t
                (quoth-read-file--exec-text path args numbered-p on-done)))))
        (error
         (funcall on-done (quoth-openai-tool-error-result
                           (error-message-string err)))
         nil))))))

(defun quoth-read-file--exec-text (path args numbered-p on-done)
  "Deliver the text read of PATH for ARGS to ON-DONE inline.
The line-numbers / offset / limit rendering path of `read_file' for
non-image files; see `quoth-read-file--exec' for the arg contracts.
An immediate tool: returns nil (no cancel thunk)."
  (let* ((range (quoth-file--read-range args))
         (offset (car range))
         (limit (cdr range))
         (text (quoth-file--read-content path))
         (lines (quoth-file--lines text))
         (line-count (length lines))
         (status "Process exited with code 0\n")
         ;; The budget's fixed cost is the non-empty
         ;; `Output:' header, derived from the same
         ;; `output-section' helper that renders the result:
         ;; its section with a one-byte dummy body, minus
         ;; the dummy, plus the status line.  The empty-file
         ;; case below renders the `(empty)' marker instead
         ;; and never reaches the budget arithmetic.
         (header-len (+ (length status)
                        (1- (length
                             (quoth-exec--output-section "x"))))))
    (if (= line-count 0)
        ;; Empty file: the `output-section' helper's
        ;; structural `(empty)' marker, no body, no marker.
        ;; Short-circuits before the offset-past-EOF check,
        ;; because offset 1 is trivially past an empty file.
        (funcall on-done
                 (cons (concat status
                               (quoth-exec--output-section nil))
                       0))
      (progn
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
                     (cons (concat status
                                   (quoth-exec--output-section body)
                                   marker)
                           0))
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
(push (cons "edit_file" #'quoth-edit-file--exec)
      quoth-openai-tool-registry)

(provide 'quoth-tools)
;;; quoth-tools.el ends here
