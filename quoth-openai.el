;;; quoth-openai.el --- OpenAI chat-completions client for quoth  -*- lexical-binding: t; -*-
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

;; The reusable OpenAI chat-completions client for quoth.el: request
;; composition (history + tool-request shape), streaming SSE parsing,
;; and the curl transport.  The Charm Hyper provider
;; (`quoth-hyper-provider.el') uses this for its HTTP+SSE path; other
;; OpenAI-compatible providers can reuse it by supplying their own
;; config and composing requests through `quoth-openai-compose-request'
;; and `quoth-openai-request'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'auth-source)

;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The order follows the dependency graph: `quoth-json' first,
;;; then `quoth-provider' (the protocol it implements).
(eval-and-compile
  (dolist (dep '("quoth-json" "quoth-provider"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(defcustom quoth-openai-timeout 300
  "Seconds to wait for an OpenAI-compatible request before giving up."
  :type 'number
  :group 'quoth-openai)

(defcustom quoth-openai-max-tokens 64000
  "Default `max_tokens' for OpenAI-compatible requests."
  :type 'number
  :group 'quoth-openai)

(defcustom quoth-openai-temperature nil
  "Sampling temperature for OpenAI-compatible requests; nil means unset."
  :type '(choice (const nil) number)
  :group 'quoth-openai)

(defcustom quoth-openai-curl-program "curl"
  "Path to the curl executable used by the OpenAI client transport."
  :type 'string
  :group 'quoth-openai)

(defcustom quoth-openai-user-agent
  "Charm-Fantasy/0.41.0 (https://charm.land/fantasy)"
  "User-Agent header value for OpenAI chat-completions requests.
The Crush CLI does not set its own User-Agent on the Hyper chat path;
the value Hyper receives is the default of the fantasy SDK pinned in
the CLI's go.mod (charm.land/fantasy v0.41.0), rendered as
`Charm-Fantasy/<version> (https://charm.land/fantasy)'.  We send the
same string so the gateway sees an identical client."
  :type 'string
  :group 'quoth-openai)

(defcustom quoth-openai-system-prompt
  "You are a helpful assistant.  You answer concisely and correctly."
  "Base system prompt for every request.
Followed by the <env>, <project_context>, and <user_preferences>
blocks.  Read at request-build time; edits apply on the next cache
miss: context-file change, `quoth-clear-buffer', or a new buffer."
  :type 'string
  :group 'quoth-openai)

(defvar quoth-model nil
  "Model to use for Quoth requests (runtime selection, not a defcustom).
When nil, the provider falls back to `quoth-openai-default-model'.  The
core passes this into the provider's model slot at buffer
initialization.  Should be a model name like
`claude-sonnet-4-20250514' or `gpt-4o'.

A plain defvar: it is the runtime selection persisted by savehist, not
a user option owned by Customize.  To set a default, put `(setq
quoth-model ...)' in your init after quoth loads, or customize
`quoth-openai-default-model'.")

(defconst quoth-openai-default-model "deepseek-v4-flash"
  "Model used when the provider model slot and `quoth-model' are both nil.")

(defcustom quoth-openai-git-status-limit 20
  "Maximum lines of `git status --short' output in the <env> block.
Matches the Crush CLI's `head -20' cap."
  :type 'integer
  :group 'quoth-openai)

(defcustom quoth-openai-git-commits 3
  "Number of recent commits to include in the <env> block."
  :type 'integer
  :group 'quoth-openai)

(defcustom quoth-openai-git-timeout 10
  "Seconds the async git stage may take before it is abandoned.
A hung `git status' on a monorepo must not stall a chat send: past the
timeout the stage is aborted and the prompt is delivered without the
git section (git failure degrades the same way)."
  :type 'number
  :group 'quoth-openai)

(defcustom quoth-openai-strip-leading-blank-lines t
  "Strip leading blank lines from streamed assistant content.
Models may begin an answer with a run of newlines (for example, a blank
`content` delta before a `tool_calls` round) that duplicates the
separator quoth already inserts between regions.  When non-nil, such
newline-only `content` deltas are discarded until the first real answer
text arrives.  Set this to nil to preserve them verbatim if a provider
ever uses leading blank lines meaningfully."
  :type 'boolean
  :group 'quoth-openai)

(defcustom quoth-openai-debug-pretty-max 4096
  "Largest JSON payload (chars) that `quoth--openai-json-pretty' will format.
Request bodies grow with the system prompt (project context, git state),
so pretty-printing them on every request is both slow and a log bloat;
bodies larger than this cap are logged in compact, truncated form.  SSE
event payloads the debug log pretty-prints are small and unaffected."
  :type 'integer
  :group 'quoth-openai)

(declare-function quoth--debug-log "quoth.el" (category message))
(declare-function quoth--schedule "quoth.el" (fn))

;;; System prompt construction: <env> block with project context.

(defun quoth-openai--build-env-block (&optional git-section)
  "Build the <env> block for the system prompt, with GIT-SECTION.
Includes working directory, git repo status, platform, and date, plus
the GIT-SECTION string (the pre-formatted branch/status/commits block
from `quoth-openai--git-section') when inside a git repository.  Git
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

(defun quoth-openai--git-command ()
  "Return the single git command string for the git stage.
The three sections (branch, status, commits) run in one shell
invocation separated by marker `echo'es, so one process covers the
whole stage.  Runs in the buffer's `default-directory'."
  (concat
   "echo BRANCH_MARKER; git branch --show-current; "
   "echo STATUS_MARKER; git status --short | head -"
   (number-to-string quoth-openai-git-status-limit) "; "
   "echo COMMITS_MARKER; git log --oneline -n "
   (number-to-string quoth-openai-git-commits)))

(defun quoth-openai--git-section-from-output (raw)
  "Build the git section from the marker-delimited RAW stage output.
Returns nil when the output is empty (git failed or is unavailable),
matching the non-git degrade.  Mirrors the three-command summary:
current branch, status (clean or listed), recent commits."
  (let ((out (string-trim raw)))
    (unless (string-empty-p out)
      (let* ((branch (quoth-openai--marker-section out "BRANCH_MARKER"
                                                   "STATUS_MARKER"))
             (status (quoth-openai--marker-section out "STATUS_MARKER"
                                                   "COMMITS_MARKER"))
             (commits (quoth-openai--marker-section out "COMMITS_MARKER"
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

(defun quoth-openai--marker-section (raw start-marker &optional end-marker)
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

(defconst quoth-openai--default-context-paths
  '(".github/copilot-instructions.md"
    ".cursorrules"
    "CLAUDE.md" "CLAUDE.local.md"
    "GEMINI.md" "gemini.md"
    "crush.md" "crush.local.md"
    "Crush.md" "Crush.local.md"
    "CRUSH.md" "CRUSH.local.md"
    "AGENTS.md" "agents.md" "Agents.md")
  "Default context file paths to discover in the working directory.")

(defcustom quoth-openai-context-paths
  quoth-openai--default-context-paths
  "List of files/directories to scan for project context.
Paths are relative to the working directory.  Directories are
walked recursively.  Defaults match the Crush CLI's list."
  :type '(repeat string)
  :group 'quoth-openai)

(defcustom quoth-openai-global-context-paths
  (list (expand-file-name "crush/CRUSH.md"
                          (or (getenv "XDG_CONFIG_HOME")
                              "~/.config"))
        (expand-file-name "AGENTS.md"
                          (or (getenv "XDG_CONFIG_HOME")
                              "~/.config")))
  "Global context files applied across all projects."
  :type '(repeat string)
  :group 'quoth-openai)

(defun quoth-openai--discover-context-files (paths)
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

;;; System prompt construction: context block builders.

(defun quoth-openai--build-context-block (files tag header intro)
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

(defun quoth-openai--build-project-context-block (files)
  "Build the <project_context> block from FILES.
FILES is a list of (RELATIVE-PATH . CONTENT) conses.  Returns nil
when no files are found."
  (quoth-openai--build-context-block
   files "project_context"
   "Project-Specific Context"
   "Make sure to follow the instructions in the context below."))

(defun quoth-openai--build-user-preferences-block (files)
  "Build the <user_preferences> block from global FILES.
FILES is a list of (PATH . CONTENT) conses.  Returns nil when no
files are found."
  (quoth-openai--build-context-block
   files "user_preferences"
   "User context"
   "The following is personal content added by the user that they'd like you to follow no matter what project you're working in."))


;;; System prompt construction: full assembly and cache.

(defvar-local quoth-openai--cached-system-prompt nil
  "Cached system prompt string for this buffer.")

(defvar-local quoth-openai--cache-key nil
  "Cache key: (working-dir . context-file-modtimes).")

(defun quoth-openai--build-system-prompt-uncached (&optional git-section)
  "Build the full system prompt with project context, with GIT-SECTION.
Assembles base text + <env> block (carrying GIT-SECTION) +
<project_context> block + <user_preferences> block.  Called by
`quoth-openai--system-prompt-async' on cache miss."
  (let* ((env (quoth-openai--build-env-block git-section))
         (project-files (quoth-openai--discover-context-files
                         quoth-openai-context-paths))
         (project-block (quoth-openai--build-project-context-block
                         project-files))
         (global-files (quoth-openai--discover-context-files
                        quoth-openai-global-context-paths))
         (prefs-block (quoth-openai--build-user-preferences-block
                       global-files))
         (parts (delq nil
                      (list quoth-openai-system-prompt
                            env project-block prefs-block))))
    (string-join parts "\n\n")))

(defun quoth-openai--context-modtimes (&optional paths)
  "Return alist of (RELATIVE-PATH . MODTIME) for existing context files.
PATHS defaults to `quoth-openai-context-paths' plus
`quoth-openai-global-context-paths'.  Non-existent files are omitted.
MODTIME is from `file-attributes' (a list of integers)."
  (let* ((all-paths (or paths
                        (append quoth-openai-context-paths
                                quoth-openai-global-context-paths)))
         result)
    (dolist (p all-paths)
      (let ((full (expand-file-name p)))
        (when (file-readable-p full)
          (let ((modtime (file-attribute-modification-time
                          (file-attributes full))))
            (push (cons p modtime) result)))))
    (nreverse result)))

(defun quoth-openai--stage-prompt-key ()
  "Return the system-prompt cache key for the current directory.
The key is (working-dir . context-file-modtimes); context-file reads
are local bounded work and stay synchronous."
  (cons (expand-file-name default-directory)
        (quoth-openai--context-modtimes)))

(defun quoth-openai--stage-filter (proc string)
  "Filter for the git stage PROC accumulating chunk STRING."
  (process-put proc :quoth-stage-output
               (concat (or (process-get proc :quoth-stage-output) "")
                       string)))

(defun quoth-openai--make-stage-sentinel (finish)
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
               (quoth-openai--git-section-from-output
                (quoth-openai--stage-output proc))))))

(defun quoth-openai--stage-output (proc)
  "Return the accumulated output of the git stage PROC."
  (or (process-get proc :quoth-stage-output) ""))

(defun quoth-openai--system-prompt-stage (buf key on-ready)
  "Run the async git stage for the prompt cached under KEY in BUF.
Spawns one git process (the three sections marker-delimited), and on
its exit delivers the assembled prompt (cached under KEY) to ON-READY
via `quoth--schedule'.  A stage past `quoth-openai-git-timeout' is
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
            (let ((prompt (quoth-openai--assemble-stage-prompt
                           git-section)))
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (when (equal quoth-openai--cache-key key)
                    (setq-local quoth-openai--cached-system-prompt
                                prompt))))
              (quoth--schedule (lambda () (funcall on-ready prompt)))))))
    (if (not git-p)
        (progn
          ;; No git repo: the gitless prompt is the whole prompt.
          (funcall finish nil)
          nil)
      (let ((sentinel
             (quoth-openai--make-stage-sentinel
              (lambda (git-section)
                (unless aborted-p
                  (cancel-timer timeout)
                  (funcall finish git-section))))))
        (setq proc
              (make-process
               :name "quoth-git-stage"
               :buffer " *quoth-git-stage*"
               :command (list shell-file-name shell-command-switch
                              (quoth-openai--git-command))
               :connection-type 'pipe
               :noquery t
               :filter #'quoth-openai--stage-filter
               :sentinel sentinel))
        ;; Expose the sentinel on the process (the tests drive the real
        ;; filter + sentinel pipeline through it).
        (process-put proc :quoth-stage-sentinel sentinel))
      (setq timeout
            (run-at-time
             quoth-openai-git-timeout nil
             (lambda ()
               (when (process-live-p proc)
                 (setq aborted-p t)
                 (delete-process proc)
                 (funcall finish nil)))))
      proc)))

(defun quoth-openai--assemble-stage-prompt (git-section)
  "Return the full system prompt with GIT-SECTION spliced in.
The gitless prompt was built synchronously at stage start; the section
lands inside its <env> block, matching `quoth-openai--build-env-block'
assembly.  A nil or empty GIT-SECTION keeps the gitless prompt."
  (let ((base (quoth-openai--build-system-prompt-uncached nil)))
    (if (or (null git-section) (string-empty-p git-section))
        base
      (let ((env-pos (string-match "</env>" base)))
        (if (not env-pos)
            base
          (concat (substring base 0 env-pos)
                  (format "\nGit status (snapshot at conversation start - may be outdated):\n%s\n"
                          git-section)
                  (substring base env-pos)))))))

(defun quoth-openai--system-prompt-async (buf on-ready)
  "Deliver the system prompt for BUF to ON-READY, asynchronously.
Cache hit (the key — working dir + context modtimes — matches the
cached prompt) delivers inline.  A miss runs the git section in one
async process (marker-delimited) and delivers the assembled prompt on
the `quoth--schedule' hop; git failure, absence, or a stage past
`quoth-openai-git-timeout' delivers without the git section.  Returns
the stage process, or nil on the cache-hit path."
  (let ((key (with-current-buffer buf
               (quoth-openai--stage-prompt-key))))
    (if (and (with-current-buffer buf
               quoth-openai--cached-system-prompt)
             (equal (with-current-buffer buf quoth-openai--cache-key)
                    key))
        ;; Deliver inline; the return value stays nil (there is no
        ;; stage process to report).
        (progn
          (funcall on-ready
                   (with-current-buffer buf
                     quoth-openai--cached-system-prompt))
          nil)
      (with-current-buffer buf
        (setq-local quoth-openai--cache-key key)
        (setq-local quoth-openai--cached-system-prompt nil))
      (quoth-openai--system-prompt-stage buf key on-ready))))

;;; Tool protocol: the OpenAI function-calling shape the client speaks.

(defcustom quoth-tools-enabled t
  "Announce the registered tools and allow tool-call rounds.
When nil, requests are byte-identical to the pre-tools format with no
`tools' key in the request body."
  :type 'boolean
  :group 'quoth)

(defcustom quoth-tool-loop-max 8
  "Tool rounds per user prompt before the loop stops.
When the loop cap is hit, a final result tells the model to stop and
the request finalizes."
  :type 'integer
  :group 'quoth)

(defvar quoth-openai-tool-registry
  (list)
  "Alist mapping tool-call names to entry functions.
An entry takes TOOL-CALL and ON-DONE: TOOL-CALL is a
`quoth-openai-tool-call' struct whose `args' slot holds the parsed
argument plist; ON-DONE receives the result (RESULT-TEXT .
EXIT-OR-NIL) exactly once — inline for immediate tools, from a window
timer or the session sentinel for process-backed ones.  The entry
returns a cancel thunk (abandon the wait; nil for immediate tools).
Local tool files (e.g. `quoth-tools.el') push their tools here at load
time.")

(cl-defstruct (quoth-openai-tool-call
               (:constructor nil)
               (:constructor quoth-make-openai-tool-call
                             (&key id name &aux (args nil) (result nil) (exit nil))))
  "A single tool call in flight.
ID is the model's call id; NAME the tool name; ARGS the parsed
argument plist (filled by the executor); RESULT the result text;
EXIT the exit code (filled after execution)."
  id
  name
  args
  result
  exit)

(defun quoth-openai-parse-tool-args (args-json)
  "Parse ARGS-JSON (a JSON string) into a plist, or nil when malformed.
Unknown keys are ignored; a non-alist payload yields nil."
  (when (and (stringp args-json) (> (length args-json) 0))
    (let ((obj (ignore-errors (quoth-json-read args-json))))
      (when (consp obj)
        (let (plist)
          (pcase-dolist (`(,key . ,value) obj)
            (let ((sym (intern (format ":%s" key))))
              (setq plist (plist-put plist sym value))))
          plist)))))

(defun quoth-openai-tool-error-result (message)
  "Return an error (RESULT-TEXT . EXIT-CODE) pair for MESSAGE.
Renders the error in Codex's prose convention with exit code -1: a
`Process exited with code -1' status line, then `Output:' and the
message."
  (cons (format "Process exited with code -1\nOutput:\n%s" message)
        -1))

(defun quoth-openai-execute-tool (tool-call on-done)
  "Dispatch TOOL-CALL, delivering its result to ON-DONE exactly once.
Looks up the tool name in `quoth-openai-tool-registry'; an unknown tool
delivers an error result to ON-DONE without spawning any process.
ON-DONE receives (RESULT-TEXT . EXIT-OR-NIL); the wrapper guards it
exactly-once, so a delivery racing the entry's own reporting
\(window timer vs. sentinel) reports only the first.  Logs the call
name and args under the `tool' category at dispatch and the result at
completion; entries must not log themselves.  Returns the entry's
cancel thunk (abandon the wait), or nil for immediate tools."
  (let* ((name (quoth-openai-tool-call-name tool-call))
         (entry (assoc name quoth-openai-tool-registry))
         (donep nil)
         (report (lambda (result)
                   (unless donep
                     (setq donep t)
                     (quoth--debug-log
                      'tool
                      (format "%s exit=%s output=%S"
                              name
                              (or (cdr result) "running")
                              (substring (car result)
                                         0 (min (length (car result)) 200))))
                     (funcall on-done result)))))
    (quoth--debug-log
     'tool
     (format "%s %S" name (quoth-openai-tool-call-args tool-call)))
    (if entry
        (funcall (cdr entry) tool-call report)
      (let ((result (quoth-openai-tool-error-result
                     (format "unknown tool %S" name))))
        (funcall report result)
        nil))))

(defun quoth-openai-compose-request (prompt model &optional history continuation)
  "Compose a chat-completions request alist for PROMPT.
MODEL is the resolved model (the caller passes the provider's model
slot, already derived from the shared `quoth-model' variable).  Falls
back to `quoth-openai-default-model'.  The system prompt is the
buffer's cached one (the staged send guarantees it is built before the
request composes); falls back to `quoth-openai--build-system-prompt-uncached'
when the cache is empty (a direct compose without a prior stage).
HISTORY is a list of message alists (already reconstructed from the
buffer by `quoth--history-for'); they ride between the system prompt
and the new user message.  With no history the body carries exactly
system + user (`stream: t', no tools).  History is disabled by the
caller passing nil (`quoth-hyper-history-limit 0 means the core
extracts none).  CONTINUATION, when non-nil, is a list of message
alists (user, assistant with `tool_calls', `role: \"tool\"') that
replace the user message; used by the tool loop to send follow-up
requests with tool results.  Both inputs are message alists, never
\(ROLE . TEXT) conses.  When `quoth-tools-enabled' is non-nil (the
default), the request announces the `bash' tool and
`tool_choice: \"auto\"'."
  (let* ((model (or model quoth-openai-default-model))
         (sys-prompt (or quoth-openai--cached-system-prompt
                         (quoth-openai--build-system-prompt-uncached)))
         (user-content prompt)
         (messages
          (cond
           (continuation
            (append (list (list '(role . "system")
                                (cons 'content sys-prompt)))
                    (or history nil)
                    continuation))
           (history
            (append (list (list '(role . "system")
                                (cons 'content sys-prompt)))
                    history
                    (list (list '(role . "user")
                                (cons 'content user-content)))))
           (t
            (list (list '(role . "system")
                        (cons 'content sys-prompt))
                  (list '(role . "user")
                        (cons 'content user-content))))))
         (body `((model . ,model)
                 (stream . t)
                 (messages . ,messages))))
    (when quoth-openai-max-tokens
      (setq body (cons (cons 'max_tokens quoth-openai-max-tokens) body)))
    (when quoth-openai-temperature
      (setq body (cons (cons 'temperature quoth-openai-temperature) body)))
    (when quoth--session-thinking
      (setq body (cons (cons 'thinking quoth--session-thinking) body)))
    (when quoth--session-reasoning-effort
      (setq body (append body
                         `((reasoning_effort . ,quoth--session-reasoning-effort)))))
    (when quoth-tools-enabled
      (setq body (append body
                         (list (cons 'tools (quoth--openai-tool-schema))
                               (cons 'tool_choice "auto")))))
    body))

(defun quoth--openai-tool-schema ()
  "Return the tool schema vector for all registered tools.
Includes `exec_command', `write_stdin', `write_file', `read_file', and
`web_search' (when `quoth-searxng-enabled' is non-nil)."
  (let ((exec-props
         `((cmd . ((type . "string")
                   (description . "Shell command to execute")))
           (workdir . ((type . "string")
                       (description . "Working directory (defaults to the buffer's project root)")))
           (yield_time_ms . ((type . "number")
                             (description . "Wait before returning a session ID for a still-running command. Defaults 10000 ms; range 250-30000 ms.")))
           (shell . ((type . "string")
                     (description . "Shell binary to run the command under. Defaults to the user's default shell.")))
           (login . ((type . "boolean")
                     (description . "True runs the shell with -l (login) semantics; false disables them. Disabled by config by default.")))))
        (write-props
         `((session_id . ((type . "number")
                          (description . "Session identifier returned by exec_command")))
           (input . ((type . "string")
                     (description . "Characters to write to the session's stdin; end with \\x04 (EOT) to close stdin - the marker is only valid as the last four characters")))
           (yield_time_ms . ((type . "number")
                             (description . "Read window to collect fresh output after writing. Defaults 1000 ms.")))))
        (write-file-props
         `((path . ((type . "string")
                    (description . "Target path, absolute or relative to workdir; tilde is expanded.")))
           (content . ((type . "string")
                       (description . "Full file text written byte-exact; line endings are preserved as given (no trailing newline is added).")))
           (workdir . ((type . "string")
                       (description . "Base directory for a relative path (defaults to the buffer's project root).")))
           (mode . ((type . "number")
                    (description . "POSIX permission bits as a decimal integer (420 = 0644, 493 = 0755) applied to the file after the write, on both fresh and overwrite paths. Optional; without it a fresh file keeps the default 0600.")))
           (overwrite . ((type . "boolean")
                         (description . "When false, fail if the file already exists. Defaults to true.")))))
        (read-file-props
         `((path . ((type . "string")
                    (description . "Target path, absolute or relative to workdir; tilde is expanded.")))
           (workdir . ((type . "string")
                       (description . "Base directory for a relative path (defaults to the buffer's project root).")))
           (line_numbers . ((type . "boolean")
                            (description . "Prefix each line with its 1-based number in cat -n style (N\\tcontent). Strip the prefix from each line before passing content back to write_file; prefixes leaked into a write corrupt the file. Off by default - leave off when you only need byte-exact read->edit->write round trips.")))
           (offset . ((type . "integer")
                      (description . "1-based first line to return. The output's line numbers start at offset, not 1, so references stay meaningful. An offset past the last line is an error; the output otherwise reuses the file's true line numbers.")))
           (limit . ((type . "integer")
                     (description . "Maximum lines returned. Clamped silently to EOF; 0 or negative is an error. Pairs with offset to paginate a file cheaply when only a slice is needed.")))))
        (search-props
         `((query . ((type . "string")
                     (description . "Search query")))
           (categories . ((type . "string")
                          (description . "Comma-separated SearXNG categories (general, images, news, science, code...). Optional.")))
           (engines . ((type . "string")
                       (description . "Comma-separated engine sources. Optional.")))
           (max_results . ((type . "integer")
                           (description . "Cap on returned results. Optional."))))))
    (let ((tools `[((type . "function")
                    (function . ((name . "exec_command")
                                 (description . "Run a command and return its output plus an exit code, or a session ID when the command is still running.")
                                 (parameters . ((type . "object")
                                                (properties . ,exec-props)
                                                (required . ["cmd"]))))))
                   ((type . "function")
                    (function . ((name . "write_stdin")
                                 (description . "Write to a running exec_command session and return recently produced output.")
                                 (parameters . ((type . "object")
                                                (properties . ,write-props)
                                                (required . ["session_id"]))))))
                   ((type . "function")
                    (function . ((name . "write_file")
                                 (description . "Write a complete file atomically and byte-exact to the given path. Replaces any existing file unless overwrite is false, and creates parent directories as needed.")
                                 (parameters . ((type . "object")
                                                (properties . ,write-file-props)
                                                (required . ["path" "content"]))))))
                   ((type . "function")
                    (function . ((name . "read_file")
                                 (description . "Read a file's text and return its content (or a window of it) under a byte cap. Un-numbered reads are byte-exact (a CRLF on disk stays a CRLF) and suited to read->edit->write_file round trips. Set line_numbers to prefix each line with its 1-based number in cat -n style when you need to refer to lines by number. Use offset and limit to paginate cheaply. Errors on missing/unreadable paths and non-UTF-8 content.")
                                 (parameters . ((type . "object")
                                                (properties . ,read-file-props)
                                                (required . ["path"]))))))]))
      (when (bound-and-true-p quoth-searxng-enabled)
        (setq tools
              (vconcat tools
                       `[((type . "function")
                          (function . ((name . "web_search")
                                       (description . "Search the web via the local SearXNG instance. Returns results with engine and score metadata.")
                                       (parameters . ((type . "object")
                                                      (properties . ,search-props)
                                                      (required . ["query"]))))))])))
      tools)))
(defun quoth-openai-sse-new-state ()
  "Return a fresh SSE parser state plist."
  (list :pending "" :done nil :error nil :tool-calls nil :content-started nil :usage nil))

(defun quoth--openai-blank-content-p (text)
  "Return non-nil when TEXT is a newline-only, non-empty content string."
  (and (stringp text)
       (> (length text) 0)
       (string-match-p "\\`[\n\r]+\\'" text)))

(defun quoth-openai-sse-feed (state chunk &optional &rest args)
  "Feed CHUNK into SSE parser STATE and return (DELTAS . NEW-STATE).
Each delta is a (KIND TEXT ORIG) list, where KIND is `content',
`reasoning', or `tool_calls' (TEXT nil for tool_calls).
Sets `:done' when `[DONE]' or an error payload is seen; the
`:pending' buffer keeps partial events across chunk boundaries.
ARGS may contain :on-event, a callback invoked with the raw payload
of each COMPLETE `data:' event (before it is dispatched), including
`[DONE]'."
  (let ((pending (concat (plist-get state :pending) chunk))
        (done (plist-get state :done))
        (error (plist-get state :error))
        (on-event (plist-get args :on-event))
        (content-started (plist-get state :content-started))
        (deltas nil))
    ;; Normalize CRLF, then split into events.  An event is one or more
    ;; lines followed by a blank line (\"\\n\\n\").  A trailing fragment
    ;; with no blank line yet stays pending.
    (let* ((text (replace-regexp-in-string "\r\n" "\n" pending))
           (complete-p (string-suffix-p "\n\n" text))
           (events (mapcar (lambda (b) (split-string b "\n" t))
                           (split-string (if complete-p
                                             (substring text 0 -2)
                                           text)
                                         "\n\n" t))))
      ;; When incomplete the last element is an unterminated fragment.
      (setq pending (if complete-p
                        ""
                      (string-join (car (last events)) "\n")))
      (unless complete-p
        (setq events (nreverse (cdr (nreverse events)))))
      (unless done
        (dolist (event events)
          (let ((data-lines (seq-filter
                             (lambda (l) (string-prefix-p "data:" l))
                             event)))
            ;; Each data: line is an independent payload (OpenAI/Hyper
            ;; never splits a JSON event across lines).
            (dolist (data-line data-lines)
              (let ((payload (string-trim (substring data-line 5))))
                (when (functionp on-event)
                  (funcall on-event payload))
                (cond
                 ((string= payload "[DONE]")
                  (setq done t))
                 ((string-prefix-p "{" payload)
                  (let ((obj (ignore-errors (quoth-json-read payload))))
                    (if (and obj (quoth--openai-alist-get "error" obj))
                        (progn
                          (setq done t)
                          (let ((err (quoth--openai-alist-get "error" obj)))
                            ;; An object error carries message/type; render
                            ;; them to a string so the on-error contract
                            ;; stays a string (never an alist).
                            (setq error
                                  (if (and (consp err)
                                           (quoth--openai-alist-get
                                            "message" err))
                                      (let ((msg (quoth--openai-alist-get
                                                  "message" err))
                                            (type (quoth--openai-alist-get
                                                   "type" err)))
                                        (format "%s%s"
                                                (or msg "")
                                                (and type
                                                     (format " (%s)" type))))
                                    err))))
                      (dolist (delta (quoth--openai-sse-extract-deltas obj))
                        (if (and (eq (nth 0 delta) 'content)
                                 (quoth--openai-blank-content-p (nth 1 delta)))
                            (unless (and quoth-openai-strip-leading-blank-lines
                                         (not content-started))
                              (setq deltas (nconc deltas (list delta))))
                          ;; Non-blank content (or reasoning/tool_calls)
                          ;; marks the start of the real answer; from
                          ;; here on blank content is legitimate.
                          (when (eq (nth 0 delta) 'content)
                            (setq content-started t))
                          (setq deltas (nconc deltas (list delta)))))
                      (when obj
                        (let ((u (quoth--openai-alist-get "usage" obj)))
                          (when u
                            (plist-put state :usage u)))
                        (quoth--openai-sse-merge-tool-calls state obj)))))))))))
      (cons deltas
            (list :pending pending :done done :error error
                  :tool-calls (plist-get state :tool-calls)
                  :content-started content-started
                  :usage (plist-get state :usage))))))

(defun quoth--openai-alist-get (key alist)
  "Return the value for KEY in ALIST, handling symbol or string keys."
  (or (cdr (assoc key alist))
      (cdr (assoc (if (stringp key) (intern key) (symbol-name key)) alist))))

(defun quoth--openai-alist-set (key alist value)
  "Set KEY to VALUE in ALIST, handling symbol or string keys.
Mutates the existing cell in place when found (either key type);
otherwise prepends a new (KEY . VALUE) cell and returns ALIST.
KEY is stored as a string to match `json-read-from-string' convention."
  (let ((cell (or (assoc key alist)
                  (assoc (if (stringp key) (intern key) (symbol-name key)) alist))))
    (if cell
        (setcdr cell value)
      (setcar alist (cons (if (stringp key) key (symbol-name key)) value)))
    alist))

(defun quoth--openai-first-choice (obj)
  "Return the first choices[] entry from SSE JSON object OBJ, or nil."
  (let ((raw-choices (quoth--openai-alist-get "choices" obj)))
    (if (vectorp raw-choices)
        (and (> (length raw-choices) 0)
             (aref raw-choices 0))
      (car-safe raw-choices))))

(defun quoth--openai-sse-extract-deltas (obj)
  "Return typed deltas from SSE JSON object OBJ.
Each delta is a list (KIND TEXT ORIG) where KIND is `content',
`reasoning', or `tool_calls'; TEXT is the delta text (nil for
tool_calls); ORIG is the parsed JSON object (nil when OBJ is nil)."
  (when obj
    (let* ((first-choice (quoth--openai-first-choice obj))
           (delta (and first-choice
                       (quoth--openai-alist-get "delta" first-choice)))
           (content (and delta
                         (quoth--openai-alist-get "content" delta)))
           (reasoning (and delta
                           (quoth--openai-alist-get "reasoning_content" delta)))
           (tool-calls (and delta
                            (quoth--openai-alist-get "tool_calls" delta))))
      (delq nil
            (list (when (stringp content)
                    (list 'content content obj))
                  (when (stringp reasoning)
                    (list 'reasoning reasoning obj))
                  (when (and tool-calls (vectorp tool-calls))
                    (list 'tool_calls nil obj)))))))

(defun quoth--openai-sse-merge-tool-calls (state obj)
  "Merge tool-call deltas from OBJ into STATE's :tool-calls vector.
OpenAI emits each tool call as several deltas: every delta carries
an index, an id (on the first chunk), and function name/arguments.
Arguments accumulate across chunks by index."
  (let* ((first-choice (quoth--openai-first-choice obj))
         (delta (and first-choice
                     (quoth--openai-alist-get "delta" first-choice)))
         (tc-delta (and delta
                        (quoth--openai-alist-get "tool_calls" delta))))
    (when (and tc-delta (vectorp tc-delta))
      (let ((tcs (plist-get state :tool-calls)))
        (unless tcs (setq tcs (make-vector 0 nil)))
        (seq-do
         (lambda (tc)
           (let ((idx (quoth--openai-alist-get "index" tc)))
             (when (and idx (integerp idx))
               (while (>= idx (length tcs))
                 (setq tcs (vconcat tcs [nil])))
               (let ((existing (aref tcs idx)))
                 (if existing
                     ;; Merge: glue new arguments onto the existing
                     ;; function's arguments cell.
                     (let* ((new-fn (quoth--openai-alist-get
                                     "function" tc))
                            (new-args (and new-fn
                                           (quoth--openai-alist-get
                                            "arguments" new-fn)))
                            (ex-fn (quoth--openai-alist-get
                                    "function" existing)))
                       (when (and new-args ex-fn)
                         (let ((cur-args (quoth--openai-alist-get
                                          "arguments" ex-fn)))
                           (quoth--openai-alist-set
                            "arguments" ex-fn
                            (concat (or cur-args "") new-args)))))
                   ;; First delta for this index: store as-is.
                   (aset tcs idx tc))))))
         tc-delta)
        (plist-put state :tool-calls tcs)))))

;;; Hyper transport

;;; The transport shells out to curl (like gptel and plz.el): curl is a
;;; mature HTTP client with reliable TLS, proxies, and streaming, and its
;;; subprocess filter gives us SSE chunks as they arrive without fighting
;;; url.el or raw sockets.  Request config and body go to curl via stdin.

(defun quoth--openai-emit-delta (proc delta kind)
  "Emit DELTA text of KIND (`content' or `reasoning') for PROC.
Store the delta as a pending `:quoth-emitted' event on PROC and
invoke the core's `:quoth-on-delta' callback, which is a closure
taking (DELTA KIND), that owns buffer insertion, the reasoning
overlay, and the cursor.  The transport never touches buffers."
  (process-put proc :quoth-emitted t)
  (let ((on-delta (process-get proc :quoth-on-delta)))
    (when (functionp on-delta)
      (funcall on-delta delta kind))))

(defun quoth-openai-abort (proc)
  "Abort the in-flight OpenAI transport process PROC.
Marks PROC finished before sending any signal so the curl sentinel
cannot re-finalize after a deliberate interrupt, then interrupts and
deletes the process.  Returns nil, and is inert when PROC is not a
process."
  (when (processp proc)
    ;; Mark finished first: a racing sentinel must observe
    ;; `:quoth-finished' and skip the completion/error callbacks.
    (process-put proc :quoth-finished t)
    (ignore-errors (interrupt-process proc))
    (when (process-live-p proc)
      (ignore-errors (delete-process proc))))
  nil)

(defun quoth--openai-http-finish (proc error)
  "Finalize the curl request on PROC with optional ERROR.
Emits ERROR through the core's `:quoth-on-error' callback when
non-nil, then runs the finalize callback exactly once."
  (unless (process-get proc :quoth-finished)
    ;; Mark finished first so a sentinel racing the [DONE] filter path
    ;; cannot double-finalize.
    (process-put proc :quoth-finished t)
    (when error
      (let ((on-error (process-get proc :quoth-on-error)))
        (when (functionp on-error)
          (funcall on-error error))))
    (let ((finish (process-get proc :quoth-done-callback)))
      (when finish (funcall finish)))
    (when (process-live-p proc)
      (delete-process proc))))

(defun quoth--openai-curl-filter (proc string)
  "Filter for the curl process PROC receiving SSE chunk STRING.
Feed the chunk to the SSE parser and emit any content deltas through
the core's on-delta callback.  The HTTP response head (headers) is
not valid SSE and is ignored by the parser; the status line is parsed
for diagnostics, and errors are surfaced by the sentinel when curl
exits non-zero."
  (unless (process-get proc :quoth-head-parsed)
    (setq string (quoth--openai-parse-head proc string)))
  (let* ((on-event (lambda (payload)
                     (quoth--debug-log
                      'output
                      (if (quoth--openai-event-worth-pretty-p payload)
                          (concat "data:\n"
                                  (quoth--openai-json-pretty payload))
                        (concat "data: " payload)))))
         (sse-state (process-get proc :quoth-sse))
         (result (quoth-openai-sse-feed sse-state string :on-event on-event))
         (deltas (car result))
         (new-state (cdr result)))
    (dolist (delta deltas)
      (when (nth 1 delta)
        (quoth--openai-emit-delta proc (nth 1 delta) (nth 0 delta))))
    ;; Persist the full parser state: the state plist has no :sse key,
    ;; and dropping the `:pending' fragment would lose any SSE event
    ;; split across process-filter chunks.
    (process-put proc :quoth-sse new-state)
    (when (plist-get new-state :done)
      (quoth--openai-http-finish proc (plist-get new-state :error)))))

(defun quoth--openai-parse-head (proc string)
  "Parse the HTTP status line out of the first chunks from PROC.
Accumulates chunks in `:quoth-head' until a double newline, then
records `:quoth-status' and `:quoth-content-type', logs a request
diagnostic line, and returns the remainder of STRING after the head.
The token is never logged."
  (let ((head (concat (process-get proc :quoth-head) string)))
    (if (string-match "\r?\n\r?\n" head)
        (let* ((head-text (substring head 0 (match-beginning 0)))
               (status (and (string-match "HTTP/[0-9.]+ \\([0-9]+\\)" head-text)
                            (string-to-number (match-string 1 head-text))))
               (content-type (and (string-match
                                   "content-type: *\\([^\r\n]+\\)"
                                   head-text)
                                  (downcase (match-string 1 head-text)))))
          (process-put proc :quoth-status status)
          (process-put proc :quoth-content-type content-type)
          (process-put proc :quoth-head-parsed t)
          (quoth--debug-log 'output (string-replace "\r" "" head-text))
          (quoth--debug-log
           'response
           (format "POST %s model=%S status=%s content-type=%s token=%s"
                   (process-get proc :quoth-url)
                   (process-get proc :quoth-model)
                   (if status (number-to-string status) "?")
                   (or content-type "?")
                   (if (process-get proc :quoth-token-p) "present" "none")))
          (substring head (match-end 0)))
      (progn
        (process-put proc :quoth-head head)
        ""))))

(defun quoth--openai-curl-sentinel (proc _event)
  "Sentinel for the curl process PROC.
If the stream did not end with `[DONE]' (e.g. connection dropped or
HTTP error), finish with an error; otherwise ensure cleanup."
  (let ((status (process-get proc :quoth-status)))
    (quoth--debug-log
     'sentinel
     (format "curl exited; status=%s finished=%S"
             (if status (number-to-string status) "?")
             (process-get proc :quoth-finished)))
    (unless (process-get proc :quoth-finished)
      (quoth--openai-http-finish
       proc
       (cond
        ((null status)
         (format "connection closed before response head from %s"
                 (process-get proc :quoth-url)))
        ((and (<= 200 status) (< status 300))
         (format "stream closed before [DONE] (HTTP %s from %s)"
                 status (process-get proc :quoth-url)))
        (t
         (format "HTTP %s from %s" status (process-get proc :quoth-url))))))))

(defun quoth--openai-json-pretty (json-string)
  "Return JSON-STRING pretty-printed with 2-space indentation.
Uses `json-pretty-print' in a temp buffer, avoiding any dependency on
`json-pretty-print-string' (not present in older json.el).  Payloads
longer than `quoth-openai-debug-pretty-max' are returned compact and
truncated (with a size note) rather than pretty-printed, so the debug
log stays cheap and bounded on large request bodies."
  (if (> (length json-string) quoth-openai-debug-pretty-max)
      (let ((max quoth-openai-debug-pretty-max))
        (format "%s
... [%d chars omitted]" (substring json-string 0 max)
(- (length json-string) max)))
    (with-temp-buffer
      (insert json-string)
      (json-pretty-print (point-min) (point-max))
      (buffer-string))))

(defun quoth--openai-event-worth-pretty-p (payload)
  "Return non-nil if SSE PAYLOAD deserves pretty-printing in the log.
A payload is worth pretty-printing when it parses as JSON and either
carries the final chunk (`choices[].finish_reason' or top-level
`usage') or a long delta text (>= 40 chars).  Everything else --
short per-token deltas, `[DONE]', malformed payloads -- is kept
compact to bound the debug log during long streams."
  (when (and (string-prefix-p "{" payload))
    (let ((obj (ignore-errors (quoth-json-read payload))))
      (when obj
        (let* ((first-choice (quoth--openai-first-choice obj))
               (delta (and first-choice
                           (quoth--openai-alist-get "delta" first-choice)))
               (finish (and first-choice
                            (quoth--openai-alist-get "finish_reason" first-choice)))
               (usage (quoth--openai-alist-get "usage" obj))
               (content (and delta
                             (quoth--openai-alist-get "content" delta)))
               (reasoning (and delta
                               (quoth--openai-alist-get "reasoning_content" delta)))
               (text (or content reasoning)))
          (or finish usage
              (and (stringp text)
                   (>= (length text) 40))))))))

(defun quoth-openai-request (base-url token body on-delta callback &optional on-error session-id x-crush-id)
  "Send HTTP POST to BASE-URL with TOKEN and JSON BODY via curl.
ON-DELTA is a callback (DELTA KIND) consuming streamed deltas (the
core's append-delta); CALLBACK runs with no args when the stream
finishes; ON-ERROR (optional) receives a stream error message;
SESSION-ID, when non-nil, is the XXH3-64 of the buffer's session UUID,
sent as x-session-id / x-session-affinity for prefix caching.
X-CRUSH-ID, when non-nil, is sent as the x-crush-id header (matching
the Crush CLI's per-machine ID).  The provider never touches buffers.
Returns the curl process."
  (let* ((payload (quoth-json-write body))
         (config (concat
                  (format "url = %s/chat/completions\n" base-url)
                  "request = POST\n"
                  "include\n"
                  "silent\n"
                  "no-buffer\n"
                  (format "max-time = %s\n" (or quoth-openai-timeout 300))
                  "header = \"Content-Type: application/json\"\n"
                  (format "header = \"User-Agent: %s\"\n" quoth-openai-user-agent)
                  (when token
                    (format "header = \"Authorization: Bearer %s\"\n" token))
                  (when session-id
                    (format "header = \"x-session-id: %s\"\n" session-id))
                  (when session-id
                    (format "header = \"x-session-affinity: %s\"\n" session-id))
                  (when x-crush-id
                    (format "header = \"x-crush-id: %s\"\n" x-crush-id))
                  "data-binary = @-\n"))
         (buf (get-buffer-create " *quoth-hyper*"))
         (proc (make-process
                :name "quoth-hyper"
                :buffer buf
                :command (list quoth-openai-curl-program
                               "--config" "-")
                :connection-type 'pipe
                :noquery t
                :filter #'quoth--openai-curl-filter
                :sentinel #'quoth--openai-curl-sentinel
                :stderr (get-buffer-create "*quoth-errors*"))))
    (process-put proc :quoth-sse (quoth-openai-sse-new-state))
    (process-put proc :quoth-on-delta on-delta)
    (process-put proc :quoth-on-error on-error)
    (process-put proc :quoth-done-callback callback)
    ;; Request metadata for `quoth--openai-curl-filter' diagnostics.
    (process-put proc :quoth-url (format "%s/chat/completions" base-url))
    (process-put proc :quoth-model (quoth--openai-alist-get "model" body))
    (process-put proc :quoth-token-p (and token t))
    (process-put proc :quoth-head "")
    (process-put proc :quoth-head-parsed nil)
    (process-put proc :quoth-status nil)
    (quoth--debug-log
     'request
     (format "POST %s model=%S token=%s sess=%s\nbody:\n%s"
             (process-get proc :quoth-url)
             (process-get proc :quoth-model)
             (if (process-get proc :quoth-token-p) "present" "none")
             (or session-id "-")
             (quoth--openai-json-pretty (quoth-json-write body))))
    ;; Config + JSON body over stdin; EOF closes the request.
    (process-send-string proc config)
    (process-send-string proc payload)
    (process-send-eof proc)
    proc))

(provide 'quoth-openai)
;;; quoth-openai.el ends here
