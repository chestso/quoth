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
Reads with `coding-system-for-read' bound to `binary' so no newline
translation happens on the way in; the caller re-decodes as text.  This
keeps the read byte-exact."
  (with-temp-buffer
    (let ((coding-system-for-read 'binary))
      (insert-file-contents path))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun quoth-write-file--exec (tool-call)
  "Execute TOOL-CALL as `write_file' and return (RESULT . EXIT-OR-NIL).
Writes the parsed `content' arg byte-exact to `path', creating missing
parent directories and replacing an existing file unless `overwrite' is
false.  Fresh-file writes go through a temp file + rename so a reader
never observes a half-written file; overwriting an existing target
falls back to a direct write (rename cannot replace an existing file on
Windows).  A missing `path' or `content' yields an error result with
exit code -1."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (path (quoth-file--resolve-path args))
         (content (plist-get args :content)))
    (cond
     ((not path)
      (quoth-exec--error "Missing or empty path" tool-call))
     ((not (stringp content))
      (quoth-exec--error "Missing or empty content" tool-call))
     (t
      (condition-case err
          (let* ((overwrite (not (eq (plist-get args :overwrite) :json-false)))
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
            (let ((text (quoth-exec--format-result
                         (format "Wrote %s" path) 0)))
              (setf (quoth-openai-tool-call-result tool-call) text
                    (quoth-openai-tool-call-exit tool-call) 0)
              (cons text 0)))
        (error (quoth-exec--error (error-message-string err) tool-call)))))))

(defun quoth-file--read-truncate (text)
  "Cap TEXT for a `read_file' result, preserving trailing content.
Unlike `quoth-exec--truncate-output', the trailing newline (and any
other trailing bytes) are preserved so a read stays byte-exact: the
model reading a file to edit it must see the file's true ending.  When
over `quoth-tool-max-output', keeps a 70% head / 30% tail split with an
omission marker."
  (let ((limit quoth-tool-max-output))
    (if (<= (length text) limit)
        text
      (let* ((head-len (floor (* limit 0.7)))
             (tail-len (- limit head-len))
             (omitted (- (length text) limit)))
        (format "%s\n... %d bytes omitted ...\n%s"
                (substring text 0 head-len)
                omitted
                (substring text (- (length text) tail-len)))))))

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
         (out (make-string n 0))
         (i 0)
         (o 0))
    (unless (quoth-file--utf8-valid-p bytes)
      (error "File is not valid UTF-8: %s" path))
    (while (< i n)
      (let ((b (aref bytes i)))
        (if (< b 128)
            (progn
              (aset out o b)
              (setq i (1+ i) o (1+ o)))
          (let* ((seq (quoth-file--utf8-next bytes i))
                 (cp (car seq))
                 (len (cdr seq)))
            (aset out o cp)
            (setq i (+ i len) o (1+ o))))))
    (substring out 0 o)))

(defun quoth-read-file--exec (tool-call)
  "Execute TOOL-CALL as `read_file' and return (RESULT . EXIT-OR-NIL).
Reads the file at `path' as UTF-8 text, preserving line endings
byte-exact (a `\\r\\n' on disk stays `\\r\\n'), and reports it truncated
to `quoth-tool-max-output' without trimming trailing newlines.  A
missing or unreadable path, or content that is not valid UTF-8, yields
an error result with exit code -1."
  (let* ((args (quoth-openai-tool-call-args tool-call))
         (path (quoth-file--resolve-path args)))
    (if (not path)
        (quoth-exec--error "Missing or empty path" tool-call)
      (condition-case err
          (progn
            (unless (file-readable-p path)
              (error "Cannot read %s" path))
            (let* ((text (quoth-file--read-content path))
                   (out (quoth-file--read-truncate text))
                   (formatted (concat
                               "Process exited with code 0\n"
                               "Output:\n"
                               out)))
              (setf (quoth-openai-tool-call-result tool-call) formatted
                    (quoth-openai-tool-call-exit tool-call) 0)
              (cons formatted 0)))
        (error (quoth-exec--error (error-message-string err) tool-call))))))

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
