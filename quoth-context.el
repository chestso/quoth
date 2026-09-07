;;; quoth-context.el --- System-prompt context assembly for quoth  -*- lexical-binding: t; -*-
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

;; The system-prompt context assembly for quoth.el: the base prompt
;; text, the <env> block (working directory, git state, platform,
;; date), the <project_context> and <user_preferences> blocks from
;; discovered context files, the buffer-local prompt cache, and the
;; async git stage that keeps a chat send from blocking on `git
;; status'.  Providers consume it through `quoth-context-async'; the
;; assembled prompt is provider-agnostic (every provider family sends
;; it as its system message).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function quoth--schedule "quoth.el" (fn))

(defcustom quoth-context-system-prompt
  "You are a helpful assistant.  You answer concisely and correctly."
  "Base system prompt for every request.
Followed by the <env>, <project_context>, and <user_preferences>
blocks.  Read at request-build time; edits apply on the next cache
miss: context-file change, `quoth-clear-buffer', or a new buffer."
  :type 'string
  :group 'quoth)

(defcustom quoth-context-git-status-limit 20
  "Maximum lines of `git status --short' output in the <env> block.
Matches the Crush CLI's `head -20' cap."
  :type 'integer
  :group 'quoth)

(defcustom quoth-context-git-commits 3
  "Number of recent commits to include in the <env> block."
  :type 'integer
  :group 'quoth)

(defcustom quoth-context-git-timeout 10
  "Seconds the async git stage may take before it is abandoned.
A hung `git status' on a monorepo must not stall a chat send: past the
timeout the stage is aborted and the prompt is delivered without the
git section (git failure degrades the same way)."
  :type 'number
  :group 'quoth)

(defconst quoth-context--default-context-paths
  '(".github/copilot-instructions.md"
    ".cursorrules"
    "CLAUDE.md" "CLAUDE.local.md"
    "GEMINI.md" "gemini.md"
    "crush.md" "crush.local.md"
    "Crush.md" "Crush.local.md"
    "CRUSH.md" "CRUSH.local.md"
    "AGENTS.md" "agents.md" "Agents.md")
  "Default context file paths to discover in the working directory.")

(defcustom quoth-context-paths
  quoth-context--default-context-paths
  "List of files/directories to scan for project context.
Paths are relative to the working directory.  Directories are
walked recursively.  Defaults match the Crush CLI's list."
  :type '(repeat string)
  :group 'quoth)

(defcustom quoth-context-global-paths
  (list (expand-file-name "crush/CRUSH.md"
                          (or (getenv "XDG_CONFIG_HOME")
                              "~/.config"))
        (expand-file-name "AGENTS.md"
                          (or (getenv "XDG_CONFIG_HOME")
                              "~/.config")))
  "Global context files applied across all projects."
  :type '(repeat string)
  :group 'quoth)

(defgroup quoth-context nil
  "System-prompt context assembly."
  :group 'quoth
  :prefix "quoth-context-")

;;; <env> block and the git stage.

(defun quoth-context--build-env-block (&optional git-section)
  "Build the <env> block for the system prompt, with GIT-SECTION.
Includes working directory, git repo status, platform, and date, plus
the GIT-SECTION string (the pre-formatted branch/status/commits block
from `quoth-context--git-section') when inside a git repository.  Git
status is a snapshot at build time and may be outdated by the time the
model reads it."
  (let* ((dir (expand-file-name default-directory))
         (is-git (file-directory-p (expand-file-name ".git" dir)))
         (platform (symbol-name system-type))
         (date (format-time-string "%-m/%-d/%Y"))
         (lines (list (format "Working directory: %s" dir)
                      (format "Is directory a git repo: %s"
                              (if is-git "yes" "no"))
                      (format "Platform: %s" platform)
                      (format "Today's date: %s" date))))
    (when (and is-git git-section)
      (setq lines (append lines
                          (list (format "\nGit status (snapshot at conversation start - may be outdated):\n%s"
                                        git-section)))))
    (format "<env>\n%s\n</env>"
            (string-join lines "\n"))))

(defun quoth-context--git-command ()
  "Return the single git command string for the git stage.
The three sections (branch, status, commits) run in one shell
invocation separated by marker `echo'es, so one process covers the
whole stage.  Runs in the buffer's `default-directory'."
  (concat
   "echo BRANCH_MARKER; git branch --show-current; "
   "echo STATUS_MARKER; git status --short | head -"
   (number-to-string quoth-context-git-status-limit) "; "
   "echo COMMITS_MARKER; git log --oneline -n "
   (number-to-string quoth-context-git-commits)))

(defun quoth-context--git-section-from-output (raw)
  "Build the git section from the marker-delimited RAW stage output.
Returns nil when the output is empty (git failed or is unavailable),
matching the non-git degrade.  Mirrors the three-command summary:
current branch, status (clean or listed), recent commits."
  (let ((out (string-trim raw)))
    (unless (string-empty-p out)
      (let* ((branch (quoth-context--marker-section out "BRANCH_MARKER"
                                                    "STATUS_MARKER"))
             (status (quoth-context--marker-section out "STATUS_MARKER"
                                                    "COMMITS_MARKER"))
             (commits (quoth-context--marker-section out "COMMITS_MARKER"
                                                     nil)))
        (string-join
         (delq nil
               (list (and (not (string-empty-p branch))
                          (format "Current branch: %s" branch))
                     (if (string-empty-p status)
                         "Status: clean"
                       (format "Status:\n%s" status))
                     (and (not (string-empty-p commits))
                          (format "Recent commits:\n%s" commits))))
         "\n")))))

(defun quoth-context--marker-section (raw start-marker &optional end-marker)
  "Return the text between START-MARKER and END-MARKER in RAW.
END-MARKER nil means to the end of RAW.  The marker lines themselves
are excluded."
  (let ((start (string-match (concat (regexp-quote start-marker)
                                     "[^\n]*\n")
                             raw)))
    (when start
      (let* ((begin (match-end 0))
             (end (if end-marker
                      (let ((e (string-match (concat (regexp-quote end-marker)
                                                     "[^\n]*")
                                             raw begin)))
                        (or e (length raw)))
                    (length raw))))
        (string-trim (substring raw begin end))))))

;;; Context-file discovery and block builders.

(defun quoth-context--discover-context-files (paths)
  "Scan PATHS relative to `default-directory' for context files.
Each path is either a file (read directly) or a directory (walked
recursively).  Returns a list of (RELATIVE-PATH . CONTENT) conses
for files that exist and are readable.  Non-existent paths are
silently skipped."
  (let (result)
    (dolist (p paths)
      (let ((full (expand-file-name p)))
        (cond
         ((file-directory-p full)
          (mapc
           (lambda (f)
             (let ((rel (file-relative-name f)))
               (push (cons rel (with-temp-buffer
                                 (insert-file-contents f)
                                 (buffer-string)))
                     result)))
           (directory-files-recursively full "")))
         ((file-readable-p full)
          (push (cons p (with-temp-buffer
                          (insert-file-contents full)
                          (buffer-string)))
                result)))))
    (nreverse result)))

(defun quoth-context--build-context-block (files tag header intro)
  "Build a context block from FILES (list of (PATH . CONTENT) conses).
TAG is the XML tag name (e.g. \"project_context\"), HEADER is the
section title, INTRO is the explanatory text.  Returns nil when
FILES is nil or empty."
  (when files
    (let ((entries (mapconcat
                    (lambda (entry)
                      (format "<file path=\"%s\">\n%s\n</file>"
                              (car entry) (cdr entry)))
                    files "\n")))
      (format "# %s\n%s\n<%s>\n%s\n</%s>"
              header intro tag entries tag))))

(defun quoth-context--build-project-context-block (files)
  "Build the <project_context> block from FILES.
FILES is a list of (RELATIVE-PATH . CONTENT) conses.  Returns nil
when no files are found."
  (quoth-context--build-context-block
   files "project_context"
   "Project-Specific Context"
   "Make sure to follow the instructions in the context below."))

(defun quoth-context--build-user-preferences-block (files)
  "Build the <user_preferences> block from global FILES.
FILES is a list of (PATH . CONTENT) conses.  Returns nil when no
files are found."
  (quoth-context--build-context-block
   files "user_preferences"
   "User context"
   "The following is personal content added by the user that they'd like you to follow no matter what project they're working in."))

;;; Full assembly and the buffer-local cache.

(defvar-local quoth-context--cached-system-prompt nil
  "Cached system prompt string for this buffer.")

(defvar-local quoth-context--cache-key nil
  "Cache key: (working-dir . context-file-modtimes).")

(defun quoth-context--build-system-prompt-uncached (&optional git-section)
  "Build the full system prompt with project context, with GIT-SECTION.
Assembles base text + <env> block (carrying GIT-SECTION) +
<project_context> block + <user_preferences> block.  Called by
`quoth-context-async' on cache miss."
  (let* ((env (quoth-context--build-env-block git-section))
         (project-files (quoth-context--discover-context-files
                         quoth-context-paths))
         (project-block (quoth-context--build-project-context-block
                         project-files))
         (global-files (quoth-context--discover-context-files
                        quoth-context-global-paths))
         (prefs-block (quoth-context--build-user-preferences-block
                       global-files))
         (parts (delq nil
                      (list quoth-context-system-prompt
                            env project-block prefs-block))))
    (string-join parts "\n\n")))

(defun quoth-context--modtimes (&optional paths)
  "Return alist of (RELATIVE-PATH . MODTIME) for existing context files.
PATHS defaults to `quoth-context-paths' plus
`quoth-context-global-paths'.  Non-existent files are omitted.
MODTIME is from `file-attributes' (a list of integers)."
  (let* ((all-paths (or paths
                        (append quoth-context-paths
                                quoth-context-global-paths)))
         result)
    (dolist (p all-paths)
      (let ((full (expand-file-name p)))
        (when (file-readable-p full)
          (let ((modtime (file-attribute-modification-time
                          (file-attributes full))))
            (push (cons p modtime) result)))))
    (nreverse result)))

(defun quoth-context--stage-prompt-key ()
  "Return the system-prompt cache key for the current directory.
The key is (working-dir . context-file-modtimes); context-file reads
are local bounded work and stay synchronous."
  (cons (expand-file-name default-directory)
        (quoth-context--modtimes)))

(defun quoth-context--stage-filter (proc string)
  "Filter for the git stage PROC accumulating chunk STRING."
  (process-put proc :quoth-stage-output
               (concat (or (process-get proc :quoth-stage-output) "")
                       string)))

(defun quoth-context--make-stage-sentinel (finish)
  "Return the git stage sentinel closing over FINISH.
FINISH receives the parsed git section (or nil).  A timed-out stage
\(the process deleted by the timeout) delivers nothing: the timeout
delivered already."
  (lambda (proc _event)
    (when (not (process-live-p proc))
      ;; Drain the tail before reading the accumulated output (the
      ;; zero-timeout poll pattern).
      (accept-process-output proc 0)
      (funcall finish
               (quoth-context--git-section-from-output
                (quoth-context--stage-output proc))))))

(defun quoth-context--stage-output (proc)
  "Return the accumulated output of the git stage PROC."
  (or (process-get proc :quoth-stage-output) ""))

(defun quoth-context--system-prompt-stage (buf key on-ready)
  "Run the async git stage for the prompt cached under KEY in BUF.
Spawns one git process (the three sections marker-delimited), and on
its exit delivers the assembled prompt (cached under KEY) to ON-READY
via `quoth--schedule'.  A stage past `quoth-context-git-timeout' is
aborted and delivers without the git section, as does git failure or
a non-git directory.  Returns the stage process (or nil on the
non-git path, which delivers synchronously)."
  (let* ((git-p (file-directory-p
                 (expand-file-name ".git" (car key))))
         (proc nil)
         (timeout nil)
         (aborted-p nil)
         (finish
          (lambda (git-section)
            (let ((prompt (quoth-context--assemble-stage-prompt
                           git-section)))
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (when (equal quoth-context--cache-key key)
                    (setq-local quoth-context--cached-system-prompt
                                prompt))))
              (quoth--schedule (lambda () (funcall on-ready prompt)))))))
    (if (not git-p)
        (progn
          ;; No git repo: the gitless prompt is the whole prompt.
          (funcall finish nil)
          nil)
      (let ((sentinel
             (quoth-context--make-stage-sentinel
              (lambda (git-section)
                (unless aborted-p
                  (cancel-timer timeout)
                  (funcall finish git-section))))))
        (setq proc
              (make-process
               :name "quoth-git-stage"
               :buffer " *quoth-git-stage*"
               :command (list shell-file-name shell-command-switch
                              (quoth-context--git-command))
               :connection-type 'pipe
               :noquery t
               :filter #'quoth-context--stage-filter
               :sentinel sentinel))
        ;; Expose the sentinel on the process (the tests drive the real
        ;; filter + sentinel pipeline through it).
        (process-put proc :quoth-stage-sentinel sentinel))
      (setq timeout
            (run-at-time
             quoth-context-git-timeout nil
             (lambda ()
               (when (process-live-p proc)
                 (setq aborted-p t)
                 (delete-process proc)
                 (funcall finish nil)))))
      proc)))

(defun quoth-context--assemble-stage-prompt (git-section)
  "Return the full system prompt with GIT-SECTION spliced in.
The gitless prompt was built synchronously at stage start; the section
lands inside its <env> block, matching `quoth-context--build-env-block'
assembly.  A nil or empty GIT-SECTION keeps the gitless prompt."
  (let ((base (quoth-context--build-system-prompt-uncached nil)))
    (if (or (null git-section) (string-empty-p git-section))
        base
      (let ((env-pos (string-match "</env>" base)))
        (if (not env-pos)
            base
          (concat (substring base 0 env-pos)
                  (format "\nGit status (snapshot at conversation start - may be outdated):\n%s\n"
                          git-section)
                  (substring base env-pos)))))))

(defun quoth-context-async (buf on-ready)
  "Deliver the system prompt for BUF to ON-READY, asynchronously.
Cache hit (the key — working dir + context modtimes — matches the
cached prompt) delivers inline.  A miss runs the git section in one
async process (marker-delimited) and delivers the assembled prompt on
the `quoth--schedule' hop; git failure, absence, or a stage past
`quoth-context-git-timeout' delivers without the git section.  Returns
the stage process, or nil on the cache-hit path."
  (let ((key (with-current-buffer buf
               (quoth-context--stage-prompt-key))))
    (if (and (with-current-buffer buf
               quoth-context--cached-system-prompt)
             (equal (with-current-buffer buf quoth-context--cache-key)
                    key))
        ;; Deliver inline; the return value stays nil (there is no
        ;; stage process to report).
        (progn
          (funcall on-ready
                   (with-current-buffer buf
                     quoth-context--cached-system-prompt))
          nil)
      (with-current-buffer buf
        (setq-local quoth-context--cache-key key)
        (setq-local quoth-context--cached-system-prompt nil))
      (quoth-context--system-prompt-stage buf key on-ready))))

(provide 'quoth-context)
;;; quoth-context.el ends here
