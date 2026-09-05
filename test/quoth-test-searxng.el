;;; quoth-test-searxng.el --- SearXNG web_search tool tests for quoth  -*- lexical-binding: t; -*-
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
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
;;; THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;; SOFTWARE.

;;; Commentary:
;;; Tests for the `web_search' tool against a local SearXNG instance
;;; (`quoth-searxng.el').  The entry fetches JSON over HTTP with the
;;; asynchronous `url-retrieve' (a retrieval callback plus a timeout
;;; timer), normalizes it into the Codex-style prose result
;;; convention, and gates on a cached health probe so a dead server is
;;; reported once rather than hammered on every tool round.  Unit tests
;;; mock the URL transport with `cl-letf' (delivering the fake
;;; response synchronously through the real callback path); the wire
;;; test drives a real dummy SearXNG server (`searxng-server.py').

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth" "quoth-openai" "quoth-searxng"))
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

(defvar quoth-test--root)
(declare-function quoth-test--cleanup "quoth-test" ())
(declare-function quoth-test--read-hyper-capture "quoth-test-hyper" (file))
(declare-function quoth-test--wait-until "quoth-test-process" (pred &optional timeout))
(declare-function quoth-searxng--exec "quoth-searxng" (tool-call on-done))

(defvar quoth-test--last-url nil
  "URL passed to the faked `url-retrieve'.")

;;; Test transport: a fake `url-retrieve' that records its URL and
;;; delivers a buffer whose contents the test controls, synchronously,
;;; through the callback the entry passed.  The buffer must look like a
;;; real HTTP response (status line + headers + body) because the tool
;;; parses the status code from it.

(defun quoth-test--http-response-buffer (status body)
  "Return a buffer holding an HTTP response with STATUS and BODY."
  (let ((buf (generate-new-buffer " *quoth-searxng-test*")))
    (with-current-buffer buf
      (insert (format "HTTP/1.1 %s\r\n" status))
      (insert "Content-Type: application/json\r\n")
      (insert "\r\n")
      (insert body))
    buf))

(defun quoth-test--with-fake-url (status body fn)
  "Call FN with `url-retrieve' faked to deliver STATUS/BODY.
The fake records the requested URL in `quoth-test--last-url' and calls
the entry's callback synchronously with the response buffer current,
mimicking a completed retrieval."
  (let ((quoth-test--last-url nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _args)
                 (setq quoth-test--last-url url)
                 (with-current-buffer
                     (quoth-test--http-response-buffer status body)
                   (funcall callback 'ok)))))
      (funcall fn))))

(defun quoth-test--searxng-call (args-json)
  "Execute a `web_search' tool call with ARGS-JSON, returning (RESULT . EXIT).
Runs the entry with the mocked transport (a synchronous retrieval), so
the single delivery is available inline."
  (let ((call (quoth-make-openai-tool-call :id "call_searxng" :name "web_search"))
        (results nil))
    (setf (quoth-openai-tool-call-args call)
          (quoth-openai-parse-tool-args args-json))
    (quoth-searxng--exec call (lambda (result) (push result results)))
    (should (equal (length results) 1))
    (car results)))

;;; 1. Registration

