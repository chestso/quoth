;;; quoth-searxng.el --- SearXNG web_search tool for quoth  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/chestso/quoth
;;; Package-Requires: ((emacs "28.1"))
;;; Keywords: tools, ai, convenience

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

;; Local `web_search' tool implementation for quoth.el: queries a
;; local SearXNG instance over HTTP and returns normalized results in
;; the Codex-style prose convention (`Process exited with code N' +
;; `Output:').  The entry reports to ON-DONE once (as every registry
;; entry does) and never blocks: the JSON fetch rides the asynchronous
;; `url-retrieve' with a timeout timer, and the retrieval callback
;; normalizes the finished payload into a markdown list of results
;; (each carrying engine + score for the model to weigh relevance),
;; deduplicating by URL keeping the highest score.  The cancel thunk
;; deletes the retrieval process and its timer.
;;
;; Gating: the search request itself is the probe.  The first call
;; determines connectivity and caches the result in a buffer-local
;; `quoth-searxng--healthy'.  A healthy state (`t') just searches; an
;; unreachable state (`unreachable') short-circuits with no HTTP request
;; so a dead server is not hammered on every tool round.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-util)

;;; Prefer `require'; fall back to loading the siblings from this
;;; file's own directory so both flycheck and package-installed loads
;;; work.  The order follows the dependency graph: `quoth-json' first,
;;; then `quoth-openai' and `quoth-tools'.
(eval-and-compile
  (dolist (dep '("quoth-json" "quoth-openai" "quoth-tools"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(declare-function quoth-openai-tool-call-args "quoth-openai" (tool-call))
(declare-function quoth-exec--format-result "quoth-tools" (output exit-code))
(declare-function quoth-openai-tool-error-result "quoth-openai" (message))
(declare-function quoth-exec--truncate-output "quoth-tools" (output))

(defgroup quoth-searxng nil
  "Local SearXNG search tool for quoth."
  :group 'quoth
  :prefix "quoth-searxng-")

(defcustom quoth-searxng-base-url "http://127.0.0.1:8888"
  "Base URL of the local SearXNG instance."
  :type 'string
  :group 'quoth-searxng)

(defcustom quoth-searxng-timeout 10
  "HTTP timeout in seconds for SearXNG requests."
  :type 'integer
  :group 'quoth-searxng)

(defcustom quoth-searxng-max-results 8
  "Default and cap on number of results returned."
  :type 'integer
  :group 'quoth-searxng)

(defcustom quoth-searxng-enabled t
  "Announce the `web_search' tool and allow search calls.
When nil, `web_search' is not in the schema and calls error."
  :type 'boolean
  :group 'quoth-searxng)

(defvar-local quoth-searxng--healthy nil
  "Cached SearXNG health state (nil means unknown).
The value is nil \(unknown), t \(healthy), or `unreachable' \(dead,
which short-circuits future calls).")

(defun quoth-searxng--query (tool-call-args)
  "Return the resolved query string for TOOL-CALL-ARGS, or nil.
The `query' argument must be a non-empty string after trimming."
  (let ((q (plist-get tool-call-args :query)))
    (and (stringp q)
         (not (string-empty-p (string-trim q)))
         q)))

(defun quoth-searxng--max-results (tool-call-args)
  "Return the resolved max-results from TOOL-CALL-ARGS or the default.
Clamped to at least 1 and at most `quoth-searxng-max-results'."
  (let ((raw (plist-get tool-call-args :max_results)))
    (if (integerp raw)
        (max 1 (min quoth-searxng-max-results raw))
      quoth-searxng-max-results)))

(defun quoth-searxng--build-url (query args)
  "Build the SearXNG search URL for QUERY with optional ARGS."
  (let* ((params (list (list "q" query)
                       (list "format" "json")))
         (cats (plist-get args :categories))
         (engs (plist-get args :engines)))
    (when (and (stringp cats) (not (string-empty-p (string-trim cats))))
      (push (list "categories" cats) params))
    (when (and (stringp engs) (not (string-empty-p (string-trim engs))))
      (push (list "engines" engs) params))
    (concat quoth-searxng-base-url "/search?"
            (url-build-query-string (nreverse params)))))

(defun quoth-searxng--response-body (buf)
  "Extract the HTTP body from BUF, stripping the status line and headers."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (if (re-search-forward "\r?\n\r?\n" nil t)
          (buffer-substring-no-properties (point) (point-max))
        ""))))

(defun quoth-searxng--http-ok-p (buf)
  "Return t if BUF's HTTP status line indicates success (2xx)."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (looking-at-p "HTTP/[0-9.]+ 2[0-9][0-9]"))))

(defun quoth-searxng--format-score (score)
  "Format SCORE as a decimal string, or `unknown' if nil."
  (if (numberp score)
      (number-to-string score)
    "unknown"))

(defun quoth-searxng--format-engines (result)
  "Format the engine name(s) from a SearXNG RESULT alist.
Prefers the `engines' vector (real SearXNG); falls back to the
singular `engine' string for simplified test payloads."
  (let ((engs (cdr (assq 'engines result))))
    (if (and engs (vectorp engs) (> (length engs) 0))
        (mapconcat #'identity (append engs nil) ", ")
      (or (let ((e (cdr (assq 'engine result))))
            (and (stringp e) e))
          "unknown"))))

(defun quoth-searxng--result-string (result)
  "Format a single SearXNG RESULT alist as a markdown block."
  (let* ((title (or (cdr (assq 'title result)) ""))
         (url (or (cdr (assq 'url result)) ""))
         (content (or (cdr (assq 'content result)) ""))
         (engine (quoth-searxng--format-engines result))
         (score (quoth-searxng--format-score (cdr (assq 'score result)))))
    (format "Result [engine: %s, score: %s]:\n# %s\n%s\n%s"
            engine score title url content)))

(defun quoth-searxng--dedup (results)
  "Deduplicate RESULTS by URL, keeping the first (highest-scoring after sort)."
  (let ((seen nil)
        (out nil))
    (dolist (r results)
      (let ((url (cdr (assq 'url r))))
        (unless (member url seen)
          (push url seen)
          (push r out))))
    (nreverse out)))

(defun quoth-searxng--normalize (obj max)
  "Normalize parsed SearXNG JSON OBJ into a markdown result list.
Limits to MAX results after deduplication."
  (let* ((results-raw (or (cdr (assq 'results obj)) []))
         (results (if (vectorp results-raw)
                      (append results-raw nil)
                    results-raw))
         (sorted (sort results
                       (lambda (a b)
                         (let ((sa (cdr (assq 'score a)))
                               (sb (cdr (assq 'score b))))
                           (> (or (and (numberp sa) sa) 0)
                              (or (and (numberp sb) sb) 0))))))
         (deduped (quoth-searxng--dedup sorted))
         (top (cl-subseq deduped 0 (min max (length deduped))))
         (blocks (mapconcat #'quoth-searxng--result-string top "\n\n"))
         (info (quoth-searxng--format-infoboxes
                (cdr (assq 'infoboxes obj))))
         (sugg (quoth-searxng--format-suggestions
                (cdr (assq 'suggestions obj)))))
    (concat
     (if (string-empty-p blocks)
         "no results"
       blocks)
     (when info (concat "\n\n" info))
     (when sugg (concat "\n\n" sugg)))))

(defun quoth-searxng--format-infoboxes (infoboxes)
  "Format INFOBOXES vector as Info: lines, or nil if empty."
  (when (and infoboxes (vectorp infoboxes) (> (length infoboxes) 0))
    (let ((titles nil))
      (dotimes (i (length infoboxes))
        (let ((title (or (cdr (assq 'infobox (aref infoboxes i)))
                         (cdr (assq 'title (aref infoboxes i))))))
          (when (and title (not (string-empty-p title)))
            (push title titles))))
      (when titles
        (format "Info: %s" (mapconcat #'identity (nreverse titles) ", "))))))

(defun quoth-searxng--format-suggestions (suggestions)
  "Format SUGGESTIONS vector as a Suggestions: line, or nil if empty."
  (when (and suggestions (vectorp suggestions) (> (length suggestions) 0))
    (let ((items (append suggestions nil)))
      (when items
        (format "Suggestions: %s" (mapconcat #'identity items ", "))))))

(defun quoth-searxng--finish (state on-done health result)
  "Deliver RESULT to ON-DONE for the search tracked by STATE, once.
HEALTH is the state the outcome leaves in the owner buffer's
`quoth-searxng--healthy' cache (the search request is the probe).
STATE's :done flag makes the delivery exactly-once, so a retrieval
racing the timeout timer (or a cancelled wait) reports only the first
outcome.  Returns non-nil when the delivery happened."
  (unless (plist-get state :done)
    (plist-put state :done t)
    (when (buffer-live-p (plist-get state :owner))
      (with-current-buffer (plist-get state :owner)
        (setq quoth-searxng--healthy health)))
    (funcall on-done result)
    t))

(defun quoth-searxng--stop (state)
  "Stop the search tracked by STATE without marking it delivered.
Cancels the timeout timer, deletes the retrieval process (a deleted
retrieval makes `url-retrieve' run the callback with a non-response
buffer, which the delivery flag then ignores), and kills the response
buffer."
  (let ((timer (plist-get state :timer)))
    (when (timerp timer)
      (cancel-timer timer)
      (plist-put state :timer nil)))
  (let ((proc (plist-get state :proc)))
    (when (and proc (processp proc) (process-live-p proc))
      (delete-process proc)))
  (let ((buf (plist-get state :buf)))
    (when (and (bufferp buf) (buffer-live-p buf))
      (kill-buffer buf))))

(defun quoth-searxng--response-p (buf)
  "Return non-nil when BUF is a live buffer holding an HTTP response.
A deleted retrieval runs the callback with whatever buffer is
current; only a response buffer carries the `HTTP/' status-line
prefix."
  (and (bufferp buf)
       (buffer-live-p buf)
       (string-match-p
        "\\`HTTP/" (buffer-substring-no-properties
                    (point-min)
                    (min 6 (point-max))))))

(defun quoth-searxng--result (state buf max)
  "Return (HEALTH . RESULT) for the response in BUF tracked by STATE.
HEALTH is the health state the outcome caches; RESULT is the
\(RESULT . EXIT) pair delivered to the round.  An unreachable server,
an empty body, or malformed JSON yields an error result with
`unreachable'; a good payload yields the normalized prose result
with t."
  (cond
   ((not (with-current-buffer buf (quoth-searxng--response-p buf)))
    (plist-put state :buf nil)
    (cons 'unreachable
          (quoth-openai-tool-error-result
           "SearXNG is unreachable (empty response)")))
   ((or (not (quoth-searxng--http-ok-p buf))
        (string-empty-p
         (or (quoth-searxng--response-body buf) "")))
    (cons 'unreachable
          (quoth-openai-tool-error-result
           (format "SearXNG is unreachable (HTTP %s)"
                   (with-current-buffer buf
                     (buffer-substring-no-properties
                      (point-min) (line-end-position)))))))
   (t
    (let ((obj (quoth-json-read (quoth-searxng--response-body buf))))
      (if (not obj)
          (cons 'unreachable
                (quoth-openai-tool-error-result
                 "SearXNG returned malformed JSON"))
        (plist-put state :buf buf)
        (cons t
              (cons (quoth-exec--format-result
                     (quoth-searxng--normalize obj max) 0)
                    0)))))))

(defun quoth-searxng--callback (state on-done max)
  "Return the `url-retrieve' callback for the search tracked by STATE.
ON-DONE is the entry's reporter; MAX is the resolved result cap.  The
callback runs with the retrieval buffer current and receives the
retrieval STATUS; the finished payload is normalized and delivered
once through `quoth-searxng--finish'."
  (lambda (_status)
    (let ((buf (current-buffer)))
      (let ((outcome (quoth-searxng--result state buf max)))
        (when (quoth-searxng--finish state on-done
                                     (car outcome) (cdr outcome))
          (quoth-searxng--stop state))))))

(defun quoth-searxng--search (url args on-done)
  "Fetch URL asynchronously, reporting to ON-DONE once with the result.
ARGS carries the resolved max-results and the owner buffer.  Arms a
`quoth-searxng-timeout' timer that deletes the retrieval and delivers
an error result.  Returns the cancel thunk (delete the retrieval
process and its timer); a cancelled wait delivers nothing."
  (let* ((state (list :done nil
                      :owner (current-buffer)
                      :timer nil :proc nil :buf nil))
         (max (quoth-searxng--max-results args))
         (timer nil))
    (plist-put state :proc
               (url-retrieve url (quoth-searxng--callback state on-done max)
                             nil t))
    (setq timer
          (run-at-time
           quoth-searxng-timeout nil
           (lambda ()
             (plist-put state :timer nil)
             (quoth-searxng--stop state)
             (plist-put state :buf nil)
             (quoth-searxng--finish
              state on-done 'unreachable
              (quoth-openai-tool-error-result
               (format "SearXNG request timed out after %ss"
                       quoth-searxng-timeout))))))
    (plist-put state :timer timer)
    (lambda ()
      ;; Abandon the wait: stop the retrieval and mark the search
      ;; delivered so a late callback cannot report.
      (quoth-searxng--stop state)
      (plist-put state :done t))))

(defun quoth-searxng--exec (tool-call on-done)
  "Execute TOOL-CALL as `web_search', reporting to ON-DONE.
Validates the `query' arg, checks the cached health state, then
fetches JSON from SearXNG asynchronously (`url-retrieve' plus a
`quoth-searxng-timeout' timer) and delivers the normalized prose
result as (RESULT . EXIT-OR-NIL) to ON-DONE, exactly once.  Errors and
timeouts deliver an error result with exit code -1.  Returns the
cancel thunk (delete the retrieval process and its timer), or nil for
the immediate validation paths."
  (let ((args (quoth-openai-tool-call-args tool-call)))
    (cond
     ((not (bound-and-true-p quoth-searxng-enabled))
      (funcall on-done (quoth-openai-tool-error-result
                        "Web search is disabled"))
      nil)
     ((not (quoth-searxng--query args))
      (funcall on-done (quoth-openai-tool-error-result "Missing query"))
      nil)
     ((eq quoth-searxng--healthy 'unreachable)
      (funcall on-done
               (quoth-openai-tool-error-result
                "SearXNG is unreachable (cached); check the local server"))
      nil)
     (t
      (condition-case err
          (quoth-searxng--search
           (quoth-searxng--build-url (quoth-searxng--query args) args)
           args on-done)
        (error
         (setq-local quoth-searxng--healthy 'unreachable)
         (funcall on-done (quoth-openai-tool-error-result
                           (error-message-string err)))
         nil))))))

;;; Register the tool into the protocol registry.

(push (cons "web_search" #'quoth-searxng--exec)
      quoth-openai-tool-registry)

(provide 'quoth-searxng)
;;; quoth-searxng.el ends here
