;;; crush-searxng.el --- SearXNG web_search tool for crush  -*- lexical-binding: t; -*-
;;; Copyright (C) 2026 Thomas Christensen

;;; Author: Thomas Christensen <thomasc1971@hotmail.com>
;;; URL: https://github.com/thomasc1971/crush.el
;;; Version: 0.1.0
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

;; Local `web_search' tool implementation for crush.el: queries a
;; local SearXNG instance over HTTP and returns normalized results in
;; the Codex-style prose convention (`Process exited with code N' +
;; `Output:').  The tool is a thin synchronous wrapper: it fetches JSON
;; via `url-retrieve-synchronously', normalizes it into a markdown list
;; of results (each carrying engine + score for the model to weigh
;; relevance), and deduplicates by URL keeping the highest score.
;;
;; Gating: the search request itself is the probe.  The first call
;; determines connectivity and caches the result in a buffer-local
;; `crush-searxng--healthy'.  A healthy state (`t') just searches; an
;; unreachable state (`unreachable') short-circuits with no HTTP request
;; so a dead server is not hammered on every tool round.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-util)
(eval-and-compile
  (dolist (dep '("crush-openai" "crush-tools"))
    (unless (require (intern dep) nil t)
      (load (expand-file-name
             (concat dep ".el")
             (file-name-directory
              (or buffer-file-name load-file-name default-directory)))
            nil t))))

(declare-function crush-openai-tool-call-args "crush-openai" (tool-call))
(declare-function crush-exec--error "crush-tools" (message tool-call))
(declare-function crush-exec--format-result "crush-tools" (output exit-code))
(declare-function crush-exec--truncate-output "crush-tools" (output))

(defgroup crush-searxng nil
  "Local SearXNG search tool for crush."
  :group 'crush
  :prefix "crush-searxng-")

(defcustom crush-searxng-base-url "http://127.0.0.1:8888"
  "Base URL of the local SearXNG instance."
  :type 'string
  :group 'crush-searxng)

(defcustom crush-searxng-timeout 10
  "HTTP timeout in seconds for SearXNG requests."
  :type 'integer
  :group 'crush-searxng)

(defcustom crush-searxng-max-results 8
  "Default and cap on number of results returned."
  :type 'integer
  :group 'crush-searxng)

(defcustom crush-searxng-enabled t
  "Announce the `web_search' tool and allow search calls.
When nil, `web_search' is not in the schema and calls error."
  :type 'boolean
  :group 'crush-searxng)

(defvar-local crush-searxng--healthy nil
  "Cached SearXNG health state (nil means unknown).
The value is nil \(unknown), t \(healthy), or `unreachable' \(dead,
which short-circuits future calls).")

(defun crush-searxng--query (tool-call-args)
  "Return the resolved query string for TOOL-CALL-ARGS, or nil.
The `query' argument must be a non-empty string after trimming."
  (let ((q (plist-get tool-call-args :query)))
    (and (stringp q)
         (not (string-empty-p (string-trim q)))
         q)))

(defun crush-searxng--max-results (tool-call-args)
  "Return the resolved max-results from TOOL-CALL-ARGS or the default.
Clamped to at least 1 and at most `crush-searxng-max-results'."
  (let ((raw (plist-get tool-call-args :max_results)))
    (if (integerp raw)
        (max 1 (min crush-searxng-max-results raw))
      crush-searxng-max-results)))

(defun crush-searxng--build-url (query args)
  "Build the SearXNG search URL for QUERY with optional ARGS."
  (let* ((params (list (list "q" query)
                       (list "format" "json")))
         (cats (plist-get args :categories))
         (engs (plist-get args :engines)))
    (when (and (stringp cats) (not (string-empty-p (string-trim cats))))
      (push (list "categories" cats) params))
    (when (and (stringp engs) (not (string-empty-p (string-trim engs))))
      (push (list "engines" engs) params))
    (concat crush-searxng-base-url "/search?"
            (url-build-query-string (nreverse params)))))

(defun crush-searxng--response-body (buf)
  "Extract the HTTP body from BUF, stripping the status line and headers."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (if (re-search-forward "\r?\n\r?\n" nil t)
          (buffer-substring-no-properties (point) (point-max))
        ""))))

(defun crush-searxng--http-ok-p (buf)
  "Return t if BUF's HTTP status line indicates success (2xx)."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (goto-char (point-min))
      (looking-at-p "HTTP/[0-9.]+ 2[0-9][0-9]"))))

(defun crush-searxng--format-score (score)
  "Format SCORE as a decimal string, or `unknown' if nil."
  (if (numberp score)
      (number-to-string score)
    "unknown"))

