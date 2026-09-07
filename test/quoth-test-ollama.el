;;; quoth-test-ollama.el --- Ollama Cloud provider tests for quoth  -*- lexical-binding: t; -*-
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

;; Ollama Cloud provider tests: catalog normalization, the bundled-seed
;; reader, provider configuration resolution, and the shared-client
;; ollama behaviors (the `reasoning' field alias, the
;; usage-with-empty-choices chunk).  Everything here runs against
;; mocked data or in-memory buffers; the true wire round trip lives in
;; the :integration tests.

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; flycheck byte-compiles this file in isolation, and its batch child's
;;; `load-path' excludes the package root and test dir.  Prefer
;;; `require'; fall back to loading each dep from this file's directory
;;; or its parent (the package root) so flycheck and package loads work.
(eval-and-compile
  (dolist (dep '("quoth" "quoth-provider" "quoth-openai-client" "quoth-openai-provider" "quoth-ollama-provider"))
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

;;; 1. Catalog normalization

(ert-deftest quoth-test/ollama-normalize-model-thinking-vision ()
  "`quoth-ollama--normalize-model' maps capabilities onto the protocol plist.
The `thinking' capability sets :can-reason; `vision' sets
:supports-attachments; the context length rides :context-window; the
cloud reports no pricing, so the cost keys stay nil."
  (let ((entry (quoth-ollama--normalize-model
                "gemma4:31b"
                (vector "completion" "thinking" "tools" "vision")
                262144)))
    (should (string= (plist-get entry :id) "gemma4:31b"))
    (should (string= (plist-get entry :name) "gemma4:31b"))
    (should (= (plist-get entry :context-window) 262144))
    (should (eq (plist-get entry :can-reason) t))
    (should (eq (plist-get entry :supports-attachments) t))
    (should (null (plist-get entry :default-max-tokens)))
    (should (null (plist-get entry :cost-in)))
    (should (null (plist-get entry :cost-out)))
    (should (null (plist-get entry :cost-cache-write)))
    (should (null (plist-get entry :cost-cache-hit)))
    (should (null (plist-get entry :reasoning-levels)))
    (should (null (plist-get entry :default-reasoning-effort)))))

(ert-deftest quoth-test/ollama-normalize-model-no-thinking-no-vision ()
  "A model without `thinking' or `vision' capabilities reports neither.
A list-shaped capabilities value (not a vector) is accepted too."
  (let ((entry (quoth-ollama--normalize-model
                "deepseek-v4-pro:0813"
                (list "completion" "tools")
                131072)))
    (should (null (plist-get entry :can-reason)))
    (should (null (plist-get entry :supports-attachments)))
    (should (= (plist-get entry :context-window) 131072))))

