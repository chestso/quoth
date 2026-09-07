;;; quoth-test-select.el --- Active provider + model selector tests for quoth  -*- lexical-binding: t; -*-
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
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;;; THE SOFTWARE.

;;; Commentary:
;;; Tests for the active-provider registry, provider generics for model
;;; catalogs, session attribute variables, and the transient selector
;;; entrypoints (bypassing transient UI, driving the apply functions
;;; directly).

;;; Code:

(require 'ert)
(require 'cl-lib)

(eval-and-compile
  (dolist (dep '("quoth"))
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
(declare-function quoth-test--fresh-buffer "quoth-test" ())
(declare-function quoth-test--cleanup "quoth-test" ())
(declare-function quoth-test--with-hyper-server "quoth-test-hyper" (mode body-fn))

;;; 101. Provider registry

(ert-deftest quoth-test/registry-builtin-shape ()
  "The `quoth-builtin-providers' registry lists hyper first, then ollama.
Each entry carries :name, :type, and a callable :factory; the ollama
entry seeds new buffers with its :default-model."
  (should (= (length quoth-builtin-providers) 2))
  (let ((hyper (nth 0 quoth-builtin-providers))
        (ollama (nth 1 quoth-builtin-providers)))
    (should (string= (plist-get hyper :name) "hyper"))
    (should (eq (plist-get hyper :type) 'hyper))
    (should (functionp (plist-get hyper :factory)))
    (should (string= (plist-get ollama :name) "ollama"))
    (should (eq (plist-get ollama :type) 'ollama))
    (should (functionp (plist-get ollama :factory)))
    (should (string= (plist-get ollama :default-model) "gpt-oss:20b"))))

(ert-deftest quoth-test/registry-default-provider-name ()
  "`quoth-default-provider' defaults to \"hyper\"."
  (should (string= (default-value 'quoth-default-provider) "hyper")))

(ert-deftest quoth-test/instantiate-provider-returns-hyper ()
  "`quoth--instantiate-provider' builds a hyper provider from the registry."
  (let ((buf (generate-new-buffer " *quoth-test-instantiate*")))
    (with-current-buffer buf
      (let ((provider (quoth--instantiate-provider "hyper" buf default-directory)))
        (should (quoth-hyper-provider-p provider))
        (should (string= (quoth-hyper-provider-base-url provider)
                         quoth-hyper-base-url))
        (should (eq (quoth-provider-buffer provider) buf))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;;; 102. Provider generics: models + apply-model

(ert-deftest quoth-test/provider-models-generic-default-is-nil ()
  "The base `quoth-provider--models-async' delivers nil for a bare provider."
  (let ((provider (make-quoth-provider))
        (delivered nil))
    (should (null (quoth-provider--models-async
                   provider (lambda (models) (push models delivered)))))
    (should (equal delivered '(nil)))))

(ert-deftest quoth-test/provider-apply-model-generic-default-is-nil ()
  "The base `quoth-provider--apply-model' returns nil for a bare provider."
  (let ((provider (make-quoth-provider)))
    (should (null (quoth-provider--apply-model provider '(:id "x"))))))

(ert-deftest quoth-test/hyper-provider-models-normalizes-plist ()
  "`quoth-provider--models-async' on hyper delivers structured plists."
  (let ((provider (quoth-make-hyper-provider
                   :buffer (current-buffer)
                   :working-directory default-directory
                   :base-url "http://127.0.0.1:1"))
        (delivered nil))
    (cl-letf (((symbol-function 'quoth-hyper--fetch-models-async)
               (lambda (_base _token on-done)
                 (funcall on-done
                          (cons '((default_large_model_id . "qwen3.7-plus"))
                                (vector
                                 (list (cons "id" "deepseek-v4-flash-0731")
                                       (cons "name" "DeepSeek V4 Flash")
                                       (cons "cost_per_1m_in" 0.1)
                                       (cons "cost_per_1m_out" 0.3)
                                       (cons "cost_per_1m_in_cached" 0.07)
                                       (cons "cost_per_1m_out_cached" 0.03)
                                       (cons "context_window" 131072)
                                       (cons "default_max_tokens" 8192)
                                       (cons "can_reason" t)
                                       (cons "reasoning_levels"
                                             (vector "low" "medium" "high"))
                                       (cons "default_reasoning_effort" "high")
                                       (cons "supports_attachments" t))
                                 (list (cons "id" "mini-no-reason")
                                       (cons "name" "Mini No Reason")
                                       (cons "cost_per_1m_in" 0.05)
                                       (cons "cost_per_1m_out" 0.1)
                                       (cons "cost_per_1m_in_cached" 0.0)
                                       (cons "cost_per_1m_out_cached" 0.0)
                                       (cons "context_window" 32768)
                                       (cons "default_max_tokens" 4096)
                                       (cons "can_reason" :json-false)
                                       (cons "reasoning_levels" (vector))
                                       (cons "default_reasoning_effort" nil)
                                       (cons "supports_attachments"
                                             :json-false))))))))
      (quoth-provider--models-async
       provider (lambda (models) (push models delivered)))
      (let ((models (car delivered)))
        (should (= (length models) 2))
        (let ((m1 (car models)))
          (should (string= (plist-get m1 :id) "deepseek-v4-flash-0731"))
          (should (string= (plist-get m1 :name) "DeepSeek V4 Flash"))
          (should (= (plist-get m1 :context-window) 131072))
          (should (= (plist-get m1 :default-max-tokens) 8192))
          (should (= (plist-get m1 :cost-in) 0.1))
          (should (= (plist-get m1 :cost-out) 0.3))
          (should (= (plist-get m1 :cost-cache-write) 0.07))
          (should (= (plist-get m1 :cost-cache-hit) 0.03))
          (should (eq (plist-get m1 :can-reason) t))
          (should (equal (plist-get m1 :reasoning-levels)
                         '("low" "medium" "high")))
          (should (string= (plist-get m1 :default-reasoning-effort) "high"))
          (should (eq (plist-get m1 :supports-attachments) t)))
        (let ((m2 (cadr models)))
          (should (string= (plist-get m2 :id) "mini-no-reason"))
          (should-not (eq (plist-get m2 :can-reason) t))
          (should (null (plist-get m2 :reasoning-levels))))))))

(ert-deftest quoth-test/hyper-provider-apply-model-sets-slot ()
  "`quoth-provider--apply-model' on hyper sets the model slot from the plist."
  (let ((provider (quoth-make-hyper-provider
                   :buffer (current-buffer)
                   :working-directory default-directory)))
    (quoth-provider--apply-model provider '(:id "qwen3.7-plus"))
    (should (string= (quoth-hyper-provider-model provider) "qwen3.7-plus"))))

(ert-deftest quoth-test/hyper-provider-models-nil-on-fetch-failure ()
  "`quoth-provider--models-async' delivers nil when the fetch fails."
  (let ((provider (quoth-make-hyper-provider
                   :buffer (current-buffer)
                   :working-directory default-directory
                   :base-url "http://127.0.0.1:1"))
        (delivered nil))
    (cl-letf (((symbol-function 'quoth-hyper--fetch-models-async)
               (lambda (_base _token on-done)
                 (funcall on-done nil))))
      (quoth-provider--models-async
       provider (lambda (models) (push models delivered)))
      (should (equal delivered '(nil))))))

;;; 103. Session attributes: buffer-local, no globals

(ert-deftest quoth-test/session-attrs-are-buffer-local ()
  "`quoth--session-thinking' and `-reasoning-effort' are buffer-local.
Once set in a buffer, the value is local to that buffer (defvar-local)."
  (with-temp-buffer
    (setq-local quoth--session-thinking t)
    (setq-local quoth--session-reasoning-effort "high")
    (should (local-variable-p (quote quoth--session-thinking)))
    (should (local-variable-p (quote quoth--session-reasoning-effort)))
    (should (eq quoth--session-thinking t))
    (should (string= quoth--session-reasoning-effort "high"))))

(ert-deftest quoth-test/compose-session-attrs-land-in-body ()
  "Session thinking + effort land in the request body when set."
  (let ((quoth--session-thinking t)
        (quoth--session-reasoning-effort "high"))
    (let ((req (quoth-openai-compose-request "P" "my-model" "sys")))
      (should (eq (alist-get 'thinking req) t))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest quoth-test/compose-defaults-omit-attrs ()
  "With session slots nil, neither thinking nor effort appears in the body."
  (let (quoth--session-thinking quoth--session-reasoning-effort)
    (let ((req (quoth-openai-compose-request "P" "m" "sys")))
      (should-not (assq 'thinking req))
      (should-not (assq 'reasoning_effort req)))))

(ert-deftest quoth-test/compose-thinking-only-omits-effort ()
  "Thinking on, effort nil: body has thinking, no reasoning_effort."
  (let ((quoth--session-thinking t)
        quoth--session-reasoning-effort)
    (let ((req (quoth-openai-compose-request "P" "m" "sys")))
      (should (eq (alist-get 'thinking req) t))
      (should-not (assq 'reasoning_effort req)))))

(ert-deftest quoth-test/compose-effort-without-thinking-sends-effort ()
  "Effort set but thinking unset: no thinking key, but effort is sent."
  (let (quoth--session-thinking
        (quoth--session-reasoning-effort "high"))
    (let ((req (quoth-openai-compose-request "P" "m" "sys")))
      (should-not (assq 'thinking req))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

(ert-deftest quoth-test/compose-thinking-off-sends-false-and-effort ()
  "Thinking off (:json-false) sends `thinking: false'; effort still sent."
  (let ((quoth--session-thinking :json-false)
        (quoth--session-reasoning-effort "high"))
    (let ((req (quoth-openai-compose-request "P" "m" "sys")))
      (should (eq (alist-get 'thinking req) :json-false))
      (should (string= (alist-get 'reasoning_effort req) "high")))))

;;; 104. Select-model via the new apply path

(ert-deftest quoth-test/select-model-applies-via-provider-generic ()
  "`quoth-select-model' applies the chosen model through the provider.
The choice lands in the buffer's session slot and the provider's model
slot via `quoth-provider--apply-model', and the sticky
`quoth-model-by-provider' entry for the session provider is written
so the next buffer on it starts there."
  (let ((quoth-model-by-provider nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'quoth-provider-models-cached)
                       (lambda (&rest _)
                         (list '(:id "qwen3.7-plus" :name "Qwen" :can-reason t
                                     :reasoning-levels ("low" "medium" "high" "max")
                                     :default-reasoning-effort "max"))))
                      ((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (&rest _) "qwen3.7-plus")))
              (quoth-select-model))
            (should (string= quoth--session-model "qwen3.7-plus"))
            (should (string= (quoth-hyper-provider-model quoth-active-provider)
                             "qwen3.7-plus"))
            (should (string= (cdr (assq 'hyper quoth-model-by-provider))
                             "qwen3.7-plus"))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/select-model-default-clears-slot ()
  "Choosing 'default' clears the session model, provider slot, and sticky.
The buffer's session slot, the provider's model slot cache, and the
sticky `quoth-model-by-provider' entry for the session provider are
all cleared, so a new buffer on the provider starts from the
provider default again."
  (let ((quoth-model-by-provider (list (cons 'hyper "qwen3.7-plus"))))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--session-model "qwen3.7-plus")
            (setf (quoth-hyper-provider-model quoth-active-provider) "qwen3.7-plus")
            (cl-letf (((symbol-function 'quoth-provider-models-cached)
                       (lambda (&rest _) nil))
                      ((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (&rest _) "default")))
              (quoth-select-model))
            (should (null quoth--session-model))
            (should (null (quoth-hyper-provider-model quoth-active-provider)))
            (should (null (assq 'hyper quoth-model-by-provider)))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/select-model-fallback-on-no-models ()
  "A cold catalog offers the resolved default as the fallback choice.
With no session model, sticky entry, registry :default-model, or
global default, the fallback bottoms out at
`quoth-openai-default-model'; picking from it still writes the
session slot, the provider slot, and the sticky entry."
  (let ((quoth-model-by-provider nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (should (null quoth--session-model))
            (cl-letf (((symbol-function 'quoth-provider-models-cached)
                       (lambda (&rest _) nil))
                      ((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (_prompt coll &rest _)
                         (should (assoc quoth-openai-default-model coll))
                         "qwen3.7-plus")))
              (quoth-select-model))
            (should (string= quoth--session-model "qwen3.7-plus"))
            (should (string= (quoth-hyper-provider-model quoth-active-provider)
                             "qwen3.7-plus"))
            (should (string= (cdr (assq 'hyper quoth-model-by-provider))
                             "qwen3.7-plus"))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

;;; 105. Persistence: savehist registration

(ert-deftest quoth-test/savehist-registers-provider-and-model ()
  "Savehist registers the provider default and the sticky model alist.
`quoth-default-provider' and `quoth-model-by-provider' are registered
with `savehist-additional-variables' so both survive restarts."
  (require 'savehist)
  (should (memq 'quoth-default-provider
                (default-value 'savehist-additional-variables)))
  (should (memq 'quoth-model-by-provider
                (default-value 'savehist-additional-variables))))

;;; 106. Provider-qualified model ids

(ert-deftest quoth-test/parse-model-id-qualified ()
  "`quoth-provider-parse-model-id' splits a registered-provider prefix.
\"ollama/gemma\" routes to the ollama provider with the bare model."
  (should (equal (quoth-provider-parse-model-id "ollama/gemma")
                 '(:provider "ollama" :model "gemma"))))

(ert-deftest quoth-test/parse-model-id-bare-is-nil ()
  "A model id with no slash is never qualified."
  (should (null (quoth-provider-parse-model-id "gemma")))
  (should (null (quoth-provider-parse-model-id ""))))

(ert-deftest quoth-test/parse-model-id-unknown-prefix-is-nil ()
  "A slash-containing id whose prefix names no provider stays bare.
`meta-llama/Llama-3' is a real model id, not a route, so the parser
must leave it alone — the registry-membership test, not a syntax
rule, decides qualification."
  (should (null (quoth-provider-parse-model-id "meta-llama/Llama-3"))))

(ert-deftest quoth-test/parse-model-id-empty-model-part-is-nil ()
  "A prefix with no model after the slash is not a route."
  (should (null (quoth-provider-parse-model-id "ollama/")))
  (should (null (quoth-provider-parse-model-id "hyper/"))))

(ert-deftest quoth-test/bare-model-id-passes-through ()
  "`quoth-provider-bare-model-id' strips only a registered prefix.
Qualified ids yield the bare model; every other id returns unchanged,
including slash-containing ids that name no provider."
  (should (string= (quoth-provider-bare-model-id "ollama/gemma") "gemma"))
  (should (string= (quoth-provider-bare-model-id "gemma") "gemma"))
  (should (string= (quoth-provider-bare-model-id "meta-llama/Llama-3")
                   "meta-llama/Llama-3")))

(ert-deftest quoth-test/set-model-spec-qualified-routes-provider ()
  "`quoth--set-model-spec' with a qualified id switches the route.
From a hyper buffer, \"ollama/gemma\" moves the session provider to
ollama, the session model to the bare gemma, and reinstantiates
`quoth-active-provider' as an ollama provider with gemma as its model
slot."
  (let ((quoth-model-by-provider nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'quoth-provider-models-refresh)
                       #'ignore))
              (should (string= quoth--session-provider "hyper"))
              (quoth--set-model-spec "ollama/gemma")
              (should (string= quoth--session-provider "ollama"))
              (should (string= quoth--session-model "gemma"))
              (should (quoth-ollama-provider-p quoth-active-provider))
              (should (string= (quoth-ollama-provider-model
                                quoth-active-provider)
                               "gemma")))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/set-model-spec-qualified-writes-target-sticky ()
  "A qualified pick writes the sticky entry under the named provider.
Picking \"ollama/gemma\" from a hyper buffer records gemma under
ollama — the next ollama buffer starts there — and leaves the hyper
entry alone."
  (let ((quoth-model-by-provider (list (cons 'hyper "qwen3.7-plus"))))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'quoth-provider-models-refresh)
                       #'ignore))
              (quoth--set-model-spec "ollama/gemma")
              (should (string= (cdr (assq 'ollama quoth-model-by-provider))
                               "gemma"))
              (should (string= (cdr (assq 'hyper quoth-model-by-provider))
                               "qwen3.7-plus")))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/set-model-spec-same-provider-no-cleanup ()
  "A qualified id naming the active provider changes only the model.
The provider switch branch (cleanup, reinstantiate) is skipped when
the route names the buffer's current provider."
  (unwind-protect
      (let ((buf (quoth-test--fresh-buffer))
            (cleaned 0))
        (with-current-buffer buf
          (cl-letf (((symbol-function 'quoth-provider-models-refresh)
                     #'ignore)
                    ((symbol-function 'quoth-provider-cleanup)
                     (lambda (&rest _) (cl-incf cleaned))))
            (let ((provider quoth-active-provider))
              (quoth--set-model-spec "hyper/qwen3.7-plus")
              (should (= cleaned 0))
              (should (eq quoth-active-provider provider))
              (should (string= quoth--session-model "qwen3.7-plus"))
              (should (string= (quoth-hyper-provider-model
                                quoth-active-provider)
                               "qwen3.7-plus"))))))
    (quoth-test--cleanup)))

(ert-deftest quoth-test/set-model-spec-bare-writes-active-sticky ()
  "A bare id writes the sticky entry under the active provider.
The session model, provider slot, and sticky entry all carry the id
verbatim."
  (let ((quoth-model-by-provider nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (quoth--set-model-spec "qwen3.7-plus")
            (should (string= quoth--session-model "qwen3.7-plus"))
            (should (string= (quoth-hyper-provider-model
                              quoth-active-provider)
                             "qwen3.7-plus"))
            (should (string= (cdr (assq 'hyper quoth-model-by-provider))
                             "qwen3.7-plus"))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/set-model-spec-empty-is-noop ()
  "`quoth--set-model-spec' ignores nil and empty input.
The picker's free-form prompt can return an empty string; it must
leave the session model, the provider slot, and the sticky alist
untouched."
  (let ((quoth-model-by-provider (list (cons 'hyper "qwen3.7-plus"))))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--session-model "qwen3.7-plus")
            (quoth--set-model-spec "")
            (quoth--set-model-spec nil)
            (should (string= quoth--session-model "qwen3.7-plus"))
            (should (string= (cdr (assq 'hyper quoth-model-by-provider))
                             "qwen3.7-plus"))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/picker-free-form-qualified-id-routes ()
  "The model picker accepts a typed qualified id.
With require-match off and `completing-read' stubbed to a
free-form \"ollama/gemma\", the picker routes the buffer onto
ollama/gemma exactly as `quoth--set-model-spec' does."
  (let ((quoth-model-by-provider nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'quoth-provider-models-cached)
                       (lambda (&rest _) nil))
                      ((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (&rest _) "ollama/gemma")))
              (quoth-select-model))
            (should (string= quoth--session-provider "ollama"))
            (should (string= quoth--session-model "gemma"))
            (should (quoth-ollama-provider-p quoth-active-provider))
            (should (string= (cdr (assq 'ollama quoth-model-by-provider))
                             "gemma"))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/set-model-default-clears-active-sticky ()
  "`quoth--set-model-default' clears the session and sticky state.
The session model, the provider's model slot, and the sticky entry
for the active provider all reset, so the next buffer on the provider
starts from its chain again."
  (let ((quoth-model-by-provider (list (cons 'hyper "qwen3.7-plus"))))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (setq-local quoth--session-model "qwen3.7-plus")
            (quoth--set-model-default)
            (should (null quoth--session-model))
            (should (null (quoth-hyper-provider-model
                           quoth-active-provider)))
            (should (null (assq 'hyper quoth-model-by-provider)))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/qualified-default-model-seeds-provider-at-init ()
  "A qualified `quoth-default-model' routes a fresh buffer.
Buffer init seeds the session provider from the qualified prefix —
overriding `quoth-default-provider' — and the session model from the
bare model."
  (let ((quoth-default-model "ollama/gemma")
        (quoth-model-by-provider nil))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (should (string= quoth--session-provider "ollama"))
            (should (string= quoth--session-model "gemma"))
            (should (quoth-ollama-provider-p quoth-active-provider))))
      (setq quoth-default-model nil
            quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(ert-deftest quoth-test/qualified-default-model-skips-other-providers ()
  "A qualified `quoth-default-model' never leaks onto another chain.
With \"ollama/gemma\" set, a hyper buffer's provider chain resolves
to nil at the global-default step: the qualified value belongs to
ollama only."
  (let ((quoth-default-model "ollama/gemma")
        (quoth-model-by-provider nil))
    (unwind-protect
        (should (null (quoth--provider-default-model "hyper")))
      (setq quoth-default-model nil
            quoth-model-by-provider nil))))

(ert-deftest quoth-test/provider-switch-preserves-sticky-for-target ()
  "`quoth--select-provider-switch' carries the sticky model across.
Switching to ollama re-seeds the session model from ollama's chain
\(the sticky entry, so gemma in this test) and writes no sticky
entry: the switch routes, it does not pick."
  (let ((quoth-model-by-provider (list (cons 'ollama "gemma"))))
    (unwind-protect
        (let ((buf (quoth-test--fresh-buffer)))
          (with-current-buffer buf
            (cl-letf (((symbol-function 'quoth-provider-models-refresh)
                       #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (&rest _) "ollama")))
              (quoth--select-provider-switch)
              (should (string= quoth--session-provider "ollama"))
              (should (string= quoth--session-model "gemma"))
              (should (quoth-ollama-provider-p quoth-active-provider))
              (should (equal quoth-model-by-provider
                             (list (cons 'ollama "gemma")))))))
      (setq quoth-model-by-provider nil)
      (quoth-test--cleanup))))

(provide 'quoth-test-select)
;;; quoth-test-select.el ends here

;;; 106. Transient selector: affixation and apply functions

(ert-deftest quoth-test/select-model-choices-builds-affixation ()
  "`quoth--model-choices' returns (ID . DISPLAY) pairs with price info."
  (let ((models (list '(:id "qwen3.7-plus" :name "Qwen 3.7 Plus"
                            :context-window 262144 :cost-in 0.2 :cost-out 0.6
                            :can-reason t
                            :reasoning-levels ("low" "medium" "high" "max"))
                      '(:id "mini-no-reason" :name "Mini No Reason"
                            :context-window 32768 :cost-in 0.05 :cost-out 0.1
                            :can-reason nil :reasoning-levels nil))))
    (let ((choices (quoth--model-choices models)))
      (should (= (length choices) 2))
      (should (string= (car (car choices)) "qwen3.7-plus"))
      (should (string-match-p "Qwen 3.7 Plus" (cdr (car choices))))
      (should (string-match-p "262144" (cdr (car choices))))
      (should (string-match-p "0.20" (cdr (car choices))))
      (should (string-match-p "reason" (cdr (car choices))))
      (should (string-match-p "no reason" (cdr (cadr choices)))))))

(ert-deftest quoth-test/select-apply-thinking-sets-session ()
  "`quoth--select-apply-thinking' sets the buffer-local session slot."
  (with-temp-buffer
    (quoth--select-apply-thinking t)
    (should (eq quoth--session-thinking t))
    (quoth--select-apply-thinking :json-false)
    (should (eq quoth--session-thinking :json-false))
    (quoth--select-apply-thinking nil)
    (should (null quoth--session-thinking))))

(ert-deftest quoth-test/select-thinking-toggle-cycles-on-off ()
  "`quoth--select-thinking-toggle' cycles on -> off -> on, never unset."
  (with-temp-buffer
    ;; unset -> on
    (quoth--select-thinking-toggle)
    (should (eq quoth--session-thinking t))
    ;; on -> off
    (quoth--select-thinking-toggle)
    (should (eq quoth--session-thinking :json-false))
    ;; off -> on
    (quoth--select-thinking-toggle)
    (should (eq quoth--session-thinking t))))

(ert-deftest quoth-test/select-apply-effort-sets-session ()
  "`quoth--select-apply-effort' sets the buffer-local session slot."
  (with-temp-buffer
    (quoth--select-apply-effort "high")
    (should (string= quoth--session-reasoning-effort "high"))
    (quoth--select-apply-effort nil)
    (should (null quoth--session-reasoning-effort))))

(ert-deftest quoth-test/select-apply-defaults-clears-session ()
  "`quoth--select-apply-defaults' clears both session slots."
  (with-temp-buffer
    (setq-local quoth--session-thinking t)
    (setq-local quoth--session-reasoning-effort "high")
    (quoth--select-apply-defaults)
    (should (null quoth--session-thinking))
    (should (null quoth--session-reasoning-effort))))

(ert-deftest quoth-test/select-current-model-entry ()
  "`quoth--select-current-model-entry' finds the active model in a list."
  (let ((models (list '(:id "a" :name "A")
                      '(:id "b" :name "B"))))
    (should (string= (plist-get (quoth--select-current-model-entry models "a") :id) "a"))
    (should (null (quoth--select-current-model-entry models "z")))))

;;; 107. Conditional visibility predicates

(ert-deftest quoth-test/select-can-reason-p-with-reasoning-model ()
  "`quoth--select-can-reason-p' returns non-nil for a reasoning model.
The effective model comes from the buffer's session slot, so a model
with `:can-reason' t enables the predicate."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (quoth--session-model "m")
            (transient--original-buffer (current-buffer)))
        (cl-letf (((symbol-function 'quoth-provider-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'quoth-provider-models-cached)
                   (lambda (&rest _)
                     (list '(:id "m" :can-reason t
                                 :reasoning-levels ("low" "high"))))))
          (should (quoth--select-can-reason-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(ert-deftest quoth-test/select-can-reason-p-with-non-reasoning-model ()
  "`quoth--select-can-reason-p' returns nil for a non-reasoning model."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (transient--original-buffer (current-buffer)))
	(cl-letf (((symbol-function 'quoth-provider-p)
		   (lambda (&rest _) t))
		  ((symbol-function 'quoth-provider-models-cached)
		   (lambda (&rest _)
		     (list '(:id "m" :can-reason nil
				 :reasoning-levels nil))))
		  ((symbol-function 'quoth-provider-model)
		   (lambda (&rest _) "m")))
	  (should-not (quoth--select-can-reason-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(ert-deftest quoth-test/select-has-reasoning-levels-p-with-levels ()
  "`quoth--select-has-reasoning-levels-p' returns non-nil when levels exist.
The effective model comes from the buffer's session slot, so a model
with reasoning levels enables the predicate."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (quoth--session-model "m")
            (transient--original-buffer (current-buffer)))
        (cl-letf (((symbol-function 'quoth-provider-p)
                   (lambda (&rest _) t))
                  ((symbol-function 'quoth-provider-models-cached)
                   (lambda (&rest _)
                     (list '(:id "m" :can-reason t
                                 :reasoning-levels ("low" "high"))))))
          (should (quoth--select-has-reasoning-levels-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(ert-deftest quoth-test/select-has-reasoning-levels-p-without-levels ()
  "`quoth--select-has-reasoning-levels-p' returns nil when no levels."
  (let ((buf (generate-new-buffer " *quoth-test-pred*")))
    (with-current-buffer buf
      (let ((quoth-active-provider (make-quoth-provider))
            (transient--original-buffer (current-buffer)))
	(cl-letf (((symbol-function 'quoth-provider-p)
		   (lambda (&rest _) t))
		  ((symbol-function 'quoth-provider-models-cached)
		   (lambda (&rest _)
		     (list '(:id "m" :can-reason t
				 :reasoning-levels nil))))
		  ((symbol-function 'quoth-provider-model)
		   (lambda (&rest _) "m")))
	  (should-not (quoth--select-has-reasoning-levels-p)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(provide 'quoth-test-select)
;;; quoth-test-select.el ends here