(defun crush-searxng--format-engines (result)
  "Format the engine name(s) from a SearXNG RESULT alist.
Prefers the `engines' vector (real SearXNG); falls back to the
singular `engine' string for simplified test payloads."
  (let ((engs (cdr (assq 'engines result))))
    (if (and engs (vectorp engs) (> (length engs) 0))
        (mapconcat #'identity (append engs nil) ", ")
      (or (let ((e (cdr (assq 'engine result))))
            (and (stringp e) e))
          "unknown"))))

(defun crush-searxng--result-string (result)
  "Format a single SearXNG RESULT alist as a markdown block."
  (let* ((title (or (cdr (assq 'title result)) ""))
         (url (or (cdr (assq 'url result)) ""))
         (content (or (cdr (assq 'content result)) ""))
         (engine (crush-searxng--format-engines result))
         (score (crush-searxng--format-score (cdr (assq 'score result)))))
    (format "Result [engine: %s, score: %s]:\n# %s\n%s\n%s"
            engine score title url content)))

(defun crush-searxng--dedup (results)
  "Deduplicate RESULTS by URL, keeping the first (highest-scoring after sort)."
  (let ((seen nil)
        (out nil))
    (dolist (r results)
      (let ((url (cdr (assq 'url r))))
        (unless (member url seen)
          (push url seen)
          (push r out))))
    (nreverse out)))

(defun crush-searxng--normalize (obj max)
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
         (deduped (crush-searxng--dedup sorted))
         (top (cl-subseq deduped 0 (min max (length deduped))))
         (blocks (mapconcat #'crush-searxng--result-string top "\n\n"))
         (info (crush-searxng--format-infoboxes
                (cdr (assq 'infoboxes obj))))
         (sugg (crush-searxng--format-suggestions
                (cdr (assq 'suggestions obj)))))
    (concat
     (if (string-empty-p blocks)
         "no results"
       blocks)
     (when info (concat "\n\n" info))
     (when sugg (concat "\n\n" sugg)))))

(defun crush-searxng--format-infoboxes (infoboxes)
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

(defun crush-searxng--format-suggestions (suggestions)
  "Format SUGGESTIONS vector as a Suggestions: line, or nil if empty."
  (when (and suggestions (vectorp suggestions) (> (length suggestions) 0))
    (let ((items (append suggestions nil)))
      (when items
        (format "Suggestions: %s" (mapconcat #'identity items ", "))))))

(defun crush-searxng--exec (tool-call)
  "Execute TOOL-CALL as `web_search' and return (RESULT . EXIT).
Validates the `query' arg, checks the cached health state, fetches
JSON from SearXNG, normalizes it, and returns the prose result.
Errors yield an error result with exit code -1."
  (let ((args (crush-openai-tool-call-args tool-call)))
    (cond
     ((not (bound-and-true-p crush-searxng-enabled))
      (crush-exec--error "Web search is disabled" tool-call))
     ((not (crush-searxng--query args))
      (crush-exec--error "Missing query" tool-call))
     ((eq crush-searxng--healthy 'unreachable)
      (crush-exec--error
       "SearXNG is unreachable (cached); check the local server"
       tool-call))
     (t
      (condition-case err
          (let* ((query (crush-searxng--query args))
                 (url (crush-searxng--build-url query args))
                 (max (crush-searxng--max-results args))
                 (buf (url-retrieve-synchronously
                       url t t crush-searxng-timeout)))
            (if (or (null buf)
                    (not (crush-searxng--http-ok-p buf))
                    (string-empty-p
                     (or (crush-searxng--response-body buf) "")))
                (progn
                  (setq-local crush-searxng--healthy 'unreachable)
                  (crush-exec--error
                   (format "SearXNG is unreachable (HTTP %s)"
                           (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (line-end-position))))
                   tool-call))
              (let ((body (crush-searxng--response-body buf)))
                (let ((obj (json-read-from-string body)))
                  (if (not obj)
                      (progn
                        (setq-local crush-searxng--healthy 'unreachable)
                        (crush-exec--error
                         "SearXNG returned malformed JSON"
                         tool-call))
                    (setq-local crush-searxng--healthy t)
                    (let* ((normalized (crush-searxng--normalize obj max))
                           (text (crush-exec--format-result normalized 0)))
                      (setf (crush-openai-tool-call-result tool-call) text
                            (crush-openai-tool-call-exit tool-call) 0)
                      (cons text 0)))))))
        (error
         (setq-local crush-searxng--healthy 'unreachable)
         (crush-exec--error (error-message-string err) tool-call)))))))

;;; Register the tool into the protocol registry.

(push (cons "web_search" #'crush-searxng--exec)
      crush-openai-tool-registry)

(provide 'crush-searxng)
;;; crush-searxng.el ends here