(ert-deftest quoth-test/ollama-context-length-matches-suffix ()
  "`quoth-ollama--context-length' matches the `.context_length' suffix.
The key is architecture-prefixed (`gptoss.context_length',
`gemma4.context_length'), so the suffix — not a fixed key — decides.
Keys arrive as strings or symbols depending on the JSON engine, so
both shapes must match."
  (let ((info (list (cons "gptoss.context_length" 131072)
                    (cons "general.architecture" "gptoss")))
        (prefixed (list (cons "gemma4.embedding_length" 5376)
                        (cons "gemma4.context_length" 262144)))
        (symbols (list (cons 'gptoss.context_length 131072)
                       (cons 'general.architecture "gptoss")))
        (other (list (cons "general.parameter_count" 32682372656))))
    (should (equal (quoth-ollama--context-length info) 131072))
    (should (equal (quoth-ollama--context-length prefixed) 262144))
    (should (equal (quoth-ollama--context-length symbols) 131072))
    (should (null (quoth-ollama--context-length other)))
    (should (null (quoth-ollama--context-length nil)))))

(ert-deftest quoth-test/ollama-tags-names-extracts-membership ()
  "`quoth-ollama--tags-names' reads the models' `name' fields.
An empty or wrong-shaped payload yields nil."
  (let ((payload '((models . [((name . "gemma4:31b"))
                              ((name . "gpt-oss:20b"))])))
        (bad '((models . [((id . "x"))]))))
    (should (equal (quoth-ollama--tags-names payload)
                   '("gemma4:31b" "gpt-oss:20b")))
    (should (null (quoth-ollama--tags-names bad)))
    (should (null (quoth-ollama--tags-names nil)))))

(ert-deftest quoth-test/ollama-seed-read-normalizes-snapshot ()
  "`quoth-ollama--models-seed-read' turns a snapshot into model plists.
The JSON array's `id', `capabilities', and `context_length' keys
normalize through the same pipeline as the live refresh."
  (let ((dir (make-temp-file "quoth-seed-" t)))
    (unwind-protect
        (let ((file (expand-file-name "snapshot.json" dir)))
          (with-temp-file file
            (insert "[{\"id\": \"gpt-oss:20b\",
                       \"capabilities\": [\"completion\", \"thinking\"],
                       \"context_length\": 131072}]"))
          (let ((entries (quoth-ollama--models-seed-read file)))
            (should (= (length entries) 1))
            (should (string= (plist-get (car entries) :id) "gpt-oss:20b"))
            (should (eq (plist-get (car entries) :can-reason) t))
            (should (= (plist-get (car entries) :context-window) 131072))))
      (delete-directory dir t))))

(ert-deftest quoth-test/ollama-seed-read-absent-never-errors ()
  "`quoth-ollama--models-seed-read' returns nil for absent or bad input.
A missing file, bad JSON, and an empty array all yield nil."
  (let ((dir (make-temp-file "quoth-seed-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "garbage.json" dir)
            (insert "not json"))
          (with-temp-file (expand-file-name "empty.json" dir)
            (insert "[]"))
          (should (null (quoth-ollama--models-seed-read
                         (expand-file-name "no-such.json" dir))))
          (should (null (quoth-ollama--models-seed-read
                         (expand-file-name "garbage.json" dir))))
          (should (null (quoth-ollama--models-seed-read
                         (expand-file-name "empty.json" dir)))))
      (delete-directory dir t))))

;;; 2. Shared-client ollama behaviors: the `reasoning' field alias
;;; and the usage-final-chunk shape.

(ert-deftest quoth-test/ollama-sse-reasoning-alias-delta ()
  "A `reasoning' delta yields a reasoning-typed delta, like `reasoning_content'.
Ollama names the field `reasoning' (the OpenAI convention is
`reasoning_content'); the client accepts whichever is present."
  (let* ((state (quoth-openai-sse-new-state))
         (result (quoth-openai-sse-feed
                  state
                  "data: {\"choices\":[{\"delta\":{\"reasoning\":\"think\"}}]}\n\n"))
         (deltas (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))))
    (should (equal deltas '((reasoning . "think"))))
    (should-not (plist-get (cdr result) :done))))

(ert-deftest quoth-test/ollama-sse-reasoning-content-preferred ()
  "`reasoning_content' wins when both reasoning fields appear.
The OpenAI convention is the preferred spelling; the alias is the
fallback."
  (let* ((state (quoth-openai-sse-new-state))
         (result (quoth-openai-sse-feed
                  state
                  (concat "data: {\"choices\":[{\"delta\":"
                          "{\"reasoning\":\"alias\",\"reasoning_content\":\"openai\"}}]}\n\n")))
         (deltas (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result))))
    (should (equal deltas '((reasoning . "openai"))))))

(ert-deftest quoth-test/ollama-sse-usage-chunk-with-empty-choices ()
  "The usage-final chunk carries `usage' and an empty `choices' array.
Ollama gates usage on `stream_options.include_usage'; that final
chunk's empty `choices' must not break delta extraction, and the
usage must land on the SSE state."
  (let* ((state (quoth-openai-sse-new-state))
         (chunk (concat
                 "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
                 "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,"
                 "\"completion_tokens\":3}}\n\n"
                 "data: [DONE]\n\n"))
         (result (quoth-openai-sse-feed state chunk))
         (deltas (mapcar (lambda (d) (cons (nth 0 d) (nth 1 d))) (car result)))
         (usage (plist-get (cdr result) :usage)))
    (should (equal deltas '((content . "hi"))))
    (should (plist-get (cdr result) :done))
    (should (equal (quoth--openai-alist-get "prompt_tokens" usage) 7))
    (should (equal (quoth--openai-alist-get "completion_tokens" usage) 3))))

;;; 3. Full transport path with ollama-shaped SSE: reasoning alias
;;; deltas drive the real curl filter into the buffer.

(declare-function quoth-test--make-transport-proc "quoth-test-hyper"
                  (target &optional done-callback))
(declare-function quoth-test--stream-into-buffer "quoth-test-hyper")
(declare-function quoth-test--hyper-completion "quoth-test-hyper" (buf))
(declare-function quoth-test--fresh-buffer "quoth-test" ())
(declare-function quoth-test--cleanup "quoth-test" ())
(defvar quoth-test--root)

(ert-deftest quoth-test/ollama-reasoning-alias-streams-fold-and-tags ()
  "`reasoning' deltas stream through the real transport like `reasoning_content'.
The ollama field name drives the same parse -> delta -> finalize path:
the CoT is tagged `reasoning', the answer `response', and the [DONE]
frame finalizes with a fresh prompt."
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (let ((old-prompt-id quoth--prompt-id))
            (save-excursion (goto-char (point-max)) (newline))
            (setq-local quoth--response-start (point-marker))
            (let ((proc (quoth-test--make-transport-proc
                         (current-buffer)
                         (quoth-test--hyper-completion (current-buffer)))))
              (unwind-protect
                  (progn
                    (quoth-test--stream-into-buffer
                     proc
                     "data: {\"choices\":[{\"delta\":{\"reasoning\":\"plan\"}}]}\n\n"
                     "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}\n\n"
                     "data: [DONE]\n\n")
                    (goto-char (point-min))
                    (should (search-forward "plan" nil t))
                    (search-backward "plan")
                    (let ((rs (point)))
                      (search-forward "answer")
                      (should (eq (get-text-property rs 'quoth-region-type)
                                  'reasoning))
                      (should (eq (get-text-property (- (point) 6)
                                                     'quoth-region-type)
                                  'response)))
                    (should-not (string= quoth--prompt-id old-prompt-id)))
                (when (process-live-p proc) (delete-process proc))))))
      (quoth-test--cleanup))))

;;; 4. Wire integration via the dummy Ollama Cloud server

;;; The dummy server (test/ollama-server.py) is a small Python program,
;;; started as a subprocess per test, that captures every request to a
;;; file and serves the ollama surfaces: GET /api/tags membership, one
;;; POST /api/show per model, and the /v1/chat/completions SSE stream.

(defun quoth-test--ollama-server-program ()
  "Return path to the dummy ollama server script."
  (expand-file-name "ollama-server.py"
                    (file-name-directory (locate-library "quoth-test"))))

(defvar quoth-test--ollama-servers nil
  "Alist of (MODE . (PROC CAP-FILE BASE-URL)) for shared dummy servers.
The server for a mode is started once and reused across tests; the
capture file is truncated before each test's body so every test sees a
clean capture.  Torn down from `kill-emacs-hook'.")

(defun quoth-test--ollama-stop-servers ()
  "Stop every shared dummy ollama server and delete its capture file."
  (dolist (entry quoth-test--ollama-servers)
    (let* ((rest (cdr entry))
           (proc (car rest))
           (cap (cadr rest)))
      (when (processp proc) (delete-process proc))
      (when (and cap (file-exists-p cap)) (delete-file cap))))
  (setq quoth-test--ollama-servers nil))

(defun quoth-test--ollama-wait-for-base (cap deadline)
  "Poll up to DEADLINE for the server to write its base URL to CAP.
Return the base URL string, or nil on timeout."
  (let (base)
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
    base))

(defun quoth-test--with-ollama-server (mode body-fn)
  "Start (or reuse) a dummy ollama server in MODE; call BODY-FN with BASE-URL.
The server for MODE is started once and reused across tests; the capture
file is truncated to the base URL line before each test's body, so every
test sees a clean capture (the server appends per-request).  Returns
\(BASE-URL . REQUESTS) parsed from the capture file."
  (let* ((cached (assq mode quoth-test--ollama-servers))
         (proc (and cached (car (cdr cached))))
         (cap (and cached (cadr (cdr cached))))
         (base (and cached (caddr (cdr cached)))))
    (unless cached
      (setq cap (make-temp-file "quoth-ollama-capture"))
      (setq proc (make-process
                  :name "quoth-ollama-test"
                  :command (list (quoth-test--ollama-server-program)
                                 cap (symbol-name mode))
                  :noquery t))
      (setq base (quoth-test--ollama-wait-for-base cap (+ (float-time) 5)))
      (unless base
        (when (processp proc) (delete-process proc))
        (when (file-exists-p cap) (delete-file cap))
        (error "Ollama dummy server failed to start"))
      (push (list mode proc cap base) quoth-test--ollama-servers))
    ;; Truncate the capture to the base URL line: the server re-opens it
    ;; in append mode per request, so a fresh per-test capture follows.
    (with-temp-file cap
      (insert base "\n"))
    (funcall body-fn base)
    (quoth-test--read-hyper-capture cap)))

(add-hook 'kill-emacs-hook #'quoth-test--ollama-stop-servers)

(declare-function quoth-test--read-hyper-capture "quoth-test-hyper" (file))
(declare-function quoth-test--wait-until "quoth-test-process" (pred &optional timeout))

(ert-deftest quoth-test/ollama-wire-captures-request-body ()
  "The request body carries the composed message list and the usage extra.
`stream_options.include_usage' rides the body as the ollama provider
extra, and no session-affinity headers are sent (ollama has no
prefix-cache protocol)." :tags '(:integration)
  (let* ((result (quoth-test--with-ollama-server
                  'ok-stream
                  (lambda (base)
                    (let ((provider (quoth-make-ollama-provider
                                     :buffer (current-buffer)
                                     :base-url base
                                     :token "tok-ol"
                                     :model "gpt-oss:20b")))
                      (let ((handle (quoth-provider-send-prompt
                                     provider "hi"
                                     :completion #'ignore
                                     :on-delta #'ignore
                                     :on-error #'ignore
                                     :buffer (current-buffer))))
                        (let ((deadline (+ (float-time) 6)))
                          (while (and (< (float-time) deadline)
                                      (not (and (plist-get handle :curl)
                                                (process-get
                                                 (plist-get handle :curl)
                                                 :quoth-finished))))
                            (accept-process-output nil 0.1))))
                      nil))))
         (base (nth 0 result))
         (requests (nth 1 result)))
    (should base)
    (should (= (length requests) 1))
    (let* ((req (car requests))
           (method (nth 0 req))
           (path (nth 1 req))
           (headers (nth 2 req))
           (body (nth 3 req))
           (decoded (json-read-from-string body)))
      (should (string= method "POST"))
      (should (string= path "/v1/chat/completions"))
      (should (string= (cdr (assoc "authorization" headers))
                       "Bearer tok-ol"))
      ;; No session-affinity headers: the negative of hyper's wire
      ;; behavior (hyper always sends them when its gate is on).
      (should-not (cdr (assoc "x-session-id" headers)))
      (should-not (cdr (assoc "x-session-affinity" headers)))
      (should (string= (quoth--openai-alist-get "model" decoded)
                       "gpt-oss:20b"))
      (should (eq (quoth--openai-alist-get "stream" decoded) t))
      ;; The provider extra: the final SSE chunk carries usage.
      (let ((extra (quoth--openai-alist-get "stream_options" decoded)))
        (should extra)
        (should (eq (quoth--openai-alist-get "include_usage" extra) t))))))

(ert-deftest quoth-test/ollama-wire-catalog-fanout-merges ()
  "The catalog assembles from one tags request plus one show per model.
The tags membership drives a parallel POST /api/show fan-out; the
join delivers one normalized plist per model with capabilities and
the architecture-prefixed context length mapped onto the protocol
keys." :tags '(:integration)
  (let ((fetched (list 'unset)))
    (let* ((result (quoth-test--with-ollama-server
                    'ok-stream
                    (lambda (base)
                      (quoth-ollama--fetch-models-async
                       (quoth-make-ollama-provider
                        :buffer (current-buffer)
                        :base-url base
                        :token "tok-cat")
                       (lambda (catalog)
                         (setq fetched (list catalog))))
                      (quoth-test--wait-until
                       (lambda () (not (eq (car fetched) 'unset))) 10))))
           (requests (nth 1 result))
           (catalog (car fetched)))
      (should-not (eq catalog 'unset))
      ;; One GET /api/tags plus one POST /api/show per tags model.
      (let (gets shows)
        (dolist (r requests)
          (cond ((and (string= (nth 0 r) "GET")
                      (string= (nth 1 r) "/api/tags"))
                 (push r gets))
                ((and (string= (nth 0 r) "POST")
                      (string= (nth 1 r) "/api/show"))
                 (push r shows))))
        (should (= (length gets) 1))
        (should (= (length shows) 2))
        ;; Each show posts the model name it is looking up.
        (let ((asked (mapcar (lambda (r)
                               (quoth--openai-alist-get
                                "model" (json-read-from-string (nth 3 r))))
                             shows)))
          (should (equal (sort asked #'string<)
                         '("gemma4:31b" "gpt-oss:20b")))))
      ;; The merged catalog: two entries, each normalized.
      (should (= (length catalog) 2))
      (let ((entry (lambda (id)
                     (cl-find id catalog
                              :test #'string=
                              :key (lambda (m) (plist-get m :id))))))
        (let ((gpt (funcall entry "gpt-oss:20b"))
              (gem (funcall entry "gemma4:31b")))
          (should gpt)
          (should gem)
          (should (= (plist-get gpt :context-window) 131072))
          (should (eq (plist-get gpt :can-reason) t))
          (should-not (plist-get gpt :supports-attachments))
          (should (= (plist-get gem :context-window) 262144))
          (should (eq (plist-get gem :can-reason) t))
          (should (eq (plist-get gem :supports-attachments) t)))))))

(defun quoth-test--ollama-req-body (request)
  "Return the JSON-decoded body of one captured REQUEST."
  (json-read-from-string (nth 3 request)))

(defun quoth-test--ollama-messages (request)
  "Return the messages array from one captured REQUEST's body."
  (quoth--openai-alist-get
   "messages" (quoth-test--ollama-req-body request)))

(defun quoth-test--ollama-stream-extra-p (request)
  "Return non-nil when REQUEST's body carries `stream_options.include_usage'."
  (let ((extra (quoth--openai-alist-get
                "stream_options" (quoth-test--ollama-req-body request))))
    (and extra
         (eq (quoth--openai-alist-get "include_usage" extra) t))))

(defun quoth-test--ollama-wait-for-text (text &optional timeout)
  "Wait up to TIMEOUT (default 6s) for TEXT to appear in the buffer."
  (let ((deadline (+ (float-time) (or timeout 6)))
        (found nil))
    (while (and (< (float-time) deadline) (not found))
      (accept-process-output nil 0.1)
      (sit-for 0.02)
      (setq found (save-excursion
                    (goto-char (point-min))
                    (search-forward text nil t))))
    (should found)))

(defun quoth-test--ollama-install-provider (base model)
  "Install an ollama provider as the current buffer's active provider.
BASE is the dummy server's base URL; MODEL is the model slot."
  (setq-local quoth-active-provider
              (quoth-make-ollama-provider
               :buffer (current-buffer)
               :working-directory default-directory
               :token "tok"
               :model model))
  (setf (quoth-ollama-provider-base-url quoth-active-provider) base))

(defun quoth-test--ollama-send-and-capture (mode model prompt wait-text)
  "Send PROMPT to a dummy ollama server in MODE, returning REQUESTS.
Installs an ollama provider for MODEL as the active provider, types
PROMPT, sends, waits for WAIT-TEXT (the turn's last streamed text)
to land in the buffer, and returns the captured request list."
  (car (cdr (quoth-test--with-ollama-server
             mode
             (lambda (base)
               (quoth-test--ollama-install-provider base model)
               (goto-char (point-max))
               (insert prompt)
               (quoth-send-input)
               (quoth-test--ollama-wait-for-text wait-text 12))))))

;;; One test at a time below this line, each kept shallow.

(ert-deftest quoth-test/ollama-wire-tool-loop-executes-and-resends ()
  "A tool_calls stream triggers tool execution and a follow-up request.
The first request gets the tool_calls frame; the loop runs `echo hi',
inserts the tool block, and the follow-up carries the tool result and
gets the content answer.  Both requests keep the ollama body shape
\(`stream_options.include_usage' on every round)."
  :tags '(:integration)
  (let ((default-directory quoth-test--root)
        (quoth-tools-enabled t))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth-test--ollama-tool-loop-body))
      (quoth-test--cleanup))))

(defun quoth-test--ollama-tool-loop-body ()
  "Drive the tool-call mode wire round trip and assert both requests."
  (let ((requests (quoth-test--ollama-send-and-capture
                   'tool-call "gpt-oss:20b" "ls" "tool-result-ack")))
    (should (= (length requests) 2))
    (quoth-test--ollama-check-plain-user-request (nth 0 requests) "ls")
    (quoth-test--ollama-check-tool-pair-request (nth 1 requests))
    (should (quoth-test--ollama-stream-extra-p (nth 0 requests)))
    (should (quoth-test--ollama-stream-extra-p (nth 1 requests)))))

(defun quoth-test--ollama-check-plain-user-request (request prompt)
  "Assert REQUEST is a plain [system, user PROMPT] body with the extra."
  (let ((msgs (quoth-test--ollama-messages request)))
    (should (= (length msgs) 2))
    (should (string= (quoth--openai-alist-get "content" (aref msgs 1))
                     prompt))))

(defun quoth-test--ollama-check-tool-pair-request (request)
  "Assert REQUEST rides the assistant tool-call and role:tool pair."
  (let ((msgs (quoth-test--ollama-messages request)))
    (should (>= (length msgs) 4))
    (should (string= (quoth--openai-alist-get "role" (aref msgs 2))
                     "assistant"))
    (should (string= (quoth--openai-alist-get "role" (aref msgs 3))
                     "tool"))))

(ert-deftest quoth-test/ollama-wire-gated-model-surfaces-error ()
  "A gated model's HTTP 402 surfaces through the existing error path.
The pane is a blockquote tagged `system'; the provider has no
tier-gating logic, so the server's own rejection is the whole story."
  :tags '(:integration)
  (let ((default-directory quoth-test--root))
    (unwind-protect
        (with-current-buffer (quoth-test--fresh-buffer)
          (quoth-test--ollama-gated-error-body))
      (quoth-test--cleanup))))

(defun quoth-test--ollama-gated-error-body ()
  "Drive the 402 mode wire round trip and assert the error surfacing."
  (let ((requests (quoth-test--ollama-send-and-capture
                   'error-402 "kimi-k3" "go" "HTTP 402")))
    (should (= (length requests) 1))
    (let ((req (car requests)))
      (should (string= (nth 0 req) "POST"))
      (should (string= (nth 1 req) "/v1/chat/completions")))
    (save-excursion
      (goto-char (point-min))
      (should (re-search-forward "> \\*\\*Error:\\*\\*" nil t))
      (should (re-search-forward "HTTP 402" nil t))
      (should (re-search-forward "server said" nil t))
      ;; The server's own message rides the note verbatim.
      (should (re-search-forward "requires a subscription" nil t))
      (should (re-search-forward "Resend" nil t)))
    (let ((pane-start (text-property-any (point-min) (point-max)
                                         'quoth-region-type 'system)))
      (should pane-start)
      ;; Nothing after the pane is tagged `response': the turn ended
      ;; in an error, not a streamed answer.
      (should-not (text-property-any pane-start (point-max)
                                     'quoth-region-type 'response)))))

(provide 'quoth-test-ollama)
;;; quoth-test-ollama.el ends here
