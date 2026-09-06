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
  (dolist (dep '("quoth" "quoth-provider" "quoth-openai" "quoth-ollama-provider"))
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
`gemma4.context_length'), so the suffix — not a fixed key — decides."
  (let ((info (list (cons "gptoss.context_length" 131072)
                    (cons "general.architecture" "gptoss")))
        (prefixed (list (cons "gemma4.embedding_length" 5376)
                        (cons "gemma4.context_length" 262144)))
        (other (list (cons "general.parameter_count" 32682372656))))
    (should (equal (quoth-ollama--context-length info) 131072))
    (should (equal (quoth-ollama--context-length prefixed) 262144))
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

(provide 'quoth-test-ollama)
;;; quoth-test-ollama.el ends here