(ert-deftest quoth-test/searxng-registered-in-registry ()
  "The registry should map \"web_search\" to `quoth-searxng--exec'."
  (should (equal (cdr (assoc "web_search" quoth-openai-tool-registry))
                 #'quoth-searxng--exec)))

(ert-deftest quoth-test/searxng-in-tool-schema ()
  "The tool schema should announce `web_search' alongside the shell tools."
  (let* ((schema (quoth--openai-tool-schema))
         (names (mapcar (lambda (tool)
                          (cdr (assq 'name (cdr (assq 'function tool)))))
                        (append schema nil))))
    (should (member "web_search" names))
    (should (member "exec_command" names))
    (should (member "write_stdin" names))))

;;; 2. Result normalization

(ert-deftest quoth-test/searxng-normalizes-results ()
  "A JSON payload should normalize to a markdown result list.
Each result carries its engine and score so the model can weigh
relevance, and the whole payload is wrapped in the prose convention."
  (let ((json (json-encode
               `(("results" .
                  [((title . "Emacs Lisp Intro")
                    (url . "https://example.org/elisp")
                    (content . "An introduction to Emacs Lisp.")
                    (engine . "duckduckgo")
                    (score . 0.98))
                   ((title . "GNU Emacs")
                    (url . "https://www.gnu.org/software/emacs/")
                    (content . "The GNU Emacs manual.")
                    (engine . "wikipedia")
                    (score . 0.87))])))))
    (quoth-test--with-fake-url
     "200 OK" json
     (lambda ()
       (let ((result (quoth-test--searxng-call "{\"query\":\"emacs lisp\"}")))
         (should (string-match-p "Process exited with code 0" (car result)))
         (should (= (cdr result) 0))
         (should (string-match-p "Result \\[engine: duckduckgo, score: 0.98\\]"
                                 (car result)))
         (should (string-match-p "Emacs Lisp Intro" (car result)))
         (should (string-match-p "https://example.org/elisp" (car result)))
         (should (string-match-p "Result \\[engine: wikipedia, score: 0.87\\]"
                                 (car result)))
         (should (string-match-p "GNU Emacs" (car result))))))))

(ert-deftest quoth-test/searxng-dedupes-by-url ()
  "Two engines returning the same URL should keep only the highest score."
  (let ((json (json-encode
               `(("results" .
                  [((title . "Same Page")
                    (url . "https://example.org/same")
                    (content . "Low score copy.")
                    (engine . "google")
                    (score . 0.4))
                   ((title . "Same Page")
                    (url . "https://example.org/same")
                    (content . "High score copy.")
                    (engine . "duckduckgo")
                    (score . 0.9))])))))
    (quoth-test--with-fake-url
     "200 OK" json
     (lambda ()
       (let ((result (quoth-test--searxng-call "{\"query\":\"same\"}")))
         (should (= 1 (cl-count-if
                       (lambda (s) (string-match-p "Same Page" s))
                       (split-string (car result) "\n"))))
         (should (string-match-p "engine: duckduckgo" (car result)))
         (should-not (string-match-p "engine: google" (car result))))))))

(ert-deftest quoth-test/searxng-includes-infobox-and-suggestions ()
  "Infoboxes and suggestions should render as Info:/Suggestions: lines."
  (let ((json (json-encode
               `(("results" .
                  [((title . "T")
                    (url . "https://example.org/t")
                    (content . "c")
                    (engine . "duckduckgo")
                    (score . 0.5))])
                 ("infoboxes" .
                  [((infobox . "Emacs Lisp")
                    (content . "A dialect of Lisp."))])
                 ("suggestions" .
                  ["emacs lisp tutorial" "emacs lisp reference"])))))
    (quoth-test--with-fake-url
     "200 OK" json
     (lambda ()
       (let ((result (quoth-test--searxng-call "{\"query\":\"emacs\"}")))
         (should (string-match-p "Info: Emacs Lisp" (car result)))
         (should (string-match-p "Suggestions: emacs lisp tutorial, emacs lisp reference"
                                 (car result))))))))

(ert-deftest quoth-test/searxng-empty-results ()
  "An empty result set reports `Output: (empty)' without erroring.
No body text could be mistaken for literal search output."
  (quoth-test--with-fake-url
   "200 OK" (json-encode '((results . [])))
   (lambda ()
     (let ((result (quoth-test--searxng-call "{\"query\":\"zzz\"}")))
       (should (string= (car result)
                        "Process exited with code 0\nOutput: (empty)\n"))
       (should (= (cdr result) 0))))))

;;; 3. Error paths

(ert-deftest quoth-test/searxng-http-error ()
  "A non-2xx response should deliver an error result with exit code -1."
  (quoth-test--with-fake-url
   "500 Internal Server Error" "oops"
   (lambda ()
     (let ((result (quoth-test--searxng-call "{\"query\":\"x\"}")))
       (should (string-match-p "Process exited with code -1" (car result)))
       (should (= (cdr result) -1))
       (should (string-match-p "500" (car result)))))))

(ert-deftest quoth-test/searxng-malformed-json ()
  "A non-JSON body should deliver an error result."
  (quoth-test--with-fake-url
   "200 OK" "<html>not json</html>"
   (lambda ()
     (let ((result (quoth-test--searxng-call "{\"query\":\"x\"}")))
       (should (string-match-p "Process exited with code -1" (car result)))
       (should (= (cdr result) -1))))))

(ert-deftest quoth-test/searxng-retrieval-failure-delivers-error ()
  "A retrieval that fails (a dead process's empty buffer) delivers an error."
  (let ((call (quoth-make-openai-tool-call :id "call_searxng"
                                           :name "web_search"))
        (results nil))
    (setf (quoth-openai-tool-call-args call)
          (quoth-openai-parse-tool-args "{\"query\":\"x\"}"))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 ;; A deleted retrieval calls back with whatever buffer
                 ;; is current — not an HTTP response.
                 (with-current-buffer (generate-new-buffer " *dead*")
                   (funcall callback 'connection-failed))
                 (make-pipe-process :name "searxng-test-dead"
                                    :noquery t))))
      (should (functionp (quoth-searxng--exec
                          call (lambda (result) (push result results)))))
      (should (equal (length results) 1))
      (should (string-match-p "Process exited with code -1"
                              (caar results)))
      (should (string-match-p "unreachable" (caar results)))
      (should (= (cdar results) -1)))))

(ert-deftest quoth-test/searxng-missing-query-errors ()
  "A missing or empty `query' should error without hitting the network."
  (let ((hit nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _args) (setq hit t) nil)))
      (dolist (json '("{}" "{\"query\":\"\"}" "{\"query\":\"  \"}"))
        (let ((result (quoth-test--searxng-call json)))
          (should (string-match-p "Process exited with code -1" (car result)))
          (should (= (cdr result) -1))))
      (should-not hit))))

;;; 4. Async delivery, timeout, and cancel

(ert-deftest quoth-test/searxng-search-delivers-asynchronously ()
  "A live search returns a cancel thunk and delivers via the callback.
The on-done fires once, from the retrieval callback, with the
normalized prose result; a cancelled wait delivers nothing."
  (let ((results nil)
        (cb nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (setq cb callback)
                 (make-pipe-process :name "searxng-test-async"
                                    :noquery t))))
      (let ((call (quoth-make-openai-tool-call :id "call_searxng"
                                               :name "web_search")))
        (setf (quoth-openai-tool-call-args call)
              (quoth-openai-parse-tool-args "{\"query\":\"emacs\"}"))
        (let ((cancel (quoth-searxng--exec
                       call (lambda (result) (push result results)))))
          (should (functionp cancel))
          ;; Nothing delivered before the retrieval completes.
          (should-not results)
          (funcall cancel)
          ;; Late retrieval delivers nothing to a cancelled wait.
          (with-current-buffer
              (quoth-test--http-response-buffer
               "200 OK" (json-encode '((results . []))))
            (funcall cb 'ok))
          (should-not results)
          ;; Clean up the timer the cancel left armed.
          (funcall cancel))))))

(ert-deftest quoth-test/searxng-cancel-deletes-retrieval ()
  "The cancel thunk deletes the retrieval process and its timer.
A cancelled search delivers nothing."
  (let ((results nil)
        (retrieval (make-pipe-process :name "searxng-test-cancel"
                                      :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (_url _callback &rest _args) retrieval)))
          (let ((call (quoth-make-openai-tool-call :id "call_searxng"
                                                   :name "web_search")))
            (setf (quoth-openai-tool-call-args call)
                  (quoth-openai-parse-tool-args "{\"query\":\"emacs\"}"))
            (let ((cancel (quoth-searxng--exec
                           call (lambda (result) (push result results)))))
              (funcall cancel)
              (should-not (process-live-p retrieval))
              (should-not results))))
      (when (process-live-p retrieval) (delete-process retrieval)))))

(ert-deftest quoth-test/searxng-timeout-delivers-error-and-kills-retrieval ()
  "A retrieval outliving `quoth-searxng-timeout' delivers an error result.
The timeout deletes the retrieval process and reports `unreachable'."
  (let ((results nil)
        (retrieval (make-pipe-process :name "searxng-test-timeout"
                                      :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (_url _callback &rest _args) retrieval)))
          (let ((call (quoth-make-openai-tool-call :id "call_searxng"
                                                   :name "web_search"))
                (quoth-searxng-timeout 0.05))
            (setf (quoth-openai-tool-call-args call)
                  (quoth-openai-parse-tool-args "{\"query\":\"emacs\"}"))
            (should (functionp (quoth-searxng--exec
                                call (lambda (result)
                                       (push result results)))))
            (should (quoth-test--wait-until (lambda () results)))
            (should (= (cdar results) -1))
            (should (string-match-p "timed out" (caar results)))
            (should-not (process-live-p retrieval))
            (should (eq quoth-searxng--healthy 'unreachable))))
      (when (process-live-p retrieval) (delete-process retrieval)))))

(ert-deftest quoth-test/searxng-late-retrieval-after-timeout-noops ()
  "A retrieval completing after the timeout delivered delivers nothing."
  (let ((results nil)
        (cb nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (setq cb callback)
                 'fake-proc))
              ((symbol-function 'delete-process) #'ignore))
      (let ((call (quoth-make-openai-tool-call :id "call_searxng"
                                               :name "web_search"))
            (quoth-searxng-timeout 0.05))
        (setf (quoth-openai-tool-call-args call)
              (quoth-openai-parse-tool-args "{\"query\":\"emacs\"}"))
        (quoth-searxng--exec call (lambda (result) (push result results)))
        (should (quoth-test--wait-until (lambda () results)))
        (let ((delivered (length results)))
          (with-current-buffer
              (quoth-test--http-response-buffer
               "200 OK" (json-encode '((results . []))))
            (funcall cb 'ok))
          (should (= (length results) delivered)))))))

;;; 5. Cached health-probe gating
;;;
;;; The search request itself is the probe: the first call determines
;;; connectivity and caches it.  A healthy state (`t') skips re-probing
;;; and just searches; an unhealthy state (`unreachable') short-circuits
;;; with no HTTP request so a dead server is not hammered on every tool
;;; round.

(ert-deftest quoth-test/searxng-unknown-state-searches-and-caches-healthy ()
  "An unknown health state performs the search and caches healthy."
  (let ((quoth-searxng--healthy nil)
        (requests 0))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (setq requests (1+ requests))
                 (with-current-buffer
                     (quoth-test--http-response-buffer
                      "200 OK" (json-encode '((results . []))))
                   (funcall callback 'ok))
                 (make-pipe-process :name "searxng-test-healthy"
                                    :noquery t))))
      (let ((result (quoth-test--searxng-call "{\"query\":\"x\"}")))
        (should (= requests 1))
        (should (eq quoth-searxng--healthy t))
        (should (= (cdr result) 0))))))

(ert-deftest quoth-test/searxng-healthy-state-searches-without-probe ()
  "A cached healthy state performs only the search, one request per call."
  (let ((quoth-searxng--healthy t)
        (requests 0))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (setq requests (1+ requests))
                 (with-current-buffer
                     (quoth-test--http-response-buffer
                      "200 OK" (json-encode '((results . []))))
                   (funcall callback 'ok))
                 (make-pipe-process :name "searxng-test-healthy"
                                    :noquery t))))
      (quoth-test--searxng-call "{\"query\":\"x\"}")
      (quoth-test--searxng-call "{\"query\":\"y\"}")
      (should (= requests 2))
      (should (eq quoth-searxng--healthy t)))))

(ert-deftest quoth-test/searxng-unreachable-short-circuits ()
  "A failed search caches `unreachable' and later calls make no request."
  (let ((quoth-searxng--healthy nil)
        (requests 0))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (setq requests (1+ requests))
                 (with-current-buffer
                     (quoth-test--http-response-buffer
                      "500 Internal Server Error" "boom")
                   (funcall callback 'ok))
                 (make-pipe-process :name "searxng-test-unreach"
                                    :noquery t))))
      (let ((result (quoth-test--searxng-call "{\"query\":\"x\"}")))
        (should (eq quoth-searxng--healthy 'unreachable))
        (should (string-match-p "unreachable" (car result)))
        (should (= (cdr result) -1)))
      (let ((result (quoth-test--searxng-call "{\"query\":\"y\"}")))
        (should (= requests 1))
        (should (string-match-p "unreachable" (car result)))
        (should (= (cdr result) -1))))))

;;; 6. Wire test against a real dummy SearXNG server

(defun quoth-test--searxng-server-program ()
  "Return path to the dummy SearXNG server script."
  (expand-file-name "searxng-server.py"
                    (file-name-directory (locate-library "quoth-test"))))

(defun quoth-test--with-searxng-server (body-fn)
  "Start the dummy SearXNG server and call BODY-FN with its BASE-URL.
Returns the capture output."
  (let* ((cap (make-temp-file "quoth-searxng-cap"))
         (proc (make-process
                :name "quoth-searxng-test"
                :command (list "python3"
                               (quoth-test--searxng-server-program)
                               cap)
                :noquery t))
         (base nil)
         (deadline (+ (float-time) 5)))
    (unwind-protect
        (progn
          (while (and (null base) (< (float-time) deadline))
            (accept-process-output nil 0.1)
            (when (file-exists-p cap)
              (with-temp-buffer
                (insert-file-contents cap)
                (goto-char (point-min))
                (let ((l (buffer-substring-no-properties
                          (point) (line-end-position))))
                  (when (string-prefix-p "http" l)
                    (setq base l))))))
          (unless base
            (error "SearXNG dummy server failed to start"))
          (funcall body-fn base)
          (quoth-test--read-hyper-capture cap))
      (when proc (delete-process proc))
      (when (file-exists-p cap) (delete-file cap)))))

(ert-deftest quoth-test/searxng-wire-search ()
  "The full path should fetch JSON from a real server and normalize it.
A live dummy SearXNG server serves a canned JSON payload; the tool
should return the normalized prose result and the server should have
captured a GET with the query." :tags '(:integration)
  (quoth-test--with-searxng-server
   (lambda (base)
     (let ((quoth-searxng-base-url base)
           (quoth-searxng--healthy nil)
           (results nil))
       (let ((call (quoth-make-openai-tool-call :id "call_searxng"
                                                :name "web_search")))
         (setf (quoth-openai-tool-call-args call)
               (quoth-openai-parse-tool-args "{\"query\":\"wire test\"}"))
         (let ((cancel (quoth-searxng--exec
                        call (lambda (result) (push result results)))))
           (unwind-protect
               (progn
                 (should (quoth-test--wait-until (lambda () results) 10))
                 (should (string-match-p "Process exited with code 0"
                                         (caar results)))
                 (should (string-match-p "Wire Result" (caar results)))
                 (should (= (cdar results) 0)))
             (when (functionp cancel) (funcall cancel)))))))))

(provide 'quoth-test-searxng)
;;; quoth-test-searxng.el ends here
