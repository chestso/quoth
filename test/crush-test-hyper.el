;;; crush-test-hyper.el --- Hyper backend tests for crush  -*- lexical-binding: t; -*-

;;; Commentary:
;;; Request composition, SSE parser, curl transport, token resolution, wire tests via dummy server.

;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'crush)

;;; 91. Hyper backend: request composition

(ert-deftest crush-test/hyper-compose-no-context ()
  "Without context, messages should be system + user with just the prompt."
  (let ((crush-model nil))
    (let* ((req (crush--hyper-compose-request "Hello" nil "qwen3.7-plus"))
           (msgs (alist-get 'messages req)))
      (should (string= (alist-get 'model req) "qwen3.7-plus"))
      (should (eq (alist-get 'stream req) t))
      (should (= (length msgs) 2))
      (should (string= (crush--hyper-alist-get "role" (nth 0 msgs)) "system"))
      (should (string= (crush--hyper-alist-get "role" (nth 1 msgs)) "user"))
      (should (string= (crush--hyper-alist-get "content" (nth 1 msgs)) "Hello"))
      (should-not (assq 'tools req)))))

(ert-deftest crush-test/hyper-compose-with-context-merges-preamble ()
  "With context, the user message should carry preamble + context + prompt."
  (let* ((req (crush--hyper-compose-request "Do the thing" "**Attachment: foo**" "m"))
         (user-content (crush--hyper-alist-get "content"
                                               (nth 1 (alist-get 'messages req)))))
    (should (string-match-p "The following markdown fenced code blocks" user-content))
    (should (string-match-p "\\*\\*Attachment: foo\\*\\*" user-content))
    (should (string-match-p "Do the thing$" user-content))))

(ert-deftest crush-test/hyper-compose-respects-defcustoms ()
  "Model, max-tokens, temperature, thinking, reasoning-effort should land in body."
  (let ((crush-model "my-model")
        (crush-hyper-max-tokens 1234)
        (crush-hyper-temperature 0.5)
        (crush-hyper-thinking t)
        (crush-hyper-reasoning-effort "high"))
    (let ((req (crush--hyper-compose-request "P" nil nil)))
      (should (string= (alist-get 'model req) "my-model"))
      (should (= (alist-get 'max_tokens req) 1234))
      (should (= (alist-get 'temperature req) 0.5))
      (should (eq (alist-get 'thinking req) t))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest crush-test/hyper-compose-model-default ()
  "When no model is set, the catalog default should be used."
  (let ((crush-model nil))
    (should (string= (alist-get 'model (crush--hyper-compose-request "P" nil nil))
                     "qwen3.7-plus"))))

(ert-deftest crush-test/hyper-compose-no-tools-in-phase1 ()
  "Phase 1 should not announce any tools."
  (let ((req (crush--hyper-compose-request "P" nil "m")))
    (should-not (assq 'tools req))
    (should-not (assq 'tool_choice req))))

;;; 92. Hyper backend: SSE parser

(defun crush-test--sse-state ()
  "Return a fresh, empty SSE parser state."
  (list :pending "" :done nil))

(ert-deftest crush-test/sse-parser-single-delta ()
  "A single data event should yield its content delta."
  (let* ((result (crush--hyper-sse-feed
                  (crush-test--sse-state)
                  "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"))
         (deltas (car result)))
    (should (equal deltas '((content . "Hello"))))
    (should-not (plist-get (cdr result) :done))))

(ert-deftest crush-test/sse-parser-multiple-events-per-chunk ()
  "A chunk with several events should yield several deltas."
  (let* ((chunk (concat
                 "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n"
                 "data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n"
                 "data: [DONE]\n\n"))
         (result (crush--hyper-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (car result) '((content . "one") (content . "two"))))
    (should (plist-get (cdr result) :done))))

(ert-deftest crush-test/sse-parser-chunk-split-mid-line ()
  "Events split across chunk boundaries should still parse."
  (let* ((state (crush-test--sse-state))
         (r1 (crush--hyper-sse-feed state "data: {\"choices\":[{\"delta\":{\"con"))
         (r2 (crush--hyper-sse-feed (cdr r1) "tent\":\"abc\"}}]}\n\n"))
         (r3 (crush--hyper-sse-feed (cdr r2) "data: [DONE]\n\n")))
    (should (equal (car r1) nil))
    (should (equal (car r2) '((content . "abc"))))
    (should (plist-get (cdr r3) :done))))

(ert-deftest crush-test/sse-parser-crlf ()
  "CRLF line endings should be handled."
  (let* ((result (crush--hyper-sse-feed
                  (crush-test--sse-state)
                  "data: {\"choices\":[{\"delta\":{\"content\":\"CR\"}}]}\r\n\r\n")))
    (should (equal (car result) '((content . "CR"))))))

(ert-deftest crush-test/sse-parser-multiline-data-payload ()
  "A data payload spanning several data: lines should be joined."
  (let* ((chunk (concat "data: {\"choices\":[{\"delta\":{\"content\":\"line"
                        "\"}}]}\n"
                        "data: {\"choices\":[{\"delta\":{\"content\":\" two\"}}]}\n\n"))
         (result (crush--hyper-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (car result) '((content . "line") (content . " two"))))))

(ert-deftest crush-test/sse-parser-reasoning-delta ()
  "A reasoning_content delta should yield a reasoning-typed delta."
  (let* ((result (crush--hyper-sse-feed
                  (crush-test--sse-state)
                  "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n")))
    (should (equal (car result) '((reasoning . "think"))))
    (should-not (plist-get (cdr result) :done))))

(ert-deftest crush-test/sse-parser-reasoning-then-content ()
  "Reasoning deltas and content deltas should be typed distinctly.
Both arrive in the same stream; the caller must be able to tell
which region each delta belongs to."
  (let* ((chunk (concat
                 "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n"
                 "data: {\"choices\":[{\"delta\":{\"content\":\"seen\"}}]}\n\n"))
         (result (crush--hyper-sse-feed (crush-test--sse-state) chunk)))
    (should (equal (car result)
                   '((reasoning . "think") (content . "seen"))))))

(ert-deftest crush-test/sse-parser-error-payload ()
  "An error data payload should set done and surface the message."
  (let* ((result (crush--hyper-sse-feed
                  (crush-test--sse-state)
                  "data: {\"error\":\"boom\"}\n\n")))
    (should (plist-get (cdr result) :done))
    (should (string= (plist-get (cdr result) :error) "boom"))))

;;; 92c. Hyper transport: filter state persistence and curl config

(ert-deftest crush-test/hyper-transport-filter-persists-split-events ()
  "A JSON SSE event split across filter chunks must fully stream.
Regression test: the filter previously persisted the non-existent
`:sse' key of the parser state, dropping the `:pending' fragment between
chunks and silently discarding any event split across them."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((target (current-buffer))
                (proc (make-pipe-process :name "crush-hyper-test-filter"
                                         :noquery t
                                         :coding 'binary)))
            (process-put proc :crush-sse (crush--hyper-sse-new-state))
            (process-put proc :crush-target target)
            (process-put proc :crush-done-callback #'ignore)
            (process-put proc :crush-head "")
            (process-put proc :crush-head-parsed nil)
            (process-put proc :crush-status nil)
            (process-put proc :crush-url "http://test/chat/completions")
            (process-put proc :crush-model "m")
            (process-put proc :crush-token-p nil)
            ;; Chunk 1: HTTP head plus the first half of a JSON SSE event.
            (crush--hyper-curl-filter
             proc "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"choices\":[{\"delta\":{\"con")
            ;; Chunk 2: the rest of the event plus [DONE].  With the bug
            ;; this chunk's `:pending' was lost, so \"hi\" never streamed.
            (crush--hyper-curl-filter
             proc "tent\":\"hi\"}}]}\n\ndata: [DONE]\n\n")
            (with-current-buffer target
              (goto-char (point-min))
              (should (search-forward "hi" nil t)))
            (when (process-live-p proc) (delete-process proc))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-transport-timeout-in-curl-config ()
  "`crush-hyper-timeout' should reach the curl config as max-time."
  (let ((received nil)
        (proc (make-pipe-process :name "crush-hyper-test-cap" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _args) proc))
                  ((symbol-function 'process-send-string)
                   (lambda (_p string) (push string received)))
                  ((symbol-function 'process-send-eof) #'ignore))
          (let ((crush-hyper-timeout 45))
            (crush--hyper-request
             "http://127.0.0.1:1" "tok"
             (crush--hyper-compose-request "hi" nil "m")
             (current-buffer) #'ignore)))
      (delete-process proc))
    (should (string-match-p "max-time = 45"
                            (mapconcat #'identity (nreverse received) "\n")))))

;;; 92b. Hyper backend: token resolution

;;; `crush-hyper--resolve-token' supports string, function, and nil
;;; tokens; the default `crush-hyper-token' function reads from
;;; `auth-source' (like gptel).

(ert-deftest crush-test/hyper-token-resolve-string ()
  "A string token resolves to itself."
  (should (string= (crush-hyper--resolve-token "sk-hyper-abc") "sk-hyper-abc")))

(ert-deftest crush-test/hyper-token-resolve-nil ()
  "A nil token resolves to nil (no authorization header)."
  (should-not (crush-hyper--resolve-token nil)))

(ert-deftest crush-test/hyper-token-resolve-function ()
  "A function token is called and its string result used."
  (let ((calls 0))
    (should (string= (crush-hyper--resolve-token
                      (lambda () (setq calls (1+ calls)) "sk-hyper-fn"))
                     "sk-hyper-fn"))
    (should (= calls 1))))

(ert-deftest crush-test/hyper-token-resolve-function-returns-function ()
  "A function returning another function is resolved recursively."
  (let ((token (lambda () (lambda () "sk-hyper-nested"))))
    (should (string= (crush-hyper--resolve-token token) "sk-hyper-nested"))))

(ert-deftest crush-test/hyper-token-from-auth-source-found ()
  "The default lookup returns the authinfo secret for hyper.charm.land."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest args)
               (should (string= (plist-get args :host) "hyper.charm.land"))
               (should (string= (plist-get args :user) "apikey"))
               (list (list :host "hyper.charm.land" :user "apikey"
                           :secret "sk-hyper-authinfo")))))
    (should (string= (crush-hyper--token-from-auth-source)
                     "sk-hyper-authinfo"))))

(ert-deftest crush-test/hyper-token-from-auth-source-missing ()
  "Missing authinfo entry signals a setup error, not a silent nil."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _args) nil)))
    (should-error (crush-hyper--token-from-auth-source) :type 'user-error)))

(ert-deftest crush-test/hyper-token-default-reads-authinfo ()
  "The default `crush-hyper-token' resolves through auth-source."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _args)
               (list (list :secret "sk-hyper-default")))))
    (let ((crush-hyper-token #'crush-hyper--token-from-auth-source))
      (should (string= (crush-hyper--resolve-token crush-hyper-token)
                       "sk-hyper-default")))))

(ert-deftest crush-test/hyper-token-backend-slot-beats-custom ()
  "A token on the backend struct wins over `crush-hyper-token'."
  (let ((backend (crush-make-hyper-backend
                  :buffer (current-buffer)
                  :base-url "http://127.0.0.1:1"
                  :token "sk-hyper-slot")))
    (let ((crush-hyper-token "sk-hyper-custom"))
      (let ((token (crush-hyper--resolve-token
                    (or (crush-hyper-backend-token backend)
                        crush-hyper-token))))
        (should (string= token "sk-hyper-slot"))))))

;;; 93. Hyper backend: wire integration via dummy server

;;; The dummy Hyper gateway is a small Python server
;;; (test/hyper-server.py), started as a subprocess per test, that
;;; captures every request to a file and streams SSE responses.  This is
;;; the same philosophy as `test/mock-crush.sh' for the CLI.

(defun crush-test--hyper-cap-file ()
  "Return a fresh capture-file path for the hyper dummy server."
  (make-temp-file "crush-hyper-capture"))

(defun crush-test--read-hyper-capture (file)
  "Read the dummy server capture FILE, returning (BASE-URL . REQUESTS)."
  (let ((base nil)
        (requests nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((first-line (buffer-substring-no-properties
                         (point) (line-end-position))))
        (setq base (if (string-prefix-p "http" first-line) first-line nil)))
      (goto-char (point-min))
      (while (re-search-forward "^REQUEST \\([^ ]+\\) \\([^ ]+\\)$" nil t)
        (let ((method (match-string 1))
              (path (match-string 2))
              (headers nil)
              (body nil))
          (forward-line 1)
          ;; Collect headers until BODY.
          (while (and (not (eobp))
                      (not (looking-at "^BODY ")))
            (when (looking-at "^\\([^: ]+\\): \\(.*\\)$")
              (push (cons (downcase (match-string 1)) (match-string 2))
                    headers))
            (forward-line 1))
          (when (looking-at "^BODY \\(.*\\)$")
            (setq body (match-string 1)))
          (push (list method path headers body) requests))))
    (list base (nreverse requests))))

(defun crush-test--hyper-server-program ()
  "Return path to the dummy hyper server script."
  (expand-file-name "hyper-server.py"
                    (file-name-directory (locate-library "crush-test"))))

(defun crush-test--with-hyper-server (mode body-fn)
  "Start a dummy hyper server in MODE, call BODY-FN with its BASE-URL,
and return the capture output."
  (let* ((cap (crush-test--hyper-cap-file))
         (proc (make-process
                :name "crush-hyper-test"
                :command (list (crush-test--hyper-server-program)
                               cap (symbol-name mode))
                :noquery t))
         (base nil)
         (deadline (+ (float-time) 5)))
    (unwind-protect
        (progn
          ;; Wait for the server to write its base URL.
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
            (error "hyper dummy server failed to start"))
          (funcall body-fn base)
          (crush-test--read-hyper-capture cap))
      (when proc (delete-process proc))
      (when (file-exists-p cap) (delete-file cap)))))

(ert-deftest crush-test/hyper-wire-captures-request-body ()
  "The dummy server should capture the composed JSON request body."
  (let* ((result (crush-test--with-hyper-server
                  'ok-stream
                  (lambda (base)
                    (let ((proc (crush--hyper-request
                                 base "tok-rf"
                                 (crush--hyper-compose-request "hi" nil "m")
                                 (current-buffer) #'ignore)))
                      (let ((deadline (+ (float-time) 6)))
                        (while (and (process-live-p proc)
                                    (null (process-get proc :crush-finished))
                                    (< (float-time) deadline))
                          (accept-process-output nil 0.1)))
                      nil))))
         (base (nth 0 result))
         (requests (nth 1 result)))
    (should base)
    (should (= (length requests) 1))
    (let* ((req (car requests))
           (method (nth 0 req))
           (path (nth 1 req))
           (headers (nth 2 req))
           (body (nth 3 req)))
      (should (string= method "POST"))
      (should (string= path "/chat/completions"))
      (should (string= (cdr (assoc "authorization" headers))
                       "Bearer tok-rf"))
      (should (string= (cdr (assoc "content-type" headers))
                       "application/json"))
      (let ((decoded (json-read-from-string body)))
        (should (string= (crush--hyper-alist-get "model" decoded) "m"))
        (should (eq (crush--hyper-alist-get "stream" decoded) t))))))

(ert-deftest crush-test/hyper-wire-streams-deltas-into-buffer ()
  "The transport should insert streamed deltas into the crush buffer."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((old-prompt-id crush--prompt-id))
            (crush-test--with-hyper-server
             'ok-stream
             (lambda (base)
               (save-excursion (goto-char (point-max)) (newline))
               (setq-local crush--response-start (point-marker))
               (let ((buf (current-buffer)))
                 (let ((proc (crush--hyper-request
                              base "tok" (crush--hyper-compose-request "hi" nil "m")
                              buf
                              (lambda ()
                                (when (buffer-live-p buf)
                                  (with-current-buffer buf
                                    (crush--finalize-response)))))))
                   (let ((deadline (+ (float-time) 6)))
                     (while (and (process-live-p proc)
                                 (null (process-get proc :crush-finished))
                                 (< (float-time) deadline))
                       (accept-process-output nil 0.1)
                       (sit-for 0.02)))))
               ;; Streamed content landed in the buffer.
               (goto-char (point-min))
               (should (search-forward "mock response!" nil t))
               ;; The [DONE] event finalized the response: tagged text
               ;; (crush-response-to) and a fresh prompt.
               (search-backward "mock response!")
               (let* ((resp-start (point))
                      (resp-end (+ resp-start (length "mock response!"))))
                 (should (eq (get-text-property resp-start 'crush-region-type)
                             'response))
                 (should (string= (get-text-property resp-end 'crush-response-to)
                                  old-prompt-id)))
               (goto-char (point-max))
               (search-backward "crush> ")
               (should (not (string= crush--prompt-id old-prompt-id)))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-reasoning-stream-highlights-cot ()
  "A reasoning_content stream should be highlighted and tagged."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (let ((old-prompt-id crush--prompt-id))
            (crush-test--with-hyper-server
             'reasoning
             (lambda (base)
               (save-excursion (goto-char (point-max)) (newline))
               (setq-local crush--response-start (point-marker))
               (let ((buf (current-buffer)))
                 (let ((proc (crush--hyper-request
                              base "tok" (crush--hyper-compose-request "hi" nil "m")
                              buf
                              (lambda ()
                                (when (buffer-live-p buf)
                                  (with-current-buffer buf
                                    (crush--finalize-response)))))))
                   (let ((deadline (+ (float-time) 6)))
                     (while (and (process-live-p proc)
                                 (null (process-get proc :crush-finished))
                                 (< (float-time) deadline))
                       (accept-process-output nil 0.1)
                       (sit-for 0.02)))))
               ;; Wait until the streamed text actually landed: the
               ;; process loop can exit the instant :crush-finished is
               ;; set, before the finalize callback's insertion is
               ;; flushed and visible.
               (let ((deadline (+ (float-time) 6)))
                 (while (and (< (float-time) deadline)
                             (not (save-excursion
                                    (goto-char (point-min))
                                    (search-forward "mock think harder" nil t))))
                   (accept-process-output nil 0.1)
                   (sit-for 0.02)))
               (goto-char (point-min))
               (should (search-forward "mock think harder" nil t))
               (search-backward "mock")
               (let ((rs (point)))
                 (search-forward "harder")
                 (should (eq (get-text-property rs 'crush-region-type)
                             'reasoning)))
               ;; The answer after it is tagged response.
               (search-forward "answer")
               (let ((as (point)))
                 (should (eq (get-text-property (- as 6) 'crush-region-type)
                             'response)))
               ;; An overlay with the reasoning face covers the CoT.
               (let ((found nil))
                 (dolist (ov (overlays-in (point-min) (point-max)))
                   (when (and (eq (overlay-get ov 'face) 'crush-reasoning-face)
                              (overlay-get ov 'crush-overlay))
                     (setq found ov)))
                 (should (overlayp found))
                 (should (string= (buffer-substring-no-properties
                                   (overlay-start found) (overlay-end found))
                                  "mock think harder")))))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-error-http-surfaces ()
  "A non-200 status should surface an error instead of streaming."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush-test--with-hyper-server
           'error-http
           (lambda (base)
             (setq-local crush--response-start (point-marker))
             (let ((proc (crush--hyper-request
                          base "tok" (crush--hyper-compose-request "hi" nil "m")
                          (current-buffer) #'ignore)))
               (let ((deadline (+ (float-time) 6)))
                 (while (and (process-live-p proc)
                             (null (process-get proc :crush-finished))
                             (< (float-time) deadline))
                   (accept-process-output nil 0.1)
                   (sit-for 0.02))))
             (goto-char (point-min))
             (should (search-forward "crush-hyper error" nil t)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-404-reports-status ()
  "An HTML 404 should be reported with its status code."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush-test--with-hyper-server
           'not-found
           (lambda (base)
             (setq-local crush--response-start (point-marker))
             (let* ((proc (crush--hyper-request
                           base "tok" (crush--hyper-compose-request "hi" nil "m")
                           (current-buffer) #'ignore))
                    (deadline (+ (float-time) 6)))
               (while (and (process-live-p proc)
                           (null (process-get proc :crush-finished))
                           (< (float-time) deadline))
                 (accept-process-output nil 0.1)
                 (sit-for 0.02))
               ;; Check the parsed status before the process is deleted.
               (let ((status (process-get proc :crush-status)))
                 (should (= status 404))))
             (goto-char (point-min))
             (should (search-forward "crush-hyper error: HTTP 404" nil t)))))
      (crush-test--cleanup))))

(ert-deftest crush-test/hyper-wire-logs-request-without-token ()
  "The request diagnostic line in *crush-debug* should not contain the token."
  (let ((default-directory crush-test--root))
    (unwind-protect
        (with-current-buffer (crush-test--fresh-buffer)
          (crush-test--with-hyper-server
           'ok-stream
           (lambda (base)
             (setq-local crush--response-start (point-marker))
             (let ((proc (crush--hyper-request
                          base "sk-hyper-supersecret"
                          (crush--hyper-compose-request "hi" nil "m")
                          (current-buffer) #'ignore)))
               (let ((deadline (+ (float-time) 6)))
                 (while (and (process-live-p proc)
                             (null (process-get proc :crush-finished))
                             (< (float-time) deadline))
                   (accept-process-output nil 0.1)
                   (sit-for 0.02))))
             ;; The request diagnostic must be logged without the token.
             (let ((debug-buf (get-buffer "*crush-debug*")))
               (should (buffer-live-p debug-buf))
               (with-current-buffer debug-buf
                 (goto-char (point-min))
                 (should (search-forward "request: POST" nil t))
                 (should (search-forward "body=" nil t))
                 (goto-char (point-min))
                 (should (search-forward "response: POST" nil t))
                 (goto-char (point-min))
                 (should-not (search-forward "sk-hyper-supersecret" nil t)))))))
      (crush-test--cleanup))))

(provide 'crush-test-hyper)
;;; crush-test-hyper.el ends here
